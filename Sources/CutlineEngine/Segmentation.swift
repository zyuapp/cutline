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
        /// The foreground instance that best matches a box (image fractions, top-left origin), limited to the box
        /// grown by `padding` (fraction of the image height); the box itself when `fallback` and no instance matches.
        /// `id` names the followed object, so temporal smoothing joins its frames although the box moves.
        case object(NormRect, padding: Double, fallback: Bool, id: String)
        /// The heuristic sky matte with `SkyMask.Settings` encoded as their key.
        case sky(String)

        public var description: String {
            switch self {
            case .person(let q): return "person.\(q.rawValue)"
            case .subject: return "subject"
            case .object(let b, let pad, let fallback, let id): return String(format: "object.%@.%.4f,%.4f,%.4f,%.4f,%.4f,%d", id, b.x, b.y, b.width, b.height, pad, fallback ? 1 : 0)
            case .sky(let s): return "sky.\(s)"
            }
        }

        /// What successive frames' masks have in common, for smoothing.
        var stream: String {
            if case .object(_, let pad, let fallback, let id) = self { return "object.\(id).\(pad).\(fallback)" }
            return description
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
    /// With `threshold` above 0 the matte is hardened first (see `harden`). `expand` then grows (negative: shrinks)
    /// the mask by that many pixels before `feather` softens its edge over about that many pixels.
    public static func apply(mask: CIImage, to image: CIImage, feather: CGFloat = 0, invert: Bool = false, expand: CGFloat = 0, threshold: CGFloat = 0) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: refine(mask, extent: image.extent, feather: feather, invert: invert, expand: expand, threshold: threshold)])
    }

    /// Steepens a soft matte around `threshold`: values 0.05 above it become 1, values 0.05 below become 0.
    public static func harden(_ mask: CIImage, threshold: CGFloat) -> CIImage {
        guard threshold > 0 else { return mask }
        let k: CGFloat = 10
        let bias = 0.5 - k * threshold
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    /// The gray matte `apply` keeps the image with, covering `e`.
    public static func refine(_ mask: CIImage, extent e: CGRect, feather: CGFloat = 0, invert: Bool = false, expand: CGFloat = 0, threshold: CGFloat = 0) -> CIImage {
        var m = harden(mask.composited(over: CIImage(color: .black)).cropped(to: e), threshold: threshold)
        if abs(expand) >= 0.5 {
            m = m.clampedToExtent()
                .applyingFilter(expand > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: abs(expand)])
                .cropped(to: e)
        }
        if feather >= 0.5 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: e)
        }
        if invert { m = m.applyingFilter("CIColorInvert") }
        return m
    }

    /// Runs Vision on a downscaled copy and returns its mask at Vision's resolution.
    static func lowRes(_ kind: Kind, _ image: CIImage) -> MaskBuffer? {
        if case .sky(let s) = kind { return SkyMask.lowRes(image, SkyMask.Settings(key: s)) }
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
        case .object(let box, let padding, let fallback, _):
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let request = VNGenerateForegroundInstanceMaskRequest()
            var picked: MaskBuffer?
            if (try? handler.perform([request])) != nil, let observation = request.results?.first, !observation.allInstances.isEmpty,
               let labels = MaskLabels(observation.instanceMask),
               let best = labels.bestInstance(box, among: observation.allInstances),
               let out = try? observation.generateMask(forInstances: IndexSet(integer: best)) {
                picked = MaskBuffer(out)
            }
            let region = box.padded(padding * Double(h) / Double(max(w, 1)), padding)
            guard let picked else { return fallback ? MaskBuffer.box(box, width: w, height: h) : .empty }
            return picked.limited(to: region)
        case .sky:
            return nil
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

    /// 1 inside `box` (fractions, top-left origin), 0 elsewhere.
    static func box(_ box: NormRect, width: Int, height: Int) -> MaskBuffer {
        MaskBuffer(width: width, height: height, values: [Float](repeating: 1, count: width * height)).limited(to: box)
    }

    /// This mask with everything outside `region` (fractions, top-left origin) cleared.
    func limited(to region: NormRect) -> MaskBuffer {
        let x0 = Int((region.x * Double(width)).rounded()), x1 = Int(((region.x + region.width) * Double(width)).rounded())
        let y0 = Int((region.y * Double(height)).rounded()), y1 = Int(((region.y + region.height) * Double(height)).rounded())
        var out = values
        for y in 0..<height {
            for x in 0..<width where x < x0 || x >= x1 || y < y0 || y >= y1 { out[y * width + x] = 0 }
        }
        return MaskBuffer(width: width, height: height, values: out)
    }
}

/// Vision's instance label map: 0 is background, n the n-th foreground instance.
struct MaskLabels {
    let width: Int
    let height: Int
    let labels: [UInt8]

    init(width: Int, height: Int, labels: [UInt8]) {
        self.width = width
        self.height = height
        self.labels = labels
    }

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { labels[y * w + x] = row[x] }
        }
        self.init(width: w, height: h, labels: labels)
    }

    /// The instance whose pixels best overlap `box` (intersection over union), counting only instances mostly inside
    /// the box or covering most of it; nil when none qualifies.
    func bestInstance(_ box: NormRect, among instances: IndexSet) -> Int? {
        var area = [Int](repeating: 0, count: 256), inside = [Int](repeating: 0, count: 256)
        let x0 = box.x * Double(width), x1 = (box.x + box.width) * Double(width)
        let y0 = box.y * Double(height), y1 = (box.y + box.height) * Double(height)
        for y in 0..<height {
            let cy = Double(y) + 0.5
            for x in 0..<width {
                let l = Int(labels[y * width + x])
                guard l > 0 else { continue }
                area[l] += 1
                let cx = Double(x) + 0.5
                if cx >= x0, cx < x1, cy >= y0, cy < y1 { inside[l] += 1 }
            }
        }
        let boxArea = max(1, (x1 - x0) * (y1 - y0))
        var best: (Int, Double)?
        for l in instances where l > 0 && l < 256 && inside[l] > 0 {
            let a = Double(area[l]), i = Double(inside[l])
            let iou = i / (a + boxArea - i)
            guard iou > 0.1 || i / a > 0.3 || i / boxArea > 0.5 else { continue }
            if best == nil || iou > best!.1 { best = (l, iou) }
        }
        return best?.0
    }
}

extension NormRect {
    /// Grown by `dx` on the left and right and `dy` on the top and bottom.
    func padded(_ dx: Double, _ dy: Double) -> NormRect {
        NormRect(x: x - dx, y: y - dy, width: width + 2 * dx, height: height + 2 * dy)
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
        let stream = "\(key.mediaId)|\(kind.stream)|\(String(format: "%.3f", s))"
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
