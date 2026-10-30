import Accelerate
import AppKit
import CoreText
import CutlineCore
import Foundation

/// The designed `title.*` generators: shapes and type with their own build-on and build-off.
enum TitlePresets {
    /// Raw progress through the build-on (a, 0→1), the build-off (b, 1→0 at the clip end) and the count (c).
    struct Clocks: Equatable {
        var a: Double
        var b: Double
        var c: Double

        var key: String { "|a\(Int((a * 10000).rounded()))b\(Int((b * 10000).rounded()))c\(Int((c * 10000).rounded()))" }
    }

    static func clocks(_ v: GeneratorRenderer.Values, time t: Double, duration: Double) -> Clocks {
        func q(_ x: Double) -> Double { (min(max(x, 0), 1) * 10000).rounded() / 10000 }
        let delay = Double(v.num("delay")), inLen = Double(v.num("in")), outLen = Double(v.num("out"))
        let a = inLen > 0 ? (t - delay) / inLen : (t >= delay ? 1 : 0)
        let b = outLen > 0 && duration > 0 ? (duration - t) / outLen : 1
        let count = Double(v.num("count"))
        let c = count > 0 ? (t - delay - inLen * 0.25) / count : 1
        return Clocks(a: q(a), b: q(b), c: q(c))
    }

    static func draw(_ type: String, ctx: CGContext, W: CGFloat, H: CGFloat, v: GeneratorRenderer.Values, clocks: Clocks) {
        let d = Design(ctx: ctx, W: W, H: H, v: v, k: clocks)
        switch type {
        case "title.lower_third_modern": d.modern()
        case "title.lower_third_box": d.box()
        case "title.lower_third_pill": d.pill()
        case "title.lower_third_line": d.line()
        case "title.card": d.card()
        case "title.quote": d.quote()
        case "title.end_card": d.endCard()
        case "title.data_callout": d.dataCallout()
        default: break
        }
    }
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
/// Fast start, long soft landing.
private func expo(_ x: Double) -> Double { CurveKey.cubicBezier(x, 0.16, 1, 0.3, 1) }
/// Overshoots a little before settling.
private func back(_ x: Double) -> Double { CurveKey.cubicBezier(x, 0.34, 1.56, 0.64, 1) }
private func smooth(_ x: Double) -> Double { Easing.easeInOut.apply(x) }

private struct Line {
    let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    var height: CGFloat { ascent + descent }

    init(_ s: String, font: NSFont, color: RGBA, kern: CGFloat = 0) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.cgColor, .kern: kern]
        if kern == 0 { attrs[.kern] = nil }
        line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        var a: CGFloat = 0, d: CGFloat = 0
        // Trailing tracking after the last letter would push centered text left.
        width = max(0, CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil)) - (s.isEmpty ? 0 : kern))
        ascent = a
        descent = d
    }

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

private final class Design {
    /// Where parts draw; swapped while a shadow's coverage is drawn small.
    var ctx: CGContext
    let W: CGFloat
    let H: CGFloat
    let v: GeneratorRenderer.Values
    let k: TitlePresets.Clocks

    init(ctx: CGContext, W: CGFloat, H: CGFloat, v: GeneratorRenderer.Values, k: TitlePresets.Clocks) {
        self.ctx = ctx
        self.W = W
        self.H = H
        self.v = v
        self.k = k
    }

    /// Progress of a part that builds on between fractions `s` and `s + l` of the build-on and leaves in reverse
    /// between fractions of the build-off.
    func phase(_ s: Double, _ l: Double, out os: Double = 0, _ ol: Double = 1) -> Double {
        min(clamp01((k.a - s) / l), clamp01((k.b - os) / ol))
    }

    func font(_ size: CGFloat, _ weight: Int, name: String? = nil) -> NSFont {
        TextRenderer.font(name ?? v.text("font"), size: max(size, 1), weight: weight)
    }

    /// Shrinks a size so `text` fits `limit` wide.
    func fitted(_ text: String, size: CGFloat, weight: Int, limit: CGFloat, kern: CGFloat = 0) -> CGFloat {
        let w = Line(text, font: font(size, weight), color: .white, kern: kern * size).width
        return w > limit && w > 0 ? size * limit / w : size
    }

