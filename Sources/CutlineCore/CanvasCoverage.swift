import Foundation

extension Project {
    /// Pictures meant to fill the frame (their size before offsets, scale and crop covers it) that leave part of it
    /// empty for at least `minFrames` frames where no opaque picture below covers that part.
    func uncoveredFrame(minFrames: Int = 12) -> [String] {
        let aspect = Double(max(1, canvas.width)) / Double(max(1, canvas.height))
        let video = tracks.indices.filter { tracks[$0].kind == .video && !tracks[$0].hidden }
        let step = canvas.frameDuration * 2
        let need = Double(minFrames) * canvas.frameDuration
        var out: [String] = []
        for (n, ti) in video.enumerated() {
            for c in tracks[ti].clips where c.duration >= need {
                guard let s = c.naturalSize(in: self, aspect: aspect), s.w >= 1 - 1e-6, s.h >= 1 - 1e-6 else { continue }
                var runs: [(start: Seconds, end: Seconds, edges: [String: Double])] = []
                var open: (start: Seconds, end: Seconds, edges: [String: Double])?
                var t = c.start
                while t < c.end - 1e-6 {
                    var empty: [(edge: String, size: Double)] = []
                    if let b = c.pictureBox(s, at: t - c.start) {
                        let gaps = b.gaps
                        if !gaps.isEmpty {
                            let below = video[..<n].compactMap { j -> PictureBox? in
                                guard let o = tracks[j].clip(at: t), let os = o.naturalSize(in: self, aspect: aspect) else { return nil }
                                return o.pictureBox(os, at: t - o.start)
                            }
                            empty = gaps.filter { g in !below.contains { $0.contains(g.band) } }.map { ($0.edge, $0.size) }
                        }
                    }
                    if empty.isEmpty {
                        if let o = open { runs.append(o); open = nil }
                    } else {
                        var o = open ?? (t, t, [:])
                        o.end = min(c.end, t + step)
                        for e in empty { o.edges[e.edge] = max(o.edges[e.edge] ?? 0, e.size) }
                        open = o
                    }
                    t += step
                }
                if let o = open { runs.append(o) }
                let long = runs.filter { $0.end - $0.start >= need - 1e-6 }
                guard let first = long.first else { continue }
                let edges = first.edges.sorted { $0.value > $1.value }.map { "\($0.key) \(max(1, Int(($0.value * 100).rounded())))%" }.joined(separator: ", ")
                let offset = c.transform.x != 0 || c.transform.y != 0 || c.anim["transform.x"] != nil || c.anim["transform.y"] != nil
                out.append("canvas not covered: \(c.id) on \(tracks[ti].id) leaves the frame's \(edges) empty at \(fmt2(first.start))–\(fmt2(first.end))s"
                    + (long.count > 1 ? " (and \(long.count - 1) more stretch\(long.count == 2 ? "" : "es"))" : "") + " with no picture below; "
                    + (offset ? "keep transform.x/y within the picture's overflow (recipe reframe and canvas_set refit them) or scale it up" : "scale it up or put a picture below"))
            }
        }
        return out
    }
}

/// A picture's rectangle in frame fractions from the top left.
struct PictureBox {
    var x0, y0, x1, y1: Double

    func contains(_ b: PictureBox) -> Bool { x0 <= b.x0 + 1e-3 && y0 <= b.y0 + 1e-3 && x1 >= b.x1 - 1e-3 && y1 >= b.y1 - 1e-3 }

    /// The frame's empty bands around the picture, by edge.
    var gaps: [(edge: String, size: Double, band: PictureBox)] {
        let m = 0.005
        var out: [(edge: String, size: Double, band: PictureBox)] = []
        if y0 > m { out.append(("top", min(1, y0), PictureBox(x0: 0, y0: 0, x1: 1, y1: min(1, y0)))) }
        if y1 < 1 - m { out.append(("bottom", min(1, 1 - y1), PictureBox(x0: 0, y0: max(0, y1), x1: 1, y1: 1))) }
        if x0 > m { out.append(("left", min(1, x0), PictureBox(x0: 0, y0: 0, x1: min(1, x0), y1: 1))) }
        if x1 < 1 - m { out.append(("right", min(1, 1 - x1), PictureBox(x0: max(0, x1), y0: 0, x1: 1, y1: 1))) }
        return out
    }
}

extension Clip {
    /// The picture's size from its fit alone, in frame fractions; nil when its coverage isn't measured (generators,
    /// titles, 3D layers, blend modes, masks, keys and warps).
    func naturalSize(in p: Project, aspect: Double) -> (w: Double, h: Double)? {
        guard !transform.threeD, blend == .normal else { return nil }
        let shaped = effects.contains { e in
            e.enabled && ((EffectCatalog.type(e.type).map { ["mask", "distort"].contains($0.category) } ?? false) || e.type.contains("key"))
        }
        guard !shaped else { return nil }
        switch kind {
        case .solid, .sequence: return (1, 1)
        case .media:
            guard let m = mediaId.flatMap(p.mediaAsset), m.hasVideo, m.width > 0, m.height > 0 else { return nil }
            let ma = Double(m.width) / Double(m.height)
            switch transform.fit {
            case .stretch: return (1, 1)
            case .fit: return ma > aspect ? (1, aspect / ma) : (ma / aspect, 1)
            case .fill: return ma > aspect ? (ma / aspect, 1) : (1, aspect / ma)
            }
        default: return nil
        }
    }

    /// Where an opaque, unrotated picture of natural size `s` sits at `local` seconds; nil otherwise.
    func pictureBox(_ s: (w: Double, h: Double), at local: Seconds) -> PictureBox? {
        let tr = resolvedTransform(at: local)
        guard tr.opacity >= 0.999, abs(tr.rotation.truncatingRemainder(dividingBy: 360)) < 1e-6, tr.rotateX == 0, tr.rotateY == 0 else { return nil }
        let cr = tr.crop, k = max(tr.scale, 0)
        let w = s.w * max(0, 1 - cr.left - cr.right) * k, h = s.h * max(0, 1 - cr.top - cr.bottom) * k
        let cx = 0.5 + (cr.left - cr.right) / 2 * s.w * k + tr.x, cy = 0.5 + (cr.top - cr.bottom) / 2 * s.h * k + tr.y
        return PictureBox(x0: cx - w / 2, y0: cy - h / 2, x1: cx + w / 2, y1: cy + h / 2)
    }
}
