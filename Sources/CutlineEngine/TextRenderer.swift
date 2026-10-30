import AppKit
import CoreText
import CutlineCore
import Foundation

/// Draws text and captions into images sized in canvas pixels.
enum TextRenderer {
    struct Run {
        var text: String
        var color: RGBA
        var font: NSFont? = nil
        var underline = false
        var highlight: RGBA? = nil
    }

    static let highlightKey = NSAttributedString.Key("CutlineHighlight")

    /// Runs for a title's styled pieces; characters from `visible` on are transparent.
    static func runs(_ spec: TextSpec, font: NSFont, visible: Int? = nil) -> [Run] {
        var out: [Run] = []
        var index = 0
        for piece in spec.styledPieces() {
            var run = Run(text: piece.text, color: spec.color)
            if let st = piece.style {
                run.color = st.color ?? spec.color
                run.underline = st.underline ?? false
                run.highlight = st.highlight
                if st.font != nil || st.weight != nil || st.scale != nil || st.italic == true {
                    var f = self.font(st.font ?? spec.font, size: font.pointSize * (st.scale ?? 1), weight: st.weight ?? spec.weight)
                    if st.italic == true { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                    run.font = f
                }
            }
            guard let visible else { out.append(run); continue }
            let chars = Array(piece.text)
            let n = max(0, min(chars.count, visible - index))
            if n > 0 { var r = run; r.text = String(chars[..<n]); out.append(r) }
            if n < chars.count { var r = run; r.text = String(chars[n...]); r.color = r.color.with(alpha: 0); r.highlight = r.highlight?.with(alpha: 0); out.append(r) }
            index += chars.count
        }
        return out
    }

    static func font(_ name: String, size: CGFloat, weight: Int) -> NSFont {
        let w: NSFont.Weight = switch weight {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
        let system = NSFont.systemFont(ofSize: size, weight: w)
        switch name.lowercased() {
        case "system", "":
            return system
        case "rounded":
            return system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case "serif":
            return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case "mono":
            return NSFont.monospacedSystemFont(ofSize: size, weight: w)
        default:
            let d = NSFontDescriptor(fontAttributes: [.family: name, .traits: [NSFontDescriptor.TraitKey.weight: w.rawValue]])
            if let f = NSFont(descriptor: d, size: size), f.familyName?.lowercased() == name.lowercased() { return f }
            return NSFont(name: name, size: size) ?? system
        }
    }

    /// Lines are separated by "\n" runs. Returns nil for empty text.
    static func render(runs: [Run], font: NSFont, align: TextAlign, maxWidth: CGFloat, background: RGBA?, stroke: RGBA?, strokeWidth: Double, shadow: Bool, letterSpacing: Double) -> CGImage? {
        guard runs.contains(where: { !$0.text.isEmpty }) else { return nil }
        let para = NSMutableParagraphStyle()
        para.alignment = switch align {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        para.lineHeightMultiple = 0.95
        func attributed(fill: Bool) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for run in runs {
                let f = run.font ?? font
                var attrs: [NSAttributedString.Key: Any] = [.font: f, .paragraphStyle: para, .kern: letterSpacing * f.pointSize]
                if fill {
                    attrs[.foregroundColor] = run.color.cgColor
                    if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.thick.rawValue; attrs[.underlineColor] = run.color.cgColor }
                    if let h = run.highlight { attrs[highlightKey] = h.cgColor }
                } else {
                    attrs[.foregroundColor] = CGColor.clear
                    attrs[.strokeColor] = (stroke ?? .black).with(alpha: run.color.a * (stroke?.a ?? 1)).cgColor
                    attrs[.strokeWidth] = strokeWidth * 200
                }
                s.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            return s
        }
        let fillText = attributed(fill: true)
        let framesetter = CTFramesetterCreateWithAttributedString(fillText)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(suggested.width) + 2, height: ceil(suggested.height) + 2)
        let fontSize = font.pointSize
        let pad: CGFloat = background != nil ? fontSize * 0.4 : 0
        let margin = fontSize * 0.35 + CGFloat(strokeWidth) * fontSize
        let size = CGSize(width: textSize.width + 2 * (pad + margin), height: textSize.height + 2 * (pad + margin))
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setShouldSmoothFonts(false)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if let background {
            let rect = CGRect(x: margin, y: margin, width: textSize.width + 2 * pad, height: textSize.height + 2 * pad)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: fontSize * 0.28, cornerHeight: fontSize * 0.28, transform: nil))
            ctx.setFillColor(background.cgColor)
            ctx.fillPath()
        }
        let textRect = CGRect(x: margin + pad, y: margin + pad, width: textSize.width, height: textSize.height)
        func draw(_ text: NSAttributedString, shadowed: Bool) {
            ctx.saveGState()
            if shadowed {
                ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.22, color: CGColor(gray: 0, alpha: 0.55))
            }
            let fs = CTFramesetterCreateWithAttributedString(text)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
            drawHighlights(frame, in: ctx, origin: textRect.origin)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
        let hasStroke = stroke != nil && strokeWidth > 0
        if hasStroke { draw(attributed(fill: false), shadowed: shadow && background == nil) }
        draw(fillText, shadowed: shadow && !hasStroke && background == nil)
        return ctx.makeImage()
    }
}

extension TextRenderer {
    /// Fills a box behind each run carrying a highlight color.
    static func drawHighlights(_ frame: CTFrame, in ctx: CGContext, origin: CGPoint) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, o) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let color = attrs[highlightKey] else { continue }
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
                var pos = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
                let padX = (ascent + descent) * 0.12
                let rect = CGRect(x: origin.x + o.x + pos.x - padX, y: origin.y + o.y - descent * 1.1, width: CGFloat(width) + 2 * padX, height: (ascent + descent) * 1.05)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.setFillColor(color as! CGColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height * 0.15, cornerHeight: rect.height * 0.15, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func with(alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
}
