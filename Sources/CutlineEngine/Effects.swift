import CoreImage
import CutlineCore
import Foundation
import simd

/// Renders catalog effects with Core Image.
///
/// Effects run on an image whose extent is the clip's own frame at canvas pixel scale,
/// so lengths given as fractions of the frame height mean the same thing in preview and export.
enum EffectRenderer {
    struct Context {
        /// Pixels per unit of "frame height" (the canvas height).
        var unit: CGFloat
        /// Timeline time, for effects that change every frame.
        var time: Double
        /// The image has no transparent areas, so edge pixels can be extended under blurs.
        var opaque: Bool
        /// Identifies the picture's source frame, so expensive per-frame masks can be cached.
        var source: MaskCache.Key? = nil
        /// Encoding color LUTs work in; HDR canvases grade in their own curve so highlights above SDR white survive.
        var gradeSpace: CGColorSpace = ColorCubes.space
    }

    static let masks = MaskCache()

    /// Applies a stack in order. `param` returns the (possibly animated) value of fx.<id>.<name>.
    ///
    /// While the picture is still whole (opaque and not yet reshaped by a mask, shadow, border or corner pin), each
    /// effect's output is masked to the picture's rectangle, so edge-extended blurs and color kernels never
    /// reach into letterbox bars.
    static func apply(_ effects: [Effect], to image: CIImage, context: Context, param: @escaping (Effect, String) -> ParamValue?) -> CIImage {
        var img = image
        var whole = context.opaque
        for e in effects where e.enabled {
            guard let type = EffectCatalog.type(e.type), type.category != "generator" else { continue }
            let value = values(e, type, param)
            let mix = min(max(param(e, "mix")?.number ?? e.mix, 0), 1)
            guard mix > 0.001 else { continue }
            var out = render(e.type, img, context, value)
            if let mask = limitMask(img, context, value) {
                out = out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: img.extent)
            }
            let reshapes = reshapes(e.type, type.category)
            if whole && !reshapes { out = confine(out, to: image.extent) }
            img = mix >= 0.999 ? out : dissolve(from: img, to: out, mix: mix)
            if reshapes { whole = false }
        }
        return img
    }

    static func values(_ e: Effect, _ type: EffectType, _ param: @escaping (Effect, String) -> ParamValue?) -> (String) -> ParamValue {
        { name in param(e, name) ?? e.params[name] ?? type.spec(name)?.defaultValue ?? .number(0) }
    }

    /// Effects that change the picture's shape or reach outside it.
    static func reshapes(_ type: String, _ category: String) -> Bool {
        category == "mask" || ["stylize.drop_shadow", "stylize.border", "distort.corner_pin"].contains(type)
    }

    /// `out` only where `picture` has coverage, premultiplied by it.
    static func confine(_ out: CIImage, to picture: CIImage) -> CIImage {
        out.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: picture]).cropped(to: picture.extent)
    }

    /// `out` inside `rect` only, through a generated mask rather than a crop, which Core Image may move ahead of color kernels.
    static func confine(_ out: CIImage, to rect: CGRect) -> CIImage {
        out.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: rect)]).cropped(to: rect)
    }

    /// Where effect `id` acts, as an opaque gray image over the picture it receives: white where it applies fully,
    /// black where it leaves the picture alone. Covers limit windows and qualifiers, masks, keys and segmentation;
    /// effects without either are white everywhere. Nil when the stack has no such effect.
    static func matte(_ effects: [Effect], id: String, to image: CIImage, context: Context, param: @escaping (Effect, String) -> ParamValue?) -> CIImage? {
        guard let i = effects.firstIndex(where: { $0.id == id }), let type = EffectCatalog.type(effects[i].type) else { return nil }
        let e = effects[i]
        let input = apply(Array(effects[..<i]), to: image, context: context, param: param)
        let extent = input.extent
        let value = values(e, type, param)
        let black = CIImage(color: .black).cropped(to: extent)
        var m: CIImage
        if type.category == "mask" && e.type != "mask.matte" {
            let opaque = input.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: extent)
            let kept = render(e.type, opaque, context, value)
            m = kept.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).cropped(to: extent)
        } else {
            m = CIImage(color: .white).cropped(to: extent)
        }
        if let limit = limitMask(input, context, value) {
            m = m.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: limit])
        }
        return m.composited(over: black).cropped(to: extent)
    }

    static func dissolve(from a: CIImage, to b: CIImage, mix: Double) -> CIImage {
        CIFilter(name: "CIDissolveTransition", parameters: [kCIInputImageKey: a, kCIInputTargetImageKey: b, kCIInputTimeKey: mix])?.outputImage ?? b
    }

    static func render(_ type: String, _ img: CIImage, _ ctx: Context, _ v: @escaping (String) -> ParamValue) -> CIImage {
        let e = img.extent
        let n: (String) -> CGFloat = { CGFloat(v($0).number ?? 0) }
        let point: () -> CIVector = { CIVector(x: e.minX + n("center_x") * e.width, y: e.maxY - n("center_y") * e.height) }
        /// Runs a filter on an edge-extended copy so blurs don't darken the borders.
        func local(_ name: String, _ params: [String: Any]) -> CIImage {
            let input = ctx.opaque ? img.clampedToExtent() : img
            return input.applyingFilter(name, parameters: params).cropped(to: ctx.opaque ? e : e.insetBy(dx: -ctx.unit * 0.3, dy: -ctx.unit * 0.3))
        }
        switch type {
        case "blur.gaussian":
            return local("CIGaussianBlur", [kCIInputRadiusKey: n("radius") * ctx.unit])
        case "blur.motion":
            return local("CIMotionBlur", [kCIInputRadiusKey: n("amount") * ctx.unit, kCIInputAngleKey: -n("angle") * .pi / 180])
        case "blur.zoom":
            return local("CIZoomBlur", ["inputAmount": n("amount") * ctx.unit, kCIInputCenterKey: point()])
        case "blur.sharpen":
            return img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(0.5, n("radius") * ctx.unit), kCIInputIntensityKey: n("amount")]).cropped(to: e)
        case "color.adjust":
            var out = img
            if n("exposure") != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: n("exposure")]) }
            let c = n("contrast"), s = n("saturation"), b = n("brightness")
            if c != 0 || s != 0 || b != 0 {
                out = out.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: c >= 0 ? 1 + c : 1 + c * 0.75,
                    kCIInputSaturationKey: 1 + s,
                    kCIInputBrightnessKey: b * 0.5,
                ])
            }
            if n("vibrance") != 0 { out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": n("vibrance")]) }
            if n("gamma") != 1 { out = out.applyingFilter("CIGammaAdjust", parameters: ["inputPower": n("gamma")]) }
            let temp = n("temperature"), tint = n("tint")
            if temp != 0 || tint != 0 {
                out = out.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500 + temp * 40, y: tint),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
            }
            return out.cropped(to: e)
        case "color.monochrome":
            let color = v("color").color ?? .white
            return img.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CIColor(red: color.r, green: color.g, blue: color.b), kCIInputIntensityKey: n("amount")])
        case "color.invert":
            return img.applyingFilter("CIColorInvert")
        case "mask.shape":
            guard let pts = v("points").string.flatMap(Curve.points), pts.count >= 3,
                  let mask = shapeMask(pts, smooth: v("smooth").bool ?? false, extent: e, feather: n("feather") * ctx.unit, invert: v("invert").bool ?? false)
            else { return img }
            return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        case "mask.person", "mask.subject":
            let kind: Segmentation.Kind = type == "mask.subject" ? .subject : .person(Segmentation.Quality(rawValue: v("quality").string ?? "balanced") ?? .balanced)
            let mask = ctx.source.flatMap { masks.mask(kind: kind, key: $0, image: img, smoothing: Double(n("smoothing"))) } ?? Segmentation.mask(kind, img)
            guard let mask else { return img }
            return Segmentation.apply(mask: mask, to: img, feather: n("feather") * ctx.unit, invert: v("invert").bool ?? false, expand: (n("expand") - n("choke")) * ctx.unit, threshold: n("threshold")).cropped(to: e)
        case "key.chroma":
            let color = v("color").string.flatMap { $0 == "auto" ? nil : RGBA(hex: $0) }
            return ChromaKey.key(img, color: color, tolerance: Double(n("tolerance")), softness: Double(n("softness")), spill: Double(n("spill")), edgeFeather: n("feather") * ctx.unit).cropped(to: e)
        case "distort.corner_pin":
            func pt(_ x: String, _ y: String) -> CIVector { CIVector(x: e.minX + n(x) * e.width, y: e.maxY - n(y) * e.height) }
            return img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": pt("tl_x", "tl_y"), "inputTopRight": pt("tr_x", "tr_y"),
                "inputBottomRight": pt("br_x", "br_y"), "inputBottomLeft": pt("bl_x", "bl_y"),
            ])
        case "stylize.glitch":
            return TransitionRenderer.glitch(img, amount: Double(n("amount")), frame: Int((ctx.time * 30).rounded()), e)
        case "color.grade", "color.wheels", "color.curves", "color.hsl", "color.look", "color.lut", "color.cdl":
            guard let cube = ColorCubes.cube(type, v) else { return img }
            return img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": ctx.gradeSpace,
            ]).cropped(to: e)
        case "stylize.glow":
            return local("CIBloom", [kCIInputRadiusKey: n("radius") * ctx.unit, kCIInputIntensityKey: n("amount")])
        case "stylize.vignette":
            let halfDiagonal = hypot(e.width, e.height) / 2
            return img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: point(),
                kCIInputRadiusKey: n("size") * halfDiagonal,
                kCIInputIntensityKey: n("amount") * 0.75,
                "inputFalloff": 0.15 + n("softness") * 0.85,
            ]).cropped(to: e)
        case "stylize.grain":
            return grain(img, amount: n("amount"), size: n("size"), mono: v("mono").bool ?? true, time: ctx.time, unit: ctx.unit)
        case "stylize.pixelate":
            return local("CIPixellate", [kCIInputScaleKey: max(1, n("size") * ctx.unit), kCIInputCenterKey: CIVector(x: e.midX, y: e.midY)])
        case "stylize.posterize":
            return img.applyingFilter("CIColorPosterize", parameters: ["inputLevels": n("levels")])
        case "stylize.drop_shadow":
            let color = v("color").color ?? .black
            let shadow = img
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: n("opacity")),
                    "inputBiasVector": CIVector(x: color.r, y: color.g, z: color.b, w: 0),
                ])
                .applyingFilter("CIPremultiply")
                .applyingGaussianBlur(sigma: Double(n("radius") * ctx.unit) / 2)
                .transformed(by: CGAffineTransform(translationX: n("x") * ctx.unit, y: -n("y") * ctx.unit))
            return img.composited(over: shadow)
        case "stylize.border":
            let color = v("color").color ?? .white
            let width = n("width") * ctx.unit
            guard width > 0.5 else { return img }
            let solid = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a))
            let grown = img.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: width])
            let ring = solid.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: grown]).cropped(to: grown.extent)
            return img.composited(over: ring)
        case "distort.bulge":
            return local("CIBumpDistortion", [kCIInputCenterKey: point(), kCIInputRadiusKey: n("radius") * ctx.unit, kCIInputScaleKey: n("amount")])
        case "distort.twirl":
            return local("CITwirlDistortion", [kCIInputCenterKey: point(), kCIInputRadiusKey: n("radius") * ctx.unit, kCIInputAngleKey: n("angle") * .pi / 180])
        case "mask.rect", "mask.ellipse":
            let mask = maskImage(type, extent: e, unit: ctx.unit, n: n, invert: v("invert").bool ?? false)
            return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        default:
            return img
        }
    }

    /// White where the clip is kept, black elsewhere, covering the image extent.
    /// The window or qualifier an effect is limited to, or nil when it applies everywhere.
    static func limitMask(_ img: CIImage, _ ctx: Context, _ v: @escaping (String) -> ParamValue) -> CIImage? {
        let parts = Set((v("limit").string ?? "none").split(separator: "+").map(String.init))
        let n: (String) -> CGFloat = { CGFloat(v($0).number ?? 0) }
        let e = img.extent
        var masks: [CIImage] = []
        if let shape = parts.first(where: { $0 == "rect" || $0 == "ellipse" }) {
            let names = ["center_x": "limit_x", "center_y": "limit_y", "width": "limit_width", "height": "limit_height", "feather": "limit_feather", "roundness": "limit_roundness"]
            masks.append(maskImage(shape == "rect" ? "mask.rect" : "mask.ellipse", extent: e, unit: ctx.unit, n: { n(names[$0] ?? $0) }, invert: false))
        }
        if parts.contains("qualifier"), let cube = ColorCubes.qualifier(hue: Float(n("q_hue")), width: Float(n("q_hue_width")), sat: (Float(n("q_sat_min")), Float(n("q_sat_max"))), luma: (Float(n("q_luma_min")), Float(n("q_luma_max"))), softness: Float(n("q_softness")), invert: false) {
            let key = img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": ColorCubes.space])
                .cropped(to: e).composited(over: CIImage(color: .black).cropped(to: e))
            masks.append(key.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1]).applyingGaussianBlur(sigma: 1.5).cropped(to: e))
        }
        guard var mask = masks.first else { return nil }
        for m in masks.dropFirst() { mask = m.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: e) }
        if v("limit_invert").bool ?? false { mask = mask.applyingFilter("CIColorInvert") }
        return mask
    }

    /// A white shape on black from points in frame fractions (top-left origin), optionally smoothed with Catmull-Rom curves.
    static func shapeMask(_ pts: [(Double, Double)], smooth: Bool, extent e: CGRect, feather: CGFloat, invert: Bool) -> CIImage? {
        let w = max(1, Int(e.width / 2)), h = max(1, Int(e.height / 2))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: invert ? 1 : 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let p = pts.map { CGPoint(x: $0.0 * Double(w), y: (1 - $0.1) * Double(h)) }
        let path = CGMutablePath()
        path.move(to: p[0])
        if smooth {
            for i in 0..<p.count {
                let p0 = p[(i - 1 + p.count) % p.count], p1 = p[i], p2 = p[(i + 1) % p.count], p3 = p[(i + 2) % p.count]
                path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6), control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            }
        } else {
            for q in p.dropFirst() { path.addLine(to: q) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(gray: invert ? 0 : 1, alpha: 1)
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        var mask = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(w), y: e.height / CGFloat(h)).concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        if feather > 0.5 { mask = mask.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: e) }
        return mask
    }

    static func maskImage(_ type: String, extent e: CGRect, unit: CGFloat, n: (String) -> CGFloat, invert: Bool) -> CIImage {
        let w = max(1, n("width") * e.width), h = max(1, n("height") * e.height)
        let cx = e.minX + n("center_x") * e.width, cy = e.maxY - n("center_y") * e.height
        let feather = n("feather") * unit
        let black = CIImage(color: .black).cropped(to: e)
        var shape: CIImage
        if type == "mask.rect" {
            let radius = n("roundness") * min(w, h)
            let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                kCIInputExtentKey: CIVector(cgRect: rect), kCIInputRadiusKey: radius, kCIInputColorKey: CIColor.white,
            ])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
        } else {
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0), "inputRadius0": 0.4999, "inputRadius1": 0.5,
                "inputColor0": CIColor.white, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            ])?.outputImage ?? CIImage.empty()
            shape = gradient.cropped(to: CGRect(x: -0.5, y: -0.5, width: 1, height: 1))
                .transformed(by: CGAffineTransform(scaleX: w, y: h).concatenating(CGAffineTransform(translationX: cx, y: cy)))
        }
        var mask = shape.composited(over: black).cropped(to: e)
        if feather > 0.5 { mask = mask.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: e) }
        if invert { mask = mask.applyingFilter("CIColorInvert") }
        return mask
    }

    static func grain(_ img: CIImage, amount: CGFloat, size: CGFloat, mono: Bool, time: Double, unit: CGFloat) -> CIImage {
        guard amount > 0.001, let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return img }
        let seed = (time * 997).truncatingRemainder(dividingBy: 1000)
        let scale = max(0.5, size) * 1.5 * unit / 1080
        var noise = random
            .transformed(by: CGAffineTransform(translationX: seed * 37, y: seed * 71))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if mono {
            noise = noise.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        let a = min(amount * 1.2, 1)
        noise = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 0),
        ]).cropped(to: img.extent)
        let grained = noise.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: img])
        return grained.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: img])
    }

    /// Composites `layer` onto `base` with a blend mode.
    static func blend(_ layer: CIImage, over base: CIImage, mode: BlendMode) -> CIImage {
        let name: String
        switch mode {
        case .normal: return layer.composited(over: base)
        case .multiply: name = "CIMultiplyBlendMode"
        case .screen: name = "CIScreenBlendMode"
        case .overlay: name = "CIOverlayBlendMode"
        case .softLight: name = "CISoftLightBlendMode"
        case .hardLight: name = "CIHardLightBlendMode"
        case .darken: name = "CIDarkenBlendMode"
        case .lighten: name = "CILightenBlendMode"
        case .colorDodge: name = "CIColorDodgeBlendMode"
        case .colorBurn: name = "CIColorBurnBlendMode"
        case .difference: name = "CIDifferenceBlendMode"
        case .exclusion: name = "CIExclusionBlendMode"
        case .add: name = "CIAdditionCompositing"
        case .hue: name = "CIHueBlendMode"
        case .saturation: name = "CISaturationBlendMode"
        case .color: name = "CIColorBlendMode"
        case .luminosity: name = "CILuminosityBlendMode"
        }
        return layer.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: base])
    }
}

