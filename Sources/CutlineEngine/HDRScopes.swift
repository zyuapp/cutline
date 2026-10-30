import AVFoundation
import CoreImage
import CutlineCore
import Foundation

/// Scopes and statistics of HDR timelines in absolute light (cd/m²), from half-float renders of PQ or HLG code values.
public enum HDRScopes {
    /// A rendered frame's code values, row 0 at the top.
    public struct Frame: Sendable {
        public var width: Int
        public var height: Int
        public var rgb: [SIMD3<Float>]
    }

    /// Light statistics of one frame. A pixel's light level is its brightest component (as for MaxCLL).
    public struct Light: Sendable, Equatable {
        public var time: Seconds = 0
        public var maxNits: Double = 0
        /// Frame-average light level (the frame's contribution to MaxFALL).
        public var averageNits: Double = 0
        public var p50: Double = 0
        public var p90: Double = 0
        public var p99: Double = 0
        /// Mean luminance (Y) in cd/m².
        public var luminance: Double = 0
        /// Shares of pixels with colors outside Display P3 and outside Rec. 709 primaries.
        public var outsideP3: Double = 0
        public var outside709: Double = 0
    }

    static func matrix(to target: Primaries) -> simd_float3x3 {
        let m = Primaries.matrix(from: .rec2020, to: target)
        return simd_float3x3(columns: (SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2)))
    }

    static let toP3 = matrix(to: .p3D65)
    static let to709 = matrix(to: .rec709)
    /// PQ code value bins for percentiles.
    static let bins = 1024

    /// Statistics of code values in `space` (PQ or HLG, BT.2020 primaries).
    public static func light(_ rgb: [SIMD3<Float>], space: WorkingSpace, time: Seconds = 0) -> Light {
        let encoding = LightEncoding(space)
        var hist = [Int](repeating: 0, count: bins)
        var peak: Float = 0
        var sum = 0.0, sumY = 0.0
        var p3 = 0, r709 = 0
        let weights = encoding.lumaWeights
        for c in rgb {
            let n = encoding.nits(c)
            let m = max(n.x, max(n.y, n.z))
            peak = max(peak, m)
            sum += Double(m)
            sumY += Double((n * weights).sum())
            hist[min(bins - 1, max(0, Int(Transfer.pqEncode(nits: m) * Float(bins - 1) + 0.5)))] += 1
            if m > 0.5 {
                if (toP3 * n).min() < -0.01 * m { p3 += 1 }
                if (to709 * n).min() < -0.01 * m { r709 += 1 }
            }
        }
        let total = max(rgb.count, 1)
        func percentile(_ q: Double) -> Double {
            let target = Int(q * Double(total - 1))
            var acc = 0
            for (i, k) in hist.enumerated() {
                acc += k
                if acc > target { return Double(Transfer.pqDecode(Float(i) / Float(bins - 1))) }
            }
            return Double(peak)
        }
        return Light(time: time, maxNits: Double(peak), averageNits: sum / Double(total), p50: percentile(0.5), p90: percentile(0.9), p99: percentile(0.99),
                     luminance: sumY / Double(total), outsideP3: Double(p3) / Double(total), outside709: Double(r709) / Double(total))
    }

    /// Code values of a half-float RGBA buffer, every `step`-th pixel.
    static func codeValues(_ pb: CVPixelBuffer, step: Int = 1) -> Frame? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity((w / step + 1) * (h / step + 1))
        var rows = 0
        for y in stride(from: 0, to: h, by: step) {
            let line = (base + y * row).assumingMemoryBound(to: Float16.self)
            for x in stride(from: 0, to: w, by: step) {
                out.append(SIMD3(Float(line[x * 4]), Float(line[x * 4 + 1]), Float(line[x * 4 + 2])))
            }
            rows += 1
        }
        return Frame(width: (w + step - 1) / step, height: rows, rgb: out)
    }

    /// One frame of an HDR timeline as code values, at most `maxSize`.
    public static func frame(_ built: BuiltTimeline, at t: Seconds, maxSize: CGSize = CGSize(width: 960, height: 540)) async throws -> Frame {
        let comp = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
        let full = comp.renderSize
        let s = min(1, maxSize.width / full.width, maxSize.height / full.height)
        comp.renderSize = CGSize(width: max(2, (full.width * s / 2).rounded() * 2), height: max(2, (full.height * s / 2).rounded() * 2))
        let reader = try AVAssetReader(asset: built.composition)
        let frameLength = built.scene.project.canvas.frameDuration
        let at = min(max(0, t), max(0, built.duration - frameLength))
        reader.timeRange = CMTimeRange(start: TimelineBuilder.time(at), duration: TimelineBuilder.time(frameLength))
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        ])
        output.videoComposition = comp
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot render the frame at \(String(format: "%.2f", t))s") }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample), let f = codeValues(pb) else {
            throw reader.error ?? EditError("No frame at \(String(format: "%.2f", t))s")
        }
        return f
    }

    /// Light statistics of every frame of `built` between `range` (render it at a small scale for speed).
    public static func measure(_ built: BuiltTimeline, range: TimeRange? = nil) async throws -> [Light] {
        let space = built.scene.project.canvas.colorSpace
        guard space.isHDR else { return [] }
        let reader = try AVAssetReader(asset: built.composition)
        if let range { reader.timeRange = CMTimeRange(start: TimelineBuilder.time(range.start), end: TimelineBuilder.time(min(range.end, built.duration))) }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        ])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the timeline's picture") }
        return try await runBlocking { stop in
            var out: [Light] = []
            while let sample = output.copyNextSampleBuffer() {
                if stop() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                let step = max(1, Int((Double(CVPixelBufferGetWidth(pb) * CVPixelBufferGetHeight(pb)) / 40_000).squareRoot()))
                if let f = codeValues(pb, step: step) { out.append(light(f.rgb, space: space, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds)) }
            }
            if reader.status == .failed { throw reader.error ?? EditError("Reading the picture failed") }
            return out
        }
    }

    // MARK: Waveform

    /// Graticule levels of the nits waveform.
    public static let levels: [Double] = [0.1, 1, 10, 100, 203, 1000, 4000, 10_000]

    /// A luminance waveform with a cd/m² scale: x follows the picture's columns, y is luminance on the PQ curve.
    public static func waveform(_ f: Frame, space: WorkingSpace, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w >= 64, h >= 48, f.width > 0, f.height > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let plot = CGRect(x: 40, y: 8, width: size.width - 48, height: size.height - 16).integral
        let pw = Int(plot.width), ph = Int(plot.height)
        let encoding = LightEncoding(space), weights = encoding.lumaWeights
        var counts = [UInt32](repeating: 0, count: pw * ph)
        for y in 0..<f.height {
            for x in 0..<f.width {
                let n = encoding.nits(f.rgb[y * f.width + x])
                let v = Transfer.pqEncode(nits: max(0, (n * weights).sum()))
                let col = x * pw / f.width
                let r = ph - 1 - Int((v * Float(ph - 1)).rounded())
                counts[max(0, min(ph - 1, r)) * pw + col] += 1
            }
        }
        let canvas = Scopes.Canvas(data: data, width: w, height: h)
        let reference = max(1, Float(f.width * f.height) / Float(pw) / 24)
        for r in 0..<ph {
            for c in 0..<pw where counts[r * pw + c] > 0 {
                canvas.add(Int(plot.minX) + c, Int(plot.minY) + r, SIMD3(0.55, 1, 0.6) * min(1, (Float(counts[r * pw + c]) / reference).squareRoot()))
            }
        }
        for level in levels {
            let v = CGFloat(Transfer.pqEncode(nits: Float(level)))
            let y = size.height - (plot.maxY - 1 - v * (plot.height - 1))
            let major = level == 100 || level == 203 || level == 1000
            ctx.setStrokeColor(CGColor(red: 0.85, green: 0.7, blue: 0.3, alpha: major ? 0.55 : 0.22))
            ctx.setLineWidth(major ? 1 : 0.5)
            ctx.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)])
            Scopes.label(ctx, level < 1 ? "0.1" : level >= 1000 ? "\(Int(level / 1000))k" : "\(Int(level))", at: CGPoint(x: 4, y: y - 3))
        }
        Scopes.label(ctx, "cd/m²", at: CGPoint(x: plot.maxX - 34, y: size.height - plot.minY - 10))
        return ctx.makeImage()
    }
}
