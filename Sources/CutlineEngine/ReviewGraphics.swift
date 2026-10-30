import AppKit
import CoreText
import CutlineCore
import Foundation

/// Draws the credits and timecode burn-in generators into a y-down canvas context.
enum ReviewGraphics {
    struct Run {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat

        init(_ s: String, font: NSFont, color: RGBA) {
            line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color.cgColor]))
            var a: CGFloat = 0, d: CGFloat = 0
            width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil))
            ascent = a
            descent = d
        }

        /// Draws with the text's middle (between ascent and descent) at `middle`.
        func draw(_ ctx: CGContext, x: CGFloat, middle: CGFloat) {
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: x, y: middle + (ascent - descent) / 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    static func credits(_ v: GeneratorRenderer.Values, ctx: CGContext, W: CGFloat, H: CGFloat) {
        let bg = v.color("background")
        if bg.a > 0.001 {
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        let fontName = v.text("font")
        let headingName = v.text("heading_font").isEmpty ? fontName : v.text("heading_font")
        let size = Double(v.num("size")), headingSize = Double(v.num("heading_size")), titleSize = Double(v.num("title_size"))
        let weight = Int(v.num("weight").rounded())
        let entries = Credits.parse(v.text("text"))
        let progress = Double(v.num("__progress"))
        let cx = v.num("x") * W
        func font(_ kind: Credits.Kind) -> NSFont {
            switch kind {
            case .title: return TextRenderer.font(fontName, size: max(1, CGFloat(titleSize) * H), weight: 800)
            case .heading: return TextRenderer.font(headingName, size: max(1, CGFloat(headingSize) * H), weight: 600)
            default: return TextRenderer.font(fontName, size: max(1, CGFloat(size) * H), weight: weight)
            }
        }
        let roleFont = TextRenderer.font(headingName, size: max(1, CGFloat(headingSize) * H), weight: 500)
        if v.text("mode") == "crawl" {
            let text = entries.compactMap { e -> String? in
                switch e.kind {
                case .space: return nil
                case .row: return e.role.isEmpty ? e.text : "\(e.role)  \(e.text)"
                default: return e.text
                }
            }.joined(separator: "   •   ")
            let run = Run(text, font: font(.name), color: v.color("color"))
            let x = W - CGFloat(progress) * (W + run.width)
            run.draw(ctx, x: x, middle: v.num("y") * H)
            return
        }
        let (lines, height) = Credits.layout(entries, size: size, headingSize: headingSize, titleSize: titleSize, spacing: Double(v.num("line_spacing")), sectionGap: Double(v.num("section_gap")))
        guard let last = lines.last else { return }
        let top = Credits.rollTop(progress: progress, height: height, lastCenter: last.top + last.height / 2, hold: v.num("end_hold") > 0)
        let gutter = v.num("gutter") * H
        for l in lines {
            let y0 = CGFloat(top + l.top) * H, h = CGFloat(l.height) * H
            guard y0 + h > 0, y0 < H else { continue }
            let middle = y0 + h / 2
            switch l.kind {
            case .row:
                let role = Run(l.role, font: roleFont, color: v.color("role_color"))
                role.draw(ctx, x: cx - gutter / 2 - role.width, middle: middle)
                Run(l.text, font: font(.row), color: v.color("color")).draw(ctx, x: cx + gutter / 2, middle: middle)
            case .heading:
                let r = Run(l.text, font: font(.heading), color: v.color("heading_color"))
                r.draw(ctx, x: cx - r.width / 2, middle: middle)
            default:
                let r = Run(l.text, font: font(l.kind), color: v.color("color"))
                r.draw(ctx, x: cx - r.width / 2, middle: middle)
            }
        }
    }

    static func burnIn(_ v: GeneratorRenderer.Values, ctx: CGContext, W: CGFloat, H: CGFloat) {
        let watermark = v.text("watermark")
        if !watermark.isEmpty {
            var c = v.color("color")
            c.a *= Double(min(max(v.num("watermark_opacity"), 0), 1))
            let r = Run(watermark, font: TextRenderer.font(v.text("font") == "mono" ? "system" : v.text("font"), size: max(1, v.num("watermark_size") * H), weight: 800), color: c)
            ctx.saveGState()
            ctx.translateBy(x: W / 2, y: H / 2)
            ctx.rotate(by: v.num("watermark_angle") * .pi / 180)
            r.draw(ctx, x: -r.width / 2, middle: 0)
            ctx.restoreGState()
        }
        var text = v.text("__burn")
        if v.raw("__burn")?.string == nil { text = [v.text("label"), "--:--:--:--"].filter { !$0.isEmpty }.joined(separator: "   ") }
        guard !text.isEmpty else { return }
        let size = max(1, v.num("size") * H)
        let run = Run(text, font: TextRenderer.font(v.text("font"), size: size, weight: 600), color: v.color("color"))
        let pad = size * 0.35, margin = v.num("margin") * H
        let bw = run.width + 2 * pad, bh = run.ascent + run.descent + 2 * pad
        let pos = v.text("position")
        let x: CGFloat = pos.hasSuffix("left") ? margin : pos.hasSuffix("right") ? W - margin - bw : (W - bw) / 2
        let y: CGFloat = pos.hasPrefix("top") ? margin : H - margin - bh
        let box = v.color("box")
        if box.a > 0.001 {
            ctx.setFillColor(box.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: bw, height: bh), cornerWidth: pad * 0.6, cornerHeight: pad * 0.6, transform: nil))
            ctx.fillPath()
        }
        run.draw(ctx, x: x + pad, middle: y + bh / 2)
    }
}
