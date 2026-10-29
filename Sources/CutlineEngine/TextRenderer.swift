import AppKit
import CoreText
import CutlineCore
import Foundation

/// Draws text and captions into images sized in canvas pixels.
enum TextRenderer {
    struct Run {
        var text: String
        var color: RGBA
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
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .kern: letterSpacing * font.pointSize]
                if fill {
                    attrs[.foregroundColor] = run.color.cgColor
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
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
        let hasStroke = stroke != nil && strokeWidth > 0
        if hasStroke { draw(attributed(fill: false), shadowed: shadow && background == nil) }
        draw(fillText, shadowed: shadow && !hasStroke && background == nil)
        return ctx.makeImage()
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func with(alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
}