    /// Group with a soft shadow so light type reads over bright footage.
    /// `rect` bounds the drawing; the shadow spreads past it.
    /// The shadow is the group's coverage drawn at quarter size and blurred, which costs far less than a
    /// Core Graphics shadow of the same softness.
    func shadowed(_ size: CGFloat, alpha: CGFloat = 0.32, in rect: CGRect, _ body: () -> Void) {
        let blur = size * 0.35
        let r = rect.insetBy(dx: -blur * 2, dy: -blur * 2).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        let s: CGFloat = 0.25
        let mw = max(1, Int((r.width * s).rounded(.up))), mh = max(1, Int((r.height * s).rounded(.up)))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if !r.isEmpty, let small = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: mw * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let soft = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: mw * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            small.translateBy(x: 0, y: CGFloat(mh))
            small.scaleBy(x: s, y: -s)
            small.translateBy(x: -r.minX, y: -r.minY)
            let main = ctx
            ctx = small
            body()
            ctx = main
            let k = UInt32(max(1, Int((blur * s).rounded()))) * 2 + 1
            var inBuf = vImage_Buffer(data: small.data, height: vImagePixelCount(mh), width: vImagePixelCount(mw), rowBytes: small.bytesPerRow)
            var outBuf = vImage_Buffer(data: soft.data, height: vImagePixelCount(mh), width: vImagePixelCount(mw), rowBytes: soft.bytesPerRow)
            vImageTentConvolve_ARGB8888(&inBuf, &outBuf, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
            // Black, keeping the blurred coverage: zero the three color channels of the RGBA pixels.
            vImageOverwriteChannelsWithScalar_ARGB8888(0, &outBuf, &outBuf, 0xE, vImage_Flags(kvImageNoFlags))
            if let image = soft.makeImage() {
                ctx.saveGState()
                ctx.setAlpha(alpha)
                // Images draw upside down in this y-down context; flip about the rect.
                ctx.translateBy(x: 0, y: r.minY + r.maxY + size * 0.1)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .low
                ctx.draw(image, in: CGRect(x: r.minX, y: r.maxY - CGFloat(mh) / s, width: CGFloat(mw) / s, height: CGFloat(mh) / s))
                ctx.restoreGState()
            }
        }
        body()
    }

    func clipped(_ r: CGRect, _ body: () -> Void) {
        ctx.saveGState()
        ctx.clip(to: r)
        body()
        ctx.restoreGState()
    }

    func faded(_ alpha: Double, _ body: () -> Void) {
        guard alpha > 0.001 else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        body()
        ctx.restoreGState()
    }

    func fill(_ path: CGPath, _ c: RGBA) {
        ctx.addPath(path)
        ctx.setFillColor(c.cgColor)
        ctx.fillPath()
    }

