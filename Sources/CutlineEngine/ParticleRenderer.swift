import CoreGraphics
import CutlineCore
import Foundation
import ImageIO

/// Draws the `particles` generator.
enum ParticleRenderer {
    nonisolated(unsafe) private static var images: [String: CGImage] = [:]
    private static let lock = NSLock()

    /// A white disc fading to transparent, as a grayscale mask.
    static let softMask: CGImage = {
        let n = 64
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Double(x) + 0.5) / Double(n) * 2 - 1, dy = (Double(y) + 0.5) / Double(n) * 2 - 1
                let r = min(1, sqrt(dx * dx + dy * dy))
                let v = pow(max(0, 1 - r), 1.6)
                data[y * n + x] = UInt8((min(1, v * 1.25) * 255).rounded())
            }
        }
        return ctx.makeImage()!
    }()

    static func image(_ path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        if let hit = lock.withLock({ images[path] }) { return hit }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        lock.withLock {
            if images.count > 16 { images.removeAll() }
            images[path] = img
        }
        return img
    }

    static func render(time: Double, canvas: CGSize, value: (String, Double) -> ParamValue) -> CGImage? {
        let w = Int(canvas.width.rounded()), h = Int(canvas.height.rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .medium
        let particles = ParticleSystem.particles(at: time, width: Double(w), height: Double(h), value: value)
        let sprite = value("sprite", time).string ?? "soft"
        let picture = sprite == "image" ? image(value("image", time).string ?? "") : nil
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        for p in particles {
            let s = CGFloat(p.size)
            let c = CGPoint(x: p.x, y: p.y)
            guard bounds.insetBy(dx: -s * 4, dy: -s * 4).contains(c) || sprite == "spark" else { continue }
            let color = p.color.cgColor
            switch sprite {
            case "dot":
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
            case "soft", "snow":
                let k: CGFloat = sprite == "snow" ? 1.6 : 2.4
                let r = CGRect(x: c.x - s * k / 2, y: c.y - s * k / 2, width: s * k, height: s * k)
                ctx.saveGState()
                ctx.clip(to: r, mask: softMask)
                ctx.setFillColor(color)
                ctx.fill(r)
                ctx.restoreGState()
                if sprite == "soft" {
                    ctx.setFillColor(p.color.with(alpha: min(1, p.color.a * 1.1)).cgColor)
                    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.22, y: c.y - s * 0.22, width: s * 0.44, height: s * 0.44))
                }
            case "spark":
                let speed = hypot(p.vx, p.vy)
                let len = max(Double(s) * 1.5, min(speed * 0.06, Double(s) * 14))
                let dx = speed > 0 ? p.vx / speed : 0, dy = speed > 0 ? p.vy / speed : -1
                ctx.setStrokeColor(color)
                ctx.setLineCap(.round)
                ctx.setLineWidth(max(0.6, s * 0.45))
                ctx.move(to: c)
                ctx.addLine(to: CGPoint(x: c.x - dx * len, y: c.y - dy * len))
                ctx.strokePath()
            case "confetti":
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: CGFloat(p.rotation * .pi / 180))
                ctx.scaleBy(x: 1, y: CGFloat(max(0.08, abs(p.flip))))
                // The back of the paper is a little darker.
                let shade = p.flip < 0 ? 0.78 : 1
                ctx.setFillColor(RGBA(r: p.color.r * shade, g: p.color.g * shade, b: p.color.b * shade, a: p.color.a).cgColor)
                ctx.fill(CGRect(x: -s / 2, y: -s * 0.3, width: s, height: s * 0.6))
                ctx.restoreGState()
            case "star":
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: CGFloat(p.rotation * .pi / 180))
                ctx.addPath(ShapeRenderer.cgPath(.polygon(width: 1, height: 1, sides: 5, inner: 0.45), scale: s))
                ctx.setFillColor(color)
                ctx.fillPath()
                ctx.restoreGState()
            case "bubble":
                let r = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(max(0.6, s * 0.07))
                ctx.strokeEllipse(in: r.insetBy(dx: s * 0.035, dy: s * 0.035))
                ctx.setFillColor(p.color.with(alpha: p.color.a * 0.12).cgColor)
                ctx.fillEllipse(in: r)
                ctx.setFillColor(p.color.with(alpha: p.color.a * 0.85).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - s * 0.28, y: c.y - s * 0.3, width: s * 0.16, height: s * 0.12))
            case "image":
                guard let picture else { continue }
                let aspect = CGFloat(picture.width) / CGFloat(max(picture.height, 1))
                let iw = aspect >= 1 ? s : s * aspect, ih = aspect >= 1 ? s / aspect : s
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: CGFloat(p.rotation * .pi / 180))
                ctx.scaleBy(x: 1, y: -1)
                ctx.setAlpha(CGFloat(p.color.a))
                ctx.draw(picture, in: CGRect(x: -iw / 2, y: -ih / 2, width: iw, height: ih))
                ctx.restoreGState()
            default:
                break
            }
        }
        return ctx.makeImage()
    }
}
