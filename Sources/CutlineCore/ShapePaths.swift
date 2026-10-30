import Foundation

public struct PathPoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    static func + (a: PathPoint, b: PathPoint) -> PathPoint { PathPoint(a.x + b.x, a.y + b.y) }
    static func - (a: PathPoint, b: PathPoint) -> PathPoint { PathPoint(a.x - b.x, a.y - b.y) }
    static func * (a: PathPoint, s: Double) -> PathPoint { PathPoint(a.x * s, a.y * s) }
    var length: Double { hypot(x, y) }

    func lerp(_ b: PathPoint, _ t: Double) -> PathPoint { PathPoint(x + (b.x - x) * t, y + (b.y - y) * t) }
}

/// A vector path made of contours of lines and cubic curves, in y-down coordinates.
public struct ShapePath: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case line(PathPoint)
        case cubic(PathPoint, PathPoint, PathPoint)

        public var end: PathPoint {
            switch self {
            case .line(let p): p
            case .cubic(_, _, let p): p
            }
        }
    }

    public struct Contour: Equatable, Sendable {
        public var start: PathPoint
        public var segments: [Segment]
        public var closed: Bool

        public init(start: PathPoint, segments: [Segment] = [], closed: Bool = false) {
            self.start = start
            self.segments = segments
            self.closed = closed
        }
    }

    public var contours: [Contour]

    public init(_ contours: [Contour] = []) {
        self.contours = contours
    }

    public var isEmpty: Bool { contours.allSatisfy { $0.segments.isEmpty } }

    /// Every on- and off-curve point.
    public var allPoints: [PathPoint] {
        contours.flatMap { c in
            [c.start] + c.segments.flatMap { s -> [PathPoint] in
                switch s {
                case .line(let p): [p]
                case .cubic(let a, let b, let p): [a, b, p]
                }
            }
        }
    }

    /// Bounds of every point, control points included.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let pts = allPoints
        guard let f = pts.first else { return nil }
        var b = (minX: f.x, minY: f.y, maxX: f.x, maxY: f.y)
        for p in pts {
            b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x)
            b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y)
        }
        return b
    }

    public func mapped(_ f: (PathPoint) -> PathPoint) -> ShapePath {
        ShapePath(contours.map { c in
            Contour(start: f(c.start), segments: c.segments.map { s in
                switch s {
                case .line(let p): .line(f(p))
                case .cubic(let a, let b, let p): .cubic(f(a), f(b), f(p))
                }
            }, closed: c.closed)
        })
    }

    // MARK: Primitives (centered on the origin, starting at the top and running clockwise)

    static let kappa = 0.5522847498307936

    public static func rect(width w: Double, height h: Double, radius: Double) -> ShapePath {
        let x0 = -w / 2, x1 = w / 2, y0 = -h / 2, y1 = h / 2
        let r = max(0, min(radius, min(w, h) / 2))
        guard r > 1e-9 else {
            return ShapePath([Contour(start: PathPoint(x0, y0), segments: [.line(PathPoint(x1, y0)), .line(PathPoint(x1, y1)), .line(PathPoint(x0, y1)), .line(PathPoint(x0, y0))], closed: true)])
        }
        let k = r * (1 - kappa)
        var s: [Segment] = []
        s.append(.line(PathPoint(x1 - r, y0)))
        s.append(.cubic(PathPoint(x1 - k, y0), PathPoint(x1, y0 + k), PathPoint(x1, y0 + r)))
        s.append(.line(PathPoint(x1, y1 - r)))
        s.append(.cubic(PathPoint(x1, y1 - k), PathPoint(x1 - k, y1), PathPoint(x1 - r, y1)))
        s.append(.line(PathPoint(x0 + r, y1)))
        s.append(.cubic(PathPoint(x0 + k, y1), PathPoint(x0, y1 - k), PathPoint(x0, y1 - r)))
        s.append(.line(PathPoint(x0, y0 + r)))
        s.append(.cubic(PathPoint(x0, y0 + k), PathPoint(x0 + k, y0), PathPoint(x0 + r, y0)))
        return ShapePath([Contour(start: PathPoint(x0 + r, y0), segments: s, closed: true)])
    }

    public static func ellipse(width w: Double, height h: Double) -> ShapePath {
        let rx = w / 2, ry = h / 2, kx = rx * kappa, ky = ry * kappa
        return ShapePath([Contour(start: PathPoint(0, -ry), segments: [
            .cubic(PathPoint(kx, -ry), PathPoint(rx, -ky), PathPoint(rx, 0)),
            .cubic(PathPoint(rx, ky), PathPoint(kx, ry), PathPoint(0, ry)),
            .cubic(PathPoint(-kx, ry), PathPoint(-rx, ky), PathPoint(-rx, 0)),
            .cubic(PathPoint(-rx, -ky), PathPoint(-kx, -ry), PathPoint(0, -ry)),
        ], closed: true)])
    }

    /// Regular polygon (inner nil) or star with points on an ellipse of the given size.
    public static func polygon(width w: Double, height h: Double, sides: Int, inner: Double? = nil, roundness: Double = 0) -> ShapePath {
        let n = max(3, sides)
        var pts: [PathPoint] = []
        let count = inner == nil ? n : n * 2
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi
            let r = inner != nil && i % 2 == 1 ? inner! : 1
            pts.append(PathPoint(sin(a) * w / 2 * r, -cos(a) * h / 2 * r))
        }
        guard roundness > 0 else {
            return ShapePath([Contour(start: pts[0], segments: pts.dropFirst().map { .line($0) } + [.line(pts[0])], closed: true)])
        }
        // Each corner becomes a curve between points `roundness` of the way along its edges.
        let f = min(roundness, 1) * 0.5
        var segs: [Segment] = []
        func corner(_ i: Int) -> (PathPoint, PathPoint, PathPoint) {
            let p = pts[i], prev = pts[(i + count - 1) % count], next = pts[(i + 1) % count]
            return (p.lerp(prev, f), p, p.lerp(next, f))
        }
        let first = corner(0)
        for i in 1...count {
            let (a, p, b) = corner(i % count)
            segs.append(.line(a))
            segs.append(.cubic(a.lerp(p, 0.55), b.lerp(p, 0.55), b))
        }
        return ShapePath([Contour(start: first.2, segments: segs, closed: true)])
    }

    public static func line(length: Double) -> ShapePath {
        ShapePath([Contour(start: PathPoint(-length / 2, 0), segments: [.line(PathPoint(length / 2, 0))])])
    }
}

