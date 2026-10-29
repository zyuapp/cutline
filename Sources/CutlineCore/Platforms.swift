import CoreGraphics
import Foundation

/// Delivery targets: shape, length and loudness limits, and where the app's own UI covers the picture.
public struct Platform: Sendable {
    public var id: String
    public var name: String
    /// Accepted width:height ratios.
    public var aspects: [Double]
    public var maxDuration: Seconds?
    public var loudness: Double
    /// Area free of platform UI, as fractions of the frame (top-left origin).
    public var safe: CGRect
    public var preset: String
    public var notes: String

    public static let all: [Platform] = [
        Platform(id: "youtube", name: "YouTube", aspects: [16.0 / 9], maxDuration: nil, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "h264", notes: "Chapters from markers go in the description; the first must be at 0:00"),
        Platform(id: "youtube_shorts", name: "YouTube Shorts", aspects: [9.0 / 16], maxDuration: 180, loudness: -14, safe: CGRect(x: 0.05, y: 0.08, width: 0.8, height: 0.72), preset: "hevc", notes: "Title and channel cover the bottom, buttons the right edge"),
        Platform(id: "tiktok", name: "TikTok", aspects: [9.0 / 16], maxDuration: 600, loudness: -14, safe: CGRect(x: 0.05, y: 0.1, width: 0.78, height: 0.65), preset: "hevc", notes: "Caption and sound bar cover the bottom quarter, buttons the right edge"),
        Platform(id: "instagram_reels", name: "Instagram Reels", aspects: [9.0 / 16], maxDuration: 180, loudness: -14, safe: CGRect(x: 0.05, y: 0.12, width: 0.8, height: 0.66), preset: "hevc", notes: "Grid crops to 3:4 around the center; keep key action there"),
        Platform(id: "instagram_feed", name: "Instagram feed", aspects: [4.0 / 5, 1], maxDuration: 60, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "hevc", notes: ""),
        Platform(id: "x", name: "X", aspects: [16.0 / 9, 1], maxDuration: 140, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "h264", notes: ""),
        Platform(id: "linkedin", name: "LinkedIn", aspects: [16.0 / 9, 1, 4.0 / 5], maxDuration: 600, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "h264", notes: "Most viewers watch muted; burn in captions"),
        Platform(id: "broadcast", name: "Broadcast (EBU R128)", aspects: [16.0 / 9], maxDuration: nil, loudness: -23, safe: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), preset: "prores", notes: "True peak at most −1 dBTP"),
    ]

    public static func named(_ id: String) -> Platform? { all.first { $0.id == id } }

    /// Problems with the edit's shape and length for this platform.
    public func check(_ p: Project) -> [String] {
        var out: [String] = []
        let aspect = Double(p.canvas.width) / Double(p.canvas.height)
        if !aspects.contains(where: { abs($0 - aspect) < 0.02 }) {
            out.append("\(name) expects \(aspects.map(Platform.ratioName).joined(separator: " or ")); the canvas is \(p.canvas.width)×\(p.canvas.height). Change it with canvas_set (use fit \"fill\" on landscape footage).")
        }
        if let maxDuration, p.duration > maxDuration + 0.01 {
            out.append("\(name) allows up to \(Int(maxDuration))s; the edit is \(fmt2(p.duration))s.")
        }
        return out
    }

    static func ratioName(_ r: Double) -> String {
        for (w, h) in [(16, 9), (9, 16), (1, 1), (4, 5), (4, 3)] where abs(Double(w) / Double(h) - r) < 0.01 { return "\(w):\(h)" }
        return String(format: "%.2f:1", r)
    }
}
