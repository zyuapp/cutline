import Foundation

/// Animates a text clip one character, word or line at a time.
///
/// Each unit enters at its own start: `index × stagger`, or the moment its word is spoken when
/// `sync` is on. Offsets are fractions of the font size with y pointing down.
public struct TextAnimator: Codable, Equatable, Hashable, Sendable {
    public enum Unit: String, Codable, Sendable, Hashable, CaseIterable {
        case char, word, line
    }

    public enum Preset: String, Codable, Sendable, Hashable, CaseIterable {
        /// Fades in.
        case fade
        /// Grows from 30% with an overshoot (its own back curve), fading in quickly.
        case pop
        /// Rises 0.6 font sizes into place while fading in.
        case slideUp = "slide_up"
        /// Drops 0.6 font sizes into place while fading in.
        case slideDown = "slide_down"
        /// Appears instantly at its start; with `char` units this types the text out.
        case typewriter
        /// Sharpens from a blur of 0.3 font sizes while fading in.
        case blurIn = "blur_in"
        /// Shrinks from 180% into place while fading in.
        case scaleIn = "scale_in"
        /// Always visible; turns `color` with a small bump for `duration` from its start, as the word is spoken.
        case highlight
        /// Falls from above and bounces to rest (its own bounce curve).
        case bounce
        /// Fades in, then bobs on a travelling wave with a 1 s period.
        case wave
    }

    public var unit: Unit
    public var preset: Preset
    /// Delay between consecutive units.
    public var stagger: Seconds
    /// Length of each unit's entrance, and of the exit.
    public var duration: Seconds
    public var ease: Easing
    /// Accent for `highlight`; yellow when nil.
    public var color: RGBA?
    /// Start each unit when its word is spoken instead of after a stagger.
    public var sync: Bool
    /// Exit played by all units together over the last `duration` of the clip.
    /// slide_up leaves upward, slide_down downward, scale_in grows away; typewriter, highlight and wave fade.
    public var out: Preset?

    public init(unit: Unit = .word, preset: Preset = .pop, stagger: Seconds = 0.06, duration: Seconds = 0.35, ease: Easing = .easeOut, color: RGBA? = nil, sync: Bool = false, out: Preset? = nil) {
        self.unit = unit
        self.preset = preset
        self.stagger = stagger
        self.duration = duration
        self.ease = ease
        self.color = color
        self.sync = sync
        self.out = out
    }

