import AVFoundation
import CoreImage
import CutlineCore
import Foundation
import VideoToolbox

/// Working-space plumbing for Core Image, AVFoundation and camera log input.
///
/// Integration in the compositor:
/// - Log clips: read the source frame with `rawImage(_:)` (no color matching) and run `applyInput(_:log:target:tone:exposure:)`.
///   The result is in the context's working space like any other layer, so effects, blending and text behave as before.
/// - Output: render with `colorSpace(target)` into a buffer of `pixelFormat(target)`, and tag the video composition with
///   `videoCompositionTags(target)` and the writer with `writerColorProperties(target)`.
/// - Log sources should be decoded at 10 bits (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`); 8-bit log bands.
public enum ColorManagement {
    public static func colorSpace(_ w: WorkingSpace) -> CGColorSpace {
        switch w {
        case .rec709: CGColorSpace(name: CGColorSpace.itur_709)!
        case .p3: CGColorSpace(name: CGColorSpace.displayP3)!
        case .rec2020_hlg: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        case .rec2020_pq: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        }
    }

    /// Values for `AVVideoComposition.colorPrimaries`, `colorTransferFunction` and `colorYCbCrMatrix`
    /// (the same strings as the CoreVideo attachment values).
    public static func videoCompositionTags(_ w: WorkingSpace) -> (primaries: String, transfer: String, matrix: String) {
        switch w {
        case .rec709: (AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_709_2)
        case .p3: (AVVideoColorPrimaries_P3_D65, AVVideoTransferFunction_IEC_sRGB, AVVideoYCbCrMatrix_ITU_R_709_2)
        case .rec2020_hlg: (AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrix_ITU_R_2020)
        case .rec2020_pq: (AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunction_SMPTE_ST_2084_PQ, AVVideoYCbCrMatrix_ITU_R_2020)
        }
    }

    /// The value for `AVVideoColorPropertiesKey` in writer output settings.
    public static func writerColorProperties(_ w: WorkingSpace) -> [String: Any] {
        let t = videoCompositionTags(w)
        return [AVVideoColorPrimariesKey: t.primaries, AVVideoTransferFunctionKey: t.transfer, AVVideoYCbCrMatrixKey: t.matrix]
    }

