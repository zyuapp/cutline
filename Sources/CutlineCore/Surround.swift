import Foundation

/// Channel layout of the mix. Surround channels are in SMPTE / ITU order.
public enum AudioLayout: String, Codable, Sendable, CaseIterable {
    case stereo
    case mono
    /// L R C LFE Ls Rs.
    case surround51
    /// L R C LFE Ls Rs Lrs Rrs.
    case surround71

    /// Accepts the raw names plus "5.1", "7.1", "2.0" and "1.0".
    public init?(name: String) {
        let aliases: [String: AudioLayout] = ["5.1": .surround51, "7.1": .surround71, "2.0": .stereo, "1.0": .mono]
        guard let l = AudioLayout(rawValue: name) ?? aliases[name] else { return nil }
        self = l
    }

    public var title: String {
        switch self {
        case .stereo: "stereo"
        case .mono: "mono"
        case .surround51: "5.1"
        case .surround71: "7.1"
        }
    }

    public var channelNames: [String] {
        switch self {
        case .stereo: ["L", "R"]
        case .mono: ["M"]
        case .surround51: ["L", "R", "C", "LFE", "Ls", "Rs"]
        case .surround71: ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]
        }
    }

    public var channelCount: Int { channelNames.count }
    public var isSurround: Bool { self == .surround51 || self == .surround71 }
    public var lfeChannel: Int? { isSurround ? 3 : nil }

    /// Speaker azimuth per channel in degrees, positive to the left of front; nil for LFE and mono.
    public var azimuths: [Double?] {
        switch self {
        case .stereo: [30, -30]
        case .mono: [nil]
        case .surround51: [30, -30, 0, nil, 110, -110]
        case .surround71: [30, -30, 0, nil, 110, -110, 150, -150]
        }
    }

    /// BS.1770-4 channel weights: 1.41 for speakers between 60° and 120° off front, 0 for LFE, else 1.
    public var loudnessWeights: [Double] {
        if self == .mono { return [1] }
        return azimuths.map { a in
            guard let a else { return 0 }
            return (60...120).contains(abs(a)) ? 1.41 : 1
        }
    }

    /// Fold-down matrix `[output][input]` from this layout to `target`. Downmixes follow ITU-R BS.775
    /// (centre and surrounds at −3 dB into L/R, LFE dropped); 7.1 rears fold into the 5.1 surrounds at −3 dB;
    /// mono is the average of the stereo fold. Upmixes place channels on the matching speakers only.
    public func downmixMatrix(to target: AudioLayout) -> [[Double]] {
        let h = 0.5.squareRoot()
        let n = channelCount
        func row(_ pairs: [(Int, Double)]) -> [Double] {
            var r = [Double](repeating: 0, count: n)
            for (i, g) in pairs where i < n { r[i] += g }
            return r
        }
        if target == self { return (0..<n).map { row([($0, 1)]) } }
        switch (self, target) {
        case (.mono, _):
            return target == .stereo ? [[1], [1]] : (0..<target.channelCount).map { $0 == 2 ? [1] : [0] }
        case (_, .mono):
            let st = downmixMatrix(to: .stereo)
            return [zip(st[0], st[1]).map { 0.5 * ($0 + $1) }]
        case (.stereo, _):
            return (0..<target.channelCount).map { $0 < 2 ? row([($0, 1)]) : row([]) }
        case (.surround51, .stereo):
            return [row([(0, 1), (2, h), (4, h)]), row([(1, 1), (2, h), (5, h)])]
        case (.surround71, .stereo):
            return [row([(0, 1), (2, h), (4, h), (6, h)]), row([(1, 1), (2, h), (5, h), (7, h)])]
        case (.surround71, .surround51):
            return [row([(0, 1)]), row([(1, 1)]), row([(2, 1)]), row([(3, 1)]), row([(4, 1), (6, h)]), row([(5, 1), (7, h)])]
        case (.surround51, .surround71):
            return (0..<8).map { $0 < 6 ? row([($0, 1)]) : row([]) }
        default:
            return (0..<target.channelCount).map { row([($0, 1)]) }
        }
    }
}

/// Where a clip sits in a surround mix. Applies when the master layout is 5.1 or 7.1.
public struct SurroundPan: Codable, Equatable, Hashable, Sendable {
    /// −1 left … 1 right.
    public var x: Double
    /// −1 back … 1 front.
    public var y: Double
    /// Share of a front-center image given to the C speaker; 0 makes a phantom center from L and R.
    public var center: Double
    /// Send to the LFE channel, low-passed at 120 Hz.
    public var lfe: Double

    public static let standard = SurroundPan()

