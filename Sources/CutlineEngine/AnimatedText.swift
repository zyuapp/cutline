import AppKit
import CoreText
import CutlineCore
import Foundation

/// Lays text out with CoreText and splits it into characters, words or lines that animate independently.
///
/// Sizes and placement match `TextRenderer`: same font, wrapping, alignment, line height, stroke,
/// shadow and background box, with extra headroom around the text so moving units are not clipped.
public enum AnimatedText {
    public typealias Animator = CutlineCore.TextAnimator

    /// One animating piece of the text. Rects are in layout pixels with the origin at the top left.
    public struct Unit: @unchecked Sendable {
        public let text: String
        /// UTF-16 range in the spec's text.
        public let range: NSRange
        /// Wrapped line the unit sits on, from 0.
        public let line: Int
        /// Typographic box of the unit's glyphs: glyph positions horizontally, the line's ascent and descent vertically.
        public let rect: CGRect
        /// Where `image` goes; `rect` plus room for stroke and shadow.
        public let imageRect: CGRect
        /// The unit alone, in the spec's color, stroke and shadow.
        public let image: CGImage
        let pieces: [Piece]
    }

    struct Piece {
        let line: Int
        let run: Int
        let glyphs: CFRange
    }

    public final class Layout: @unchecked Sendable {
        /// Image size: the text block plus headroom on every side.
        public let size: CGSize
        /// The area `TextRenderer` would draw for the same spec, within `size`, top-left origin.
        public let textRect: CGRect
        /// The background box within `size`, when the spec has a background.
        public let backgroundRect: CGRect?
        public let fontSize: CGFloat
        public let units: [Unit]

        let spec: TextSpec
        let fill: [(CTLine, [CTRun], CGPoint)]
        let stroke: [(CTLine, [CTRun], CGPoint)]?
        let margin: CGFloat
        private let lock = NSLock()
        private var tinted: [String: CGImage] = [:]

        init(size: CGSize, textRect: CGRect, backgroundRect: CGRect?, fontSize: CGFloat, units: [Unit], spec: TextSpec, fill: [(CTLine, [CTRun], CGPoint)], stroke: [(CTLine, [CTRun], CGPoint)]?, margin: CGFloat) {
            self.size = size
            self.textRect = textRect
            self.backgroundRect = backgroundRect
            self.fontSize = fontSize
            self.units = units
            self.spec = spec
            self.fill = fill
            self.stroke = stroke
            self.margin = margin
        }

        /// Unit `i`'s image with its fill recolored; the plain image when `color` is nil or the spec color.
        public func image(ofUnit i: Int, color: RGBA?) -> CGImage? {
            guard units.indices.contains(i) else { return nil }
            guard let color, color != spec.color else { return units[i].image }
            let key = "\(i):\(color.hex)"
            lock.lock()
            defer { lock.unlock() }
            if let hit = tinted[key] { return hit }
            let img = AnimatedText.unitImage(units[i].pieces, imageRect: units[i].imageRect, layout: self, color: color)
            tinted[key] = img
            return img
        }
    }

    private static let cache: NSCache<NSString, Layout> = {
        let c = NSCache<NSString, Layout>()
        c.countLimit = 64
        return c
    }()

    /// Nil for text with no visible units.
    public static func layout(_ spec: TextSpec, canvasHeight: Double, canvasWidth: Double, unit: Animator.Unit) -> Layout? {
        let key = "\(spec.hashValue):\(Int(canvasWidth))x\(Int(canvasHeight)):\(unit.rawValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let layout = build(spec, canvasHeight: canvasHeight, canvasWidth: canvasWidth, unit: unit) else { return nil }
        cache.setObject(layout, forKey: key)
        return layout
    }