    func stroke(_ path: ShapePath, _ c: RGBA, width: CGFloat, trim: Double = 1, from: Double = 0, cap: CGLineCap = .round) {
        guard trim > from + 1e-4 else { return }
        ctx.addPath(ShapeRenderer.cgPath(path.trimmed(start: from, end: trim), scale: 1))
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    func background() {
        let bg = v.color("background")
        guard bg.a > 0 else { return }
        let p = phase(0, 0.3, out: 0, 0.4)
        guard p > 0 else { return }
        ctx.setFillColor(bg.with(alpha: bg.a * smooth(p)).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }

    var hasBackground: Bool { v.color("background").a > 0.5 }

    // MARK: Lower thirds

    func modern() {
        let fs = max(v.num("size") * H, 1)
        let accent = v.color("accent"), tc = v.color("text_color")
        let title = Line(v.text("title"), font: font(fs, 700), color: tc, kern: -0.01 * fs)
        let subSize = fs * 0.4
        let subText = v.text("subtitle").uppercased()
        let sub = subText.isEmpty ? nil : Line(subText, font: font(subSize, 600), color: tc.with(alpha: tc.a * 0.86), kern: 0.16 * subSize)
        let gap = fs * 0.22
        let blockH = title.height + (sub.map { gap + $0.height } ?? 0)
        let x0 = v.num("x") * W, cy = v.num("y") * H
        let top = cy - blockH / 2
        let barW = max(2, fs * 0.085)
        let tx = x0 + barW + fs * 0.34
        let pb = phase(0, 0.45, out: 0, 0.45)
        let pt = expo(phase(0.18, 0.6, out: 0.2, 0.6))
        let ps = expo(phase(0.36, 0.64, out: 0.32, 0.68))
        guard pb > 0 else { return }
        shadowed(fs, in: CGRect(x: x0, y: top - fs * 0.5, width: barW + fs * 1.5 + max(title.width, sub?.width ?? 0), height: blockH + fs)) {
            let barH = (blockH + fs * 0.24) * CGFloat(back(pb))
            fill(CGPath(rect: CGRect(x: x0, y: cy - barH / 2, width: barW, height: barH), transform: nil), accent)
            // Text slides out from behind the bar.
            clipped(CGRect(x: x0 + barW, y: top - fs, width: W, height: blockH + 2 * fs)) {
                if pt > 0 {
                    title.draw(ctx, x: tx - (1 - CGFloat(pt)) * (title.width + fs * 0.6), baseline: top + title.ascent)
                }
                if let sub, ps > 0 {
                    let y = top + title.height + gap
                    clipped(CGRect(x: x0 + barW, y: y - fs * 0.05, width: W, height: sub.height + fs * 0.1)) {
                        sub.draw(ctx, x: tx, baseline: y + sub.ascent + (1 - CGFloat(ps)) * sub.height * 1.2)
                    }
                }
            }
        }
    }

    func box() {
        let fs = max(v.num("size") * H, 1)
        let accent = v.color("accent"), panel = v.color("panel"), tc = v.color("text_color")
        let title = Line(v.text("title"), font: font(fs, 700), color: tc, kern: -0.005 * fs)
        let subSize = fs * 0.56
        let subText = v.text("subtitle")
        let sub = subText.isEmpty ? nil : Line(subText, font: font(subSize, 500), color: tc.with(alpha: tc.a * 0.92), kern: 0.01 * subSize)
        let padX = fs * 0.42, padY = fs * 0.24
        let nameBox = CGSize(width: title.width + padX * 2, height: title.height + padY * 2)
        var roleBox = sub.map { CGSize(width: $0.width + padX * 1.6, height: $0.height + padY * 1.5) } ?? .zero
        // Nearly equal widths read as a mistake; square them up.
        if sub != nil, abs(roleBox.width - nameBox.width) < padX { roleBox.width = nameBox.width }
        let x0 = v.num("x") * W, cy = v.num("y") * H
        let top = cy - (nameBox.height + roleBox.height) / 2
        let pn = expo(phase(0, 0.5, out: 0.25, 0.75))
        let ptxt = expo(phase(0.15, 0.55, out: 0.3, 0.7))
        let pr = expo(phase(0.28, 0.5, out: 0, 0.6))
        let ps = expo(phase(0.42, 0.58, out: 0.05, 0.6))
        guard pn > 0 || pr > 0 else { return }
        shadowed(fs, alpha: 0.28, in: CGRect(x: x0, y: top, width: max(nameBox.width, roleBox.width), height: nameBox.height + roleBox.height)) {
            if let sub, pr > 0 {
                let r = CGRect(x: x0 + fs * 0.0, y: top + nameBox.height, width: roleBox.width * CGFloat(pr), height: roleBox.height)
                fill(CGPath(rect: r, transform: nil), panel)
                clipped(r) {
                    sub.draw(ctx, x: r.minX + padX * 0.8 - (1 - CGFloat(ps)) * fs * 0.6, baseline: r.minY + padY * 0.75 + sub.ascent)
                }
            }
            if pn > 0 {
                let r = CGRect(x: x0, y: top, width: nameBox.width * CGFloat(pn), height: nameBox.height)
                fill(CGPath(rect: r, transform: nil), accent)
                clipped(r) {
                    title.draw(ctx, x: x0 + padX - (1 - CGFloat(ptxt)) * fs * 0.8, baseline: top + padY + title.ascent)
                }
            }
        }
    }

    func pill() {
        let fs = max(v.num("size") * H, 1)
        let accent = v.color("accent"), panel = v.color("panel"), tc = v.color("text_color")
        let name = v.text("title")
        let title = Line(name, font: font(fs, 700), color: tc, kern: -0.005 * fs)
        let subText = v.text("subtitle")
        let subSize = fs * 0.62
        let sub = subText.isEmpty ? nil : Line(subText, font: font(subSize, 500), color: tc.with(alpha: tc.a * 0.7))
        let gap = fs * 0.08
        let textH = title.height + (sub.map { gap + $0.height } ?? 0)
        let badge = max(textH * 0.9, fs * 1.4)
        let inset = fs * 0.32
        let ringGap = fs * 0.1
        let pillH = badge + 2 * inset
        let x0 = v.num("x") * W, cy = v.num("y") * H
        let textW = max(title.width, sub?.width ?? 0)
        let fullW = pillH + fs * 0.25 + textW + pillH * 0.5
        let bc = CGPoint(x: x0 + pillH / 2, y: cy)
        let pBadge = phase(0, 0.38, out: 0, 0.45)
        let pRing = smooth(phase(0.12, 0.5, out: 0.1, 0.5))
        let pPill = expo(phase(0.28, 0.5, out: 0.2, 0.6))
        let pTitle = expo(phase(0.46, 0.5, out: 0.4, 0.6))
        let pSub = expo(phase(0.56, 0.44, out: 0.45, 0.55))
        guard pBadge > 0 || pPill > 0 else { return }
        shadowed(fs, alpha: 0.25, in: CGRect(x: x0 - fs * 0.2, y: cy - pillH / 2 - fs * 0.2, width: fullW + fs * 0.4, height: pillH + fs * 0.4)) {
            if pPill > 0 {
                let w = pillH + (fullW - pillH) * CGFloat(pPill)
                let r = CGRect(x: x0, y: cy - pillH / 2, width: w, height: pillH)
                let path = CGPath(roundedRect: r, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)
                fill(path, panel.with(alpha: panel.a * min(1, pPill * 3)))
                clipped(r.insetBy(dx: pillH * 0.25, dy: 0)) {
                    let tx = x0 + pillH + fs * 0.25
                    let top = cy - textH / 2
                    if pTitle > 0 {
                        faded(pTitle) { title.draw(ctx, x: tx - (1 - CGFloat(pTitle)) * fs * 0.7, baseline: top + title.ascent) }
                    }
                    if let sub, pSub > 0 {
                        faded(pSub) { sub.draw(ctx, x: tx - (1 - CGFloat(pSub)) * fs * 0.7, baseline: top + title.height + gap + sub.ascent) }
                    }
                }
            }
            if pBadge > 0 {
                let s = CGFloat(back(pBadge))
                let r = badge / 2 * s
                fill(CGPath(ellipseIn: CGRect(x: bc.x - r, y: bc.y - r, width: 2 * r, height: 2 * r), transform: nil), accent)
                var initials = v.text("badge")
                if initials.isEmpty { initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
                let mark = Line(initials, font: font(badge * 0.38 * s, 700), color: .white, kern: 0.02 * badge * 0.38 * s)
                if s > 0.05 { mark.draw(ctx, x: bc.x - mark.width / 2, baseline: bc.y + (mark.ascent - mark.descent) / 2) }
            }
            if pRing > 0 {
                let rr = badge / 2 + ringGap
                let ring = ShapePath.ellipse(width: rr * 2, height: rr * 2).mapped { PathPoint($0.x + bc.x, $0.y + bc.y) }
                stroke(ring, accent.with(alpha: accent.a * 0.9), width: max(1.5, fs * 0.05), trim: pRing)
            }
        }
    }

    func line() {
        let fs = max(v.num("size") * H, 1)
        let accent = v.color("accent"), tc = v.color("text_color")
        let title = Line(v.text("title"), font: font(fs, 600), color: tc, kern: -0.005 * fs)
        let subSize = fs * 0.38
        let subText = v.text("subtitle").uppercased()
        let sub = subText.isEmpty ? nil : Line(subText, font: font(subSize, 500), color: tc.with(alpha: tc.a * 0.82), kern: 0.2 * subSize)
        let centered = v.text("align") == "center"
        let length = max(title.width, sub?.width ?? 0) + fs * 0.8
        let x0 = centered ? v.num("x") * W - length / 2 : v.num("x") * W
        let ry = v.num("y") * H
        let pr = smooth(phase(0, 0.55, out: 0, 0.6))
        let pt = expo(phase(0.25, 0.6, out: 0.25, 0.6))
        let ps = expo(phase(0.35, 0.6, out: 0.3, 0.6))
        guard pr > 0 || pt > 0 else { return }
        let rule = ShapePath([.init(start: PathPoint(x0, ry), segments: [.line(PathPoint(x0 + length, ry))])])
        func tx(_ w: CGFloat) -> CGFloat { centered ? x0 + (length - w) / 2 : x0 }
        shadowed(fs, alpha: 0.35, in: CGRect(x: x0 - fs, y: ry - title.height - fs, width: length + 2 * fs, height: title.height + (sub?.height ?? 0) + fs * 2)) {
            let width = max(1.5, fs * 0.035)
            if centered {
                stroke(rule, accent, width: width, trim: 0.5 + pr / 2, from: 0.5 - pr / 2, cap: .butt)
            } else {
                stroke(rule, accent, width: width, trim: pr, cap: .butt)
            }
            let above = ry - fs * 0.24
            if pt > 0 {
                clipped(CGRect(x: 0, y: above - title.height - fs * 0.2, width: W, height: title.height + fs * 0.2)) {
                    title.draw(ctx, x: tx(title.width), baseline: above - title.descent + (1 - CGFloat(pt)) * (title.height + fs * 0.1))
                }
            }
            if let sub, ps > 0 {
                let below = ry + fs * 0.26
                clipped(CGRect(x: 0, y: below, width: W, height: sub.height + fs * 0.2)) {
                    sub.draw(ctx, x: tx(sub.width), baseline: below + sub.ascent - (1 - CGFloat(ps)) * (sub.height + fs * 0.1))
                }
            }
        }
    }

    // MARK: Cards

    func card() {
        background()
        let fs0 = max(v.num("size") * H, 1)
        let accent = v.color("accent"), tc = v.color("text_color")
        let titleText = v.text("title")
        let fs = fitted(titleText, size: fs0, weight: 750, limit: W * 0.86, kern: -0.02)
        let title = Line(titleText, font: font(fs, 750), color: tc, kern: -0.02 * fs)
        let kSize = fs * 0.2
        let kickerText = v.text("kicker").uppercased()
        let pk = expo(phase(0, 0.7, out: 0, 0.7))
        let kicker = kickerText.isEmpty ? nil : Line(kickerText, font: font(kSize, 600), color: accent, kern: (0.3 + 0.35 * (1 - CGFloat(pk))) * kSize)
        let subSize = fs * 0.28
        let subText = v.text("subtitle")
        let sub = subText.isEmpty ? nil : Line(subText, font: font(subSize, 400), color: tc.with(alpha: tc.a * 0.8), kern: 0.02 * subSize)
        let ruleH = max(2, fs * 0.045), ruleW = fs * 1.1
        let g1 = fs * 0.34, g2 = fs * 0.3
        let total = (kicker.map { $0.height + g1 } ?? 0) + title.height + g2 + ruleH + (sub.map { g2 + $0.height } ?? 0)
        let cx = v.num("x") * W
        let top = v.num("y") * H - total / 2
        let pt = expo(phase(0.12, 0.62, out: 0.1, 0.7))
        let pr = expo(phase(0.36, 0.5, out: 0.25, 0.6))
        let ps = expo(phase(0.5, 0.5, out: 0.35, 0.65))
        func body() {
            var y = top
            if let kicker {
                if pk > 0 { faded(pk) { kicker.draw(ctx, x: cx - kicker.width / 2, baseline: y + kicker.ascent) } }
                y += kicker.height + g1
            }
            if pt > 0 {
                let box = CGRect(x: 0, y: y - fs * 0.05, width: W, height: title.height + fs * 0.1)
                clipped(box) { title.draw(ctx, x: cx - title.width / 2, baseline: y + title.ascent + (1 - CGFloat(pt)) * title.height * 1.05) }
            }
            y += title.height + g2
            if pr > 0 {
                let w = ruleW * CGFloat(pr)
                fill(CGPath(rect: CGRect(x: cx - w / 2, y: y, width: w, height: ruleH), transform: nil), accent)
            }
            y += ruleH
            if let sub, ps > 0 {
                y += g2
                faded(ps) { sub.draw(ctx, x: cx - sub.width / 2, baseline: y + sub.ascent + (1 - CGFloat(ps)) * fs * 0.25) }
            }
        }
        if hasBackground { body() } else { shadowed(fs * 0.6, alpha: 0.4, in: CGRect(x: cx - max(title.width, kicker?.width ?? 0, sub?.width ?? 0) / 2 - fs * 0.3, y: top - fs * 0.3, width: max(title.width, kicker?.width ?? 0, sub?.width ?? 0) + fs * 0.6, height: total + fs * 0.9), body) }
    }

    func wrap(_ text: String, font f: NSFont, width: CGFloat) -> [String] {
        var lines: [String] = []
        for para in text.components(separatedBy: "\n") {
            var cur = ""
            for word in para.split(separator: " ") {
                let next = cur.isEmpty ? String(word) : cur + " " + word
                if !cur.isEmpty, Line(next, font: f, color: .white).width > width {
                    lines.append(cur)
                    cur = String(word)
                } else {
                    cur = next
                }
            }
            lines.append(cur)
        }
        return lines
    }

    func quote() {
        background()
        let fs = max(v.num("size") * H, 1)
        let accent = v.color("accent"), tc = v.color("text_color")
        let f = font(fs, 400)
        let maxW = v.num("width") * W
        let rows = wrap(v.text("quote"), font: f, width: maxW).map { Line($0, font: f, color: tc) }
        let lead = fs * 1.38
        let markSize = fs * 3.4
        let mark = Line("\u{201C}", font: font(markSize, 700, name: v.text("font")), color: accent)
        let markH = markSize * 0.52
        let authorText = v.text("author").uppercased()
        let aSize = fs * 0.4
        let author = authorText.isEmpty ? nil : Line(authorText, font: font(aSize, 600, name: "system"), color: tc.with(alpha: tc.a * 0.85), kern: 0.18 * aSize)
        let ruleW = fs * 0.9, ruleH = max(1.5, fs * 0.04)
        let textH = CGFloat(max(rows.count - 1, 0)) * lead + (rows.first.map { $0.height } ?? 0)
        let total = markH + fs * 0.25 + textH + (author.map { fs * 0.9 + ruleH + fs * 0.45 + $0.height } ?? 0)
        let cx = v.num("x") * W
        let top = v.num("y") * H - total / 2
        let pm = phase(0, 0.4, out: 0, 0.7)
        func body() {
            var y = top
            if pm > 0 {
                let s = CGFloat(back(pm))
                faded(min(1, pm * 2)) {
                    ctx.saveGState()
                    ctx.translateBy(x: cx, y: y + markH / 2)
                    ctx.scaleBy(x: s, y: s)
                    mark.draw(ctx, x: -mark.width / 2, baseline: markSize * 0.62)
                    ctx.restoreGState()
                }
            }
            y += markH + fs * 0.25
            let n = rows.count
            for (i, row) in rows.enumerated() {
                let start = 0.12 + 0.42 * Double(i) / Double(max(n - 1, 1))
                let p = expo(phase(start, 0.46, out: 0.1 * Double(n - 1 - i) / Double(max(n - 1, 1)), 0.7))
                if p > 0 {
                    faded(p) { row.draw(ctx, x: cx - row.width / 2, baseline: y + CGFloat(i) * lead + row.ascent + (1 - CGFloat(p)) * fs * 0.4) }
                }
            }
            y += textH
            if let author {
                y += fs * 0.9
                let pr = expo(phase(0.62, 0.38, out: 0.4, 0.6))
                if pr > 0 {
                    let w = ruleW * CGFloat(pr)
                    fill(CGPath(rect: CGRect(x: cx - w / 2, y: y, width: w, height: ruleH), transform: nil), accent)
                    y += ruleH + fs * 0.45
                    faded(pr) { author.draw(ctx, x: cx - author.width / 2, baseline: y + author.ascent) }
                }
            }
        }
        if hasBackground { body() } else { shadowed(fs, alpha: 0.4, in: CGRect(x: cx - maxW / 2 - fs, y: top - fs * 0.5, width: maxW + 2 * fs, height: total + fs), body) }
    }

    func endCard() {
        background()
        let fs = fitted(v.text("title"), size: max(v.num("size") * H, 1), weight: 700, limit: W * 0.86)
        let accent = v.color("accent"), tc = v.color("text_color")
        let title = Line(v.text("title"), font: font(fs, 700), color: tc, kern: -0.015 * fs)
        let subText = v.text("subtitle")
        let sub = subText.isEmpty ? nil : Line(subText, font: font(fs * 0.36, 400), color: tc.with(alpha: tc.a * 0.72))
        let slots = Int(v.num("slots").rounded())
        let slotW = W * 0.3, slotH = slotW * 9 / 16, slotGap = W * 0.035
        let buttonText = v.text("button")
        let bSize = fs * 0.4
        let button = buttonText.isEmpty ? nil : Line(buttonText, font: font(bSize, 700), color: .white, kern: 0.01 * bSize)
        let titleY = slots > 0 ? H * 0.17 : H * 0.36
        let slotsY = H * 0.36
        let buttonY = slots > 0 ? slotsY + slotH + H * 0.1 : H * 0.6
        let cx = W / 2
        let pt = expo(phase(0, 0.55, out: 0.2, 0.8))
        let ps = expo(phase(0.12, 0.5, out: 0.15, 0.8))
        if pt > 0 {
            faded(pt) { title.draw(ctx, x: cx - title.width / 2, baseline: titleY + title.ascent + (1 - CGFloat(pt)) * fs * 0.35) }
        }
        if let sub, ps > 0 {
            faded(ps) { sub.draw(ctx, x: cx - sub.width / 2, baseline: titleY + title.height + fs * 0.12 + sub.ascent + (1 - CGFloat(ps)) * fs * 0.3) }
        }
        let rowW = CGFloat(slots) * slotW + CGFloat(max(slots - 1, 0)) * slotGap
        for i in 0..<max(0, min(slots, 2)) {
            let p = smooth(phase(0.2 + 0.12 * Double(i), 0.55, out: 0.1, 0.8))
            guard p > 0 else { continue }
            let r = CGRect(x: cx - rowW / 2 + CGFloat(i) * (slotW + slotGap), y: slotsY, width: slotW, height: slotH)
            let radius = slotH * 0.06
            ctx.setFillColor(tc.with(alpha: tc.a * 0.06 * p).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            let outline = ShapePath.rect(width: slotW, height: slotH, radius: radius).mapped { PathPoint($0.x + r.midX, $0.y + r.midY) }
            stroke(outline, tc.with(alpha: tc.a * 0.55), width: max(1.5, H * 0.0035), trim: p)
            let tri = slotH * 0.16
            let play = CGMutablePath()
            play.move(to: CGPoint(x: r.midX - tri * 0.4, y: r.midY - tri / 2))
            play.addLine(to: CGPoint(x: r.midX + tri * 0.55, y: r.midY))
            play.addLine(to: CGPoint(x: r.midX - tri * 0.4, y: r.midY + tri / 2))
            play.closeSubpath()
            fill(play, tc.with(alpha: tc.a * 0.35 * p * p))
        }
        if let button {
            let p = phase(0.5, 0.45, out: 0, 0.7)
            guard p > 0 else { return }
            let s = CGFloat(back(p))
            let bw = button.width + bSize * 2.2, bh = button.height + bSize * 1.1
            ctx.saveGState()
            ctx.translateBy(x: cx, y: buttonY + bh / 2)
            ctx.scaleBy(x: s, y: s)
            fill(CGPath(roundedRect: CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh), cornerWidth: bh / 2, cornerHeight: bh / 2, transform: nil), accent.with(alpha: accent.a * min(1, p * 2)))
            button.draw(ctx, x: -button.width / 2, baseline: (button.ascent - button.descent) / 2)
            ctx.restoreGState()
        }
    }

    func dataCallout() {
        let fs = max(v.num("size") * H, 1)
        let accent = v.color("accent"), track = v.color("track"), tc = v.color("text_color")
        let style = v.text("style")
        let pc = expo(clamp01(k.c))
        let n = Double(v.num("from")) + (Double(v.num("value")) - Double(v.num("from"))) * pc
        let digits = GeneratorRenderer.format(n, decimals: Int(v.num("decimals").rounded()), separator: true)
        var f = font(fs, 700)
        if ["system", ""].contains(v.text("font").lowercased()) {
            f = NSFont.monospacedDigitSystemFont(ofSize: fs, weight: .bold)
        } else {
            let tabular = f.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
            f = NSFont(descriptor: tabular, size: fs) ?? f
        }
        let number = Line(v.text("prefix") + digits + v.text("suffix"), font: f, color: tc, kern: -0.02 * fs)
        // The widest the number gets, so the layout holds still while it counts.
        let widest = Line(v.text("prefix") + GeneratorRenderer.format(max(abs(Double(v.num("value"))), abs(Double(v.num("from")))), decimals: Int(v.num("decimals").rounded()), separator: true) + v.text("suffix"), font: f, color: tc, kern: -0.02 * fs)
        let labelText = v.text("label")
        let lSize = fs * 0.2
        let label = labelText.isEmpty ? nil : Line(labelText, font: font(lSize, 500), color: tc.with(alpha: tc.a * 0.82), kern: 0.01 * lSize)
        let cx = v.num("x") * W, cy = v.num("y") * H
        let pIn = expo(phase(0, 0.55, out: 0.15, 0.85))
        let pLabel = expo(phase(0.35, 0.65, out: 0, 0.7))
        guard pIn > 0 else { return }
        let fillTo = Double(v.num("fill")) * pc
        let numberBaseline: (CGFloat) -> CGFloat = { center in center + (f.capHeight) / 2 }
        let radius = max(widest.width / 2 + fs * 0.42, fs * 1.0)
        let w = max(2, fs * 0.13)
        let barW = max(widest.width * 1.6, fs * 4), barH = max(3, fs * 0.11)
        let half = max(style == "ring" ? radius + w : style == "bar" ? barW / 2 : widest.width / 2, (label?.width ?? 0) / 2)
        let above = style == "ring" ? radius + w : fs
        let below = (style == "ring" ? radius + w : fs * 0.5) + fs * 0.6
        shadowed(fs * 0.5, alpha: 0.3, in: CGRect(x: cx - half, y: cy - above, width: half * 2, height: above + below)) {
            switch style {
            case "ring":
                let s = 0.92 + 0.08 * CGFloat(pIn)
                faded(pIn) {
                    ctx.saveGState()
                    ctx.translateBy(x: cx, y: cy)
                    ctx.scaleBy(x: s, y: s)
                    let ring = ShapePath.ellipse(width: radius * 2, height: radius * 2)
                    stroke(ring, track, width: w)
                    stroke(ring, accent, width: w, trim: fillTo)
                    number.draw(ctx, x: -number.width / 2, baseline: numberBaseline(0))
                    ctx.restoreGState()
                }
                if let label, pLabel > 0 {
                    faded(pLabel) { label.draw(ctx, x: cx - label.width / 2, baseline: cy + radius + w + fs * 0.3 + label.ascent + (1 - CGFloat(pLabel)) * fs * 0.15) }
                }
            case "bar":
                let left = cx - barW / 2
                let barY = cy + fs * 0.2
                faded(pIn) {
                    number.draw(ctx, x: left, baseline: barY - fs * 0.22 + (1 - CGFloat(pIn)) * fs * 0.2)
                    let r = CGRect(x: left, y: barY, width: barW, height: barH)
                    fill(CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil), track)
                    if fillTo > 0.001 {
                        let fw = max(barH, barW * CGFloat(fillTo))
                        fill(CGPath(roundedRect: CGRect(x: left, y: barY, width: fw, height: barH), cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil), accent)
                    }
                }
                if let label, pLabel > 0 {
                    faded(pLabel) { label.draw(ctx, x: left, baseline: barY + barH + fs * 0.2 + label.ascent) }
                }
            default:
                faded(pIn) { number.draw(ctx, x: cx - number.width / 2, baseline: numberBaseline(cy) + (1 - CGFloat(pIn)) * fs * 0.2) }
                if let label, pLabel > 0 {
                    faded(pLabel) { label.draw(ctx, x: cx - label.width / 2, baseline: cy + fs * 0.5 + fs * 0.25 + label.ascent) }
                }
            }
        }
    }
}