    public init(x: Double = 0, y: Double = 1, center: Double = 1, lfe: Double = 0) {
        self.x = x
        self.y = y
        self.center = center
        self.lfe = lfe
    }

    enum CodingKeys: String, CodingKey { case x, y, center, lfe }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 1
        center = try c.decodeIfPresent(Double.self, forKey: .center) ?? 1
        lfe = try c.decodeIfPresent(Double.self, forKey: .lfe) ?? 0
    }
}

/// Constant-power VBAP panning across a layout's speaker ring.
///
/// The pan field is a square: its front edge runs L (30°) → C → R (−30°), its sides run from the front
/// speakers back to the rearmost surrounds (Ls/Rs in 5.1, Lrs/Rrs in 7.1), and its back edge passes behind
/// the listener. A point inside the square is panned toward the edge point in its direction and spread over
/// every speaker as it nears the middle (the middle itself feeds all speakers equally).
public enum SurroundPanner {
    /// Gains per channel (LFE 0) whose squares sum to 1.
    public static func gains(x: Double, y: Double, center: Double = 1, layout: AudioLayout) -> [Double] {
        let n = layout.channelCount
        switch layout {
        case .mono: return [1]
        case .stereo:
            let theta = (min(max(x, -1), 1) + 1) * .pi / 4
            return [cos(theta), sin(theta)]
        default: break
        }
        let ring = layout.azimuths.enumerated().compactMap { i, a in a.map { (i, $0) } }
        let x = min(max(x, -1), 1), y = min(max(y, -1), 1)
        let r = max(abs(x), abs(y))
        let omni = 1 / Double(ring.count)
        guard r > 1e-9 else { return layout.azimuths.map { $0 == nil ? 0 : omni.squareRoot() } }
        let back = ring.map { abs($0.1) }.max() ?? 110
        let az = azimuth(px: x / r, py: y / r, back: back)
        let withC = vbap(az, ring, n)
        let c = min(max(center, 0), 1)
        var dir = withC
        if c < 1 {
            let withoutC = vbap(az, ring.filter { $0.1 != 0 }, n)
            dir = zip(withC, withoutC).map { (c * $0 * $0 + (1 - c) * $1 * $1).squareRoot() }
        }
        return (0..<n).map { i in
            guard layout.azimuths[i] != nil else { return 0 }
            return (r * r * dir[i] * dir[i] + (1 - r * r) * omni).squareRoot()
        }
    }

    /// Gains for the two channels of a stereo source: its left channel sits at `x − 1`, its right at `x + 1`.
    public static func pairGains(x: Double, y: Double, center: Double = 1, layout: AudioLayout) -> (left: [Double], right: [Double]) {
        (gains(x: max(x - 1, -1), y: y, center: center, layout: layout), gains(x: min(x + 1, 1), y: y, center: center, layout: layout))
    }

    /// Azimuth in degrees of a point on the edge of the pan square.
    static func azimuth(px: Double, py: Double, back: Double) -> Double {
        let front = 30.0
        if abs(py) >= abs(px) {
            return py > 0 ? -front * px : back + (180 - back) * (px + 1)
        }
        let side = front + (back - front) * (1 - py) / 2
        return px < 0 ? side : -side
    }

    /// Pairwise 2D VBAP over `ring` (channel, azimuth), normalized to unit power.
    static func vbap(_ az: Double, _ ring: [(Int, Double)], _ n: Int) -> [Double] {
        func norm(_ a: Double) -> Double { let m = a.truncatingRemainder(dividingBy: 360); return m < 0 ? m + 360 : m }
        let sorted = ring.map { ($0.0, norm($0.1)) }.sorted { $0.1 < $1.1 }
        var out = [Double](repeating: 0, count: n)
        let a = norm(az)
        for k in sorted.indices {
            let (i1, a1) = sorted[k], (i2, a2) = sorted[(k + 1) % sorted.count]
            let span = norm(a2 - a1), offset = norm(a - a1)
            guard offset <= span + 1e-9, span > 0 else { continue }
            let r1 = a1 * .pi / 180, r2 = a2 * .pi / 180, rp = a * .pi / 180
            let det = cos(r1) * sin(r2) - sin(r1) * cos(r2)
            var g1 = (cos(rp) * sin(r2) - sin(rp) * cos(r2)) / det
            var g2 = (sin(rp) * cos(r1) - cos(rp) * sin(r1)) / det
            g1 = max(0, g1)
            g2 = max(0, g2)
            let p = (g1 * g1 + g2 * g2).squareRoot()
            out[i1] = g1 / p
            out[i2] = g2 / p
            return out
        }
        return out
    }
}
