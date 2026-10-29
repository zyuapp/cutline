import Accelerate
import CoreImage
import CoreVideo
import CutlineCore
import Foundation
import Vision

/// Person and subject masks from Vision, and compositing with them.
///
/// Masks are grayscale images covering the input image's extent: white keeps, black drops.
public enum Segmentation {
    public enum Quality: String, Sendable, CaseIterable {
        case fast, balanced, accurate
    }

    public enum Kind: Hashable, Sendable, CustomStringConvertible {
        case person(Quality)
        /// Every foreground instance Vision finds: people, animals, objects.
        case subject

        public var description: String {
            switch self {
            case .person(let q): return "person.\(q.rawValue)"
            case .subject: return "subject"
            }
        }
    }

    /// Longest side of the frame handed to Vision.
    static let maxSide: CGFloat = 1024
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = CutlineCompositor.device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// People in the frame. Nil when Vision fails; a black mask when nobody is there.
    public static func personMask(_ image: CIImage, quality: Quality = .balanced) -> CIImage? {
        lowRes(.person(quality), image)?.image(fitting: image.extent)
    }

    /// All salient foreground instances. Nil when Vision fails; a black mask when there are none.
    public static func subjectMask(_ image: CIImage) -> CIImage? {
        lowRes(.subject, image)?.image(fitting: image.extent)
    }

    public static func mask(_ kind: Kind, _ image: CIImage) -> CIImage? {
        lowRes(kind, image)?.image(fitting: image.extent)
    }

    /// Keeps the image where `mask` is white (the background instead when `invert`).
    /// `expand` grows (negative: shrinks) the mask by that many pixels before
    /// `feather` softens its edge over about that many pixels.
    public static func apply(mask: CIImage, to image: CIImage, feather: CGFloat = 0, invert: Bool = false, expand: CGFloat = 0) -> CIImage {
        let e = image.extent
        var m = mask.composited(over: CIImage(color: .black)).cropped(to: e)
        if abs(expand) >= 0.5 {
            m = m.clampedToExtent()
                .applyingFilter(expand > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: abs(expand)])
                .cropped(to: e)
        }
        if feather >= 0.5 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: e)
        }
        if invert { m = m.applyingFilter("CIColorInvert") }
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
    }

    /// Runs Vision on a downscaled copy and returns its mask at Vision's resolution.
    static func lowRes(_ kind: Kind, _ image: CIImage) -> MaskBuffer? {
        guard let buffer = pixelBuffer(image) else { return nil }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        switch kind {
        case .person(let quality):
            let request = VNGeneratePersonSegmentationRequest()
            switch quality {
            case .fast: request.qualityLevel = .fast
            case .balanced: request.qualityLevel = .balanced
            case .accurate: request.qualityLevel = .accurate
            }
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            guard (try? handler.perform([request])) != nil else { return nil }
            guard let out = request.results?.first?.pixelBuffer else { return .empty }
            return MaskBuffer(out)
        case .subject:
            let request = VNGenerateForegroundInstanceMaskRequest()
            guard (try? handler.perform([request])) != nil else { return nil }
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return .empty }
            guard let out = try? observation.generateMask(forInstances: observation.allInstances) else { return nil }
            return MaskBuffer(out)
        }
    }

    /// Renders the image, origin at zero, into a BGRA buffer no larger than `maxSide`.
    static func pixelBuffer(_ image: CIImage, maxSide: CGFloat = Segmentation.maxSide) -> CVPixelBuffer? {
        let e = image.extent
        guard !e.isInfinite, !e.isEmpty, e.width >= 1, e.height >= 1 else { return nil }
        let s = min(1, maxSide / max(e.width, e.height))
        let w = max(1, Int((e.width * s).rounded())), h = max(1, Int((e.height * s).rounded()))
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height)))
            .composited(over: CIImage(color: .black))
        context.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: sRGB)
        return buffer
    }
}

/// A single-channel mask in 0…1, rows top to bottom.
final class MaskBuffer {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    static let empty = MaskBuffer(width: 1, height: 1, values: [0])

    var cost: Int { values.count * MemoryLayout<Float>.size }

