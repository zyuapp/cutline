import Foundation

extension Project {
    /// Generators that paint the whole frame; the others are graphics drawn over the picture.
    static let fullFrameGenerators: Set<String> = ["gradient"]

    /// Fraction of the canvas a picture clip covers at timeline time `t` (0…1), from its source size, crop, fit,
    /// scale and position; rotation and 3D tilts are ignored. Text, adjustment clips and graphics generators
    /// (lower thirds, shapes, callouts…) cover nothing.
    public func frameCoverage(_ c: Clip, at t: Seconds) -> Double {
        let local = t - c.start
        let xf = c.resolvedTransform(at: local)
        guard xf.opacity > 0.01 else { return 0 }
        let cw = Double(canvas.width), ch = Double(canvas.height)
        var w = cw, h = ch
        switch c.kind {
        case .media:
            guard let m = c.mediaId.flatMap({ mediaAsset($0) }), m.width > 0, m.height > 0 else { return 0 }
            let sw = Double(m.width) * max(0.01, 1 - xf.crop.left - xf.crop.right)
            let sh = Double(m.height) * max(0.01, 1 - xf.crop.top - xf.crop.bottom)
            switch xf.fit {
            case .fit: let s = min(cw / sw, ch / sh); (w, h) = (sw * s, sh * s)
            case .fill: let s = max(cw / sw, ch / sh); (w, h) = (sw * s, sh * s)
            case .stretch: break
            }
        case .solid, .sequence: break
        case .generator: guard c.effects.first.map({ Self.fullFrameGenerators.contains($0.type) }) == true else { return 0 }
        case .text, .adjustment: return 0
        }
        w *= xf.scale
        h *= xf.scale
        let cx = cw / 2 + xf.x * cw, cy = ch / 2 + xf.y * ch
        let ox = max(0, min(cw, cx + w / 2) - max(0, cx - w / 2))
        let oy = max(0, min(ch, cy + h / 2) - max(0, cy - h / 2))
        return ox * oy / (cw * ch)
    }

    /// Picture layers visible at `t`, top first, with the share of the frame each one shows after the layers above
    /// it (treated as opaque) cover their part.
    public func pictureLayers(at t: Seconds) -> [(clip: Clip, coverage: Double, visible: Double)] {
        var out: [(clip: Clip, coverage: Double, visible: Double)] = []
        var hidden = 0.0
        for track in tracks.reversed() where track.kind == .video && !track.hidden {
            guard let c = track.clip(at: t), [.media, .solid, .sequence, .generator].contains(c.kind) else { continue }
            let cov = frameCoverage(c, at: t)
            guard cov > 0 else { continue }
            out.append((c, cov, cov * (1 - hidden)))
            hidden = min(1, hidden + cov * (1 - hidden))
        }
        return out
    }

    /// The clip showing the most of the frame at `t`.
    public func mainPicture(at t: Seconds) -> Clip? {
        pictureLayers(at: t).max { $0.visible < $1.visible }?.clip
    }

    /// The timeline without what is drawn over the picture: captions, text and graphics generators (and their
    /// transitions). Grades, adjustment layers and picture clips stay, for measuring the graded picture.
    public func pictureOnly() -> Project {
        var p = self
        p.captions.enabled = false
        var gone = Set<String>()
        for t in p.tracks.indices where p.tracks[t].kind == .video {
            p.tracks[t].clips.removeAll { c in
                let graphic = c.kind == .text || (c.kind == .generator && c.effects.first.map { !Self.fullFrameGenerators.contains($0.type) } ?? true)
                if graphic { gone.insert(c.id) }
                return graphic
            }
        }
        p.transitions.removeAll { tr in [tr.from, tr.to].contains { $0.map(gone.contains) ?? false } }
        return p
    }

    /// Timeline spans each showing one shot of one media clip as the main picture (`mainPicture`), split at clip
    /// edges and at `shots` (source spans per clip id), with that clip and the shot's index among its shots.
    public func mainPictureShots(shots: (Clip) -> [TimeRange], minLength: Seconds = 0.3) -> [(range: TimeRange, clip: Clip, shot: Int, shots: Int)] {
        var cuts = Set<Double>([0, duration])
        var spans: [String: [TimeRange]] = [:]
        for t in tracks where t.kind == .video && !t.hidden {
            for c in t.clips where [.media, .solid, .sequence, .generator].contains(c.kind) {
                cuts.insert(c.start)
                cuts.insert(c.end)
                guard c.kind == .media else { continue }
                let s = shots(c).map { c.timelineSpan(ofSource: $0) }.sorted { $0.start < $1.start }
                spans[c.id] = s
                for r in s where r.start > c.start + 1e-6 && r.start < c.end - 1e-6 { cuts.insert(r.start) }
            }
        }
        let bounds = cuts.sorted()
        var out: [(range: TimeRange, clip: Clip, shot: Int, shots: Int)] = []
        for (lo, hi) in zip(bounds, bounds.dropFirst()) where hi - lo > minLength {
            guard let c = mainPicture(at: (lo + hi) / 2), c.kind == .media else { continue }
            let s = spans[c.id] ?? []
            let i = s.lastIndex { $0.start <= (lo + hi) / 2 + 1e-6 } ?? 0
            out.append((TimeRange(lo, hi), c, i, max(1, s.count)))
        }
        return out
    }
}