// MARK: SVG path data

extension ShapePath {
    /// Parses SVG path data (M L H V C S Q T A Z, absolute and relative).
    public static func svg(_ d: String) throws -> ShapePath {
        var tokens: [Character] = Array(d)
        var i = 0
        func skip() { while i < tokens.count, tokens[i].isWhitespace || tokens[i] == "," { i += 1 } }
        func number() throws -> Double {
            skip()
            var s = ""
            if i < tokens.count, tokens[i] == "-" || tokens[i] == "+" { s.append(tokens[i]); i += 1 }
            var dot = false, exp = false
            while i < tokens.count {
                let c = tokens[i]
                if c.isNumber { s.append(c) }
                else if c == ".", !dot, !exp { dot = true; s.append(c) }
                else if c == "e" || c == "E", !exp, !s.isEmpty { exp = true; s.append(c); if i + 1 < tokens.count, tokens[i + 1] == "-" || tokens[i + 1] == "+" { i += 1; s.append(tokens[i]) } }
                else { break }
                i += 1
            }
            guard let v = Double(s) else { throw EditError("SVG path: expected a number near character \(i) of \"\(d.prefix(60))\"") }
            return v
        }
        func flag() throws -> Bool {
            skip()
            guard i < tokens.count, tokens[i] == "0" || tokens[i] == "1" else { throw EditError("SVG path: arc flags are 0 or 1") }
            i += 1
            return tokens[i - 1] == "1"
        }
        func hasNumber() -> Bool {
            skip()
            guard i < tokens.count else { return false }
            let c = tokens[i]
            return c.isNumber || c == "-" || c == "+" || c == "."
        }
        tokens.append(" ")
        var contours: [Contour] = []
        var cur: Contour?
        var pen = PathPoint(0, 0)
        var lastCtrl: PathPoint?
        var lastQuad: PathPoint?
        var cmd: Character = " "
        func finish() {
            if let c = cur, !c.segments.isEmpty { contours.append(c) }
            cur = nil
        }
        func ensure() { if cur == nil { cur = Contour(start: pen) } }
        while true {
            skip()
            guard i < tokens.count - 1 else { break }
            if tokens[i].isLetter, tokens[i] != "e", tokens[i] != "E" {
                cmd = tokens[i]
                i += 1
            } else if cmd == " " {
                throw EditError("SVG path must start with a command such as M, got \"\(d.prefix(20))\"")
            }
            if contours.isEmpty, cur == nil, cmd != "M", cmd != "m" { throw EditError("SVG path data starts with M (move to), got \"\(d.prefix(20))\"") }
            let rel = cmd.isLowercase
            let base = rel ? pen : PathPoint(0, 0)
            func pt() throws -> PathPoint { let x = try number(); let y = try number(); return base + PathPoint(x, y) }
            var nextCtrl: PathPoint?
            var nextQuad: PathPoint?
            switch cmd.uppercased().first! {
            case "M":
                finish()
                pen = try pt()
                cur = Contour(start: pen)
                cmd = rel ? "l" : "L"
            case "L":
                ensure(); pen = try pt(); cur!.segments.append(.line(pen))
            case "H":
                ensure(); pen = PathPoint((rel ? pen.x : 0) + (try number()), pen.y); cur!.segments.append(.line(pen))
            case "V":
                ensure(); pen = PathPoint(pen.x, (rel ? pen.y : 0) + (try number())); cur!.segments.append(.line(pen))
            case "C":
                ensure()
                let a = try pt(), b = try pt(), p = try pt()
                cur!.segments.append(.cubic(a, b, p)); pen = p; nextCtrl = b
            case "S":
                ensure()
                let a = lastCtrl.map { pen * 2 - $0 } ?? pen
                let b = try pt(), p = try pt()
                cur!.segments.append(.cubic(a, b, p)); pen = p; nextCtrl = b
            case "Q":
                ensure()
                let q = try pt(), p = try pt()
                cur!.segments.append(.cubic(pen.lerp(q, 2.0 / 3), p.lerp(q, 2.0 / 3), p)); pen = p; nextQuad = q
            case "T":
                ensure()
                let q = lastQuad.map { pen * 2 - $0 } ?? pen
                let p = try pt()
                cur!.segments.append(.cubic(pen.lerp(q, 2.0 / 3), p.lerp(q, 2.0 / 3), p)); pen = p; nextQuad = q
            case "A":
                ensure()
                let rx = try number(), ry = try number(), rot = try number()
                let large = try flag(), sweep = try flag()
                let p = try pt()
                cur!.segments += ShapePath.arc(from: pen, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                pen = p
            case "Z":
                if var c = cur {
                    if (pen - c.start).length > 1e-9 { c.segments.append(.line(c.start)) }
                    c.closed = true
                    pen = c.start
                    cur = c
                    finish()
                }
                cmd = " "
                continue
            default:
                throw EditError("SVG path: unknown command \(cmd)")
            }
            lastCtrl = nextCtrl
            lastQuad = nextQuad
            if !hasNumber(), i < tokens.count - 1, !(tokens[i].isLetter) { throw EditError("SVG path: unexpected \"\(tokens[i])\"") }
        }
        finish()
        guard !contours.isEmpty else { throw EditError("SVG path has no drawable segments: \"\(d.prefix(40))\"") }
        return ShapePath(contours)
    }

    /// SVG elliptical arc as cubic curves (SVG implementation notes F.6).
    static func arc(from p0: PathPoint, to p1: PathPoint, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool) -> [Segment] {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 1e-12, ry > 1e-12, (p1 - p0).length > 1e-12 else { return [.line(p1)] }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var co = sqrt(max(0, num / den))
        if large == sweep { co = -co }
        let cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2, cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let n = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(n)
        let k = 4.0 / 3 * tan(step / 4)
        func point(_ a: Double) -> PathPoint {
            PathPoint(cx + rx * cos(a) * cp - ry * sin(a) * sp, cy + rx * cos(a) * sp + ry * sin(a) * cp)
        }
        func deriv(_ a: Double) -> PathPoint {
            PathPoint(-rx * sin(a) * cp - ry * cos(a) * sp, -rx * sin(a) * sp + ry * cos(a) * cp)
        }
        var out: [Segment] = []
        var a = theta
        for j in 0..<n {
            let b = a + step
            let pa = point(a), pb = j == n - 1 ? p1 : point(b)
            out.append(.cubic(pa + deriv(a) * k, pb - deriv(b) * k, pb))
            a = b
        }
        return out
    }
}

// MARK: Length, trimming and morphing

extension ShapePath {
    static func cubicPoint(_ p0: PathPoint, _ a: PathPoint, _ b: PathPoint, _ p1: PathPoint, _ t: Double) -> PathPoint {
        let u = 1 - t
        return p0 * (u * u * u) + a * (3 * u * u * t) + b * (3 * u * t * t) + p1 * (t * t * t)
    }

