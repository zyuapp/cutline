import AVFoundation
import CoreImage
import CutlineCore
import Foundation

/// Per-frame picture statistics, in Rec. 709 code values 0…1.
public struct FrameStats: Sendable {
    public var time: Seconds
    public var luma: Double
    public var p2: Double
    public var p98: Double
    /// Fractions of pixels at or above 0.98 / at or below 0.02.
    public var clipped: Double
    public var crushed: Double
    public var saturation: Double
    /// Mean chroma: positive cb is blue, positive cr is red.
    public var cb: Double
    public var cr: Double
}

/// Numbers an agent can grade and check the picture with.
public struct PictureReport: Sendable {
    public var frames: [FrameStats]
    /// Stretches darker than 0.03 mean luma for at least 3 frames.
    public var black: [TimeRange]
    /// Luminance flashes: more than 3 big brightness reversals within a second (photosensitivity risk).
    public var flashes: [TimeRange]
    /// Single or double frames whose brightness jumps away and straight back.
    public var flashFrames: [Seconds]
}

public enum PictureMeter {
    /// Reads every frame of the built timeline (at a small render size) between `range`.
    public static func measure(_ built: BuiltTimeline, range: TimeRange? = nil) async throws -> PictureReport {
        let comp = built.composition
        let reader = try AVAssetReader(asset: comp)
        let tracks = try await comp.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(start: TimelineBuilder.time(range.start), end: TimelineBuilder.time(min(range.end, built.duration)))
        }
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the timeline's picture") }
        var frames: [FrameStats] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(stats(pb, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        if reader.status == .failed { throw reader.error ?? EditError("Reading the picture failed") }
        return analyze(frames)
    }

    static func analyze(_ frames: [FrameStats]) -> PictureReport {
        var black: [TimeRange] = []
        var run: [FrameStats] = []
        for f in frames + [FrameStats(time: .infinity, luma: 1, p2: 1, p98: 1, clipped: 0, crushed: 0, saturation: 0, cb: 0, cr: 0)] {
            if f.luma < 0.03 { run.append(f); continue }
            if run.count >= 3, let a = run.first, let b = run.last { black.append(TimeRange(a.time, b.time + (frames.count > 1 ? frames[1].time - frames[0].time : 0))) }
            run = []
        }
        var flashFrames: [Seconds] = []
        if frames.count >= 3 {
            for i in 1..<(frames.count - 1) {
                let a = frames[i - 1].luma, b = frames[i].luma, c = frames[i + 1].luma
                if abs(b - a) > 0.25 && abs(b - c) > 0.25 && abs(a - c) < 0.1 { flashFrames.append(frames[i].time) }
            }
        }
        // WCAG 2.3.1: a flash is a pair of opposing luminance changes of 10% or more; more than three per second is a risk.
        var reversals: [Seconds] = []
        var lastSign = 0
        var anchor = frames.first?.luma ?? 0
        for f in frames {
            let d = f.luma - anchor
            if abs(d) >= 0.1 {
                let sign = d > 0 ? 1 : -1
                if sign != lastSign && lastSign != 0 { reversals.append(f.time) }
                lastSign = sign
                anchor = f.luma
            } else if (d > 0 && lastSign > 0) || (d < 0 && lastSign < 0) {
                anchor = f.luma
            }
        }
        var flashes: [TimeRange] = []
        var i = 0
        for j in reversals.indices {
            while reversals[j] - reversals[i] > 1 { i += 1 }
            if j - i + 1 > 6 {
                let r = TimeRange(reversals[i], reversals[j])
                if let last = flashes.last, last.end >= r.start { flashes[flashes.count - 1] = TimeRange(last.start, r.end) } else { flashes.append(r) }
            }
        }
        return PictureReport(frames: frames, black: black, flashes: flashes, flashFrames: flashFrames)
    }

    static func stats(_ pb: CVPixelBuffer, time: Seconds) -> FrameStats {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            return FrameStats(time: time, luma: 0, p2: 0, p98: 0, clipped: 0, crushed: 0, saturation: 0, cb: 0, cr: 0)
        }
        var hist = [Int](repeating: 0, count: 256)
        var sumY = 0.0, sumS = 0.0, sumCb = 0.0, sumCr = 0.0
        var clipped = 0, crushed = 0
        let step = max(1, Int(sqrt(Double(w * h) / 40_000)))
        var n = 0
        for y in stride(from: 0, to: h, by: step) {
            let p = base + y * row
            for x in stride(from: 0, to: w, by: step) {
                let b = Double(p[x * 4]) / 255, g = Double(p[x * 4 + 1]) / 255, r = Double(p[x * 4 + 2]) / 255
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                hist[min(255, Int(luma * 255))] += 1
                sumY += luma
                let mx = max(r, g, b), mn = min(r, g, b)
                sumS += mx > 0 ? (mx - mn) / mx : 0
                sumCb += (b - luma) / 1.8556
                sumCr += (r - luma) / 1.5748
                if luma >= 0.98 { clipped += 1 }
                if luma <= 0.02 { crushed += 1 }
                n += 1
            }
        }
        let total = Double(max(n, 1))
        func percentile(_ q: Double) -> Double {
            let target = Int(q * total)
            var acc = 0
            for (i, c) in hist.enumerated() {
                acc += c
                if acc > target { return Double(i) / 255 }
            }
            return 1
        }
        return FrameStats(time: time, luma: sumY / total, p2: percentile(0.02), p98: percentile(0.98), clipped: Double(clipped) / total, crushed: Double(crushed) / total, saturation: sumS / total, cb: sumCb / total, cr: sumCr / total)
    }

