import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

private func makeContext(_ w: Int, _ h: Int, data: UnsafeMutableRawPointer? = nil, bytesPerRow: Int = 0) -> CGContext {
    CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

/// Random rectangles and discs, for registration to lock onto.
private func texture(width w: Int, height h: Int, seed: UInt64, dark: Bool = false) -> CGImage {
    var rng = LCG(state: seed)
    let ctx = makeContext(w, h)
    ctx.setFillColor(gray: dark ? 0.1 : 0.5, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for _ in 0..<(w * h / 900) {
        let scale = dark ? 0.3 : 1
        ctx.setFillColor(red: rng.next() * scale, green: rng.next() * scale, blue: rng.next() * scale, alpha: 1)
        let r = CGRect(x: rng.next() * Double(w), y: rng.next() * Double(h), width: 6 + rng.next() * 40, height: 6 + rng.next() * 40)
        if rng.next() < 0.5 { ctx.fill(r) } else { ctx.fillEllipse(in: r) }
    }
    return ctx.makeImage()!
}

/// Draws each frame in y-up CoreGraphics coordinates.
private func writeVideo(width w: Int, height h: Int, fps: Int32, frames: Int, transform: CGAffineTransform = .identity, draw: (CGContext, Int) -> Void) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("motion-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * Int(fps)],
    ])
    input.expectsMediaDataInRealTime = false
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        draw(makeContext(w, h, data: CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)), i)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

/// Luma of every frame, row-major from the top left.
private func readLuma(_ url: URL) async throws -> (width: Int, height: Int, frames: [[Double]], times: [Seconds]) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    #expect(reader.startReading())
    return try await runBlocking { _ in
        var frames: [[Double]] = [], times: [Seconds] = []
        var w = 0, h = 0
        while let s = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
            frames.append(luma(pb))
            times.append(CMSampleBufferGetPresentationTimeStamp(s).seconds)
            w = CVPixelBufferGetWidth(pb)
            h = CVPixelBufferGetHeight(pb)
        }
        _ = asset
        return (w, h, frames, times)
    }
}

private func luma(_ pb: CVPixelBuffer) -> [Double] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var out = [Double](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let o = y * row + x * 4
            out[y * w + x] = (0.11 * Double(p[o]) + 0.59 * Double(p[o + 1]) + 0.3 * Double(p[o + 2])) / 255
        }
    }
    return out
}

private func meanDiff(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(max(1, a.count))
}

/// Centroid of pixels brighter than `threshold`, in fractions from the top left.
private func centroid(_ l: [Double], width: Int, height: Int, threshold: Double = 0.7) -> (x: Double, y: Double)? {
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in 0..<height {
        for x in 0..<width where l[y * width + x] > threshold {
            sx += Double(x)
            sy += Double(y)
            n += 1
        }
    }
    return n > 0 ? ((sx / n + 0.5) / Double(width), (sy / n + 0.5) / Double(height)) : nil
}

private func jitter(_ x: [Double]) -> Double {
    guard x.count > 2 else { return 0 }
    var sum = 0.0
    for i in 1..<(x.count - 1) {
        let d: Double = x[i - 1] - 2 * x[i] + x[i + 1]
        sum += abs(d)
    }
    return sum / Double(x.count - 2)
}

