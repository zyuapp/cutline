import CoreImage
import CoreVideo
import CutlineCore
import Foundation
import simd

/// A heuristic sky matte (Vision has no sky segmentation): bright, smooth pixels of sky colors grown from the top
/// of the frame without crossing edges, plus pockets of the same sky seen through gaps, computed at low resolution
/// and snapped to the picture's edges with a guided filter. Night skies, skies without a clear horizon and
/// sky-colored walls or water joined to the sky defeat it.
public enum SkyMask {
    public enum Colors: String, CaseIterable, Sendable {
        case auto, blue, overcast, sunset
    }

    public struct Settings: Equatable, Sendable {
        public var sensitivity: Double = 0.5
        public var smoothness: Double = 0.5
        public var colors: Colors = .auto
        public var bottom: Double = 0.9

        public init(sensitivity: Double = 0.5, smoothness: Double = 0.5, colors: Colors = .auto, bottom: Double = 0.9) {
            self.sensitivity = sensitivity
            self.smoothness = smoothness
            self.colors = colors
            self.bottom = bottom
        }

        var key: String { String(format: "%.3f|%.3f|%@|%.3f", sensitivity, smoothness, colors.rawValue, bottom) }

        init(key: String) {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 4 else { return }
            sensitivity = Double(parts[0]) ?? 0.5
            smoothness = Double(parts[1]) ?? 0.5
            colors = Colors(rawValue: parts[2]) ?? .auto
            bottom = Double(parts[3]) ?? 0.9
        }
    }

    /// Longest side of the picture the heuristic reads.
    static let analysisSide: CGFloat = 384

    /// The mask.sky effect: the matte (cached per source frame, smoothed over time), refined, then applied.
    static func render(_ img: CIImage, _ ctx: EffectRenderer.Context, _ n: (String) -> CGFloat, _ v: (String) -> ParamValue) -> CIImage {
        let e = img.extent
        let s = Settings(sensitivity: Double(n("sensitivity")), smoothness: Double(n("smoothness")), colors: Colors(rawValue: v("colors").string ?? "auto") ?? .auto, bottom: Double(n("bottom")))
        let kind = Segmentation.Kind.sky(s.key)
        guard var mask = ctx.source.flatMap({ EffectRenderer.masks.mask(kind: kind, key: $0, image: img, smoothing: Double(n("smoothing"))) }) ?? Segmentation.mask(kind, img) else { return img }
        mask = refine(mask, guide: img, amount: Double(n("refine")))
        return Segmentation.apply(mask: mask, to: img, feather: n("feather") * ctx.unit, invert: v("invert").bool ?? false, expand: n("expand") * ctx.unit).cropped(to: e)
    }

    /// The sky matte of `image` over its extent, refined to its edges; nil when it can't be read.
    public static func matte(_ image: CIImage, settings: Settings = Settings(), refine amount: Double = 0.6) -> CIImage? {
        guard let m = Segmentation.mask(.sky(settings.key), image) else { return nil }
        return refine(m, guide: image, amount: amount)
    }

    /// The mean display color of the sky in `frame` and the share of the frame it covers; nil color without sky.
    public static func measure(_ frame: CGImage, settings: Settings = Settings()) -> (sky: SIMD3<Double>?, coverage: Double) {
        let img = CIImage(cgImage: frame)
        guard let low = lowRes(img, settings), let rgb = displayRGB(frame, width: low.width, height: low.height) else { return (nil, 0) }
        var sum = SIMD3<Double>(repeating: 0), weight = 0.0
        for i in 0..<(low.width * low.height) where low.values[i] > 0.5 {
            sum += SIMD3(Double(rgb[i * 3]), Double(rgb[i * 3 + 1]), Double(rgb[i * 3 + 2]))
            weight += 1
        }
        let coverage = weight / Double(max(1, low.width * low.height))
        return (weight > 0 ? sum / weight : nil, coverage)
    }

