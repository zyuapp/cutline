import AppKit
import CoreText
import CutlineCore
import Foundation

/// Text on a path (`text.path`) and extruded text (`text.extruded`), drawn into y-down canvas-pixel contexts.
enum PathText {
    struct Glyph {
        var glyph: CGGlyph
        var font: CTFont
        /// Center of the glyph's advance on the path (canvas pixels, top-left origin).
        var center: CGPoint
        /// Path direction there, radians clockwise from +x.
        var angle: CGFloat
        var advance: CGFloat
    }

    static func font(_ v: GeneratorRenderer.Values, size: CGFloat) -> NSFont {
        TextRenderer.font(v.text("font"), size: max(1, size), weight: Int(v.num("weight").rounded()))
    }

    static func line(_ text: String, font: NSFont, spacing: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: spacing * font.pointSize]))
    }

    /// Each glyph of a line with its pen position along the line and advance.
    static func glyphs(_ line: CTLine) -> [(glyph: CGGlyph, font: CTFont, x: CGFloat, advance: CGFloat)] {
        var out: [(CGGlyph, CTFont, CGFloat, CGFloat)] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            var adv = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            CTRunGetAdvances(run, CFRange(location: 0, length: n), &adv)
            for i in 0..<n { out.append((glyphs[i], font, pos[i].x, adv[i].width)) }
        }
        return out
    }

    /// The text.path path in canvas pixels: the chosen kind (or `override`, in frame heights around x,y) placed at x,y.
    static func path(_ v: GeneratorRenderer.Values, W: CGFloat, H: CGFloat) -> ShapePath? {
        let kind = v.text("path")
        guard var p = ShapePath.textPath(kind: kind, radius: Double(v.num("radius")), arcStart: Double(v.num("arc_start")), arcEnd: Double(v.num("arc_end")), width: Double(v.num("width")), amplitude: Double(v.num("amplitude")), waves: Double(v.num("waves")), d: v.text("d")) else { return nil }
        if v.bool("flip") { p = p.reversed }
        let ox = Double(v.num("x") * W), oy = Double(v.num("y") * H), s = Double(H)
        return p.mapped { PathPoint(ox + $0.x * s, oy + $0.y * s) }
    }

    /// Where every shown glyph of a text.path sits.
    static func layout(_ v: GeneratorRenderer.Values, W: CGFloat, H: CGFloat) -> [Glyph] {
        guard let p = path(v, W: W, H: H) else { return [] }
        let total = p.length
        let text = v.text("text")
        guard total > 1, !text.isEmpty else { return [] }
        let f = font(v, size: v.num("size") * H)
        let ln = line(text, font: f, spacing: v.num("letter_spacing"))
        let width = CGFloat(CTLineGetTypographicBounds(ln, nil, nil, nil))
        let all = glyphs(ln)
        let shown = Int((Double(all.count) * min(max(Double(v.num("reveal")), 0), 1) + 1e-6).rounded(.down))
        let L = CGFloat(total)
        let closed = p.isClosed
        var start: CGFloat = 0, spread: CGFloat = 0
        switch v.text("align") {
        case "center": start = (L - width) / 2
        case "end": start = L - width
        case "spread": spread = (L - width) / CGFloat(max(1, closed ? all.count : all.count - 1))
        default: break
        }
        start += v.num("offset") * L
        var out: [Glyph] = []
        for (k, g) in all.prefix(shown).enumerated() {
            var s = start + g.x + spread * CGFloat(k) + g.advance / 2
            if closed {
                s = s.truncatingRemainder(dividingBy: L)
                if s < 0 { s += L }
            } else if s < 0 || s > L {
                continue
            }
            guard let (pt, tan) = p.point(at: Double(s)) else { continue }
            out.append(Glyph(glyph: g.glyph, font: g.font, center: CGPoint(x: pt.x, y: pt.y), angle: atan2(CGFloat(tan.y), CGFloat(tan.x)), advance: g.advance))
        }
        return out
    }

    static func drawPath(_ v: GeneratorRenderer.Values, ctx: CGContext, W: CGFloat, H: CGFloat) {
        let lift = max(0, v.num("baseline")) * H
        let combined = CGMutablePath()
        for g in layout(v, W: W, H: H) {
            guard let outline = CTFontCreatePathForGlyph(g.font, g.glyph, nil) else { continue }
            // Glyph space is y-up from the baseline's left end; the context is y-down.
            let t = CGAffineTransform(scaleX: 1, y: -1)
                .concatenating(CGAffineTransform(translationX: -g.advance / 2, y: -lift))
                .concatenating(CGAffineTransform(rotationAngle: g.angle))
                .concatenating(CGAffineTransform(translationX: g.center.x, y: g.center.y))
            combined.addPath(outline, transform: t)
        }
        paint(combined, v, ctx: ctx, H: H, fill: v.color("color"))
    }

    static func paint(_ path: CGPath, _ v: GeneratorRenderer.Values, ctx: CGContext, H: CGFloat, fill: RGBA) {
        guard !path.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        let stroke = v.color("stroke"), sw = v.num("stroke_width") * H
        if stroke.a > 0, sw > 0.1 {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(sw)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: Extruded text

    enum Part { case all, face, side }

    /// The extruded text's outline, centered on x,y, in canvas pixels.
    static func outline(_ v: GeneratorRenderer.Values, W: CGFloat, H: CGFloat) -> CGPath {
        let f = font(v, size: v.num("size") * H)
        let ln = line(v.text("text"), font: f, spacing: v.num("letter_spacing"))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ln, &ascent, &descent, nil))
        let origin = CGPoint(x: v.num("x") * W - width / 2, y: v.num("y") * H + (ascent - descent) / 2)
        let out = CGMutablePath()
        for g in glyphs(ln) {
            guard let p = CTFontCreatePathForGlyph(g.font, g.glyph, nil) else { continue }
            out.addPath(p, transform: CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: origin.x + g.x, y: origin.y)))
        }
        return out
    }

    /// Unit vector of a CSS-style direction (0 up, 90 right) in y-down coordinates.
    static func direction(_ degrees: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: sin(a), y: -cos(a))
    }

    /// Closed polygons approximating a path's contours.
    static func polygons(_ path: CGPath) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var cur: [CGPoint] = []
        path.applyWithBlock { el in
            let e = el.pointee
            let pen = cur.last ?? .zero
            switch e.type {
            case .moveToPoint:
                if cur.count > 2 { out.append(cur) }
                cur = [e.points[0]]
            case .addLineToPoint:
                cur.append(e.points[0])
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                for k in 1...6 {
                    let t = CGFloat(k) / 6, m = 1 - t
                    cur.append(CGPoint(x: m * m * pen.x + 2 * m * t * c.x + t * t * p.x, y: m * m * pen.y + 2 * m * t * c.y + t * t * p.y))
                }
            case .addCurveToPoint:
                let a = e.points[0], b = e.points[1], p = e.points[2]
                for k in 1...8 {
                    let t = CGFloat(k) / 8, m = 1 - t
                    let x = m * m * m * pen.x + 3 * m * m * t * a.x + 3 * m * t * t * b.x + t * t * t * p.x
                    let y = m * m * m * pen.y + 3 * m * m * t * a.y + 3 * m * t * t * b.y + t * t * t * p.y
                    cur.append(CGPoint(x: x, y: y))
                }
            case .closeSubpath:
                if cur.count > 2 { out.append(cur) }
                cur = []
            @unknown default:
                break
            }
        }
        if cur.count > 2 { out.append(cur) }
        return out
    }

    static func mixed(_ c: RGBA, toward t: RGBA, _ f: Double) -> RGBA {
        let f = min(max(f, 0), 1)
        return RGBA(r: c.r + (t.r - c.r) * f, g: c.g + (t.g - c.g) * f, b: c.b + (t.b - c.b) * f, a: c.a)
    }

    /// Shade of a surface facing `normal` (unit, y-down) under the light: −1 facing away … 1 facing it.
    static func lit(_ normal: CGPoint, _ light: CGPoint) -> Double { Double(normal.x * light.x + normal.y * light.y) }

    static func drawExtruded(_ v: GeneratorRenderer.Values, ctx: CGContext, W: CGFloat, H: CGFloat, part: Part = .all) {
        let face = outline(v, W: W, H: H)
        guard !face.isEmpty else { return }
        let light = direction(v.num("light"))
        let shading = Double(min(max(v.num("shading"), 0), 1))
        let side = v.color("side_color")
        let depth = v.num("depth") * H
        if part == .side {
            // One slice of the 3D stack: the silhouette in the side color, its edges lit by the light.
            ctx.saveGState()
            ctx.addPath(face)
            ctx.setFillColor(mixed(side, toward: RGBA(r: 0, g: 0, b: 0, a: 1), 0.15 * shading).cgColor)
            ctx.fillPath()
            ctx.addPath(face)
            ctx.clip()
            let band = max(1.5, v.num("size") * H * 0.03)
            ctx.translateBy(x: -light.x * band, y: -light.y * band)
            ctx.addPath(face)
            ctx.setStrokeColor(mixed(side, toward: .white, 0.45 * shading).cgColor)
            ctx.setLineWidth(2 * band)
            ctx.strokePath()
            ctx.restoreGState()
            return
        }
        if part == .all && depth > 0.5 {
            let d = direction(v.num("angle"))
            let D = CGPoint(x: d.x * depth, y: d.y * depth)
            var quads: [(order: CGFloat, pts: [CGPoint], shade: Double)] = []
            for poly in polygons(face) {
                for i in poly.indices {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    let ex = b.x - a.x, ey = b.y - a.y, len = hypot(ex, ey)
                    guard len > 1e-3 else { continue }
                    var n = CGPoint(x: ey / len, y: -ex / len)
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    if face.contains(CGPoint(x: mid.x + n.x * 0.5, y: mid.y + n.y * 0.5)) { n = CGPoint(x: -n.x, y: -n.y) }
                    // Sides facing away from the extrusion are hidden behind the face.
                    guard n.x * D.x + n.y * D.y > 0 else { continue }
                    quads.append((mid.x * D.x + mid.y * D.y, [a, b, CGPoint(x: b.x + D.x, y: b.y + D.y), CGPoint(x: a.x + D.x, y: a.y + D.y)], lit(n, light)))
                }
            }
            // Sides farther along the extrusion are nearer the viewer.
            quads.sort { $0.order < $1.order }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let fade = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.45 * shading)] as CFArray, locations: [0, 1])!
            for q in quads {
                let s = q.shade
                let color = s >= 0 ? mixed(side, toward: .white, 0.35 * shading * s) : mixed(side, toward: RGBA(r: 0, g: 0, b: 0, a: 1), 0.5 * shading * -s)
                let path = CGMutablePath()
                path.addLines(between: q.pts)
                path.closeSubpath()
                ctx.saveGState()
                ctx.setShouldAntialias(true)
                ctx.addPath(path)
                ctx.setFillColor(color.cgColor)
                // A hairline stroke closes the seams between neighbouring quads.
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(0.6)
                ctx.drawPath(using: .fillStroke)
                ctx.addPath(path)
                ctx.clip()
                ctx.drawLinearGradient(fade, start: q.pts[0], end: q.pts[3], options: [.drawsAfterEndLocation])
                ctx.restoreGState()
            }
        }
        // The face with a bevel: a lit band along edges facing the light, a shaded band along the others.
        let fill = v.color("color")
        paint(face, v, ctx: ctx, H: H, fill: fill)
        let bevel = v.num("bevel") * H
        if bevel > 0.3 && shading > 0 {
            for (sign, tone, amount) in [(CGFloat(1), RGBA(r: 0, g: 0, b: 0, a: 1), 0.4 * shading), (-1, .white, 0.5 * shading)] {
                ctx.saveGState()
                ctx.addPath(face)
                ctx.clip()
                ctx.translateBy(x: sign * light.x * bevel, y: sign * light.y * bevel)
                ctx.addPath(face)
                ctx.setStrokeColor(mixed(fill, toward: tone, amount).cgColor)
                ctx.setLineWidth(2 * bevel)
                ctx.setLineJoin(.round)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }

    /// The face and one side slice of a text.extruded, canvas-sized, for stacking in 3D.
    static func extrudedParts(value: (String) -> ParamValue, canvas: CGSize) -> (face: CGImage, side: CGImage)? {
        guard let spec = GeneratorCatalog.type("text.extruded") else { return nil }
        var map: [String: ParamValue] = [:]
        for p in spec.params { map[p.name] = value(p.name) }
        let v = GeneratorRenderer.Values(map: map, spec: spec)
        func draw(_ part: Part) -> CGImage? {
            let w = Int(canvas.width.rounded()), h = Int(canvas.height.rounded())
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            drawExtruded(v, ctx: ctx, W: CGFloat(w), H: CGFloat(h), part: part)
            return ctx.makeImage()
        }
        guard let face = draw(.face), let side = draw(.side) else { return nil }
        return (face, side)
    }
}
