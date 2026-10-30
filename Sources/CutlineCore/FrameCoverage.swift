import Foundation

extension Project {
    /// Fraction of the canvas a picture clip covers at timeline time `t` (0…1), from its source size, crop, fit,
    /// scale and position; rotation and 3D tilts are ignored. Text and adjustment clips cover nothing.
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
        case .solid, .sequence, .generator: break
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
}