    /// Cumulative arc length at evenly spaced parameters of a cubic.
    static func cubicTable(_ p0: PathPoint, _ a: PathPoint, _ b: PathPoint, _ p1: PathPoint) -> [Double] {
        let n = 48
        var acc = [0.0]
        var last = p0
        for i in 1...n {
            let q = cubicPoint(p0, a, b, p1, Double(i) / Double(n))
            acc.append(acc.last! + (q - last).length)
            last = q
        }
        return acc
    }

    /// The parameter at which a cubic has covered `s` of its length.
    static func parameter(_ table: [Double], at s: Double) -> Double {
        let total = table.last!
        guard total > 0 else { return 0 }
        let s = min(max(s, 0), total)
        var lo = 0, hi = table.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if table[mid] < s { lo = mid } else { hi = mid }
        }
        let seg = table[hi] - table[lo]
        let f = seg > 0 ? (s - table[lo]) / seg : 0
        return (Double(lo) + f) / Double(table.count - 1)
    }

    /// The part of a cubic between parameters t0 and t1.
    static func subCubic(_ p0: PathPoint, _ a: PathPoint, _ b: PathPoint, _ p1: PathPoint, _ t0: Double, _ t1: Double) -> (PathPoint, PathPoint, PathPoint, PathPoint) {
        func split(_ p0: PathPoint, _ a: PathPoint, _ b: PathPoint, _ p1: PathPoint, _ t: Double) -> (left: (PathPoint, PathPoint, PathPoint, PathPoint), right: (PathPoint, PathPoint, PathPoint, PathPoint)) {
            let ab = p0.lerp(a, t), bc = a.lerp(b, t), cd = b.lerp(p1, t)
            let abc = ab.lerp(bc, t), bcd = bc.lerp(cd, t)
            let m = abc.lerp(bcd, t)
            return ((p0, ab, abc, m), (m, bcd, cd, p1))
        }
        let left = t1 < 1 ? split(p0, a, b, p1, t1).left : (p0, a, b, p1)
        guard t0 > 0, t1 > 0 else { return left }
        return split(left.0, left.1, left.2, left.3, t0 / t1).right
    }

