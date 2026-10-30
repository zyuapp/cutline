import CoreGraphics
import Foundation

extension Platform {
    /// Platforms whose app UI covers part of a 9:16 picture.
    public static var vertical: [Platform] { all.filter { $0.aspects.contains { abs($0 - 9.0 / 16) < 0.01 } } }

    /// The area clear of every vertical platform's UI.
    public static var verticalSafe: CGRect {
        vertical.map(\.safe).reduce(CGRect(x: 0, y: 0, width: 1, height: 1)) { $0.intersection($1) }
    }
}

extension CaptionStyle {
    /// Rough height of a full caption as a fraction of the canvas height: `maxLines` lines of `maxWordsPerLine`
    /// words, each wrapping when it is wider than `maxWidth`.
    public func estimatedHeight(canvas: Canvas) -> Double {
        let short = Double(min(canvas.width, canvas.height))
        let font = size * short
        let charWidth = font * (uppercase ? 0.68 : 0.56)
        let lineWidth = Double(max(1, maxWordsPerLine)) * 6 * charWidth
        let wraps = max(1, Int(ceil(lineWidth / max(1, maxWidth * Double(canvas.width)))))
        let lines = Double(max(1, maxLines) * min(wraps, 3))
        let pad = background == nil ? font * strokeWidth * 2 : font * 0.6
        return (lines * font * 1.25 + pad) / Double(canvas.height)
    }

    /// This style moved and narrowed only as far as needed to sit inside `area` (frame fractions, top-left origin).
    /// Captions stay centered when a centered line can still be at least 0.6 of the frame wide.
    public func fitted(in area: CGRect, canvas: Canvas) -> CaptionStyle {
        func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        var s = self
        let margin = 0.015
        let lo = Double(area.minX) + margin, hi = Double(area.maxX) - margin
        let cx = s.x ?? 0.5
        let centered = 2 * min(cx - lo, hi - cx)
        if centered >= min(s.maxWidth, 0.6) {
            if s.maxWidth > centered { s.maxWidth = r3(centered) }
        } else {
            s.maxWidth = r3(min(s.maxWidth, hi - lo))
            s.x = r3(min(max(cx, lo + s.maxWidth / 2), hi - s.maxWidth / 2))
        }
        let half = min(s.estimatedHeight(canvas: canvas), Double(area.height)) / 2
        let y = min(max(s.y, Double(area.minY) + half), Double(area.maxY) - half)
        if abs(y - s.y) > 1e-6 { s.y = r3(y) }
        return s
    }
}

extension Project {
    /// The area captions stay inside: `captions.platform`'s UI-free area, or on a 9:16 canvas the area clear of
    /// every vertical platform's UI; nil when captions.platform is "none" or no platform applies.
    public var captionSafeArea: (name: String, rect: CGRect)? {
        if let id = captions.platform {
            return Platform.named(id).map { ("\($0.name)'s UI-free area", $0.safe) }
        }
        guard canvas.height > 0, abs(Double(canvas.width) / Double(canvas.height) - 9.0 / 16) < 0.02 else { return nil }
        return ("the area clear of \(Platform.vertical.map(\.name).joined(separator: ", ")) UI", Platform.verticalSafe)
    }

    /// The caption style as rendered: `captions.style` kept inside `captionSafeArea`.
    public var captionStyle: CaptionStyle {
        guard let area = captionSafeArea else { return captions.style }
        return captions.style.fitted(in: area.rect, canvas: canvas)
    }

    /// The project with captions kept inside `platform`'s UI-free area, unless captions.platform is "none".
    public func placingCaptions(for platform: Platform?) -> Project {
        guard let platform, captions.enabled, captions.platform != "none", captions.platform != platform.id else { return self }
        var p = self
        p.captions.platform = platform.id
        return p
    }
}
