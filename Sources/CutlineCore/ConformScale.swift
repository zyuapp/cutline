import Foundation

/// A clip's fit mode as plain scale, for formats that size pictures by scale alone: multiples of the media fit whole
/// into the canvas (AAF Video Scale, Final Cut's fit conform) or of its own pixels (FCP7 Basic Motion).
extension Canvas {
    /// Media pixels to canvas pixels when the media is fit whole; nil without media dimensions.
    func mediaFitScale(_ m: MediaAsset?) -> Double? {
        guard let m, m.width > 0, m.height > 0, width > 0, height > 0 else { return nil }
        return min(Double(width) / Double(m.width), Double(height) / Double(m.height))
    }

    /// Size of the picture `fit` gives media `m` cropped by `crop` (the compositor fits the crop), x and y, in
    /// multiples of the media fit whole; (1, 1) without media dimensions.
    func conformScale(_ m: MediaAsset?, crop cr: Crop, fit: FitMode) -> (x: Double, y: Double) {
        guard let whole = mediaFitScale(m), let m else { return (1, 1) }
        let w = Double(m.width) * max(0.01, 1 - cr.left - cr.right), h = Double(m.height) * max(0.01, 1 - cr.top - cr.bottom)
        let sx = Double(width) / w, sy = Double(height) / h
        switch fit {
        case .fit: return (min(sx, sy) / whole, min(sx, sy) / whole)
        case .fill: return (max(sx, sy) / whole, max(sx, sy) / whole)
        case .stretch: return (sx / whole, sy / whole)
        }
    }

    /// Sets `c`'s fit and scale from a picture `x`×`y` times media `m` fit whole (the clip's crop already set):
    /// stretch when the axes differ as the canvas and cropped media do, fill when uniform at the fill size, else fit.
    /// Returns a warning when the scale is neither uniform nor a stretch.
    func setConform(_ c: inout Clip, media m: MediaAsset?, x: Double, y: Double) -> String? {
        let cr = c.transform.crop
        let fit = conformScale(m, crop: cr, fit: .fit), fill = conformScale(m, crop: cr, fit: .fill), stretch = conformScale(m, crop: cr, fit: .stretch)
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 2e-3 * max(abs(a), abs(b), 1e-9) }
        func tidy(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
        if !near(x, y) {
            if !near(stretch.x, stretch.y), near(x / y, stretch.x / stretch.y) {
                c.transform.fit = .stretch
                c.transform.scale = tidy(x / stretch.x)
                return nil
            }
            c.transform.fit = .fit
            c.transform.scale = tidy((x + y) / 2 / fit.x)
            return "Non-uniform scale on \(c.name ?? "a clip") averaged"
        }
        if !near(fill.x, fit.x), near(x, fill.x) {
            c.transform.fit = .fill
            c.transform.scale = 1
        } else {
            c.transform.fit = .fit
            c.transform.scale = tidy(x / fit.x)
        }
        return nil
    }
}

extension Project {
    /// Size of the picture `c`'s fit gives it, in multiples of its media fit whole.
    func conformScale(_ c: Clip) -> (x: Double, y: Double) {
        canvas.conformScale(c.kind == .media ? c.mediaId.flatMap(mediaAsset) : nil, crop: c.transform.crop, fit: c.transform.fit)
    }
}
