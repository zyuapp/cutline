import CoreImage
import CutlineCore
import Foundation
import simd

/// Green and blue screen keying through 3D LUTs computed in Y'CbCr.
public enum ChromaKey {
    static let cubeSize = 64

    /// Makes the screen color transparent.
    ///
    /// - color: the screen; nil detects green or blue from the border, returning the image unchanged if neither is found.
    /// - tolerance, softness: CbCr distance from the key relative to the key's own saturation. Closer than
    ///   `tolerance` is removed, beyond `tolerance + softness` kept. Shadows on the screen down to half its brightness still key.
    /// - spill: 0…1, how far the key channel is pulled down toward the mean of the other two.
    /// - edgeFeather: matte blur in pixels.
    public static func key(_ image: CIImage, color: RGBA? = nil, tolerance: Double = 0.35, softness: Double = 0.25, spill: Double = 0.8, edgeFeather: CGFloat = 1) -> CIImage {
        guard let k = color ?? detectKeyColor(image) else { return image }
        let e = image.extent
        let luts = Luts.get(SIMD3(Float(k.r), Float(k.g), Float(k.b)), Float(max(tolerance, 0)), Float(max(softness, 0.001)), Float(min(max(spill, 0), 1)))
        let cube: (Data) -> CIImage = { data in
            image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cubeSize, "inputCubeData": data, "inputColorSpace": Segmentation.sRGB,
            ]).cropped(to: e)
        }
        var matte = cube(luts.matte)
        if edgeFeather >= 0.25 {
            matte = matte.clampedToExtent().applyingGaussianBlur(sigma: Double(edgeFeather) / 2).cropped(to: e)
        }
        return cube(luts.color).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: matte])
    }

    /// The dominant green or blue of the image border, or nil when the border isn't a screen.
    public static func detectKeyColor(_ image: CIImage) -> RGBA? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 1, e.height >= 1 else { return nil }
        let s = min(1, 96 / max(e.width, e.height))
        let w = max(1, Int(e.width * s)), h = max(1, Int(e.height * s))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height)))
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            Segmentation.context.render(small, toBitmap: raw.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: Segmentation.sRGB)
        }
        let bw = max(1, w / 10), bh = max(1, h / 10)
        var greens: [SIMD3<Float>] = [], blues: [SIMD3<Float>] = []
        var total = 0
        for y in 0..<h {
            for x in 0..<w where x < bw || x >= w - bw || y < bh || y >= h - bh {
                let o = (y * w + x) * 4
                guard px[o + 3] > 0.5 else { continue }
                total += 1
                let c = SIMD3(px[o], px[o + 1], px[o + 2]) / px[o + 3]
                if c.y - max(c.x, c.z) > 0.1 { greens.append(c) }
                else if c.z - max(c.x, c.y) > 0.1 { blues.append(c) }
            }
        }
        let pick = greens.count >= blues.count ? greens : blues
        guard total > 0, Double(pick.count) >= 0.3 * Double(total) else { return nil }
        func median(_ i: Int) -> Double { Double(pick.map { $0[i] }.sorted()[pick.count / 2]) }
        return RGBA(r: median(0), g: median(1), b: median(2))
    }

    /// BT.709 Y', Cb, Cr of gamma-encoded RGB.
    static func ycc(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        return SIMD3(y, (c.z - y) / 1.8556, (c.x - y) / 1.5748)
    }

    /// Matte (0 = screen) for a gamma-encoded color.
    static func alpha(_ c: SIMD3<Float>, key k: SIMD3<Float>, tolerance: Float, softness: Float) -> Float {
        let p = ycc(c), q = ycc(k)
        let kc = SIMD2(q.y, q.z)
        let lift = p.x < q.x ? min(q.x / max(p.x, 1e-4), 2) : 1
        let d = simd_length(SIMD2(p.y, p.z) * lift - kc) / max(simd_length(kc), 0.05)
        let t = min(max((d - tolerance) / softness, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Color with the key channel's excess over the other two reduced by `amount`.
    static func despill(_ c: SIMD3<Float>, channel: Int, amount: Float) -> SIMD3<Float> {
        var o = c
        let others = (c.x + c.y + c.z - c[channel]) / 2
        o[channel] -= amount * max(0, c[channel] - others)
        return o
    }

    static func srgbEncode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    final class Luts {
        let color: Data
        let matte: Data

        init(color: Data, matte: Data) {
            self.color = color
            self.matte = matte
        }

        nonisolated(unsafe) static let cache: NSCache<NSString, Luts> = {
            let c = NSCache<NSString, Luts>()
            c.countLimit = 8
            return c
        }()

        static func get(_ key: SIMD3<Float>, _ tolerance: Float, _ softness: Float, _ spill: Float) -> Luts {
            let id = String(format: "%.3f|%.3f|%.3f|%.3f|%.3f|%.3f", key.x, key.y, key.z, tolerance, softness, spill) as NSString
            if let hit = cache.object(forKey: id) { return hit }
            let n = cubeSize
            let channel = key.y >= key.z ? (key.y >= key.x ? 1 : 0) : (key.z >= key.x ? 2 : 0)
            var color = [Float](repeating: 1, count: n * n * n * 4)
            var matte = [Float](repeating: 1, count: n * n * n * 4)
            let step = 1 / Float(n - 1)
            for b in 0..<n {
                for g in 0..<n {
                    for r in 0..<n {
                        let c = SIMD3(Float(r), Float(g), Float(b)) * step
                        let o = ((b * n + g) * n + r) * 4
                        // The cube's output is decoded from sRGB, so encode the matte to keep it linear.
                        let a = srgbEncode(alpha(c, key: key, tolerance: tolerance, softness: softness))
                        let d = despill(c, channel: channel, amount: spill)
                        color[o] = d.x
                        color[o + 1] = d.y
                        color[o + 2] = d.z
                        matte[o] = a
                        matte[o + 1] = a
                        matte[o + 2] = a
                    }
                }
            }
            let luts = Luts(color: color.withUnsafeBufferPointer { Data(buffer: $0) }, matte: matte.withUnsafeBufferPointer { Data(buffer: $0) })
            cache.setObject(luts, forKey: id)
            return luts
        }
    }
}
