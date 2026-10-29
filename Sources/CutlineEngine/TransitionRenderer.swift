import CoreImage
import CutlineCore
import Foundation

/// Draws a transition between two placed layers. `p` is eased progress, 0 all outgoing to 1 all incoming.
enum TransitionRenderer {
    static func render(_ tr: Transition, a: CIImage?, b: CIImage?, p: Double, canvas c: CGRect, frame: Int) -> CIImage {
        let clear = CIImage(color: .clear).cropped(to: c)
        let a = (a ?? clear).cropped(to: c), b = (b ?? clear).cropped(to: c)
        let p = min(max(p, 0), 1)
        let peak = 1 - abs(2 * p - 1)
        let u = direction(tr.string("direction"))
        switch tr.type {
        case "dip":
            let color = solid(tr.string("color"), c)
            let hold = min(max(tr.number("hold"), 0), 0.8)
            let ramp = (1 - hold) / 2
            if p < ramp { return mix(a, color, p / ramp) }
            if p > 1 - ramp { return mix(color, b, (p - (1 - ramp)) / ramp) }
            return color
        case "flash":
            let f = tr.number("intensity") * pow(peak, 1.5)
            return mix(p < 0.5 ? a : b, solid(tr.string("color"), c), f)
        case "wipe":
            return b.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: wipeMask(u, angle: tr.number("angle"), softness: tr.number("softness"), p: p, c)]).cropped(to: c)
        case "iris":
            let center = CGPoint(x: c.minX + c.width * tr.number("center_x"), y: c.minY + c.height * (1 - tr.number("center_y")))
            let far = [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY), CGPoint(x: c.minX, y: c.maxY), CGPoint(x: c.maxX, y: c.maxY)].map { hypot($0.x - center.x, $0.y - center.y) }.max()!
            let sw = max(1, tr.number("softness") * max(c.width, c.height))
            let r = p * (far + sw)
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(cgPoint: center), "inputRadius0": max(0, r - sw), "inputRadius1": max(0.5, r),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!.cropped(to: c)
            return b.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: mask]).cropped(to: c)
        case "slide":
            return shift(b, by: CGPoint(x: -u.x, y: -u.y), (1 - p), c).composited(over: a).cropped(to: c)
        case "push":
            return shift(b, by: CGPoint(x: -u.x, y: -u.y), (1 - p), c).composited(over: shift(a, by: u, p, c)).cropped(to: c)
        case "whip":
            let pushed = shift(b, by: CGPoint(x: -u.x, y: -u.y), (1 - p), c).composited(over: shift(a, by: u, p, c)).cropped(to: c)
            let radius = tr.number("blur") * c.height * sin(.pi * p)
            guard radius > 0.5 else { return pushed }
            return pushed.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(u.y, u.x)]).cropped(to: c)
        case "zoom":
            let amount = tr.number("amount")
            let za = scaled(a, 1 + amount * p, c), zb = scaled(b, 1 + amount * (1 - p), c)
            var out = mix(za, zb, smooth((p - 0.3) / 0.4))
            let blur = tr.number("blur") * c.height * peak
            if blur > 0.5 {
                out = out.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: c.midX, y: c.midY), kCIInputAmountKey: blur]).cropped(to: c)
            }
            return out
        case "blur":
            let r = tr.number("radius") * c.height
            return mix(blurred(a, r * min(1, p * 2), c), blurred(b, r * min(1, (1 - p) * 2), c), smooth((p - 0.25) / 0.5))
        case "spin":
            let turns = tr.number("turns")
            let grow = 1 + 0.45 * sin(.pi * p)
            let ra = rotated(a, turns * 2 * .pi * p, scale: grow, c), rb = rotated(b, -turns * 2 * .pi * (1 - p), scale: grow, c)
            var out = mix(ra, rb, smooth((p - 0.35) / 0.3))
            let blur = 0.05 * c.height * peak * abs(turns) * 4
            if blur > 0.5 {
                out = out.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: c.midX, y: c.midY), kCIInputAmountKey: blur]).cropped(to: c)
            }
            return out
        case "glitch":
            return glitch(p < 0.5 ? a : b, amount: tr.number("intensity") * pow(peak, 0.7), frame: frame, c)
        default:
            return mix(a, b, p)
        }
    }

    /// Unit vector of the motion in Core Image coordinates (y up).
    static func direction(_ s: String) -> CGPoint {
        switch s {
        case "right": return CGPoint(x: 1, y: 0)
        case "up": return CGPoint(x: 0, y: 1)
        case "down": return CGPoint(x: 0, y: -1)
        default: return CGPoint(x: -1, y: 0)
        }
    }

    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func solid(_ hex: String, _ c: CGRect) -> CIImage {
        CIImage(color: CIColor(cgColor: (RGBA(hex: hex) ?? .black).cgColor)).cropped(to: c)
    }

    static func mix(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        if t <= 0.0005 { return a }
        if t >= 0.9995 { return b }
        return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: t])
    }

    static func shift(_ img: CIImage, by u: CGPoint, _ amount: Double, _ c: CGRect) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: u.x * c.width * amount, y: u.y * c.height * amount))
    }

    static func scaled(_ img: CIImage, _ s: Double, _ c: CGRect) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: -c.midX, y: -c.midY).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: c.midX, y: c.midY))).cropped(to: c)
    }

    static func rotated(_ img: CIImage, _ angle: Double, scale: Double, _ c: CGRect) -> CIImage {
        let t = CGAffineTransform(translationX: -c.midX, y: -c.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(translationX: c.midX, y: c.midY))
        return img.transformed(by: t).cropped(to: c)
    }

    /// Full-frame layers blur with clamped edges; partial layers blur into transparency.
    static func blurred(_ img: CIImage, _ r: Double, _ c: CGRect) -> CIImage {
        guard r > 0.3 else { return img }
        if img.extent.insetBy(dx: -1, dy: -1).contains(c) {
            return img.clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: c)
        }
        return img.applyingGaussianBlur(sigma: r).cropped(to: c)
    }

    /// White where the incoming picture shows. The edge travels along `u`, revealing from behind it.
    static func wipeMask(_ u: CGPoint, angle: Double, softness: Double, p: Double, _ c: CGRect) -> CIImage {
        let a = angle * .pi / 180
        let d = CGPoint(x: u.x * cos(a) - u.y * sin(a), y: u.x * sin(a) + u.y * cos(a))
        let reach = abs(d.x) * c.width / 2 + abs(d.y) * c.height / 2
        let sw = max(1, softness * max(c.width, c.height))
        // s is the distance along -d from the center; the incoming picture covers s > threshold.
        let threshold = (reach + sw / 2) - p * (2 * reach + sw)
        func point(_ s: Double) -> CIVector { CIVector(x: c.midX - d.x * s, y: c.midY - d.y * s) }
        return CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": point(threshold - sw / 2), "inputColor0": CIColor.black,
            "inputPoint1": point(threshold + sw / 2), "inputColor1": CIColor.white,
        ])!.outputImage!.cropped(to: c)
    }

    /// RGB split plus displaced horizontal slices, varying per frame.
    static func glitch(_ img: CIImage, amount g: Double, frame: Int, _ c: CGRect) -> CIImage {
        guard g > 0.02 else { return img }
        func channel(_ r: CGFloat, _ gr: CGFloat, _ b: CGFloat) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gr, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        let split = g * c.width * 0.025
        let red = channel(1, 0, 0).transformed(by: CGAffineTransform(translationX: split, y: 0))
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).transformed(by: CGAffineTransform(translationX: -split, y: 0))
        var out = red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue]).cropped(to: c)
        var rng = UInt64(truncatingIfNeeded: frame &* 2_654_435_761 &+ 1)
        func next() -> Double {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Double(rng % 10_000) / 10_000
        }
        let bands = 3 + Int(g * 6)
        for _ in 0..<bands {
            let y = c.minY + next() * c.height
            let h = c.height * (0.02 + next() * 0.08 * g)
            let dx = (next() - 0.5) * c.width * 0.15 * g
            let slice = out.cropped(to: CGRect(x: c.minX, y: y, width: c.width, height: h)).transformed(by: CGAffineTransform(translationX: dx, y: 0))
            out = slice.composited(over: out).cropped(to: c)
        }
        if g > 0.6 {
            out = out.applyingFilter("CIPixellate", parameters: [kCIInputCenterKey: CIVector(x: c.midX, y: c.midY), kCIInputScaleKey: max(1, (g - 0.6) * c.height * 0.05)]).cropped(to: c)
        }
        return out
    }
}
