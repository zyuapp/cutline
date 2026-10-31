import AVFoundation
import CoreMedia
import CutlineCore
import Foundation
import VideoToolbox

/// HDR10 static metadata: the mastering display's color volume (SMPTE ST 2086) and the program's content light
/// levels (CTA-861.3 MaxCLL and MaxFALL), written into PQ HEVC exports.
public struct HDRMetadata: Sendable, Equatable {
    /// Primaries of the display the program was graded on.
    public enum MasteringPrimaries: String, CaseIterable, Sendable {
        case p3_d65, bt2020, rec709

        var primaries: Primaries {
            switch self {
            case .p3_d65: .p3D65
            case .bt2020: .rec2020
            case .rec709: .rec709
            }
        }
    }

    public var primaries: MasteringPrimaries
    /// Peak and black luminance of the mastering display, in cd/m².
    public var maxLuminance: Double
    public var minLuminance: Double
    /// Brightest pixel and brightest frame average of the program, in cd/m²; nil measures them from the render.
    public var maxCLL: Int?
    public var maxFALL: Int?

    public init(primaries: MasteringPrimaries = .p3_d65, maxLuminance: Double = 1000, minLuminance: Double = 0.0001, maxCLL: Int? = nil, maxFALL: Int? = nil) {
        self.primaries = primaries
        self.maxLuminance = maxLuminance
        self.minLuminance = minLuminance
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }

    /// The 24-byte big-endian mastering display color volume: G, B, R then white chromaticities in 0.00002 units,
    /// then max and min luminance in 0.0001 cd/m² (the HEVC SEI and `mdcv` box layout).
    public var masteringDisplayData: Data {
        let p = primaries.primaries
        var d = Data()
        func u16(_ v: Double) { withUnsafeBytes(of: UInt16(min(50_000, max(0, (v / 0.00002).rounded()))).bigEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: Double) { withUnsafeBytes(of: UInt32(min(Double(UInt32.max), max(0, (v / 0.0001).rounded()))).bigEndian) { d.append(contentsOf: $0) } }
        for xy in [p.green, p.blue, p.red] { u16(xy.x); u16(xy.y) }
        u16(p.white.x)
        u16(p.white.y)
        u32(maxLuminance)
        u32(minLuminance)
        return d
    }

    /// The 4-byte big-endian content light level info: MaxCLL then MaxFALL.
    public static func contentLightData(maxCLL: Int, maxFALL: Int) -> Data {
        var d = Data()
        for v in [maxCLL, maxFALL] { withUnsafeBytes(of: UInt16(min(65_535, max(0, v))).bigEndian) { d.append(contentsOf: $0) } }
        return d
    }

    /// Decodes `masteringDisplayData`.
    public init?(masteringDisplay d: Data) {
        guard d.count == 24 else { return nil }
        let b = [UInt8](d)
        func u16(_ i: Int) -> Double { Double(UInt16(b[i]) << 8 | UInt16(b[i + 1])) * 0.00002 }
        func u32(_ i: Int) -> Double { Double(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])) * 0.0001 }
        let red = SIMD2(u16(8), u16(10))
        guard let match = MasteringPrimaries.allCases.first(where: { simd_distance($0.primaries.red, red) < 0.001 }) else { return nil }
        self.init(primaries: match, maxLuminance: u32(16), minLuminance: u32(20))
    }

    /// Content light levels of a rendered PQ program, accumulated frame by frame.
    public struct LightLevels: Sendable, Equatable {
        public var maxCLL: Double = 0
        public var maxFALL: Double = 0
        public var frames = 0

        public init() {}

        /// Adds one frame of PQ code values in a half-float RGBA buffer: each pixel's light level is its brightest
        /// component in cd/m².
        public mutating func add(_ pb: CVPixelBuffer) {
            guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            let chunks = min(h, 16)
            var peaks = [Float](repeating: 0, count: chunks), sums = [Double](repeating: 0, count: chunks)
            let nits = HDRMetadata.pqNits
            nonisolated(unsafe) let src = base
            peaks.withUnsafeMutableBufferPointer { pk in
                sums.withUnsafeMutableBufferPointer { sm in
                    nonisolated(unsafe) let peak = pk.baseAddress!, sum = sm.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: chunks) { k in
                        var top: Float16 = 0
                        var total: Float = 0
                        for y in h * k / chunks..<h * (k + 1) / chunks {
                            let line = (src + y * row).assumingMemoryBound(to: Float16.self)
                            var lineTotal: Float = 0
                            for x in 0..<w {
                                let m = max(line[x * 4], line[x * 4 + 1], line[x * 4 + 2])
                                lineTotal += nits(m)
                                if m > top { top = m }
                            }
                            total += lineTotal
                        }
                        peak[k] = nits(top)
                        sum[k] = Double(total)
                    }
                }
            }
            maxCLL = max(maxCLL, Double(peaks.max() ?? 0))
            maxFALL = max(maxFALL, sums.reduce(0, +) / Double(max(1, w * h)))
            frames += 1
        }
    }

    /// cd/m² of a PQ code value, clamped to 0…1.
    @inline(__always) static func pqNits(_ v: Float16) -> Float {
        pqTable[Int((Float(min(max(v, 0), 1)) * 4095).rounded())]
    }

    static let pqTable: [Float] = (0...4095).map { Transfer.pqDecode(Float($0) / 4095) }

    /// Renders `built` over `range` (timeline seconds) through the compositor and measures its content light levels.
    public static func measure(_ built: BuiltTimeline, range: CMTimeRange) async throws -> LightLevels {
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = range
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        ])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the timeline to measure its light levels") }
        return try await runBlocking { stop in
            var levels = LightLevels()
            while let sample = output.nextSample() {
                if stop() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                if let pb = CMSampleBufferGetImageBuffer(sample) { levels.add(pb) }
            }
            if reader.status == .failed { throw reader.error ?? EditError("Measuring light levels failed") }
            return levels
        }
    }

    /// The static metadata a movie's first video track carries, with its content light levels; nil without any.
    public static func read(_ url: URL) async throws -> HDRMetadata? {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let fd = try await track.load(.formatDescriptions).first else { return nil }
        let ext = { (k: CFString) in CMFormatDescriptionGetExtension(fd, extensionKey: k) as? Data }
        guard let mdcv = ext(kCMFormatDescriptionExtension_MasteringDisplayColorVolume), var meta = HDRMetadata(masteringDisplay: mdcv) else { return nil }
        if let clli = ext(kCMFormatDescriptionExtension_ContentLightLevelInfo), clli.count == 4 {
            let b = [UInt8](clli)
            meta.maxCLL = Int(UInt16(b[0]) << 8 | UInt16(b[1]))
            meta.maxFALL = Int(UInt16(b[2]) << 8 | UInt16(b[3]))
        }
        return meta
    }

    /// Whether a file's picture is tagged PQ or HLG; nil when it has none or can't be read.
    public static func isHDR(_ url: URL) async -> Bool? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return nil }
        let transfer = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return transfer.map { [kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG].map { $0 as String }.contains($0) } ?? false
    }

    /// Default HEVC bitrate for HDR delivery: 20 Mb/s at 1080p up to 30 fps, scaling with the 0.75 power of the
    /// pixel count and the 0.7 power of the frame rate above 30.
    public static func defaultBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = Double(width * height) / (1920 * 1080)
        return Int(20_000_000 * pow(pixels, 0.75) * pow(max(fps, 30) / 30, 0.7))
    }
}