    struct Measured {
        var from: PathPoint
        var seg: Segment
        var length: Double
        var table: [Double]?
    }

    static func measure(_ c: Contour) -> [Measured] {
        var out: [Measured] = []
        var pen = c.start
        for s in c.segments {
            switch s {
            case .line(let p):
                out.append(Measured(from: pen, seg: s, length: (p - pen).length))
            case .cubic(let a, let b, let p):
                let t = cubicTable(pen, a, b, p)
                out.append(Measured(from: pen, seg: s, length: t.last!, table: t))
            }
            pen = s.end
        }
        if c.closed, (pen - c.start).length > 1e-9 { out.append(Measured(from: pen, seg: .line(c.start), length: (c.start - pen).length)) }
        return out
    }

    public var length: Double { contours.reduce(0) { $0 + ShapePath.measure($1).reduce(0) { $0 + $1.length } } }

    /// The stretch of a contour between arc lengths s0 ≤ s1.
    static func piece(_ m: [Measured], _ s0: Double, _ s1: Double) -> Contour? {
        var out: Contour?
        var acc = 0.0
        for item in m {
            let a = acc, b = acc + item.length
            acc = b
            guard b > s0 + 1e-12, a < s1 - 1e-12, item.length > 0 else { continue }
            let u0 = max(0, s0 - a), u1 = min(item.length, s1 - a)
            switch item.seg {
            case .line(let p):
                let q0 = item.from.lerp(p, u0 / item.length), q1 = item.from.lerp(p, u1 / item.length)
                if out == nil { out = Contour(start: q0) }
                out!.segments.append(.line(q1))
            case .cubic(let ca, let cb, let p):
                let t0 = parameter(item.table!, at: u0), t1 = parameter(item.table!, at: u1)
                let sub = subCubic(item.from, ca, cb, p, t0, t1)
                if out == nil { out = Contour(start: sub.0) }
                out!.segments.append(.cubic(sub.1, sub.2, sub.3))
            }
        }
        return out
    }