@Test func stabilizerRecoversJitteryPanAndSmoothsIt() async throws {
    let w = 480, h = 270, frames = 45
    let tex = texture(width: 900, height: 600, seed: 7)
    var rng = LCG(state: 3)
    let offsets = (0..<frames).map { i in (x: 3.0 * Double(i) + (rng.next() - 0.5) * 8, y: 1.5 * Double(i) + (rng.next() - 0.5) * 8) }
    let url = try await writeVideo(width: w, height: h, fps: 30, frames: frames) { ctx, i in
        // Camera window at (x, y) from the texture's top left; content moves the other way.
        ctx.draw(tex, in: CGRect(x: -offsets[i].x - 20, y: offsets[i].y + 20 + Double(h) - Double(tex.height), width: Double(tex.width), height: Double(tex.height)))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let range = TimeRange(0, Double(frames - 1) / 30)
    try? FileManager.default.removeItem(at: Stabilizer.cacheURL(media: url, range: range))
    let started = Date()
    let m = try await Stabilizer.analyze(media: url, range: range)
    let elapsed = Date().timeIntervalSince(started)
    #expect(m.count == frames && m.fps == 30 && m.start == 0)
    #expect(abs(m.aspect - 16.0 / 9) < 0.01)
    for i in 0..<frames {
        let ex = -(offsets[i].x - offsets[0].x) / Double(w), ey = -(offsets[i].y - offsets[0].y) / Double(h)
        #expect(abs(m.dx[i] - ex) < 0.01, "dx[\(i)] \(m.dx[i]) vs \(ex)")
        #expect(abs(m.dy[i] - ey) < 0.015, "dy[\(i)] \(m.dy[i]) vs \(ey)")
        #expect(abs(m.angle[i]) < 1, "angle[\(i)] \(m.angle[i])")
    }
    #expect(Stabilizer.cached(media: url, range: range) == m)

    let path = Stabilizer.path(m, smoothing: 0.3)
    #expect(Stabilizer.path(m, smoothing: 0.3) === path)
    let fixed = (0..<frames).map { i -> (Double, Double) in
        let c = Stabilizer.correction(m, at: Double(i) / 30, smoothing: 0.3, strength: 1)
        return (m.dx[i] + c.dx, m.dy[i] + c.dy)
    }
    #expect(jitter(fixed.map(\.0)) < 0.3 * jitter(m.dx), "\(jitter(fixed.map(\.0))) vs \(jitter(m.dx))")
    #expect(jitter(fixed.map(\.1)) < 0.3 * jitter(m.dy))
    let half = path.correction(at: 0.5, strength: 0.5), full = path.correction(at: 0.5, strength: 1)
    #expect(abs(half.dx * 2 - full.dx) < 1e-12)
    let zoom = Stabilizer.requiredZoom(path, strength: 1)
    #expect(zoom > 1 && zoom < 1.1, "zoom \(zoom)")
    #expect(Stabilizer.requiredZoom(path, strength: 0) == 1)
    print("stabilizer: \(frames) frames analysed in \(String(format: "%.2f", elapsed)) s, zoom \(zoom)")
}

@Test func stabilizerMeasuresRotationClockwise() async throws {
    let w = 480, h = 270, frames = 12
    let tex = texture(width: 700, height: 700, seed: 11)
    let url = try await writeVideo(width: w, height: h, fps: 30, frames: frames) { ctx, i in
        ctx.translateBy(x: Double(w) / 2, y: Double(h) / 2)
        ctx.rotate(by: -Double(i) * 0.4 * .pi / 180)
        ctx.draw(tex, in: CGRect(x: -350, y: -350, width: 700, height: 700))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let range = TimeRange(0, Double(frames - 1) / 30)
    try? FileManager.default.removeItem(at: Stabilizer.cacheURL(media: url, range: range))
    let m = try await Stabilizer.analyze(media: url, range: range)
    let last = frames - 1
    #expect(abs(m.angle[last] - 0.4 * Double(last)) < 0.8, "angle \(m.angle)")
    #expect(abs(m.dx[last]) < 0.01 && abs(m.dy[last]) < 0.01, "\(m.dx[last]), \(m.dy[last])")
}

@Test func smoothedPathKeepsSteadyPans() {
    let m = Stabilizer.Motion(fps: 30, start: 2, aspect: 16.0 / 9, dx: (0..<60).map { Double($0) * 0.01 }, dy: Array(repeating: 0, count: 60), angle: Array(repeating: 0, count: 60))
    let path = StabilizationPath(m, smoothing: 0.5)
    for t in stride(from: 2.0, through: m.end, by: 0.1) { #expect(abs(path.correction(at: t, strength: 1).dx) < 1e-9) }
    #expect(Stabilizer.requiredZoom(path, strength: 1) < 1 + 1e-9)
}

@Test func objectTrackerFollowsMovingSquare() async throws {
    let w = 640, h = 360, fps: Int32 = 15, frames = 30
    let bg = texture(width: w, height: h, seed: 5, dark: true)
    let side = 60.0
    // Top-left of the square in y-down pixels.
    let pos = { (i: Int) in (x: 80 + 12 * Double(i), y: 60 + 5 * Double(i)) }
    let url = try await writeVideo(width: w, height: h, fps: fps, frames: frames) { ctx, i in
        ctx.draw(bg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 1, green: 0.95, blue: 0.5, alpha: 1)
        let p = pos(i)
        ctx.fill(CGRect(x: p.x, y: Double(h) - p.y - side, width: side, height: side))
        ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: p.x + 15, y: Double(h) - p.y - side + 15, width: 30, height: 30))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let box = { (i: Int) in NormRect(x: pos(i).x / Double(w), y: pos(i).y / Double(h), width: side / Double(w), height: side / Double(h)) }
    let duration = Double(frames - 1) / Double(fps)

    let started = Date()
    let forward = try await ObjectTracker.track(media: url, from: 0, to: duration, box: box(0))
    let elapsed = Date().timeIntervalSince(started)
    #expect(forward.count == frames)
    #expect(forward.first?.t == 0)
    for s in forward {
        let truth = box(Int((s.t * Double(fps)).rounded()))
        #expect(hypot(s.box.midX - truth.midX, s.box.midY - truth.midY) < 0.05, "t \(s.t): \(s.box) vs \(truth)")
    }
    #expect(forward.dropFirst().allSatisfy { $0.confidence > 0.3 })

    let backward = try await ObjectTracker.track(media: url, from: duration, to: 0.5, box: box(frames - 1), fps: 10)
    #expect(backward.map(\.t) == backward.map(\.t).sorted())
    #expect(abs((backward.first?.t ?? 0) - 0.5) < 1e-6 && abs((backward.last?.t ?? 0) - duration) < 1e-6)
    for s in backward {
        let truth = box(Int((s.t * Double(fps)).rounded()))
        #expect(hypot(s.box.midX - truth.midX, s.box.midY - truth.midY) < 0.05, "back t \(s.t): \(s.box) vs \(truth)")
    }
    print("tracker: \(frames) frames in \(String(format: "%.2f", elapsed)) s")
}

@Test func sourceFramesApplyTrackOrientation() async throws {
    let w = 320, h = 180
    let url = try await writeVideo(width: w, height: h, fps: 10, frames: 5, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0)) { ctx, _ in
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 20, y: Double(h) - 20 - 40, width: 60, height: 40))
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let frames = try await SourceFrames.open(url: url, maxSize: CGSize(width: 1000, height: 1000), from: 0)
    #expect(frames.size == CGSize(width: h, height: w))
    let ours = try #require(centroid(luma(try frames.frame(near: 0.2).buffer), width: h, height: w))

    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    let img = try await gen.image(at: CMTime(value: 2, timescale: 10)).image
    #expect(img.width == h && img.height == w)
    let ctx = makeContext(img.width, img.height)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    var pixels = [Double](repeating: 0, count: img.width * img.height)
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<img.height {
        for x in 0..<img.width { pixels[y * img.width + x] = Double(p[y * ctx.bytesPerRow + x * 4 + 1]) / 255 }
    }
    let theirs = try #require(centroid(pixels, width: img.width, height: img.height))
    #expect(abs(ours.x - theirs.x) < 0.02 && abs(ours.y - theirs.y) < 0.02, "\(ours) vs \(theirs)")
    #expect(ours.x > 0.5 && ours.y < 0.5)
}

