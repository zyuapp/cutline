import Foundation

/// How a sky replacement relights the foreground: color.wheels gains that move its highlights from the light of the
/// old sky toward the new sky's horizon.
public enum SkyMatch {
    /// Gains for color.wheels from the old sky's and the new horizon's mean display colors. `blend` 0 leaves the
    /// foreground alone, 1 is the full match; the color shift and the brightness change are each limited.
    public static func gains(oldSky: SIMD3<Double>, newHorizon: SIMD3<Double>, blend: Double) -> [String: Double] {
        let b = min(max(blend, 0), 1)
        func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        let lumaRatio = max(luma(newHorizon), 0.02) / max(luma(oldSky), 0.02)
        var out: [String: Double] = [:]
        out["gain"] = (min(max(b * 0.3 * (lumaRatio - 1), -0.2), 0.2) * 1000).rounded() / 1000
        for (i, ch) in ["r", "g", "b"].enumerated() {
            let ratio = max(newHorizon[i], 0.02) / max(oldSky[i], 0.02) / lumaRatio
            out["gain_\(ch)"] = (min(max(b * 0.4 * (ratio - 1), -0.15), 0.15) * 1000).rounded() / 1000
        }
        return out
    }
}
