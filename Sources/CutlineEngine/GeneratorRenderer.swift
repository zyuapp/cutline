import Accelerate
import AppKit
import CoreText
import CutlineCore
import Foundation

/// Draws `GeneratorCatalog` graphics into transparent, premultiplied sRGB images the size of the canvas.
public enum GeneratorRenderer {
    private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 48
        return c
    }()

    /// `value` returns each catalog parameter's current value. Nil for unknown types, an empty canvas or a camera.
    /// Particles and title presets also read the clip-local `time` and the clip `duration`; `history` gives a
    /// parameter's value at another clip-local time, for particles born earlier.
    public static func render(type: String, value: (String) -> ParamValue, canvas: CGSize, time: Double = 0, duration: Double = 0, history: ((String, Double) -> ParamValue)? = nil) -> CGImage? {
        guard let spec = GeneratorCatalog.type(type), canvas.width >= 1, canvas.height >= 1, type != "camera" else { return nil }
        if type == "particles" {
            if let history { return ParticleRenderer.render(time: time, canvas: canvas, value: history) }
            return withoutActuallyEscaping(value) { value in ParticleRenderer.render(time: time, canvas: canvas) { name, _ in value(name) } }
        }
        var map: [String: ParamValue] = [:]
        var key = "\(type)|\(Int(canvas.width.rounded()))x\(Int(canvas.height.rounded()))"
        var names = spec.params.map(\.name)
        if type == "shape" { names += ShapeLayers.names(shapes: value("shapes").string ?? "").map(\.0) }
        if type == "timecode_burn" { names.append("__burn") }
        for name in names {
            var v = value(name)
            // 1e-4 of the frame is well under a pixel at 4K, so neighbouring frames of a still graphic share an image.
            if let n = v.number {
                let q = (n * 10000).rounded()
                v = .number(q / 10000)
                key += "|\(q)"
            } else {
                key += "|\(v)"
            }
            map[name] = v
        }
        if type == "credits" {
            let fixed = map["progress"]?.number ?? -1
            let p = fixed >= 0 ? fixed : Credits.progress(time: time, duration: duration, endHold: map["end_hold"]?.number ?? 0)
            let q = (p * 100_000).rounded()
            map["__progress"] = .number(q / 100_000)
            key += "|p\(q)"
        }
        let values = Values(map: map, spec: spec)
        let clocks = type.hasPrefix("title.") ? TitlePresets.clocks(values, time: time, duration: duration) : nil
        if let clocks { key += clocks.key }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let img = draw(type, values, canvas: canvas, clocks: clocks) else { return nil }
        cache.setObject(img, forKey: key as NSString)
        return img
    }

    /// Renders with `params` over the catalog defaults.
    public static func render(type: String, params: [String: ParamValue], canvas: CGSize, time: Double = 0, duration: Double = 0) -> CGImage? {
        render(type: type, value: { params[$0] ?? GeneratorCatalog.defaultValue(type: type, name: $0, params: params) ?? .number(0) }, canvas: canvas, time: time, duration: duration)
    }

    struct Values {
        let map: [String: ParamValue]
        let spec: EffectType

        func raw(_ k: String) -> ParamValue? { map[k] ?? spec.spec(k)?.defaultValue }
        func num(_ k: String) -> CGFloat { CGFloat(raw(k)?.number ?? 0) }
        func bool(_ k: String) -> Bool { raw(k)?.bool ?? (raw(k)?.number).map { $0 != 0 } ?? false }
        func text(_ k: String) -> String { raw(k)?.string ?? "" }
        func color(_ k: String) -> RGBA {
            if let s = raw(k)?.string, let c = RGBA(hex: s) ?? RGBA.named(s) { return c }
            return spec.spec(k)?.defaultValue.color ?? .white
        }
    }

    static func draw(_ type: String, _ v: Values, canvas: CGSize, clocks: TitlePresets.Clocks? = nil) -> CGImage? {
        let w = Int(canvas.width.rounded()), h = Int(canvas.height.rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Top-left origin, y down, like positions everywhere else in Cutline.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.interpolationQuality = .high
        let d = Drawing(ctx: ctx, W: CGFloat(w), H: CGFloat(h), v: v)
        switch type {
        case "shape.rect": d.box(ellipse: false)
        case "shape.ellipse": d.box(ellipse: true)
        case "shape.line": d.line()
        case "shape.arrow": d.arrow()
        case "shape.highlight": d.highlight()
        case "callout": d.callout()
        case "lower_third": d.lowerThird()
        case "progress_bar": d.progressBar()
        case "counter": d.counter()
        case "gradient": d.gradient()
        case "grid_overlay": d.grid()
        case "text.path": PathText.drawPath(v, ctx: ctx, W: CGFloat(w), H: CGFloat(h))
        case "text.extruded": PathText.drawExtruded(v, ctx: ctx, W: CGFloat(w), H: CGFloat(h))
        case "credits": ReviewGraphics.credits(v, ctx: ctx, W: CGFloat(w), H: CGFloat(h))
        case "timecode_burn": ReviewGraphics.burnIn(v, ctx: ctx, W: CGFloat(w), H: CGFloat(h))
        case "shape":
            guard let items = try? ShapeLayers.parse(v.text("shapes")) else { return nil }
            ShapeRenderer.draw(items, ctx: ctx, W: CGFloat(w), H: CGFloat(h)) { v.map[$0] }
        default:
            guard let clocks, type.hasPrefix("title.") else { return nil }
            TitlePresets.draw(type, ctx: ctx, W: CGFloat(w), H: CGFloat(h), v: v, clocks: clocks)
        }
        return ctx.makeImage()
    }

    /// Fills rows where t = t0 + sx·x + sy·y with |sy| ≤ |sx|, copying each from one precomputed long row.
    /// Rounding the per-row shift to whole pixels moves t by at most half a pixel's step.
    static func shiftFill(_ p: UnsafeMutablePointer<UInt32>, width w: Int, height h: Int, stride: Int, lut: UnsafeBufferPointer<UInt32>, t0: Double, sx: Double, sy: Double) {
        let shift = sx != 0 ? sy / sx : 0
        let extra = Int((abs(shift) * Double(h)).rounded(.up)) + 2
        let origin = shift < 0 ? extra - 1 : 0
        let top = Double(lut.count - 1)
        var row = [UInt32](repeating: 0, count: w + extra)
        for k in row.indices {
            let t = t0 + sx * Double(k - origin)
            row[k] = lut[Int((min(max(t, 0), 1) * top).rounded())]
        }
        row.withUnsafeBufferPointer { m in
            for y in 0..<h {
                let off = origin + Int((Double(y) * shift).rounded())
                (p + y * stride).update(from: m.baseAddress! + off, count: w)
            }
        }
    }

    /// Formats a counter value: fixed decimals, optional thousands separators.
    public static func format(_ n: Double, decimals: Int, separator: Bool) -> String {
        let s = String(format: "%.\(max(0, min(decimals, 6)))f", n)
        guard separator else { return s }
        var digits = s
        var sign = ""
        if digits.hasPrefix("-") { sign = "-"; digits.removeFirst() }
        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let int = Array(parts[0])
        var grouped = ""
        for (i, ch) in int.enumerated() {
            if i > 0 && (int.count - i) % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        return sign + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }
}

private struct TextLine {
    let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    var height: CGFloat { ascent + descent }

    init(_ s: String, font: NSFont, color: RGBA, kern: CGFloat = 0) {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color.cgColor, .kern: kern])
        line = CTLineCreateWithAttributedString(attr)
        var a: CGFloat = 0, d: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil))
        ascent = a
        descent = d
    }

    /// Draws with the baseline at `y` in a y-down context.
    func draw(_ ctx: CGContext, x: CGFloat, baseline y: CGFloat) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