/// 3D LUTs baked from color effect parameters or loaded from .cube files, cached by content.
enum ColorCubes {
    final class Cube {
        let size: Int
        let data: Data
        init(size: Int, data: Data) {
            self.size = size
            self.data = data
        }
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    nonisolated(unsafe) static let cache: NSCache<NSString, Cube> = {
        let c = NSCache<NSString, Cube>()
        c.countLimit = 64
        return c
    }()

    static func cube(_ type: String, _ v: @escaping (String) -> ParamValue) -> Cube? {
        guard let spec = EffectCatalog.type(type) else { return nil }
        var key = type
        for p in spec.params {
            let value = v(p.name)
            key += "|" + (value.number.map { String(format: "%.4f", $0) } ?? value.description)
        }
        if type == "color.lut", let path = v("file").string {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            key += "|\(mtime)"
        }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let cube = make(type, v) else { return nil }
        cache.setObject(cube, forKey: key as NSString)
        return cube
    }

    /// A key that is white where colors match the hue, saturation and lightness ranges.
    static func qualifier(hue: Float, width: Float, sat: (Float, Float), luma: (Float, Float), softness: Float, invert: Bool) -> Cube? {
        let key = String(format: "q|%.1f|%.1f|%.3f|%.3f|%.3f|%.3f|%.3f|%d", hue, width, sat.0, sat.1, luma.0, luma.1, softness, invert ? 1 : 0) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let soft = max(0.001, softness)
        func ramp(_ x: Float, _ lo: Float, _ hi: Float, _ s: Float) -> Float {
            let a = min(1, max(0, (x - (lo - s)) / s)), b = min(1, max(0, ((hi + s) - x) / s))
            return min(a, b)
        }
        let data = ColorMath.cubeData(size: 33) { c in
            let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
            let l = (mx + mn) / 2
            let d = mx - mn
            let s = d < 1e-5 ? 0 : d / (1 - abs(2 * l - 1) + 1e-5)
            var h: Float = 0
            if d > 1e-5 {
                if mx == c.x { h = 60 * ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) } else { h = 60 * ((c.x - c.y) / d + 4) }
                if h < 0 { h += 360 }
            }
            var dh = abs(h - hue).truncatingRemainder(dividingBy: 360)
            if dh > 180 { dh = 360 - dh }
            let hw = width >= 359 ? Float(1) : min(1, max(0, (width / 2 + soft * 90 - dh) / (soft * 90)))
            var w = hw * ramp(min(s, 1), sat.0, sat.1, soft) * ramp(l, luma.0, luma.1, soft)
            if d < 1e-5 && width < 359 { w = 0 }
            if invert { w = 1 - w }
            return SIMD3(w, w, w)
        }
        let cube = Cube(size: 33, data: data.withUnsafeBufferPointer { Data(buffer: $0) })
        cache.setObject(cube, forKey: key)
        return cube
    }