private func movingSquareVideo() async throws -> URL {
    let w = 320, h = 180
    return try await writeVideo(width: w, height: h, fps: 10, frames: 10) { ctx, i in
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 20 + 24 * Double(i), y: 70, width: 40, height: 40))
    }
}

@Test func retimeSourceTimesFollowClipTiming() {
    var clip = Clip(id: "c", kind: .media, mediaId: "m", start: 5, duration: 2, sourceIn: 1, speed: 0.5)
    #expect(abs(RetimeProxy.sourceTime(clip, atLocal: 0) - 1) < 1e-9)
    #expect(abs(RetimeProxy.sourceTime(clip, atLocal: 2) - 2) < 1e-9)
    #expect(abs(RetimeProxy.sourceTime(clip, atLocal: -0.2) - 0.9) < 1e-9)
    clip.reverse = true
    #expect(abs(RetimeProxy.sourceTime(clip, atLocal: 0) - 2) < 1e-9)
    #expect(abs(RetimeProxy.sourceTime(clip, atLocal: 2.4) - 0.8) < 1e-9)
    clip.reverse = false
    clip.anim["time.speed"] = Curve(keys: [CurveKey(t: 0, v: .number(1), ease: .linear), CurveKey(t: 2, v: .number(0.25), ease: .linear)])
    for t in stride(from: 0.0, through: 2, by: 0.25) {
        #expect(abs(RetimeProxy.sourceTime(clip, atLocal: t) - clip.sourceTime(atTimeline: 5 + t)) < 1e-3, "t \(t)")
    }
    #expect(abs(RetimeProxy.sourceTime(clip, atLocal: 2.4) - (clip.sourceOut + 0.1)) < 1e-3)
}

