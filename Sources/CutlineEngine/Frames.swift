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
    /// Renders timeline frames through the compositor, exactly as export will. HDR timelines come back tone-mapped
    /// to Rec. 709 (`ColorPipeline.sdrPreview`), so SDR material looks as it does on an SDR timeline.
    public static func timeline(_ built: BuiltTimeline, times: [Seconds], maxSize: CGSize) async throws -> [LabeledFrame] {
        let frame = built.scene.project.canvas.frameDuration
        let clampedTimes = times.map { min(max(0, $0), max(0, built.duration - frame)) }
        let space = built.scene.project.canvas.colorSpace
        if space.isHDR {
            var out: [LabeledFrame] = []
            for t in clampedTimes { out.append(LabeledFrame(time: t, label: timecode(t), image: try await hdrPreview(built, at: t, maxSize: maxSize, space: space))) }
            return out
        }
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = maxSize
        var out: [LabeledFrame] = []
        for t in clampedTimes {
            let (img, _) = try await gen.image(at: TimelineBuilder.time(t))
            out.append(LabeledFrame(time: t, label: timecode(t), image: img))
        }
        return out
    }

    /// One HDR frame read at half float (8-bit PQ is too coarse for saturated colors) and tone-mapped to Rec. 709.
    static func hdrPreview(_ built: BuiltTimeline, at t: Seconds, maxSize: CGSize, space: WorkingSpace) async throws -> CGImage {
        let comp = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
        let full = comp.renderSize
        let s = min(1, maxSize.width > 0 ? maxSize.width / full.width : 1, maxSize.height > 0 ? maxSize.height / full.height : 1)
        comp.renderSize = CGSize(width: max(2, (full.width * s / 2).rounded() * 2), height: max(2, (full.height * s / 2).rounded() * 2))
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(start: TimelineBuilder.time(t), duration: TimelineBuilder.time(built.scene.project.canvas.frameDuration))
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        ])
        output.videoComposition = comp
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot render the frame at \(String(format: "%.2f", t))s") }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) else { throw reader.error ?? EditError("No frame at \(String(format: "%.2f", t))s") }
        guard let img = sdrPreview(pb, from: space) else { throw EditError("Cannot convert the frame at \(String(format: "%.2f", t))s") }
        return img
    }

    /// A half-float RGBA frame of code values in `space` as an 8-bit Rec. 709 picture through `ColorPipeline.sdrPreview`.
    static func sdrPreview(_ pb: CVPixelBuffer, from space: WorkingSpace) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let target = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: videoSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let dst = target.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(pb)
        let f = ColorPipeline.sdrPreview(from: space)
        nonisolated(unsafe) let src = base, d = dst
        DispatchQueue.concurrentPerform(iterations: min(h, 32)) { k in
            let chunks = min(h, 32)
            for y in h * k / chunks..<h * (k + 1) / chunks {
                let line = (src + y * row).assumingMemoryBound(to: Float16.self)
                for x in 0..<w {
                    let v = f(SIMD3(Float(line[x * 4]), Float(line[x * 4 + 1]), Float(line[x * 4 + 2]))) * 255
                    let o = (y * w + x) * 4
                    d[o] = UInt8(v.x.rounded())
                    d[o + 1] = UInt8(v.y.rounded())
                    d[o + 2] = UInt8(v.z.rounded())
                    d[o + 3] = 255
                }
            }
        }
        return target.makeImage()
    }

    /// The color space AVFoundation gives Rec. 709 frames of SDR timelines, so HDR previews draw the same way.
    static let videoSpace: CGColorSpace = {
        let tags = ColorManagement.videoCompositionTags(.rec709)
        let attachments = [kCVImageBufferColorPrimariesKey: tags.primaries, kCVImageBufferTransferFunctionKey: tags.transfer, kCVImageBufferYCbCrMatrixKey: tags.matrix] as CFDictionary
        return CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() ?? ColorManagement.colorSpace(.rec709)
    }()

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
        // Interlaced frames are deinterlaced at full size, then scaled.
        let fields = media.deinterlaces ? media.fieldOrder : nil
        gen.maximumSize = fields == nil ? maxSize : .zero
        var out: [LabeledFrame] = []
        for t in times {
            let clamped = min(max(0, t), max(0, media.duration - 0.05))
            var (img, _) = try await gen.image(at: CMTime(seconds: clamped, preferredTimescale: 600))
            if let fields, let clean = deinterlaced(img, order: fields, maxSize: maxSize) { img = clean }
            out.append(LabeledFrame(time: clamped, label: timecode(clamped), image: img))
        }
        return out
    }

    static func deinterlaced(_ img: CGImage, order: FieldOrder, maxSize: CGSize) -> CGImage? {
        var ci = Deinterlace.apply(CIImage(cgImage: img), order: order)
        let s = min(1, maxSize.width > 0 ? maxSize.width / ci.extent.width : 1, maxSize.height > 0 ? maxSize.height / ci.extent.height : 1)
        if s < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true) }
        return deinterlaceContext.createCGImage(ci, from: ci.extent.integral)
    }

    static let deinterlaceContext = CIContext()

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