    static func make(_ type: String, _ v: @escaping (String) -> ParamValue) -> Cube? {
        let n: (String) -> Float = { Float(v($0).number ?? 0) }
        let text: (String) -> String? = { v($0).string.flatMap { $0.isEmpty ? nil : $0 } }
        let f: ColorMath.Transform
        switch type {
        case "color.grade":
            let tint: (String) -> RGBA? = { v($0).color }
            f = ColorMath.grade(lift: n("lift"), gamma: n("gamma"), gain: n("gain"), shadowsTint: tint("shadows"), shadowsAmount: n("shadows_amount"), midtonesTint: tint("midtones"), midtonesAmount: n("midtones_amount"), highlightsTint: tint("highlights"), highlightsAmount: n("highlights_amount"))
        case "color.wheels":
            let w = ColorMath.Wheels { v($0).number ?? 0 }
            guard !w.isIdentity else { return nil }
            f = ColorMath.wheels(w)
        case "color.curves":
            guard let t = try? ColorMath.curves(master: text("master"), red: text("red"), green: text("green"), blue: text("blue")) else { return nil }
            f = t
        case "color.hsl":
            guard let t = try? ColorMath.hsl(range: v("range").string ?? "blues", hue: n("hue"), saturation: n("saturation"), lightness: n("lightness")) else { return nil }
            f = t
        case "color.look":
            guard let t = try? ColorMath.look(v("look").string ?? "teal_orange", amount: n("amount")) else { return nil }
            f = t
        case "color.cdl":
            f = CDL(effect: Effect(id: "", type: type, params: Dictionary(uniqueKeysWithValues: (EffectCatalog.type(type)?.params ?? []).map { ($0.name, v($0.name)) }))).transform
        case "color.lut":
            guard let path = text("file"), let s = try? String(contentsOfFile: path, encoding: .utf8), let lut = try? ColorMath.parseCube(s) else { return nil }
            if lut.domainMin == SIMD3(0, 0, 0) && lut.domainMax == SIMD3(1, 1, 1) {
                return Cube(size: lut.size, data: lut.rgba.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            // Re-sample LUTs with a custom input domain onto 0…1.
            let size = lut.size
            f = { c in
                let x = (c - lut.domainMin) / (lut.domainMax - lut.domainMin)
                let i = simd_clamp(x, SIMD3(repeating: 0), SIMD3(repeating: 1)) * Float(size - 1)
                let r = Int(i.x.rounded()), g = Int(i.y.rounded()), b = Int(i.z.rounded())
                let o = ((b * size + g) * size + r) * 4
                return SIMD3(lut.rgba[o], lut.rgba[o + 1], lut.rgba[o + 2])
            }
        default:
            return nil
        }
        let data = ColorMath.cubeData(size: 33, f)
        return Cube(size: 33, data: data.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