@Test func retimeProxyBlendsSlowMotion() async throws {
    let url = try await movingSquareVideo()
    defer { try? FileManager.default.removeItem(at: url) }
    let media = MediaAsset(id: "m", path: url.path, name: "square", duration: 1, width: 320, height: 180, fps: 10, hasVideo: true, hasAudio: false)
    let clip = Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 1.6, sourceIn: 0, speed: 0.5)
    let started = Date()
    let (proxy, usedFlow) = try await RetimeProxy.url(for: media, clip: clip, head: 0.2, fps: 10, maxSize: CGSize(width: 320, height: 320))
    let elapsed = Date().timeIntervalSince(started)
    #expect(!usedFlow)
    let duration = try await AVURLAsset(url: proxy).load(.duration).seconds
    #expect(abs(duration - 1.8) < 0.01, "duration \(duration)")
    let out = try await readLuma(proxy)
    let src = try await readLuma(url)
    #expect(out.frames.count == 18 && out.width == 320 && out.height == 180)
    // Frames 0–2 are the extrapolated head: source -0.1, -0.05 (clamped to frame 0) and 0.
    #expect(meanDiff(out.frames[0], src.frames[0]) < 0.02)
    #expect(meanDiff(out.frames[2], src.frames[0]) < 0.02)
    #expect(meanDiff(out.frames[4], src.frames[1]) < 0.02)
    let between = out.frames[3]
    #expect(meanDiff(between, out.frames[2]) > 0.01 && meanDiff(between, out.frames[4]) > 0.01)
    let ghost = centroid(between, width: 320, height: 180, threshold: 0.4)
    let a = centroid(out.frames[2], width: 320, height: 180)!, b = centroid(out.frames[4], width: 320, height: 180)!
    #expect(abs((ghost?.x ?? 0) - (a.x + b.x) / 2) < 0.02)
    let again = try await RetimeProxy.url(for: media, clip: clip, head: 0.2, fps: 10, maxSize: CGSize(width: 320, height: 320))
    #expect(again.url == proxy)
    print("retime blend: \(out.frames.count) frames in \(String(format: "%.2f", elapsed)) s")
}

@Test func retimeProxyReversesAndTriesFlow() async throws {
    let url = try await movingSquareVideo()
    defer { try? FileManager.default.removeItem(at: url) }
    let media = MediaAsset(id: "m", path: url.path, name: "square", duration: 1, width: 320, height: 180, fps: 10, hasVideo: true, hasAudio: false)
    var clip = Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 1.6, sourceIn: 0, speed: 0.5)
    clip.reverse = true
    let src = try await readLuma(url)

    let reversed = try await RetimeProxy.url(for: media, clip: clip, fps: 10, maxSize: CGSize(width: 320, height: 320))
    let back = try await readLuma(reversed.url)
    #expect(back.frames.count == 16)
    #expect(meanDiff(back.frames[0], src.frames[8]) < 0.02)
    #expect(meanDiff(back.frames[2], src.frames[7]) < 0.02)
    #expect(meanDiff(back.frames[1], src.frames[8]) > 0.01 && meanDiff(back.frames[1], src.frames[7]) > 0.01)

    let started = Date()
    let flow = try await RetimeProxy.url(for: media, clip: clip, fps: 10, maxSize: CGSize(width: 320, height: 320), interpolation: .flow)
    let elapsed = Date().timeIntervalSince(started)
    let f = try await readLuma(flow.url)
    #expect(f.frames.count == 16)
    #expect(meanDiff(f.frames[2], src.frames[7]) < 0.03)
    if flow.usedFlow {
        #expect(flow.url != reversed.url)
        let mid = try #require(centroid(f.frames[1], width: 320, height: 180, threshold: 0.6))
        let a = centroid(src.frames[8], width: 320, height: 180)!, b = centroid(src.frames[7], width: 320, height: 180)!
        #expect(abs(mid.x - (a.x + b.x) / 2) < 0.03, "flow mid \(mid.x) vs \((a.x + b.x) / 2)")
    } else {
        #expect(flow.url == reversed.url)
    }
    print("retime flow: usedFlow \(flow.usedFlow), \(f.frames.count) frames in \(String(format: "%.2f", elapsed)) s")
}