    enum CodingKeys: String, CodingKey { case unit, preset, stagger, duration, ease, color, sync, out }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextAnimator()
        unit = try c.decodeIfPresent(Unit.self, forKey: .unit) ?? d.unit
        preset = try c.decodeIfPresent(Preset.self, forKey: .preset) ?? d.preset
        stagger = try c.decodeIfPresent(Seconds.self, forKey: .stagger) ?? d.stagger
        duration = try c.decodeIfPresent(Seconds.self, forKey: .duration) ?? d.duration
        ease = try c.decodeIfPresent(Easing.self, forKey: .ease) ?? d.ease
        color = try c.decodeIfPresent(RGBA.self, forKey: .color)
        sync = try c.decodeIfPresent(Bool.self, forKey: .sync) ?? d.sync
        out = try c.decodeIfPresent(Preset.self, forKey: .out)
    }

    public static let defaultAccent = RGBA(r: 1, g: 0.839, b: 0.039)

    /// One unit's look at one moment, relative to its resting place.
    public struct UnitState: Equatable, Sendable {
        public var opacity: Double
        /// Offsets in font sizes; positive dy moves down.
        public var dx: Double
        public var dy: Double
        /// Scale about the unit's center.
        public var scale: Double
        /// Blur radius in font sizes.
        public var blur: Double
        /// Replaces the text color when set.
        public var color: RGBA?

        public init(opacity: Double = 1, dx: Double = 0, dy: Double = 0, scale: Double = 1, blur: Double = 0, color: RGBA? = nil) {
            self.opacity = opacity
            self.dx = dx
            self.dy = dy
            self.scale = scale
            self.blur = blur
            self.color = color
        }

        public static let rest = UnitState()
        public static let hidden = UnitState(opacity: 0)

        func combined(with o: UnitState) -> UnitState {
            UnitState(opacity: opacity * o.opacity, dx: dx + o.dx, dy: dy + o.dy, scale: scale * o.scale, blur: blur + o.blur, color: color ?? o.color)
        }
    }

    /// When unit `index` begins: its spoken time when synced and known, otherwise `index × stagger`.
    public func start(ofUnit index: Int, spoken: Seconds? = nil) -> Seconds {
        if sync, let spoken { return spoken }
        return Double(index) * stagger
    }

    /// The state of one unit at `local` seconds from the clip start.
    public static func state(_ a: TextAnimator, unitIndex: Int, unitStart: Seconds, local: Seconds, clipDuration: Seconds) -> UnitState {
        var s = enter(a, unitIndex: unitIndex, since: local - unitStart)
        if let out = a.out {
            let remaining = clipDuration - local
            if a.duration <= 0 {
                if remaining <= 0 { s.opacity = 0 }
            } else if remaining < a.duration {
                s = s.combined(with: leave(out, a, presence: max(0, remaining) / a.duration))
            }
        }
        return s
    }

    static func enter(_ a: TextAnimator, unitIndex: Int, since t: Seconds) -> UnitState {
        let d = a.duration
        if a.preset == .highlight {
            guard t >= 0, t < max(d, 1e-6) else { return .rest }
            let bump = sin(.pi * min(1, t / max(min(d, 0.25), 1e-6)))
            return UnitState(scale: 1 + 0.06 * bump, color: a.color ?? defaultAccent)
        }
        guard t >= 0 else { return .hidden }
        let p = d > 0 ? min(1, t / d) : 1
        let e = a.ease.apply(p)
        switch a.preset {
        case .fade: return UnitState(opacity: e)
        case .pop: return UnitState(opacity: min(1, p * 2.5), scale: 0.3 + 0.7 * Easing.back.apply(p))
        case .slideUp: return UnitState(opacity: e, dy: 0.6 * (1 - e))
        case .slideDown: return UnitState(opacity: e, dy: -0.6 * (1 - e))
        case .typewriter: return .rest
        case .blurIn: return UnitState(opacity: e, blur: 0.3 * (1 - e))
        case .scaleIn: return UnitState(opacity: e, scale: 1 + 0.8 * (1 - e))
        case .bounce: return UnitState(opacity: min(1, p * 4), dy: -0.9 * (1 - Easing.bounce.apply(p)))
        case .wave: return UnitState(opacity: e, dy: -0.15 * e * sin(2 * .pi * t + Double(unitIndex) * 0.6))
        case .highlight: return .rest
        }
    }

    /// `presence` runs from 1 when the exit starts to 0 at the clip end.
    static func leave(_ preset: Preset, _ a: TextAnimator, presence p: Double) -> UnitState {
        let e = a.ease.apply(p)
        switch preset {
        case .fade, .typewriter, .highlight, .wave: return UnitState(opacity: e)
        case .pop: return UnitState(opacity: min(1, p * 2.5), scale: 0.3 + 0.7 * Easing.back.apply(p))
        case .slideUp: return UnitState(opacity: e, dy: -0.6 * (1 - e))
        case .slideDown: return UnitState(opacity: e, dy: 0.6 * (1 - e))
        case .blurIn: return UnitState(opacity: e, blur: 0.3 * (1 - e))
        case .scaleIn: return UnitState(opacity: e, scale: 1 + 0.8 * (1 - e))
        case .bounce: return UnitState(opacity: e, dy: 0.9 * (1 - e))
        }
    }
}

extension TextSpec {
    /// Span styling that won't show as asked: spans that match nothing, and span colors that keep their characters
    /// out of a highlight animator's accent.
    public var spanWarnings: [String] {
        guard let spans, !spans.isEmpty else { return [] }
        var out: [String] = []
        for s in spans where s.ranges(in: text).isEmpty {
            out.append("span \(s.match.map { "“\($0)”" } ?? "\(s.from ?? 0)…\(s.to.map(String.init) ?? "end")") matches nothing in the text")
        }
        if let a = animator, a.preset == .highlight, spans.contains(where: { $0.color != nil }) {
            out.append("span colors stay on their characters, so the highlight animator's accent only colors the rest")
        }
        return out
    }
}
