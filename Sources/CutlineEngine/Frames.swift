import AVFoundation
import AppKit
import CoreImage
import CutlineCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct LabeledFrame {
    public var time: Seconds
    public var label: String
    public var image: CGImage

    public init(time: Seconds, label: String, image: CGImage) {
        self.time = time
        self.label = label
        self.image = image
    }
}

public enum Frames {
    /// Renders timeline frames through the compositor, exactly as export will.
    public static func timeline(_ built: BuiltTimeline, times: [Seconds], maxSize: CGSize) async throws -> [LabeledFrame] {
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = maxSize
        let frame = built.scene.project.canvas.frameDuration
        var out: [LabeledFrame] = []
        for t in times {
            let clamped = min(max(0, t), max(0, built.duration - frame))
            let (img, _) = try await gen.image(at: TimelineBuilder.time(clamped))
            out.append(LabeledFrame(time: clamped, label: timecode(clamped), image: img))
        }
        return out
    }

    /// Source frames of one media file with its orientation applied.
    public static func media(_ media: MediaAsset, times: [Seconds], maxSize: CGSize) async throws -> [LabeledFrame] {
        if media.isImage {
            guard let src = CGImageSourceCreateWithURL(media.url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(maxSize.width, maxSize.height), kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { throw EditError("Cannot read \(media.path)") }
            return [LabeledFrame(time: 0, label: media.name, image: img)]
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        gen.maximumSize = maxSize
        var out: [LabeledFrame] = []
        for t in times {
            let clamped = min(max(0, t), max(0, media.duration - 0.05))
            let (img, _) = try await gen.image(at: CMTime(seconds: clamped, preferredTimescale: 600))
            out.append(LabeledFrame(time: clamped, label: timecode(clamped), image: img))
        }
        return out
    }

    /// Draws labeled boxes (fractions of the frame, top-left origin) over an image.
    public static func annotate(_ image: CGImage, boxes: [(NormRect, CGColor, String?)]) -> CGImage {
        guard !boxes.isEmpty else { return image }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let line = max(2, CGFloat(h) / 180)
        for (box, color, label) in boxes {
            let r = CGRect(x: box.x * Double(w), y: (1 - box.y - box.height) * Double(h), width: box.width * Double(w), height: box.height * Double(h))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(line)
            ctx.stroke(r)
            if let label {
                let font = NSFont.systemFont(ofSize: max(11, CGFloat(h) / 28), weight: .semibold)
                let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white])
                let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                text.draw(at: CGPoint(x: r.minX + line, y: r.maxY + line))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return ctx.makeImage() ?? image
    }

    /// Evenly spaced sample times, centered in each slot.
    public static func spread(_ count: Int, from start: Seconds, to end: Seconds) -> [Seconds] {
        let n = max(1, count)
        let span = max(0, end - start)
        return (0..<n).map { start + span * (Double($0) + 0.5) / Double(n) }
    }

    /// Lays frames out in a labeled grid and encodes it as JPEG.
    public static func contactSheet(_ frames: [LabeledFrame], columns: Int? = nil, cellWidth: CGFloat = 384) -> Data? {
        guard let first = frames.first else { return nil }
        let cols = columns ?? min(frames.count, frames.count <= 4 ? frames.count : 4)
        let rows = Int(ceil(Double(frames.count) / Double(cols)))
        let aspect = CGFloat(first.image.height) / CGFloat(max(first.image.width, 1))
        let cellH = cellWidth * aspect
        let labelH: CGFloat = 26, gap: CGFloat = 6
        let width = CGFloat(cols) * cellWidth + CGFloat(cols + 1) * gap
        let height = CGFloat(rows) * (cellH + labelH) + CGFloat(rows + 1) * gap
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        for (i, f) in frames.enumerated() {
            let col = i % cols, row = i / cols
            let x = gap + CGFloat(col) * (cellWidth + gap)
            let yTop = height - gap - CGFloat(row) * (cellH + labelH + gap)
            let imgRect = CGRect(x: x, y: yTop - cellH, width: cellWidth, height: cellH)
            let fit = aspectFit(CGSize(width: f.image.width, height: f.image.height), in: imgRect)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(imgRect)
            ctx.interpolationQuality = .high
            ctx.draw(f.image, in: fit)
            let label = NSAttributedString(string: f.label, attributes: [.font: font, .foregroundColor: CGColor(gray: 0.9, alpha: 1)])
            let line = CTLineCreateWithAttributedString(label)
            ctx.textPosition = CGPoint(x: x + 4, y: yTop - cellH - labelH + 8)
            CTLineDraw(line, ctx)
        }
        guard let img = ctx.makeImage() else { return nil }
        return jpeg(img)
    }

    public static func jpeg(_ image: CGImage, quality: Double = 0.82) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let s = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    public static func timecode(_ t: Seconds) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}

public enum SceneDetector {
    /// Samples small frames and reports times where the picture changes sharply.
    public static func detect(_ media: MediaAsset, interval: Seconds = 0.25) async throws -> [Seconds] {
        guard media.hasVideo, !media.isImage, media.duration > interval * 2 else { return [] }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
        gen.maximumSize = CGSize(width: 48, height: 48)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let times = stride(from: 0.0, to: media.duration, by: interval).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var previous: [UInt8]?
        var diffs: [(Seconds, Double)] = []
        for await result in gen.images(for: times) {
            guard let img = try? result.image else { continue }
            let lum = luma(img)
            if let previous, previous.count == lum.count {
                var sum = 0
                for i in lum.indices { sum += abs(Int(lum[i]) - Int(previous[i])) }
                diffs.append((result.requestedTime.seconds, Double(sum) / Double(lum.count)))
            }
            previous = lum
        }
        guard !diffs.isEmpty else { return [] }
        let sorted = diffs.map(\.1).sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(28, median * 4)
        var cuts: [Seconds] = []
        for (t, d) in diffs where d > threshold {
            if let last = cuts.last, t - last < 0.75 { continue }
            cuts.append((t * 100).rounded() / 100)
        }
        return cuts
    }

    static func luma(_ img: CGImage) -> [UInt8] {
        let w = 32, h = 18
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }
}
