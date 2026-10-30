import AVFoundation
import CoreImage
import CutlineCore
import Foundation
import simd

/// Matte cleanup for keys, in pixels: denoise (open, then close), clean black/white levels, choke, feather.
struct KeyCleanup {
    var black: CGFloat = 0
    var white: CGFloat = 0
    var denoise: CGFloat = 0
    var choke: CGFloat = 0
    var feather: CGFloat = 0

    init(black: CGFloat = 0, white: CGFloat = 0, denoise: CGFloat = 0, choke: CGFloat = 0, feather: CGFloat = 0) {
        self.black = black
        self.white = white
        self.denoise = denoise
        self.choke = choke
        self.feather = feather
    }

    /// Reads clean_black, clean_white, denoise, choke and feather; lengths are fractions of the frame height.
    init(_ n: (String) -> CGFloat, unit: CGFloat) {
        self.init(black: n("clean_black"), white: n("clean_white"), denoise: n("denoise") * unit, choke: n("choke") * unit, feather: n("feather") * unit)
    }

    /// `matte` (gray, white keeps) cleaned up over `e`.
    func apply(_ matte: CIImage, extent e: CGRect) -> CIImage {
        var m = matte
        if denoise >= 0.5 {
            m = m.clampedToExtent()
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: denoise]).applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: denoise])
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: denoise]).applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: denoise])
                .cropped(to: e)
        }
        if black > 0.001 || white > 0.001 {
            let lo = min(black, 0.49), hi = max(1 - white, lo + 0.02)
            let s = 1 / (hi - lo)
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
                "inputBiasVector": CIVector(x: -lo * s, y: -lo * s, z: -lo * s, w: 0),
            ]).applyingFilter("CIColorClamp").cropped(to: e)
        }
        if abs(choke) >= 0.5 {
            m = m.clampedToExtent().applyingFilter(choke > 0 ? "CIMorphologyMinimum" : "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: abs(choke)]).cropped(to: e)
        }
        if feather >= 0.25 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: e)
        }
        return m
    }
}