    /// Draws every unit with its state into one `layout.size` image. `states` pairs with `layout.units`;
    /// missing states draw at rest. The background box takes the highest unit opacity.
    public static func render(_ layout: Layout, states: [Animator.UnitState], spec: TextSpec) -> CGImage? {
        let size = layout.size
        guard let ctx = bitmap(size) else { return nil }
        let fs = layout.fontSize
        if let bg = spec.background, let r = layout.backgroundRect {
            let opacity = layout.units.indices.map { $0 < states.count ? states[$0].opacity : 1 }.max() ?? 1
            if opacity > 0.001 {
                let flipped = CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
                ctx.addPath(CGPath(roundedRect: flipped, cornerWidth: fs * 0.28, cornerHeight: fs * 0.28, transform: nil))
                ctx.setFillColor(bg.with(alpha: bg.a * min(1, opacity)).cgColor)
                ctx.fillPath()
            }
        }
        for (i, u) in layout.units.enumerated() {
            let s = i < states.count ? states[i] : .rest
            guard s.opacity > 0.001, s.scale > 0.001, let img = layout.image(ofUnit: i, color: s.color) else { continue }
            let dest = CGRect(x: u.imageRect.minX, y: size.height - u.imageRect.maxY, width: u.imageRect.width, height: u.imageRect.height)
            let center = CGPoint(x: u.rect.midX, y: size.height - u.rect.midY)
            ctx.saveGState()
            ctx.setAlpha(min(1, s.opacity))
            let radius = CGFloat(s.blur) * fs
            // A shadow of a copy drawn off-canvas is a fast true Gaussian blur of the unit's silhouette.
            let away = size.width + size.height + radius * 4
            if radius > 0.5 {
                ctx.setShadow(offset: CGSize(width: away, height: 0), blur: radius * 1.5, color: (s.color ?? spec.color).cgColor)
                ctx.translateBy(x: -away, y: 0)
            }
            ctx.translateBy(x: center.x + CGFloat(s.dx) * fs, y: center.y - CGFloat(s.dy) * fs)
            ctx.scaleBy(x: s.scale, y: s.scale)
            ctx.translateBy(x: -center.x, y: -center.y)
            ctx.draw(img, in: dest)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func bitmap(_ size: CGSize) -> CGContext? {
        let ctx = CGContext(data: nil, width: max(1, Int(size.width.rounded(.up))), height: max(1, Int(size.height.rounded(.up))), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.setShouldSmoothFonts(false)
        ctx?.setLineJoin(.round)
        ctx?.setLineCap(.round)
        ctx?.interpolationQuality = .high
        return ctx
    }

    /// Applies the fonts and sizes of a title's spans.
    static func withSpanFonts(_ text: NSAttributedString, _ spec: TextSpec, font: NSFont) -> NSAttributedString {
        guard spec.spans?.isEmpty == false else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        var at = 0
        for run in TextRenderer.runs(spec, font: font) {
            let len = (run.text as NSString).length
            if let f = run.font { out.addAttribute(.font, value: f, range: NSRange(location: at, length: len)) }
            at += len
        }
        return out
    }

    static func build(_ spec: TextSpec, canvasHeight: Double, canvasWidth: Double, unit: Animator.Unit) -> Layout? {
        let text = spec.text as NSString
        guard text.length > 0 else { return nil }
        let font = TextRenderer.font(spec.font, size: spec.size * min(canvasWidth, canvasHeight), weight: spec.weight)
        let fs = font.pointSize
        let para = NSMutableParagraphStyle()
        para.alignment = switch spec.align {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        para.lineHeightMultiple = 0.95
        var base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .kern: spec.letterSpacing * fs]
        // Ligatures would merge characters that must animate apart.
        if unit == .char { base[NSAttributedString.Key(kCTLigatureAttributeName as String)] = 0 }
        var fillAttrs = base
        fillAttrs[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true
        let fillText = withSpanFonts(NSAttributedString(string: spec.text, attributes: fillAttrs), spec, font: font)
        let framesetter = CTFramesetterCreateWithAttributedString(fillText)
        let maxWidth = spec.maxWidth * canvasWidth
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(suggested.width) + 2, height: ceil(suggested.height) + 2)
        let pad: CGFloat = spec.background != nil ? fs * 0.4 : 0
        let margin = fs * 0.35 + CGFloat(spec.strokeWidth) * fs
        let headroom = fs * 1.2
        let size = CGSize(width: textSize.width + 2 * (pad + margin + headroom), height: textSize.height + 2 * (pad + margin + headroom))
        // Frame coordinates are y-up within the full layout image, as when drawing.
        let frameRect = CGRect(x: headroom + margin + pad, y: headroom + margin + pad, width: textSize.width, height: textSize.height)

        func lines(_ attr: NSAttributedString) -> [(CTLine, [CTRun], CGPoint)] {
            let fs = CTFramesetterCreateWithAttributedString(attr)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
            let ls = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: ls.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            return zip(ls, origins).map { ($0, CTLineGetGlyphRuns($0) as! [CTRun], CGPoint(x: frameRect.minX + $1.x, y: frameRect.minY + $1.y)) }
        }
        let fill = lines(fillText)
        var stroke: [(CTLine, [CTRun], CGPoint)]?
        if let s = spec.stroke, spec.strokeWidth > 0 {
            var attrs = base
            attrs[.foregroundColor] = CGColor.clear
            attrs[.strokeColor] = s.with(alpha: spec.color.a * s.a).cgColor
            attrs[.strokeWidth] = spec.strokeWidth * 200
            stroke = lines(withSpanFonts(NSAttributedString(string: spec.text, attributes: attrs), spec, font: font))
        }

        let ranges = unitRanges(text, unit: unit, lines: fill.map { CTLineGetStringRange($0.0) })
        var pending: [(String, NSRange, Int, CGRect, [Piece])] = []
        for r in ranges {
            var pieces: [Piece] = []
            var box = CGRect.null
            var firstLine = -1
            for (li, (line, runs, origin)) in fill.enumerated() {
                let lr = CTLineGetStringRange(line)
                guard r.location < lr.location + lr.length, lr.location < r.location + r.length else { continue }
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                for (ri, run) in runs.enumerated() {
                    let n = CTRunGetGlyphCount(run)
                    guard n > 0 else { continue }
                    var idx = [CFIndex](repeating: 0, count: n)
                    var pos = [CGPoint](repeating: .zero, count: n)
                    var adv = [CGSize](repeating: .zero, count: n)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
                    CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
                    CTRunGetAdvances(run, CFRange(location: 0, length: n), &adv)
                    let hits = (0..<n).filter { idx[$0] >= r.location && idx[$0] < r.location + r.length }
                    guard let lo = hits.min(), let hi = hits.max() else { continue }
                    pieces.append(Piece(line: li, run: ri, glyphs: CFRange(location: lo, length: hi - lo + 1)))
                    let x0 = hits.map { pos[$0].x }.min()!, x1 = hits.map { pos[$0].x + adv[$0].width }.max()!
                    box = box.union(CGRect(x: origin.x + x0, y: origin.y - descent, width: x1 - x0, height: ascent + descent))
                    if firstLine < 0 { firstLine = li }
                }
            }
            guard !pieces.isEmpty, !box.isNull else { continue }
            // Store top-left based rects.
            let rect = CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height)
            pending.append((text.substring(with: r), r, firstLine, rect, pieces))
        }
        guard !pending.isEmpty else { return nil }
        let textRect = CGRect(x: headroom, y: headroom, width: size.width - 2 * headroom, height: size.height - 2 * headroom)
        let bgRect = spec.background != nil ? textRect.insetBy(dx: margin, dy: margin) : nil
        let shell = Layout(size: size, textRect: textRect, backgroundRect: bgRect, fontSize: fs, units: [], spec: spec, fill: fill, stroke: stroke, margin: margin)
        let units: [Unit] = pending.compactMap { t, r, line, rect, pieces in
            let imageRect = rect.insetBy(dx: -margin, dy: -margin).integral
            guard let img = unitImage(pieces, imageRect: imageRect, layout: shell, color: spec.color) else { return nil }
            return Unit(text: t, range: r, line: line, rect: rect, imageRect: imageRect, image: img, pieces: pieces)
        }
        return Layout(size: size, textRect: textRect, backgroundRect: bgRect, fontSize: fs, units: units, spec: spec, fill: fill, stroke: stroke, margin: margin)
    }

    /// UTF-16 ranges of the units in reading order. Whitespace never forms or ends a unit.
    static func unitRanges(_ text: NSString, unit: Animator.Unit, lines: [CFRange]) -> [NSRange] {
        let ws = CharacterSet.whitespacesAndNewlines
        func trimmed(_ r: NSRange) -> NSRange? {
            var lo = r.location, hi = r.location + r.length
            while lo < hi, let s = UnicodeScalar(text.character(at: lo)), ws.contains(s) { lo += 1 }
            while hi > lo, let s = UnicodeScalar(text.character(at: hi - 1)), ws.contains(s) { hi -= 1 }
            return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
        }
        switch unit {
        case .line:
            return lines.compactMap { trimmed(NSRange(location: $0.location, length: $0.length)) }
        case .char:
            var out: [NSRange] = []
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byComposedCharacterSequences) { s, r, _, _ in
                if let s, !s.unicodeScalars.allSatisfy({ ws.contains($0) }) { out.append(r) }
            }
            return out
        case .word:
            var out: [NSRange] = []
            var start: Int?
            for i in 0..<text.length {
                let isSpace = UnicodeScalar(text.character(at: i)).map { ws.contains($0) } ?? false
                if isSpace, let s = start { out.append(NSRange(location: s, length: i - s)); start = nil }
                if !isSpace, start == nil { start = i }
            }
            if let s = start { out.append(NSRange(location: s, length: text.length - s)) }
            return out
        }
    }

    /// Draws a unit's glyphs straight from the laid-out runs, so positions match the full layout exactly.
    static func unitImage(_ pieces: [Piece], imageRect: CGRect, layout: Layout, color: RGBA) -> CGImage? {
        guard let ctx = bitmap(imageRect.size) else { return nil }
        let spec = layout.spec
        let fs = layout.fontSize
        ctx.translateBy(x: -imageRect.minX, y: -(layout.size.height - imageRect.maxY))
        ctx.textMatrix = .identity
        func draw(_ lines: [(CTLine, [CTRun], CGPoint)], shadowed: Bool) {
            ctx.saveGState()
            if shadowed {
                ctx.setShadow(offset: CGSize(width: 0, height: -fs * 0.05), blur: fs * 0.22, color: CGColor(gray: 0, alpha: 0.55))
            }
            ctx.setFillColor(color.cgColor)
            // One layer per pass so overlapping glyphs cast a single shadow, as with CTFrameDraw.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for p in pieces {
                let (_, runs, origin) = lines[p.line]
                ctx.textPosition = origin
                CTRunDraw(runs[p.run], ctx, p.glyphs)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        if let stroke = layout.stroke { draw(stroke, shadowed: spec.shadow && spec.background == nil) }
        draw(layout.fill, shadowed: spec.shadow && layout.stroke == nil && spec.background == nil)
        return ctx.makeImage()
    }
}