private func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

private func ease(_ x: CGFloat) -> CGFloat { CGFloat(Easing.easeOut.apply(Double(x))) }

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    var length: CGFloat { hypot(x, y) }
}

private struct Drawing {
    let ctx: CGContext
    let W: CGFloat
    let H: CGFloat
    let v: GeneratorRenderer.Values

    func point(_ kx: String, _ ky: String) -> CGPoint { CGPoint(x: v.num(kx) * W, y: v.num(ky) * H) }
    func len(_ k: String) -> CGFloat { v.num(k) * H }

    /// Draws `body` in one layer with a soft drop shadow under the whole group.
    func shadowed(_ size: CGFloat, alpha: CGFloat = 0.35, blur: CGFloat = 0.35, in rect: CGRect, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * blur * 0.18), blur: size * blur, color: CGColor(gray: 0, alpha: alpha))
        ctx.beginTransparencyLayer(in: rect.insetBy(dx: -size * blur * 2, dy: -size * blur * 2), auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func box(ellipse: Bool) {
        let c = point("x", "y")
        let w = len("width"), h = len("height")
        guard w > 0, h > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: v.num("rotation") * .pi / 180)
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let path: CGPath
        if ellipse {
            path = CGPath(ellipseIn: rect, transform: nil)
        } else {
            let r = min(len("radius"), min(w, h) / 2)
            path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        let fill = v.color("fill")
        if fill.a > 0 {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        let sw = len("stroke_width"), stroke = v.color("stroke")
        if sw > 0, stroke.a > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(sw)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    func line() {
        let a = point("x1", "y1"), b = point("x2", "y2")
        let p = clamp01(v.num("progress"))
        let width = max(len("width"), 0.5)
        guard p > 0 else { return }
        let end = a + (b - a) * p
        ctx.setLineCap(v.bool("round") ? .round : .butt)
        ctx.setLineWidth(width)
        if v.bool("dash") { ctx.setLineDash(phase: 0, lengths: [width * 2.5, width * 2]) }
        ctx.setStrokeColor(v.color("color").cgColor)
        ctx.move(to: a)
        ctx.addLine(to: end)
        ctx.strokePath()
    }

    func arrow() {
        let a = point("x1", "y1"), b = point("x2", "y2")
        let p = clamp01(v.num("progress"))
        let d = b - a
        let L = d.length
        guard p > 0, L > 0.5 else { return }
        let width = max(len("width"), 0.5)
        // Quadratic bezier bowed along the left normal of the direction of travel (screen space, y down).
        let normal = CGPoint(x: d.y / L, y: -d.x / L)
        let ctrl = (a + b) * 0.5 + normal * (v.num("curve") * L * 0.5)
        let n = 64
        var pts: [CGPoint] = []
        var acc: [CGFloat] = [0]
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n), u = 1 - t
            let q = a * (u * u) + ctrl * (2 * u * t) + b * (t * t)
            if let last = pts.last { acc.append(acc.last! + (q - last).length) }
            pts.append(q)
        }
        let total = acc.last!
        func at(_ s: CGFloat) -> CGPoint {
            let s = min(max(s, 0), total)
            var i = 1
            while i < n && acc[i] < s { i += 1 }
            let seg = acc[i] - acc[i - 1]
            let f = seg > 0 ? (s - acc[i - 1]) / seg : 0
            return pts[i - 1] + (pts[i] - pts[i - 1]) * f
        }
        let drawn = total * p
        let head = min(max(len("head"), width * 2.4), total * 0.6) * min(1, drawn / max(len("head"), 1))
        let tip = at(drawn)
        let back = at(drawn - max(head, 1) * 0.5)
        var dir = tip - back
        let dl = dir.length
        dir = dl > 0 ? dir * (1 / dl) : d * (1 / L)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        ctx.setStrokeColor(v.color("color").cgColor)
        ctx.setFillColor(v.color("color").cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Shaft stops inside the head so its round cap never pokes past the tip.
        let shaftEnd = drawn - head * 0.6
        if shaftEnd > 0 {
            ctx.setLineWidth(width)
            ctx.move(to: pts[0])
            var i = 1
            while i <= n && acc[i] < shaftEnd { ctx.addLine(to: pts[i]); i += 1 }
            ctx.addLine(to: at(shaftEnd))
            ctx.strokePath()
        }
        guard head > 0.5 else { return }
        let base = tip - dir * head
        ctx.move(to: tip)
        ctx.addLine(to: base + perp * (head * 0.55))
        ctx.addLine(to: tip - dir * (head * 0.72))
        ctx.addLine(to: base - perp * (head * 0.55))
        ctx.closePath()
        ctx.setLineWidth(max(head * 0.1, 0.5))
        ctx.drawPath(using: .fillStroke)
    }

    func highlight() {
        let c = point("x", "y")
        let w = len("width"), h = len("height")
        let p = clamp01(v.num("progress"))
        guard w > 0, h > 0, p > 0 else { return }
        let left = c.x - w / 2, right = c.x + w / 2, top = c.y - h / 2, bottom = c.y + h / 2
        let amp = h * 0.03
        let cap = min(h * 0.2, w / 4)
        // Gentle irregular wobble along the long edges and bulging ends read as a marker stroke rather than a box.
        func wobble(_ x: CGFloat, _ phase: CGFloat) -> CGFloat {
            let u = (x - left) / h
            return amp * (0.6 * sin(u * 1.3 + phase) + 0.4 * sin(u * 3.1 + phase * 2.7))
        }
        let n = max(8, Int((w / max(h * 0.15, 1)).rounded(.up)))
        func x(_ i: Int) -> CGFloat { left + cap + (w - 2 * cap) * CGFloat(i) / CGFloat(n) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x(0), y: top + wobble(x(0), 0.4)))
        for i in 1...n { path.addLine(to: CGPoint(x: x(i), y: top + wobble(x(i), 0.4))) }
        path.addQuadCurve(to: CGPoint(x: x(n), y: bottom + wobble(x(n), 2.1)), control: CGPoint(x: right + cap * 0.7, y: c.y))
        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: CGPoint(x: x(i), y: bottom + wobble(x(i), 2.1))) }
        path.addQuadCurve(to: CGPoint(x: x(0), y: top + wobble(x(0), 0.4)), control: CGPoint(x: left - cap * 0.7, y: c.y))
        path.closeSubpath()
        let skew = v.num("skew")
        var shear = CGAffineTransform(a: 1, b: 0, c: -skew, d: 1, tx: skew * c.y, ty: 0)
        guard let sheared = path.copy(using: &shear) else { return }
        let bounds = sheared.boundingBoxOfPath
        let color = v.color("color")
        ctx.saveGState()
        ctx.clip(to: CGRect(x: bounds.minX, y: bounds.minY - 1, width: bounds.width * p, height: bounds.height + 2))
        ctx.addPath(sheared)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        // Denser ink along the edges, where a real marker pools.
        ctx.addPath(sheared)
        ctx.clip()
        ctx.setFillColor(color.with(alpha: color.a * 0.25).cgColor)
        ctx.concatenate(shear)
        ctx.fill(CGRect(x: left - cap, y: top - amp, width: w + 2 * cap, height: h * 0.08 + amp))
        ctx.fill(CGRect(x: left - cap, y: bottom - h * 0.08, width: w + 2 * cap, height: h * 0.08 + amp))
        ctx.restoreGState()
    }

    func callout() {
        let size = max(len("size"), 1)
        let target = point("target_x", "target_y")
        let center = point("label_x", "label_y")
        let color = v.color("color")
        let font = TextRenderer.font(v.text("font"), size: size, weight: 600)
        let label = TextLine(v.text("label"), font: font, color: v.color("text_color"))
        let padX = size * 0.6, padY = size * 0.34
        let pill = CGRect(x: center.x - label.width / 2 - padX, y: center.y - label.height / 2 - padY, width: label.width + 2 * padX, height: label.height + 2 * padY)
        let dot = size * 0.2
        let lineW = max(1, size * 0.07)
        // Leader leaves from where the ray toward the target crosses the pill's edge.
        let d = target - center
        let tx = d.x != 0 ? (pill.width / 2) / abs(d.x) : .infinity
        let ty = d.y != 0 ? (pill.height / 2) / abs(d.y) : .infinity
        let edge = center + d * min(1, min(tx, ty))
        let bounds = pill.union(CGRect(x: target.x - dot * 2.2, y: target.y - dot * 2.2, width: dot * 4.4, height: dot * 4.4))
        shadowed(size, in: bounds) {
            if (target - edge).length > dot {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(lineW)
                ctx.setLineCap(.round)
                ctx.move(to: edge)
                ctx.addLine(to: target)
                ctx.strokePath()
            }
            ctx.setFillColor(color.with(alpha: color.a * 0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: target.x - dot * 2.1, y: target.y - dot * 2.1, width: dot * 4.2, height: dot * 4.2))
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: target.x - dot, y: target.y - dot, width: dot * 2, height: dot * 2))
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.fillPath()
        }
        label.draw(ctx, x: pill.minX + padX, baseline: pill.minY + padY + label.ascent)
    }

    func lowerThird() {
        let fs = max(len("size"), 1)
        let style = v.text("style")
        let accent = v.color("accent")
        let textColor = v.color("text_color")
        let p = clamp01(v.num("progress"))
        guard p > 0 else { return }
        let fontName = v.text("font")
        let title = TextLine(v.text("title"), font: TextRenderer.font(fontName, size: fs, weight: 700), color: textColor, kern: -0.01 * fs)
        let subText = v.text("subtitle")
        let subSize = fs * 0.58
        let subColor = style == "clean" ? accent : textColor.with(alpha: textColor.a * 0.82)
        let sub = subText.isEmpty ? nil : TextLine(subText, font: TextRenderer.font(fontName, size: subSize, weight: 500), color: subColor, kern: 0.02 * subSize)
        let ruleGap = style == "underline" ? fs * 0.16 : 0
        let rule = style == "underline" ? max(2, fs * 0.07) : 0
        let gap = fs * 0.2
        let textH = title.height + ruleGap * 2 + rule + (sub.map { gap + $0.height } ?? 0)
        let textW = max(title.width, sub?.width ?? 0)
        let x0 = v.num("x") * W
        let cy = v.num("y") * H
        let top = cy - textH / 2
        let barW = fs * 0.12
        let padX = style == "box" ? fs * 0.55 : 0
        let padY = style == "box" ? fs * 0.42 : 0
        let lead: CGFloat = switch style {
        case "bar": barW + fs * 0.38
        case "box": barW + padX
        default: 0
        }
        let contentW = max(textW, len("width") - lead - padX)
        let blockW = lead + contentW + padX
        let outer = CGRect(x: x0, y: top - padY, width: blockW, height: textH + 2 * padY)

        let pa = ease(clamp01(p / 0.45))
        let pt = ease(clamp01((p - 0.2) / 0.5))
        let ps = ease(clamp01((p - 0.4) / 0.6))

        shadowed(fs, alpha: style == "box" ? 0.3 : 0.45, in: outer) {
            switch style {
            case "bar":
                let h = outer.height + fs * 0.08
                ctx.setFillColor(accent.cgColor)
                ctx.fill(CGRect(x: x0, y: cy - h * pa / 2, width: barW, height: h * pa))
            case "box":
                let panel = CGRect(x: outer.minX, y: outer.minY, width: outer.width * pa, height: outer.height)
                let r = fs * 0.14
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: outer, cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.clip()
                let light = 0.299 * textColor.r + 0.587 * textColor.g + 0.114 * textColor.b > 0.5
                ctx.setFillColor(light ? CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.72) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88))
                ctx.fill(panel)
                ctx.setFillColor(accent.cgColor)
                ctx.fill(CGRect(x: outer.minX, y: outer.minY, width: min(barW, panel.width), height: outer.height))
                ctx.restoreGState()
            default:
                break
            }
            let tx = x0 + lead
            if pt > 0 {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: tx - fs * 0.1, y: top - fs * 0.3, width: (contentW + fs * 0.4) * pt + fs * 0.1, height: title.height + fs * 0.6))
                ctx.setAlpha(pt)
                title.draw(ctx, x: tx - (1 - pt) * fs * 0.5, baseline: top + title.ascent)
                ctx.restoreGState()
            }
            if rule > 0 {
                ctx.setFillColor(accent.cgColor)
                ctx.fill(CGRect(x: tx, y: top + title.height + ruleGap, width: max(textW, contentW) * pa, height: rule))
            }
            if let sub, ps > 0 {
                let y = top + title.height + ruleGap * 2 + rule + gap
                ctx.saveGState()
                ctx.clip(to: CGRect(x: tx - fs * 0.1, y: y - fs * 0.2, width: (contentW + fs * 0.4) * ps + fs * 0.1, height: sub.height + fs * 0.4))
                ctx.setAlpha(ps)
                sub.draw(ctx, x: tx - (1 - ps) * fs * 0.3, baseline: y + sub.ascent)
                ctx.restoreGState()
            }
        }
    }

    func progressBar() {
        let h = max(len("height"), 0.5)
        let y = v.num("y") * H - h / 2
        let bg = v.color("background")
        if bg.a > 0 {
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: W, height: h))
        }
        let p = clamp01(v.num("progress"))
        guard p > 0 else { return }
        ctx.setFillColor(v.color("color").cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: W * p, height: h))
    }

    func counter() {
        let size = max(len("size"), 1)
        let n = Double(v.num("from") + (v.num("to") - v.num("from")) * clamp01(v.num("progress")))
        let s = v.text("prefix") + GeneratorRenderer.format(n, decimals: Int(v.num("decimals").rounded()), separator: v.bool("separator")) + v.text("suffix")
        var font = TextRenderer.font(v.text("font"), size: size, weight: 800)
        // Tabular figures keep a centered counter from jittering as digits change.
        let tabular = font.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        font = NSFont(descriptor: tabular, size: size) ?? font
        let line = TextLine(s, font: font, color: v.color("color"), kern: -0.01 * size)
        let c = point("x", "y")
        let baseline = c.y + font.capHeight / 2
        let rect = CGRect(x: c.x - line.width / 2, y: baseline - line.ascent, width: line.width, height: line.height)
        shadowed(size, alpha: 0.4, blur: 0.12, in: rect) {
            line.draw(ctx, x: rect.minX, baseline: baseline)
        }
    }

    /// Writes pixels directly: every row of a linear gradient is a shifted copy of one long row.
    func gradient() {
        guard let data = ctx.data else { return }
        let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow / 4
        let angle = Double(v.num("angle")) * .pi / 180
        let dx = sin(angle), dy = -cos(angle)
        let span = abs(Double(w) * dx) + abs(Double(h) * dy)
        // t = 0 at the start corner, 1 at the end corner, per pixel center.
        let a = dx / span, b = dy / span
        let t0 = 0.5 + (0.5 - Double(w) / 2) * a + (0.5 - Double(h) / 2) * b
        let c1 = v.color("color1"), c2 = v.color("color2")
        let n = 4096
        var lut = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let u = Double(i) / Double(n - 1)
            func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
            let al = min(max(mix(c1.a, c2.a), 0), 1)
            func byte(_ x: Double) -> UInt32 { UInt32((min(max(x, 0), 1) * al * 255).rounded()) }
            lut[i] = UInt32((al * 255).rounded()) << 24 | byte(mix(c1.r, c2.r)) << 16 | byte(mix(c1.g, c2.g)) << 8 | byte(mix(c1.b, c2.b))
        }
        let pixels = data.assumingMemoryBound(to: UInt32.self)
        lut.withUnsafeBufferPointer { lut in
            if abs(a) >= abs(b) {
                GeneratorRenderer.shiftFill(pixels, width: w, height: h, stride: stride, lut: lut, t0: t0, sx: a, sy: b)
                return
            }
            // Mostly vertical: fill the image rotated a quarter turn counterclockwise, then turn it back.
            let tmp = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
            defer { tmp.deallocate() }
            GeneratorRenderer.shiftFill(tmp, width: h, height: w, stride: h, lut: lut, t0: t0 + a * Double(w - 1), sx: b, sy: -a)
            var src = vImage_Buffer(data: tmp, height: vImagePixelCount(w), width: vImagePixelCount(h), rowBytes: h * 4)
            var dst = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: ctx.bytesPerRow)
            var clear: [UInt8] = [0, 0, 0, 0]
            vImageRotate90_ARGB8888(&src, &dst, UInt8(kRotate90DegreesClockwise), &clear, vImage_Flags(kvImageNoFlags))
        }
    }

    func grid() {
        let color = v.color("color")
        let lw = max(len("width"), 1)
        let path = CGMutablePath()
        switch v.text("kind") {
        case "safe":
            for inset in [0.05, 0.1] as [CGFloat] {
                path.addRect(CGRect(x: W * inset, y: H * inset, width: W * (1 - 2 * inset), height: H * (1 - 2 * inset)))
            }
        case "center":
            let arm = H * 0.04
            path.move(to: CGPoint(x: W / 2 - arm, y: H / 2)); path.addLine(to: CGPoint(x: W / 2 + arm, y: H / 2))
            path.move(to: CGPoint(x: W / 2, y: H / 2 - arm)); path.addLine(to: CGPoint(x: W / 2, y: H / 2 + arm))
            path.addEllipse(in: CGRect(x: W / 2 - arm * 0.5, y: H / 2 - arm * 0.5, width: arm, height: arm))
        default:
            for f in [1.0 / 3, 2.0 / 3] as [CGFloat] {
                path.move(to: CGPoint(x: W * f, y: 0)); path.addLine(to: CGPoint(x: W * f, y: H))
                path.move(to: CGPoint(x: 0, y: H * f)); path.addLine(to: CGPoint(x: W, y: H * f))
            }
        }
        // A dark halo keeps light guides visible over bright footage.
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35 * color.a))
        ctx.setLineWidth(lw * 2.5)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.strokePath()
    }
}