    /// Trim paths: keeps the stretch from `start` to `end` (fractions of each contour's length), shifted by
    /// `offset` and wrapping around closed contours.
    public func trimmed(start: Double, end: Double, offset: Double = 0) -> ShapePath {
        var s = min(start, end), e = max(start, end)
        s = min(max(s, 0), 1)
        e = min(max(e, 0), 1)
        if s <= 1e-9 && e >= 1 - 1e-9 { return self }
        guard e - s > 1e-9 else { return ShapePath() }
        let off = offset - offset.rounded(.down)
        var out: [Contour] = []
        for c in contours {
            let m = ShapePath.measure(c)
            let total = m.reduce(0) { $0 + $1.length }
            guard total > 0 else { continue }
            var a = s + off, b = e + off
            if a >= 1 { a -= 1; b -= 1 }
            if b <= 1 {
                if let p = ShapePath.piece(m, a * total, b * total) { out.append(p) }
            } else if var first = ShapePath.piece(m, a * total, total) {
                // Runs past the end: closed contours continue from the start in one stroke.
                if let rest = ShapePath.piece(m, 0, (b - 1) * total) {
                    if c.closed { first.segments += rest.segments } else { out.append(rest) }
                }
                out.append(first)
            }
        }
        return ShapePath(out)
    }

    /// The same contours with every segment as a cubic, so two paths with matching segment counts can blend.
    public var asCubics: ShapePath {
        ShapePath(contours.map { c in
            var pen = c.start
            var segs: [Segment] = []
            for s in c.segments {
                switch s {
                case .line(let p): segs.append(.cubic(pen.lerp(p, 1.0 / 3), pen.lerp(p, 2.0 / 3), p))
                case .cubic: segs.append(s)
                }
                pen = s.end
            }
            return Contour(start: c.start, segments: segs, closed: c.closed)
        })
    }

    /// Whether `morph(to:)` can blend the two paths.
    public func morphs(with other: ShapePath) -> Bool {
        contours.count == other.contours.count && zip(contours, other.contours).allSatisfy { $0.segments.count == $1.segments.count }
    }

    /// Point-by-point blend toward `other`; nil when their contours or segment counts differ.
    public func morph(to other: ShapePath, _ t: Double) -> ShapePath? {
        guard morphs(with: other) else { return nil }
        if t <= 0 { return self }
        if t >= 1 { return other }
        let a = asCubics, b = other.asCubics
        return ShapePath(zip(a.contours, b.contours).map { ca, cb in
            Contour(start: ca.start.lerp(cb.start, t), segments: zip(ca.segments, cb.segments).map { sa, sb in
                guard case .cubic(let a1, let a2, let ap) = sa, case .cubic(let b1, let b2, let bp) = sb else { return sa }
                return .cubic(a1.lerp(b1, t), a2.lerp(b2, t), ap.lerp(bp, t))
            }, closed: ca.closed || cb.closed)
        })
    }
}