/// Luma and difference keys. Mattes are gray images over the picture: white keeps, black is keyed out.
public enum Keyers {
    /// `img` kept where `matte` is white (where it is black when `invert`).
    static func keep(_ img: CIImage, matte: CIImage, invert: Bool) -> CIImage {
        let m = invert ? matte.applyingFilter("CIColorInvert") : matte
        return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m]).cropped(to: img.extent)
    }

    /// Keeps luma between `low` and `high`, fading out over `softness` beyond them.
    static func luma(_ img: CIImage, low: Double, high: Double, softness: Double, invert: Bool = false, cleanup: KeyCleanup? = nil) -> CIImage {
        keep(img, matte: lumaMatte(img, low: low, high: high, softness: softness, cleanup: cleanup), invert: invert)
    }

    static func lumaMatte(_ img: CIImage, low: Double, high: Double, softness: Double, cleanup: KeyCleanup?) -> CIImage {
        let e = img.extent
        let cube = lumaCube(Float(low), Float(high), Float(max(softness, 0.001)))
        let raw = img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": ColorCubes.space])
            .cropped(to: e).composited(over: CIImage(color: .black).cropped(to: e))
        return (cleanup ?? KeyCleanup()).apply(raw, extent: e)
    }

    /// Weight of luma `y` for a key keeping [low, high] with `soft` falloff.
    static func lumaWeight(_ y: Float, low: Float, high: Float, soft: Float) -> Float {
        func smooth(_ t: Float) -> Float { let c = min(max(t, 0), 1); return c * c * (3 - 2 * c) }
        let below = low <= 0 ? 1 : smooth((y - (low - soft)) / soft)
        let above = high >= 1 ? 1 : smooth(((high + soft) - y) / soft)
        return min(below, above)
    }

    nonisolated(unsafe) static let cubes: NSCache<NSString, ColorCubes.Cube> = {
        let c = NSCache<NSString, ColorCubes.Cube>()
        c.countLimit = 16
        return c
    }()

    static func lumaCube(_ low: Float, _ high: Float, _ soft: Float) -> ColorCubes.Cube {
        let key = String(format: "luma|%.4f|%.4f|%.4f", low, high, soft) as NSString
        if let hit = cubes.object(forKey: key) { return hit }
        let data = ColorMath.cubeData(size: 48) { c in
            let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            return SIMD3(repeating: ChromaKey.srgbEncode(lumaWeight(y, low: low, high: high, soft: soft)))
        }
        let cube = ColorCubes.Cube(size: 48, data: data.withUnsafeBufferPointer { Data(buffer: $0) })
        cubes.setObject(cube, forKey: key)
        return cube
    }

    /// Keeps what differs from `plate` by more than `threshold` (largest channel difference of the display-encoded
    /// pictures), fading in over `softness`. The plate is stretched over the picture.
    static func difference(_ img: CIImage, plate: CIImage, threshold: Double, softness: Double, invert: Bool = false, cleanup: KeyCleanup? = nil) -> CIImage {
        keep(img, matte: differenceMatte(img, plate: plate, threshold: threshold, softness: softness, cleanup: cleanup), invert: invert)
    }

    static func differenceMatte(_ img: CIImage, plate: CIImage, threshold: Double, softness: Double, cleanup: KeyCleanup?) -> CIImage {
        let e = img.extent
        let p = plate.extent
        guard !p.isInfinite, p.width >= 1, p.height >= 1 else { return CIImage(color: .white).cropped(to: e) }
        let fitted = plate.transformed(by: CGAffineTransform(translationX: -p.minX, y: -p.minY)
            .concatenating(CGAffineTransform(scaleX: e.width / p.width, y: e.height / p.height))
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        let black = CIImage(color: .black).cropped(to: e)
        let a = img.composited(over: black).applyingFilter("CILinearToSRGBToneCurve")
        let b = fitted.composited(over: black).cropped(to: e).applyingFilter("CILinearToSRGBToneCurve")
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: e)
        func channel(_ v: CIVector) -> CIImage {
            diff.applyingFilter("CIColorMatrix", parameters: ["inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        let largest = channel(CIVector(x: 1, y: 0, z: 0, w: 0))
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(CIVector(x: 0, y: 1, z: 0, w: 0))])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(CIVector(x: 0, y: 0, z: 1, w: 0))])
        let s = 1 / CGFloat(max(softness, 0.001)), t = CGFloat(threshold)
        let ramp = largest.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
            "inputBiasVector": CIVector(x: -t * s, y: -t * s, z: -t * s, w: 0),
        ]).applyingFilter("CIColorClamp").cropped(to: e)
        return (cleanup ?? KeyCleanup()).apply(ramp, extent: e)
    }
}

/// Clean plates for difference keys: image files and frames of media, decoded once.
enum CleanPlates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String: CIImage?] = [:]

    /// The plate an effect names: `plate` (an image file) or the frame `at` source seconds of the clip's media.
    static func plate(path: String, at: Double, mediaPath: String?) -> CIImage? {
        if !path.isEmpty { return image((path as NSString).expandingTildeInPath) }
        guard at >= 0, let mediaPath else { return nil }
        return frame(mediaPath, at: at)
    }

    static func image(_ path: String) -> CIImage? {
        cached("img|\(path)") { CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) }
    }

    static func frame(_ path: String, at t: Double) -> CIImage? {
        cached(String(format: "frame|%@|%.4f", path, t)) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 600)
            let box = PlateBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                box.image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                done.signal()
            }
            done.wait()
            return box.image.map { CIImage(cgImage: $0) }
        }
    }

    private static func cached(_ key: String, _ make: () -> CIImage?) -> CIImage? {
        if let hit = lock.withLock({ images[key] }) { return hit }
        let img = make()
        lock.withLock {
            if images.count > 16 { images.removeAll() }
            images[key] = img
        }
        return img
    }

    private final class PlateBox: @unchecked Sendable {
        var image: CGImage?
    }
}
