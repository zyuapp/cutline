import Foundation

/// Procedural motion evaluated with a curve: its keys (looped if asked), plus a steady rate and a wiggle.
public struct CurveExpression: Codable, Equatable, Hashable, Sendable {
    public enum Loop: String, Codable, Sendable, CaseIterable {
        /// Repeats the keys from the first to the last.
        case cycle
        /// Plays the keys forwards, then backwards.
        case pingpong
    }

    public var loop: Loop?
    /// Added per second since `origin` (AE `time * k`).
    public var rate: Double?
    /// Wiggles per second and their size, in the parameter's own units.
    public var wiggleFreq: Double?
    public var wiggleAmp: Double?
    public var wiggleOctaves: Int?
    public var seed: UInt64
    /// Clip-local time the expression's clock reads zero.
    public var origin: Seconds
    /// Range the result is clamped to, from the parameter's spec.
    public var lo: Double?
    public var hi: Double?

    public init(loop: Loop? = nil, rate: Double? = nil, wiggleFreq: Double? = nil, wiggleAmp: Double? = nil, wiggleOctaves: Int? = nil, seed: UInt64 = 0, origin: Seconds = 0, lo: Double? = nil, hi: Double? = nil) {
        self.loop = loop
        self.rate = rate
        self.wiggleFreq = wiggleFreq
        self.wiggleAmp = wiggleAmp
        self.wiggleOctaves = wiggleOctaves
        self.seed = seed
        self.origin = origin
        self.lo = lo
        self.hi = hi
    }

    /// The key time `t` reads after looping past the last key.
    public func loopedTime(_ t: Seconds, keys: [CurveKey]) -> Seconds {
        guard let loop, let a = keys.first?.t, let b = keys.last?.t, b - a > 1e-6, t > b else { return t }
        let span = b - a
        let u = (t - a) / span
        let whole = u.rounded(.down)
        let f = u - whole
        switch loop {
        case .cycle: return a + f * span
        case .pingpong: return Int(whole) % 2 == 0 ? a + f * span : b - f * span
        }
    }

    public func apply(_ curve: Curve, at t: Seconds) -> ParamValue? {
        guard let v = curve.keyed(at: loopedTime(t, keys: curve.keys)) else { return nil }
        guard case .number(var n) = v else { return v }
        let clock = t - origin
        if let rate { n += rate * clock }
        if let f = wiggleFreq, let a = wiggleAmp, f > 0, a != 0 {
            n += a * StableRandom.fractal(seed, clock * f, octaves: wiggleOctaves ?? 1)
        }
        if let lo { n = max(lo, n) }
        if let hi { n = min(hi, n) }
        return .number(n)
    }

    public var summary: String {
        var parts: [String] = []
        if let loop { parts.append("loop \(loop.rawValue)") }
        if let rate { parts.append("+\(ParamValue.number(rate))/s") }
        if let f = wiggleFreq, let a = wiggleAmp { parts.append("wiggle \(ParamValue.number(f))/s ±\(ParamValue.number(a))") }
        return parts.joined(separator: ", ")
    }
}

/// Follows another clip's parameter: value × scale + offset, `delay` seconds later on the timeline.
public struct CurveLink: Codable, Equatable, Hashable, Sendable {
    public var clip: String
    public var path: String
    public var scale: Double
    public var offset: Double
    public var delay: Seconds

    public init(clip: String, path: String, scale: Double = 1, offset: Double = 0, delay: Seconds = 0) {
        self.clip = clip
        self.path = path
        self.scale = scale
        self.offset = offset
        self.delay = delay
    }
}

extension Clip {
    /// Paths that render from keys alone, outside the picture compositor.
    static func refusesExpressions(_ path: String) -> Bool {
        path == "time.speed" || path.hasPrefix("audio.")
    }

    /// The curve an expression attaches to: the existing animation, or one key holding the current value.
    mutating func expressionCurve(_ rawPath: String, numeric: Bool = true) throws -> (String, ParamSpec, Curve) {
        let path = Clip.canonical(rawPath)
        let spec = try spec(path)
        guard spec.animatable else { throw EditError("\(path) can't be animated, so it takes no expression") }
        guard !Clip.refusesExpressions(path) else { throw EditError("\(path) is rendered from its keys alone; animate it with keys instead") }
        if numeric, spec.kind != .number { throw EditError("\(path) is a \(spec.kind.label); wiggle and rate need a number") }
        let curve = anim[path] ?? Curve(keys: [CurveKey(t: 0, v: staticValue(path) ?? spec.defaultValue, ease: .linear)])
        return (path, spec, curve)
    }