    convenience init?(_ buffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var values = [Float](repeating: 0, count: w * h)
        if format == kCVPixelFormatType_OneComponent8 || format == kCVPixelFormatType_OneComponent32Float {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            values.withUnsafeMutableBufferPointer { out in
                for y in 0..<h {
                    let row = base + y * rowBytes
                    let dst = out.baseAddress! + y * w
                    if format == kCVPixelFormatType_OneComponent8 {
                        vDSP_vfltu8(row.assumingMemoryBound(to: UInt8.self), 1, dst, 1, vDSP_Length(w))
                        var scale: Float = 1 / 255
                        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(w))
                    } else {
                        dst.update(from: row.assumingMemoryBound(to: Float.self), count: w)
                    }
                }
            }
        } else {
            let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            values.withUnsafeMutableBytes { raw in
                Segmentation.context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Rf, colorSpace: nil)
            }
        }
        self.init(width: w, height: h, values: values)
    }

    /// `weight` of `previous` mixed into this mask.
    func blended(with previous: MaskBuffer, weight: Float) -> MaskBuffer {
        guard previous.width == width, previous.height == height else { return self }
        var out = [Float](repeating: 0, count: values.count)
        var w = weight
        // out = values + weight * (previous - values)
        vDSP_vintb(values, 1, previous.values, 1, &w, &out, 1, vDSP_Length(values.count))
        return MaskBuffer(width: width, height: height, values: out)
    }

    /// Gray mask stretched over `extent`.
    func image(fitting extent: CGRect) -> CIImage {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let raw = CIImage(bitmapData: data, bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .Rf, colorSpace: nil)
        let red = CIVector(x: 1, y: 0, z: 0, w: 0)
        let gray = raw.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": red, "inputGVector": red, "inputBVector": red,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return gray.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
                .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .cropped(to: extent)
    }
}

/// Masks per source frame, since each costs a Vision request, with optional temporal smoothing.
public final class MaskCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var mediaId: String
        /// Source time in 1/120 s ticks.
        public var tick: Int

        public init(mediaId: String, time: Seconds) {
            self.mediaId = mediaId
            tick = Int((time * 120).rounded())
        }
    }

    /// Frames further apart than this (in ticks) don't smooth into each other.
    static let maxGap = 30

    private let cache = NSCache<NSString, MaskBuffer>()
    private let lock = NSLock()
    private var previous: [String: (tick: Int, mask: MaskBuffer)] = [:]

    public init(costLimit: Int = 256 << 20) {
        cache.totalCostLimit = costLimit
    }

    /// The mask of `kind` for the frame `key`, computed from `image` on a miss and fitted to its extent.
    /// `smoothing` (0…0.95) is the weight of the previous nearby frame's mask (an EMA), which
    /// reduces flicker when frames are requested in order.
    public func mask(kind: Segmentation.Kind, key: Key, image: CIImage, smoothing: Double = 0) -> CIImage? {
        let s = Float(min(max(smoothing, 0), 0.95))
        let stream = "\(key.mediaId)|\(kind)|\(String(format: "%.3f", s))"
        let rawKey = "\(key.mediaId)|\(kind)|\(key.tick)" as NSString
        let smoothKey = "\(stream)|\(key.tick)" as NSString

        if s > 0, let hit = cache.object(forKey: smoothKey) {
            remember(stream, key.tick, hit)
            return hit.image(fitting: image.extent)
        }
        var mask: MaskBuffer
        if let hit = cache.object(forKey: rawKey) {
            mask = hit
        } else {
            guard let fresh = Segmentation.lowRes(kind, image) else { return nil }
            cache.setObject(fresh, forKey: rawKey, cost: fresh.cost)
            mask = fresh
        }
        if s > 0 {
            lock.lock()
            let prev = previous[stream]
            lock.unlock()
            if let prev, prev.tick != key.tick, abs(prev.tick - key.tick) <= Self.maxGap {
                mask = mask.blended(with: prev.mask, weight: s)
            }
            remember(stream, key.tick, mask)
            cache.setObject(mask, forKey: smoothKey, cost: mask.cost)
        }
        return mask.image(fitting: image.extent)
    }

    public func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        previous.removeAll()
        lock.unlock()
    }

    private func remember(_ stream: String, _ tick: Int, _ mask: MaskBuffer) {
        lock.lock()
        previous[stream] = (tick, mask)
        lock.unlock()
    }
}
