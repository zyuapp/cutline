import Foundation

extension Canvas {
    /// Standard video rates; the NTSC ones are exact (24000/1001, 30000/1001, …).
    public static let standardRates: [Double] = [24_000.0 / 1001, 24, 25, 30_000.0 / 1001, 30, 48, 50, 60_000.0 / 1001, 60, 100, 120_000.0 / 1001, 120]

    /// `fps` as the standard rate within 0.1% of it (23.976… becomes exactly 24000/1001), else rounded to 0.001.
    public static func standardRate(_ fps: Double) -> Double {
        if let r = standardRates.min(by: { abs($0 - fps) < abs($1 - fps) }), abs(r - fps) / r < 0.001 { return r }
        return (fps * 1000).rounded() / 1000
    }

    /// Whether footage at `fps` plays on this canvas without judder: the canvas shows every frame, or every
    /// n-th frame of a whole multiple.
    public func playsSmoothly(_ fps: Double) -> Bool {
        guard fps > 0 else { return true }
        let ratio = Canvas.standardRate(fps) / self.fps
        return ratio >= 1 - 1e-4 && abs(ratio - ratio.rounded()) < 1e-4
    }

    /// "23.976", "29.97", "24".
    public static func rateLabel(_ fps: Double) -> String {
        var s = Substring(String(format: "%.3f", fps))
        while s.hasSuffix("0") { s = s.dropLast() }
        if s.hasSuffix(".") { s = s.dropLast() }
        return String(s)
    }
}

extension Project {
    /// What a video import does to the canvas. Into an empty timeline whose canvas was never set deliberately, the
    /// first video sets the canvas to its size and standard rate; otherwise media at a rate the canvas can't show
    /// smoothly gets a warning. Nil when there's nothing to say.
    public mutating func fitCanvas(toImported m: MediaAsset) -> String? {
        guard m.hasVideo, !m.isImage, m.width > 0, m.height > 0, m.fps > 0 else { return nil }
        let rate = Canvas.standardRate(m.fps)
        let label = Canvas.rateLabel
        if canvasSet != true, tracks.allSatisfy(\.clips.isEmpty) {
            canvasSet = true
            let w = min(8192, max(16, m.width - m.width % 2)), h = min(8192, max(16, m.height - m.height % 2))
            guard w != canvas.width || h != canvas.height || abs(rate - canvas.fps) > 1e-9 else { return nil }
            let was = "\(canvas.width)×\(canvas.height) @\(label(canvas.fps))fps"
            let old = canvas.fps
            canvas.width = w
            canvas.height = h
            canvas.fps = rate
            if abs(old - rate) > 1e-9 { _ = conformFrameRate(from: old, mode: .snap) }
            return "Canvas set to \(m.id)'s \(w)×\(h) @\(label(rate))fps (was \(was)): it is the first footage in an empty project. canvas_set changes it."
        }
        guard !canvas.playsSmoothly(m.fps) else { return nil }
        return "\(m.id) is \(label(rate))fps but the canvas is \(label(canvas.fps))fps, so its motion will judder (frames repeat or drop unevenly). If it is the main footage, canvas_set fps:\(label(rate)) conforms the timeline to it."
    }
}