    // MARK: Text legibility

    public struct TextCheck: Sendable {
        public var label: String
        public var time: Seconds
        /// Fractions of the canvas, origin top left.
        public var box: CGRect
        public var contrast: Double
        /// How far the box pokes outside the safe area, as a fraction of the canvas; 0 when inside.
        public var safeOverflow: Double
    }

    /// Where each title and caption sits, and its WCAG contrast against the picture behind it.
    /// `background` renders the timeline without text at a time.
    public static func checkText(_ project: Project, captions: [CaptionSegment], safe: CGRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), background: (Seconds) async throws -> CGImage) async throws -> [TextCheck] {
        let scene = RenderScene(project: project, captions: captions, trackIDs: [:], orientations: [:], images: [:])
        let canvas = scene.canvasRect
        var samples: [(String, Seconds, CGRect, TextStyleColors)] = []
        for track in project.tracks where track.kind == .video && !track.hidden {
            for clip in track.clips where clip.kind == .text {
                let t = clip.start + min(clip.duration * 0.5, max(0.5, clip.duration * 0.3))
                let local = t - clip.start
                guard let spec = clip.resolvedText(at: local), let img = scene.textImage(spec, reveal: nil) else { continue }
                let xf = clip.resolvedTransform(at: local)
                let size = CGSize(width: img.extent.width * xf.scale, height: img.extent.height * xf.scale)
                let cx = canvas.width * (spec.x + xf.x), cyTop = canvas.height * (spec.y + xf.y)
                let box = CGRect(x: (cx - size.width / 2) / canvas.width, y: (cyTop - size.height / 2) / canvas.height, width: size.width / canvas.width, height: size.height / canvas.height)
                let name = "\(clip.id) \"\(spec.text.prefix(24))\""
                samples.append((name, t, box, TextStyleColors(text: spec.color, background: spec.background, stroke: spec.strokeWidth > 0.04 ? spec.stroke : nil)))
            }
        }
        if project.captions.enabled {
            let style = project.captions.style
            for seg in captions.sorted(by: { $0.text.count > $1.text.count }).prefix(4) {
                let t = (seg.start + seg.end) / 2
                guard let img = scene.captionImage(at: t) else { continue }
                let e = img.extent
                let box = CGRect(x: e.minX / canvas.width, y: (canvas.height - e.maxY) / canvas.height, width: e.width / canvas.width, height: e.height / canvas.height)
                samples.append(("caption \"\(seg.text.replacingOccurrences(of: "\n", with: " ").prefix(24))\"", t, box, TextStyleColors(text: style.color, background: style.background, stroke: style.strokeWidth > 0.04 ? style.stroke : nil)))
            }
        }
        var out: [TextCheck] = []
        for (label, t, box, colors) in samples {
            let bg = try await background(t)
            let contrast = colors.contrast(over: luminances(bg, box: box))
            let overflow = max(0, safe.minX - box.minX, box.maxX - safe.maxX, safe.minY - box.minY, box.maxY - safe.maxY)
            out.append(TextCheck(label: label, time: t, box: box, contrast: contrast, safeOverflow: overflow))
        }
        return out
    }

    struct TextStyleColors {
        var text: RGBA
        var background: RGBA?
        var stroke: RGBA?

        /// Contrast against the brightest (for light text) or darkest (dark text) tenth of the backdrop,
        /// improved by a box behind the text or an outline when present.
        func contrast(over lums: [Double]) -> Double {
            let lt = PictureMeter.relativeLuminance(text)
            if let bgc = background, bgc.a >= 0.6 {
                return PictureMeter.contrast(lt, PictureMeter.relativeLuminance(bgc))
            }
            let sorted = lums.sorted()
            guard !sorted.isEmpty else { return 21 }
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let worst = lt > mean ? sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))] : sorted[Int(Double(sorted.count) * 0.1)]
            var c = PictureMeter.contrast(lt, worst)
            if let stroke { c = max(c, PictureMeter.contrast(lt, PictureMeter.relativeLuminance(stroke))) }
            return c
        }
    }

    static func relativeLuminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Relative luminance of pixels inside a box given in canvas fractions (top-left origin).
    static func luminances(_ img: CGImage, box: CGRect) -> [Double] {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let x0 = max(0, Int(box.minX * Double(w))), x1 = min(w, Int(box.maxX * Double(w)))
        let y0 = max(0, Int(box.minY * Double(h))), y1 = min(h, Int(box.maxY * Double(h)))
        var out: [Double] = []
        let step = max(1, Int(sqrt(Double(max(1, (x1 - x0) * (y1 - y0))) / 4000)))
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                let o = y * w * 4 + x * 4
                out.append(relativeLuminance(RGBA(r: Double(data[o]) / 255, g: Double(data[o + 1]) / 255, b: Double(data[o + 2]) / 255)))
            }
        }
        return out
    }
}
