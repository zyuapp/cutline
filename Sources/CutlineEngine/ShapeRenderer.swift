import CoreGraphics
import CutlineCore
import Foundation

/// Draws shape-layer shapes into a y-down context whose units are canvas pixels.
enum ShapeRenderer {
    static func cgPath(_ p: ShapePath, scale s: CGFloat) -> CGPath {
        let out = CGMutablePath()
        func pt(_ q: PathPoint) -> CGPoint { CGPoint(x: q.x * s, y: q.y * s) }
        for c in p.contours {
            out.move(to: pt(c.start))
            for seg in c.segments {
                switch seg {
                case .line(let q): out.addLine(to: pt(q))
                case .cubic(let a, let b, let q): out.addCurve(to: pt(q), control1: pt(a), control2: pt(b))
                }
            }
            if c.closed { out.closeSubpath() }
        }
        return out
    }

    static func color(_ v: ParamValue?, _ fallback: RGBA) -> RGBA {
        guard let s = v?.string else { return fallback }
        if s.lowercased() == "none" { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        return RGBA(hex: s) ?? RGBA.named(s) ?? fallback
    }

    /// `value` reads "<shape id>.<property>" at the current frame.
    static func draw(_ items: [ShapeItem], ctx: CGContext, W: CGFloat, H: CGFloat, value: (String) -> ParamValue?) {
        for item in items {
            draw(item, ctx: ctx, W: W, H: H) { prop in value("\(item.id).\(prop)") ?? item.value(prop) }
        }
    }

    static func draw(_ item: ShapeItem, ctx: CGContext, W: CGFloat, H: CGFloat, value: (String) -> ParamValue) {
        func num(_ k: String) -> Double { value(k).number ?? item.value(k).number ?? 0 }
        let opacity = min(max(num("opacity"), 0), 1)
        let count = max(0, num("repeat_count"))
        guard opacity > 0.001, count > 0.001, let shape = try? item.path(num), !shape.isEmpty else { return }
        let fill = color(value("fill"), .white)
        let fillAlpha = CGFloat(min(max(num("fill_opacity"), 0), 1))
        let stroke = color(value("stroke"), RGBA(r: 0, g: 0, b: 0, a: 0))
        let strokeAlpha = CGFloat(min(max(num("stroke_opacity"), 0), 1))
        let sw = CGFloat(num("stroke_width")) * H
        let hasFill = (item.gradient != nil || fill.a > 0) && fillAlpha > 0
        let hasStroke = sw > 0 && stroke.a > 0 && strokeAlpha > 0
        guard hasFill || hasStroke else { return }
        let fillPath = cgPath(shape, scale: H)
        var strokePath = fillPath
        if hasStroke {
            let trimmed = shape.trimmed(start: num("trim_start"), end: num("trim_end"), offset: num("trim_offset"))
            strokePath = cgPath(trimmed, scale: H)
        }
        let strokeVisible = hasStroke && !strokePath.isEmpty

        let own = CGAffineTransform(scaleX: CGFloat(num("scale") * num("scale_x")), y: CGFloat(num("scale") * num("scale_y")))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(num("rotation") * .pi / 180)))
        let pivot = CGPoint(x: num("repeat_anchor_x") * H, y: num("repeat_anchor_y") * H)
        let step = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(scaleX: CGFloat(num("repeat_scale")), y: CGFloat(num("repeat_scale"))))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(num("repeat_rotation") * .pi / 180)))
            .concatenating(CGAffineTransform(translationX: pivot.x + num("repeat_x") * H, y: pivot.y + num("repeat_y") * H))
        let place = CGAffineTransform(translationX: num("x") * W, y: num("y") * H)
        let copies = Int(count.rounded(.up))
        let lastOpacity = min(max(num("repeat_opacity"), 0), 1)
        var repeated = CGAffineTransform.identity
        for i in 0..<min(copies, 200) {
            var alpha = opacity * (copies > 1 ? 1 + (lastOpacity - 1) * Double(i) / Double(copies - 1) : 1)
            if i == copies - 1, count < Double(copies) { alpha *= count - Double(copies - 1) }
            defer { repeated = repeated.concatenating(step) }
            guard alpha > 0.001 else { continue }
            ctx.saveGState()
            ctx.concatenate(own.concatenating(repeated).concatenating(place))
            let group = hasFill && strokeVisible && alpha < 0.999
            ctx.setAlpha(CGFloat(alpha))
            if group {
                ctx.beginTransparencyLayer(in: fillPath.boundingBoxOfPath.insetBy(dx: -sw, dy: -sw), auxiliaryInfo: nil)
                ctx.setAlpha(1)
            }
            if hasFill { drawFill(item, fillPath, fill, fillAlpha, ctx: ctx) }
            if strokeVisible {
                ctx.addPath(strokePath)
                ctx.setStrokeColor(stroke.with(alpha: stroke.a * Double(strokeAlpha)).cgColor)
                ctx.setLineWidth(sw)
                ctx.setLineCap(item.cap == "butt" ? .butt : item.cap == "square" ? .square : .round)
                ctx.setLineJoin(item.join == "miter" ? .miter : item.join == "bevel" ? .bevel : .round)
                if !item.dash.isEmpty { ctx.setLineDash(phase: CGFloat(num("dash_offset")) * H, lengths: item.dash.map { CGFloat($0) * H }) }
                ctx.strokePath()
            }
            if group { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
    }

    static func drawFill(_ item: ShapeItem, _ path: CGPath, _ fill: RGBA, _ alpha: CGFloat, ctx: CGContext) {
        guard let g = item.gradient else {
            ctx.addPath(path)
            ctx.setFillColor(fill.with(alpha: fill.a * Double(alpha)).cgColor)
            ctx.fillPath(using: item.evenOdd ? .evenOdd : .winding)
            return
        }
        let colors = g.colors.map { $0.with(alpha: $0.a * Double(alpha)).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: g.stops.map { CGFloat($0) }) else { return }
        let b = path.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(path)
        if item.evenOdd { ctx.clip(using: .evenOdd) } else { ctx.clip() }
        switch g.kind {
        case .linear:
            let a = g.angle * .pi / 180
            let dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
            let half = (abs(b.width * dx) + abs(b.height * dy)) / 2
            let c = CGPoint(x: b.midX, y: b.midY)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - dx * half, y: c.y - dy * half), end: CGPoint(x: c.x + dx * half, y: c.y + dy * half), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            let c = CGPoint(x: b.minX + b.width * g.center.0, y: b.minY + b.height * g.center.1)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(b.width, b.height) * g.radius, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
}