    /// Writer output settings: H.264 High for SDR, HEVC Main10 for HDR, tagged for `w`.
    public static func writerVideoSettings(_ w: WorkingSpace, width: Int, height: Int, bitrate: Int? = nil) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoProfileLevelKey: w.isHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
        ]
        if let bitrate { compression[AVVideoAverageBitRateKey] = bitrate }
        return [
            AVVideoCodecKey: w.isHDR ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: writerColorProperties(w),
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// Render-target pixel format: 8-bit BGRA for SDR, half-float RGBA for HDR.
    public static func pixelFormat(_ w: WorkingSpace) -> OSType {
        w.isHDR ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
    }

    /// Attaches primaries, transfer function and matrix for `w` to a rendered buffer.
    public static func tag(_ pb: CVPixelBuffer, _ w: WorkingSpace) {
        let t = videoCompositionTags(w)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, t.primaries as CFString, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, t.transfer as CFString, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, t.matrix as CFString, .shouldPropagate)
    }

    // MARK: Log input

    /// Core Image's default working space. `CIColorCubeWithColorSpace` converts from the working space into its
    /// `inputColorSpace` before the lookup; using the working space itself makes that a no-op, so the cube sees the
    /// raw camera values of an image made by `rawImage(_:)`. Contexts must keep the default working space.
    public static let passthroughSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A frame with its decoded RGB values untouched by color matching (video range is still expanded to 0…1).
    public static func rawImage(_ pb: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
    }

    final class Cube {
        let size: Int
        let data: Data
        init(size: Int, data: Data) {
            self.size = size
            self.data = data
        }
    }

    nonisolated(unsafe) static let cubes: NSCache<NSString, Cube> = {
        let c = NSCache<NSString, Cube>()
        c.countLimit = 32
        return c
    }()

    /// A 65³ RGBA float cube from camera-encoded log RGB to `target`'s encoded signal, for `CIColorCubeWithColorSpace`.
    ///
    /// The cube expects raw camera values, so apply it on `rawImage(_:)` with `passthroughSpace`, then tag the result
    /// as `colorSpace(target)` to bring it into the working space:
    ///
    ///     ColorManagement.rawImage(pb)
    ///         .applyingFilter("CIColorCubeWithColorSpace", parameters: [
    ///             "inputCubeDimension": cube.size, "inputCubeData": cube.data,
    ///             "inputColorSpace": ColorManagement.passthroughSpace])
    ///         .matchedToWorkingSpace(from: ColorManagement.colorSpace(target))
    ///
    /// `applyInput` does exactly this.
    public static func inputCube(log: LogProfile, target: WorkingSpace, tone: ToneMap, exposure: Float, recordedIn: SignalRange = .video) -> (size: Int, data: Data) {
        let key = "in|\(log.rawValue)|\(target.rawValue)|\(tone.rawValue)|\(String(format: "%.4f", exposure))|\(recordedIn.rawValue)" as NSString
        if let hit = cubes.object(forKey: key) { return (hit.size, hit.data) }
        let cube = bake(size: 65, ColorPipeline.inputTransform(log: log, target: target, tone: tone, exposure: exposure, recordedIn: recordedIn))
        cubes.setObject(cube, forKey: key)
        return (cube.size, cube.data)
    }

    /// A 33³ cube between two display encodings, applied the same way with `colorSpace(source)` values as input.
    public static func displayCube(from source: WorkingSpace, to target: WorkingSpace, tone: ToneMap, exposure: Float) -> (size: Int, data: Data) {
        let key = "disp|\(source.rawValue)|\(target.rawValue)|\(tone.rawValue)|\(String(format: "%.4f", exposure))" as NSString
        if let hit = cubes.object(forKey: key) { return (hit.size, hit.data) }
        let cube = bake(size: 33, ColorPipeline.displayTransform(from: source, to: target, tone: tone, exposure: exposure))
        cubes.setObject(cube, forKey: key)
        return (cube.size, cube.data)
    }

    /// Converts a raw log frame to `target`, returning an image in the working space.
    public static func applyInput(_ raw: CIImage, log: LogProfile, target: WorkingSpace, tone: ToneMap, exposure: Float, recordedIn: SignalRange = .video) -> CIImage {
        let cube = inputCube(log: log, target: target, tone: tone, exposure: exposure, recordedIn: recordedIn)
        let mapped = raw.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": passthroughSpace,
        ])
        return mapped.matchedToWorkingSpace(from: colorSpace(target)) ?? mapped
    }

    /// Samples `f` on a `size`³ grid, red fastest, slices in parallel.
    static func bake(size n: Int, _ f: ColorMath.Transform) -> Cube {
        var floats = [Float](repeating: 1, count: n * n * n * 4)
        let step = 1 / Float(n - 1)
        floats.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            nonisolated(unsafe) let out = base
            DispatchQueue.concurrentPerform(iterations: n) { b in
                for g in 0..<n {
                    for r in 0..<n {
                        let v = simd_clamp(f(SIMD3(Float(r), Float(g), Float(b)) * step), .zero, SIMD3(repeating: 1))
                        let o = ((b * n + g) * n + r) * 4
                        out[o] = v.x
                        out[o + 1] = v.y
                        out[o + 2] = v.z
                    }
                }
            }
        }
        return Cube(size: n, data: floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    // MARK: Detection

    /// The camera log a video was recorded in, from its format description (Apple Log) or vendor metadata
    /// (Sony XML, and log names in QuickTime/MP4 metadata). Nil when nothing identifies it.
    public static func detectLog(_ asset: AVAsset) async -> LogProfile? {
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var text: [String] = []
        for track in tracks {
            for desc in (try? await track.load(.formatDescriptions)) ?? [] {
                guard let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] else { continue }
                for key in [kCMFormatDescriptionExtension_LogTransferFunction as String, kCVImageBufferLogTransferFunctionKey as String] {
                    if let value = ext[key] as? String, let p = logTransfer(value) { return p }
                }
                text.append(contentsOf: ext.values.compactMap { $0 as? String })
            }
            for item in (try? await track.load(.metadata)) ?? [] {
                if let s = try? await item.load(.stringValue) { text.append(s) }
            }
        }
        if let items = try? await asset.load(.metadata) {
            for item in items {
                if let s = try? await item.load(.stringValue) { text.append(s) }
            }
        }
        for s in text {
            if let p = profile(fromMarker: s) { return p }
        }
        if let url = (asset as? AVURLAsset)?.url, url.isFileURL, let p = sonyXML(url) { return p }
        return nil
    }

    static func logTransfer(_ value: String) -> LogProfile? {
        if value == kCMFormatDescriptionLogTransferFunction_AppleLog as String || value == kCVImageBufferLogTransferFunction_AppleLog2 as String {
            return .apple_log
        }
        return profile(fromMarker: value)
    }

    /// Recognizes a log curve name in free text such as "S-Log3-Cine", "V-Log", "LogC4" or "com.apple.log".
    static func profile(fromMarker text: String) -> LogProfile? {
        let s = text.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }
        if has("d-log-m", "dlog-m", "d-logm") { return nil }
        if has("s-log3", "slog3") {
            if has("cine") { return .slog3 }
            return has("s-gamut3", "sgamut3") ? .slog3_sgamut3 : .slog3
        }
        if has("logc4", "log-c4") { return .logc4 }
        if has("logc", "log-c") { return .logc3 }
        if has("v-log") { return .vlog }
        if has("canon-log-3", "c-log3", "clog3", "canon-log3") { return .clog3 }
        if has("canon-log-2", "c-log2", "clog2", "canon-log2") { return .clog2 }
        if has("f-log2", "flog2") { return .flog2 }
        if has("f-log") { return .flog }
        if has("n-log") { return .nlog }
        if has("film-gen-5", "film-gen5", "filmgen5") { return .bmd_film_gen5 }
        if has("log3g10") { return .redlog3g10 }
        if has("d-log") { return .dlog }
        if has("apple-log", "applelog", "com.apple.log") { return .apple_log }
        return nil
    }

    /// Sony XAVC files carry NonRealTimeMeta XML with CaptureGammaEquation / CaptureColorPrimaries,
    /// near the start or end of the file.
    static func sonyXML(_ url: URL) -> LogProfile? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 2 << 20
        var blobs: [Data] = []
        if let head = try? h.read(upToCount: chunk) { blobs.append(head) }
        if let end = try? h.seekToEnd(), end > UInt64(chunk) {
            try? h.seek(toOffset: end - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { blobs.append(tail) }
        }
        for blob in blobs {
            if let p = sonyMarker(blob) { return p }
        }
        return nil
    }

    static func sonyMarker(_ blob: Data) -> LogProfile? {
        func value(_ name: String) -> String? {
            guard let r = blob.range(of: Data("\"\(name)\" value=\"".utf8)) else { return nil }
            let rest = blob[r.upperBound...].prefix(64)
            guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
            return String(decoding: blob[r.upperBound..<end], as: UTF8.self)
        }
        guard let gamma = value("CaptureGammaEquation") else { return nil }
        return profile(fromMarker: gamma + " " + (value("CaptureColorPrimaries") ?? ""))
    }
}
