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

    /// After the canvas changes shape, keeps media pictures framed for it. A fill clip that was framed (offset or
    /// animated) takes `framing`'s offsets for the new shape when it gives some; otherwise its offsets keep the same
    /// subject point in the middle (they scale with the picture's new size) and stay within the overflow, so the
    /// picture still covers the frame. A fit clip that sat inside the frame stays inside it. Returns the clips changed.
    @discardableResult
    public mutating func refitPictures(fromAspect old: Double, framing: (Clip, Project) -> (x: Double, y: Double)? = { _, _ in nil }) -> [String] {
        let new = Double(canvas.width) / Double(max(1, canvas.height))
        guard old > 0, new > 0, abs(old - new) > 1e-6 else { return [] }
        var changed: [String] = []
        let snapshot = self
        for ti in tracks.indices where tracks[ti].kind == .video {
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].kind == .media {
                var c = tracks[ti].clips[ci]
                guard let m = c.mediaId.flatMap({ mediaAsset($0) }), m.hasVideo, m.width > 0, m.height > 0 else { continue }
                guard c.transform.x != 0 || c.transform.y != 0 || c.anim["transform.x"] != nil || c.anim["transform.y"] != nil else { continue }
                let source = Double(m.width) / Double(m.height)
                let fit = c.transform.fit, scale = c.transform.scale
                func size(_ aspect: Double) -> (w: Double, h: Double) {
                    switch fit {
                    case .fill: (max(1, source / aspect) * scale, max(1, aspect / source) * scale)
                    case .fit: (min(1, source / aspect) * scale, min(1, aspect / source) * scale)
                    case .stretch: (scale, scale)
                    }
                }
                let was = size(old), now = size(new)
                let before = c
                if fit == .fill, let f = framing(c, snapshot) {
                    c.transform.x = f.x
                    c.transform.y = f.y
                    c.anim["transform.x"] = nil
                    c.anim["transform.y"] = nil
                } else {
                    func moved(_ v: Double, _ a: Double, _ b: Double) -> Double {
                        // Covering pictures keep their overflow; smaller ones stay inside the frame if they were.
                        if fit == .fill || b >= 1 {
                            let room = max(0, (b - 1) / 2)
                            return min(room, max(-room, fit == .fill && a > 0 ? v * b / a : v))
                        }
                        let room = (1 - b) / 2
                        return abs(v) <= (1 - a) / 2 + 1e-6 ? min(room, max(-room, v)) : v
                    }
                    c.transform.x = moved(c.transform.x, was.w, now.w)
                    c.transform.y = moved(c.transform.y, was.h, now.h)
                    for (path, a, b) in [("transform.x", was.w, now.w), ("transform.y", was.h, now.h)] {
                        guard var curve = c.anim[path] else { continue }
                        for k in curve.keys.indices { if let v = curve.keys[k].v.number { curve.keys[k].v = .number(moved(v, a, b)) } }
                        c.anim[path] = curve
                    }
                }
                if c != before {
                    tracks[ti].clips[ci] = c
                    changed.append(c.id)
                }
            }
        }
        return changed
    }
}