    /// The mean display color of a replacement sky's horizon band (55–75% down the picture), the light near the
    /// skyline once it sits behind the foreground.
    public static func horizon(_ frame: CGImage) -> SIMD3<Double>? {
        let w = 64, h = 36
        guard let rgb = displayRGB(frame, width: w, height: h) else { return nil }
        var sum = SIMD3<Double>(repeating: 0)
        var n = 0
        for y in Int(Double(h) * 0.55)..<Int(Double(h) * 0.75) {
            for x in 0..<w {
                let i = (y * w + x) * 3
                sum += SIMD3(Double(rgb[i]), Double(rgb[i + 1]), Double(rgb[i + 2]))
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// Display-encoded RGB of `image` stretched to width × height, rows top to bottom.
    static func displayRGB(_ image: CGImage, width w: Int, height h: Int) -> [Float]? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Segmentation.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.interpolationQuality = .medium
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            for c in 0..<3 { rgb[i * 3 + c] = Float(px[i * 4 + c]) / 255 }
        }
        return rgb
    }

    /// `mask` snapped to the guide's edges by a guided filter, mixed in by `amount`.
    static func refine(_ mask: CIImage, guide: CIImage, amount: Double) -> CIImage {
        let e = mask.extent
        guard amount > 0.01 else { return mask }
        let radius = max(2, min(e.width, e.height) * 0.006)
        guard let filtered = CIFilter(name: "CIGuidedFilter", parameters: [
            kCIInputImageKey: mask.cropped(to: e), "inputGuideImage": guide.composited(over: CIImage(color: .black)).cropped(to: e),
            "inputRadius": radius, "inputEpsilon": 0.0004,
        ])?.outputImage, !filtered.extent.isEmpty else { return mask }
        let snapped = filtered.applyingFilter("CIColorClamp").cropped(to: e)
        return amount >= 0.99 ? snapped : EffectRenderer.dissolve(from: mask, to: snapped, mix: amount)
    }

    /// The low-resolution matte (rows top to bottom) of `image`.
    static func lowRes(_ image: CIImage, _ s: Settings) -> MaskBuffer? {
        guard let buffer = Segmentation.pixelBuffer(image, maxSide: analysisSide) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let o = (y * w + x) * 3
                rgb[o] = Float(row[x * 4 + 2]) / 255
                rgb[o + 1] = Float(row[x * 4 + 1]) / 255
                rgb[o + 2] = Float(row[x * 4]) / 255
            }
        }
        return MaskBuffer(width: w, height: h, values: estimate(rgb: rgb, width: w, height: h, settings: s))
    }

    static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / max(e1 - e0, 1e-6), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 1 inside [lo, hi] degrees, fading over `soft` either side.
    static func band(_ h: Float, _ lo: Float, _ hi: Float, _ soft: Float) -> Float {
        if h >= lo && h <= hi { return 1 }
        let d = h < lo ? lo - h : h - hi
        return max(0, 1 - d / soft)
    }

    /// How sky-colored a display-encoded pixel is.
    static func colorScore(hue: Float, sat: Float, luma: Float, colors: Colors) -> Float {
        let blue = sat > 0.05 ? band(hue, 180, 250, 20) * smooth(0.04, 0.1, sat) : 0
        let gray = (1 - smooth(0.12, 0.24, sat)) * smooth(0.35, 0.6, luma)
        let warm = (band(hue, 0, 45, 15) + band(hue, 315, 360, 15)) * smooth(0.08, 0.15, sat) * smooth(0.3, 0.45, luma)
        switch colors {
        case .auto: return max(blue, gray, 0.75 * min(warm, 1))
        case .blue: return max(blue, 0.6 * gray * smooth(0.65, 0.85, luma))
        case .overcast: return gray
        case .sunset: return max(min(warm, 1), blue)
        }
    }

    /// The sky matte of display-encoded RGB (rows top to bottom), 0…1 per pixel.
    public static func estimate(rgb: [Float], width w: Int, height h: Int, settings s: Settings) -> [Float] {
        let n = w * h
        guard w >= 4, h >= 4, rgb.count >= n * 3 else { return [Float](repeating: 0, count: max(n, 0)) }
        let sens = Float(min(max(s.sensitivity, 0), 1)), smoothness = Float(min(max(s.smoothness, 0), 1))
        var luma = [Float](repeating: 0, count: n)
        var like = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2]
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        // Sobel gradient, in luma steps per pixel of a 384-pixel-wide picture.
        let scale = Float(max(w, h)) / Float(analysisSide)
        var grad = [Float](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let xl = max(x - 1, 0), xr = min(x + 1, w - 1), yu = max(y - 1, 0), yd = min(y + 1, h - 1)
                func L(_ xx: Int, _ yy: Int) -> Float { luma[yy * w + xx] }
                let gx = (L(xr, yu) + 2 * L(xr, y) + L(xr, yd)) - (L(xl, yu) + 2 * L(xl, y) + L(xl, yd))
                let gy = (L(xl, yd) + 2 * L(x, yd) + L(xr, yd)) - (L(xl, yu) + 2 * L(x, yu) + L(xr, yu))
                grad[y * w + x] = (gx * gx + gy * gy).squareRoot() / 8 * scale
            }
        }
        let texture = boxBlur(grad, w, h, radius: 2)
        let texLimit = 0.006 + 0.03 * (1 - smoothness)
        let bottomRow = Int(Double(h) * min(max(s.bottom, 0.05), 1))
        for i in 0..<n where i / w < bottomRow {
            let r = rgb[i * 3], g = rgb[i * 3 + 1], b = rgb[i * 3 + 2]
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx > 1e-4 ? (mx - mn) / mx : 0
            var hue: Float = 0
            if mx - mn > 1e-5 {
                if mx == r { hue = 60 * ((g - b) / (mx - mn)) } else if mx == g { hue = 60 * ((b - r) / (mx - mn) + 2) } else { hue = 60 * ((r - g) / (mx - mn) + 4) }
                if hue < 0 { hue += 360 }
            }
            let bright = smooth(0.2 - 0.12 * sens, 0.42 - 0.12 * sens, luma[i])
            let smoothScore = 1 - smooth(texLimit * 0.6, texLimit * 1.6, texture[i])
            like[i] = colorScore(hue: hue, sat: sat, luma: luma[i], colors: s.colors) * bright * smoothScore
        }
        let accept = 0.75 - 0.5 * sens
        let edgeLimit = texLimit * 3
        func color(_ i: Int) -> SIMD3<Float> { SIMD3(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]) }
        func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = simd_abs(a - b); return max(d.x, d.y, d.z) }

        // Seeds along the top rows.
        let seedRows = max(2, h / 25)
        var region = [Bool](repeating: false, count: n)
        var queue: [Int] = []
        var mean = SIMD3<Float>(repeating: 0)
        for y in 0..<min(seedRows, bottomRow) {
            for x in 0..<w where like[y * w + x] > accept {
                region[y * w + x] = true
                queue.append(y * w + x)
                mean += color(y * w + x)
            }
        }
        guard queue.count >= max(4, w * seedRows / 50) else { return [Float](repeating: 0, count: n) }
        mean /= Float(queue.count)
        // Grow across small color steps, never across edges.
        let step = 0.05 + 0.04 * sens, global = 0.3 + 0.2 * sens
        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            let x = i % w, y = i / w
            let ci = color(i)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < bottomRow else { continue }
                let j = ny * w + nx
                guard !region[j], like[j] > accept * 0.6, grad[j] < edgeLimit else { continue }
                let cj = color(j)
                guard dist(ci, cj) < step, dist(cj, mean) < global else { continue }
                region[j] = true
                queue.append(j)
            }
        }
        // Pockets of the same sky between branches or under bridges.
        var skyMean = SIMD3<Float>(repeating: 0)
        var lowest = 0
        for i in queue { skyMean += color(i) }
        skyMean /= Float(queue.count)
        let rows = queue.map { $0 / w }.sorted()
        lowest = rows[min(rows.count - 1, rows.count * 9 / 10)]
        var seen = region
        for start in 0..<(w * bottomRow) where !seen[start] && like[start] > accept {
            var comp = [start]
            seen[start] = true
            var k = 0
            var sum = SIMD3<Float>(repeating: 0), rowSum = 0
            while k < comp.count {
                let i = comp[k]
                k += 1
                sum += color(i)
                rowSum += i / w
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < bottomRow else { continue }
                    let j = ny * w + nx
                    guard !seen[j], like[j] > accept else { continue }
                    seen[j] = true
                    comp.append(j)
                }
            }
            let c = sum / Float(comp.count)
            if dist(c, skyMean) < 0.08 + 0.06 * sens, rowSum / comp.count <= lowest {
                for i in comp { region[i] = true }
            }
        }
        // The gradient test stops the growth a pixel or two short of each edge; take back edge pixels still lit like
        // the sky so no rim of the old sky is left around the foreground.
        let skyLuma = 0.2126 * skyMean.x + 0.7152 * skyMean.y + 0.0722 * skyMean.z
        for _ in 0..<2 {
            var grown = region
            for y in 0..<bottomRow {
                for x in 0..<w where !region[y * w + x] {
                    let i = y * w + x
                    let touches = (x > 0 && region[i - 1]) || (x < w - 1 && region[i + 1]) || (y > 0 && region[i - w]) || (y < h - 1 && region[i + w])
                    if touches, (luma[i] > skyLuma * 0.9 && dist(color(i), skyMean) < 0.3) || dist(color(i), skyMean) < 0.12 { grown[i] = true }
                }
            }
            region = grown
        }
        // Close one-pixel holes, then soften.
        var mask = region.map { $0 ? Float(1) : 0 }
        mask = morph(mask, w, h, grow: true)
        mask = morph(mask, w, h, grow: false)
        for i in (w * bottomRow)..<n { mask[i] = 0 }
        return boxBlur(mask, w, h, radius: 1)
    }

    static func morph(_ m: [Float], _ w: Int, _ h: Int, grow: Bool) -> [Float] {
        var out = m
        for y in 0..<h {
            for x in 0..<w {
                var v = m[y * w + x]
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    v = grow ? max(v, m[ny * w + nx]) : min(v, m[ny * w + nx])
                }
                out[y * w + x] = v
            }
        }
        return out
    }

    static func boxBlur(_ m: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: m.count), out = tmp
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, c: Float = 0
                for xx in max(0, x - r)...min(w - 1, x + r) { s += m[y * w + xx]; c += 1 }
                tmp[y * w + x] = s / c
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, c: Float = 0
                for yy in max(0, y - r)...min(h - 1, y + r) { s += tmp[yy * w + x]; c += 1 }
                out[y * w + x] = s / c
            }
        }
        return out
    }
}
