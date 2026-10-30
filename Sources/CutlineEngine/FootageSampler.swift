import AVFoundation
import CoreGraphics
import CutlineCore
import Foundation

/// A quick look at footage without shot analysis: sharpness, motion and brightness from small decoded frames.
public enum FootageSampler {
    public struct Sample: Sendable, Equatable {
        public var time: Seconds
        /// Mean absolute Laplacian of the luma, 0…1; soft or out-of-focus frames score low.
        public var sharpness: Double
        /// Mean absolute luma change to the frame `gap` later, 0…1.
        public var motion: Double
        public var brightness: Double

        /// Sharp, well-exposed frames score high; near-black or blown-out frames are penalized.
        public var quality: Double {
            var q = sharpness * 10
            if brightness < 0.06 || brightness > 0.92 { q -= 0.5 }
            return q
        }
    }

    static let side = 160

    /// Measures frames at `times` (source seconds) of a video file, each against the frame `gap` later.
    public static func sample(_ url: URL, times: [Seconds], gap: Seconds = 0.2) async throws -> [Sample] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: side, height: side)
        let tolerance = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        var out: [Sample] = []
        for t in times {
            let a = min(max(0, t), max(0, duration - gap - 0.05))
            guard let first = try? await gen.image(at: CMTime(seconds: a, preferredTimescale: 600)).image, let lumaA = luma(first) else { continue }
            let second = try? await gen.image(at: CMTime(seconds: a + gap, preferredTimescale: 600)).image
            let lumaB = second.flatMap(luma)
            out.append(measure(lumaA, lumaB, time: t))
        }
        return out
    }

    struct Luma {
        let width: Int
        let height: Int
        let values: [UInt8]
    }

    static func luma(_ img: CGImage) -> Luma? {
        let w = img.width, h = img.height
        guard w > 2, h > 2, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var values = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { values[y * w + x] = data[y * ctx.bytesPerRow + x] } }
        return Luma(width: w, height: h, values: values)
    }

    static func measure(_ a: Luma, _ b: Luma?, time: Seconds) -> Sample {
        let w = a.width, h = a.height
        var lap = 0.0, bright = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Int(a.values[y * w + x])
                let l = 4 * c - Int(a.values[y * w + x - 1]) - Int(a.values[y * w + x + 1]) - Int(a.values[(y - 1) * w + x]) - Int(a.values[(y + 1) * w + x])
                lap += Double(abs(l))
            }
        }
        for v in a.values { bright += Double(v) }
        var motion = 0.0
        if let b, b.width == w, b.height == h {
            for i in a.values.indices { motion += Double(abs(Int(a.values[i]) - Int(b.values[i]))) }
            motion /= Double(a.values.count) * 255
        }
        return Sample(time: time, sharpness: lap / Double((w - 2) * (h - 2)) / 255 / 4, motion: motion, brightness: bright / Double(a.values.count) / 255)
    }
}