    /// Adds smooth random motion of ±`amp` around the parameter's value or animation.
    public mutating func wiggle(_ rawPath: String, freq: Double, amp: Double, octaves: Int = 1, seed: UInt64? = nil) throws {
        guard freq > 0, freq <= 120 else { throw EditError("wiggle freq is wiggles per second, 0…120") }
        var (path, spec, curve) = try expressionCurve(rawPath)
        var x = curve.expression ?? CurveExpression(lo: spec.min, hi: spec.max)
        x.wiggleFreq = freq
        x.wiggleAmp = amp
        x.wiggleOctaves = octaves > 1 ? min(octaves, 8) : nil
        x.seed = seed ?? StableRandom.hash("\(id).\(path)")
        curve.expression = x
        anim[path] = curve
    }

    /// Adds `rate` per second since the clip start.
    public mutating func addRate(_ rawPath: String, rate: Double) throws {
        var (path, spec, curve) = try expressionCurve(rawPath)
        var x = curve.expression ?? CurveExpression(lo: spec.min, hi: spec.max)
        x.rate = rate == 0 ? nil : rate
        curve.expression = x
        anim[path] = curve
    }

    /// Repeats the parameter's keys after the last one.
    public mutating func loop(_ rawPath: String, _ mode: CurveExpression.Loop?) throws {
        var (path, spec, curve) = try expressionCurve(rawPath, numeric: false)
        if mode != nil { guard curve.keys.count >= 2, curve.keys.last!.t - curve.keys.first!.t > 1e-3 else { throw EditError("loop repeats keys; animate \(path) with at least two keys first") } }
        var x = curve.expression ?? CurveExpression(lo: spec.min, hi: spec.max)
        x.loop = mode
        curve.expression = x
        anim[path] = curve
    }
}

extension Project {
    /// Keys of a linked parameter, derived from its source clip.
    func linkedKeys(_ link: CurveLink, into c: Clip, spec: ParamSpec) -> [CurveKey]? {
        guard let src = clip(link.clip), link.clip != c.id else { return nil }
        let path = Clip.canonical(link.path)
        func map(_ v: ParamValue) -> ParamValue {
            guard case .number(let n) = v else { return v }
            var m = n * link.scale + link.offset
            if let lo = spec.min { m = max(lo, m) }
            if let hi = spec.max { m = min(hi, m) }
            return .number(m)
        }
        let shift = src.start + link.delay - c.start
        if let curve = src.anim[path], curve.expression == nil {
            return curve.keys.map { k in var k = k; k.t += shift; k.v = map(k.v); return k }
        }
        if src.anim[path] != nil {
            let step = canvas.frameDuration
            return stride(from: 0.0, through: c.duration + step / 2, by: step).compactMap { t in
                src.value(path, at: t - shift).map { CurveKey(t: t, v: map($0), ease: .linear) }
            }
        }
        return src.staticValue(path).map { [CurveKey(t: 0, v: map($0), ease: .linear)] }
    }

    /// Links a parameter of `c` to another clip's parameter and fills in its keys.
    public func link(_ c: inout Clip, path rawPath: String, to link: CurveLink) throws {
        guard let src = clip(link.clip) else { throw EditError("No clip \(link.clip) to link to") }
        guard link.clip != c.id else { throw EditError("A parameter can't link to its own clip; use loop or rate") }
        let path = Clip.canonical(rawPath)
        let spec = try c.spec(path)
        guard spec.animatable, !Clip.refusesExpressions(path) else { throw EditError("\(path) can't follow another parameter") }
        let srcSpec = try src.spec(Clip.canonical(link.path))
        guard (spec.kind == .number) == (srcSpec.kind == .number) else { throw EditError("\(path) is a \(spec.kind.label) but \(link.clip).\(link.path) is a \(srcSpec.kind.label)") }
        var normalized = link
        normalized.path = Clip.canonical(link.path)
        var curve = Curve(keys: linkedKeys(normalized, into: c, spec: spec) ?? [])
        curve.link = normalized
        c.anim[path] = curve
    }

    /// Points links among copied clips at the copies, by old id → new id.
    public mutating func relink(_ ids: [String: String]) {
        let copies = Set(ids.values)
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices where copies.contains(tracks[ti].clips[ci].id) {
                for (path, curve) in tracks[ti].clips[ci].anim {
                    guard let link = curve.link, let to = ids[link.clip] else { continue }
                    tracks[ti].clips[ci].anim[path]?.link?.clip = to
                }
            }
        }
        refreshLinks()
    }

    /// Recomputes every linked parameter from its source, following chains of links.
    public mutating func refreshLinks() {
        for _ in 0..<4 {
            var changed = false
            for ti in tracks.indices {
                for ci in tracks[ti].clips.indices {
                    let c = tracks[ti].clips[ci]
                    for (path, curve) in c.anim {
                        guard let link = curve.link, let spec = try? c.spec(path), let keys = linkedKeys(link, into: c, spec: spec), keys != curve.keys else { continue }
                        tracks[ti].clips[ci].anim[path]?.keys = keys
                        changed = true
                    }
                }
            }
            if !changed { return }
        }
    }
}
