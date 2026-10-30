import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let context = CIContext(options: [.workingColorSpace: NSNull()])

private struct Rand {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}

/// A blocky random texture tinted toward `tint`, `w`×`h`, shifted right by `shift` pixels.
private func shot(_ w: Int, _ h: Int, seed: UInt64, tint: SIMD3<Float>, shift: Int = 0, noise: Float = 0, frame: UInt64 = 0) -> Plane {
    var rng = Rand(state: seed)
    let cells = (0..<(64 * 64)).map { _ in rng.next() }
    var grain = Rand(state: seed &* 31 &+ frame)
    var p = Plane(width: w, height: h)
    for y in 0..<h {
        for x in 0..<w {
            let v = cells[((y / 8) % 64) * 64 + ((x + shift) / 8) % 64]
            for c in 0..<3 { p.data[(y * w + x) * 3 + c] = min(1, max(0, tint[c] * (0.55 + 0.45 * v) + noise * (grain.next() - 0.5))) }
        }
    }
    return p
}

private func pixelBuffer(_ p: Plane) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, p.width, p.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    p.write(to: pb!)
    return pb!
}

private func run(_ frames: [Plane], fps: Double = 24, cuts: [Seconds] = [], stages: [TemporalStage]) async throws -> [Plane] {
    try await runBlocking { cancelled in
        var k = 0
        let window = FrameWindow(cuts: cuts, frameDuration: 1 / fps) {
            guard k < frames.count else { return nil }
            defer { k += 1 }
            return (Double(k) / fps, pixelBuffer(frames[k]))
        }
        var out: [Plane] = []
        try PictureProcessor(stages: stages).run(window, cancelled: cancelled) { _, _, plane in out.append(plane) }
        return out
    }
}

private func meanColor(_ p: Plane, x0: Int, y0: Int, x1: Int, y1: Int) -> SIMD3<Float> {
    var s = SIMD3<Float>(repeating: 0)
    for y in y0..<y1 { for x in x0..<x1 { let o = (y * p.width + x) * 3; s += SIMD3(p.data[o], p.data[o + 1], p.data[o + 2]) } }
    return s / Float((x1 - x0) * (y1 - y0))
}

private let red = SIMD3<Float>(0.95, 0.15, 0.2), blue = SIMD3<Float>(0.15, 0.25, 0.95)

@Test func shotSplitterFindsHardCutsButNotPans() {
    let w = 160, h = 90
    let splitter = ShotSplitter(cuts: [], frameDuration: 1.0 / 24)
    var frames: [Plane] = []
    for i in 0..<12 { frames.append(shot(w, h, seed: 1, tint: red, shift: 3 * i, noise: 0.05, frame: UInt64(i))) }
    for i in 0..<12 { frames.append(shot(w, h, seed: 2, tint: red * 0.9 + blue * 0.1, shift: 3 * i, noise: 0.05, frame: UInt64(i))) }
    for (i, f) in frames.enumerated() { splitter.feed(pixelBuffer(f), time: Double(i) / 24) }
    splitter.finish()
    #expect(splitter.flags.indices.filter { splitter.flags[$0] } == [12])
    #expect(splitter.sameShot(3, 11) && !splitter.sameShot(11, 12) && splitter.sameShot(12, 23))
}

@Test func analysisCutReportedLateSplitsAtTheChange() {
    // A soft cut the detector alone misses: the same texture, shifted, a little darker. Analysis samples every
    // 0.25 s, so it reports the cut after the frame where it happens.
    let w = 160, h = 90
    var frames: [Plane] = []
    for _ in 0..<10 { frames.append(shot(w, h, seed: 3, tint: SIMD3(0.6, 0.6, 0.6))) }
    for _ in 0..<10 { frames.append(shot(w, h, seed: 3, tint: SIMD3(0.55, 0.55, 0.55), shift: 4)) }
    let plain = ShotSplitter(cuts: [], frameDuration: 1.0 / 24)
    let guided = ShotSplitter(cuts: [10.0 / 24 + 0.2], frameDuration: 1.0 / 24)
    for (i, f) in frames.enumerated() {
        let pb = pixelBuffer(f)
        plain.feed(pb, time: Double(i) / 24)
        guided.feed(pb, time: Double(i) / 24)
    }
    plain.finish()
    guided.finish()
    #expect(!plain.flags.contains(true))
    #expect(guided.flags.indices.filter { guided.flags[$0] } == [10])
}

@Test func denoiseNeverBlendsAcrossACut() async throws {
    let w = 96, h = 64
    let frames = (0..<8).map { shot(w, h, seed: 4, tint: red, noise: 0.08, frame: UInt64($0)) } + (0..<8).map { shot(w, h, seed: 5, tint: blue, noise: 0.08, frame: UInt64($0)) }
    // A threshold this loose would happily average red into blue if the cut weren't respected.
    let denoiser = Denoiser(.init(radius: 3, strength: 1, threshold: 2, spatial: 0, mix: 1), flow: nil, context: context)
    let out = try await run(frames, stages: [denoiser])
    #expect(out.count == frames.count)
    for i in 8..<11 {
        let c = meanColor(out[i], x0: 0, y0: 0, x1: w, y1: h)
        let truth = meanColor(frames[i], x0: 0, y0: 0, x1: w, y1: h)
        #expect(abs(c.x - truth.x) < 0.02, "frame \(i) red \(c.x) vs \(truth.x)")
    }
    for i in 5..<8 {
        let c = meanColor(out[i], x0: 0, y0: 0, x1: w, y1: h)
        let truth = meanColor(frames[i], x0: 0, y0: 0, x1: w, y1: h)
        #expect(abs(c.z - truth.z) < 0.02, "frame \(i) blue \(c.z) vs \(truth.z)")
    }
}

@Test func objectRemovalNeverCopiesPixelsFromThePreviousShot() async throws {
    let w = 128, h = 72
    // Shot A shows the background behind the box (no object); shot B has a static object there, so only shot A
    // would reveal what's behind it.
    let a = (0..<12).map { shot(w, h, seed: 6, tint: red, shift: $0, frame: UInt64($0)) }
    var b: [Plane] = []
    for i in 0..<14 {
        var f = shot(w, h, seed: 7, tint: blue, frame: UInt64(i))
        for y in 24..<48 { for x in 52..<76 { let o = (y * w + x) * 3; f.data[o] = 0.1; f.data[o + 1] = 0.9; f.data[o + 2] = 0.1 } }
        b.append(f)
    }
    let box = NormRect(x: 52.0 / Double(w), y: 24.0 / Double(h), width: 24.0 / Double(w), height: 24.0 / Double(h))
    var s = ObjectRemover.Settings(samples: [TrackSample(t: 0, box: box, confidence: 1), TrackSample(t: 25.0 / 24, box: box, confidence: 1)], padding: 2 / Float(h), window: 1, feather: 1 / Float(h), mix: 1)
    s.patchFill = false
    let out = try await run(a + b, stages: [ObjectRemover(s, fps: 24, context: context)])
    for i in 12..<16 {
        let hole = meanColor(out[i], x0: 56, y0: 28, x1: 72, y1: 44)
        #expect(hole.x < 0.4 && hole.z > 0.5, "frame \(i) hole \(hole)")
    }
}

private func makeContext(_ w: Int, _ h: Int, data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext {
    CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

private func writeVideo(width w: Int, height h: Int, fps: Int32, frames: Int, draw: (CGContext, Int) -> Void) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotcut-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * Int(fps)],
    ])
    input.expectsMediaDataInRealTime = false
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

/// Shot A (frames 0..<cut): a square moving right on a dark texture. Shot B: a different scene with a look-alike square.
private func twoShotVideo(cut: Int, frames: Int, fps: Int32) async throws -> (URL, (Int) -> NormRect) {
    let w = 320, h = 180, side = 40.0
    let pos = { (i: Int) in (x: 60 + 6 * Double(i), y: 60.0) }
    let url = try await writeVideo(width: w, height: h, fps: fps, frames: frames) { ctx, i in
        var rng = Rand(state: i < cut ? 1 : 2)
        ctx.setFillColor(red: i < cut ? 0.15 : 0.7, green: i < cut ? 0.12 : 0.75, blue: i < cut ? 0.1 : 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for _ in 0..<70 {
            ctx.setFillColor(red: CGFloat(rng.next()), green: CGFloat(rng.next()), blue: CGFloat(rng.next()), alpha: 1)
            ctx.fill(CGRect(x: CGFloat(rng.next()) * CGFloat(w), y: CGFloat(rng.next()) * CGFloat(h), width: 8 + CGFloat(rng.next()) * 30, height: 8 + CGFloat(rng.next()) * 30))
        }
        let p = i < cut ? pos(i) : (x: 220.0, y: 100.0)
        ctx.setFillColor(red: 1, green: 0.95, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: p.x, y: Double(h) - p.y - side, width: side, height: side))
    }
    return (url, { i in NormRect(x: pos(i).x / Double(w), y: pos(i).y / Double(h), width: side / Double(w), height: side / Double(h)) })
}

@Test func trackersStopAtACut() async throws {
    let fps: Int32 = 24, cut = 18, frames = 36
    let (url, box) = try await twoShotVideo(cut: cut, frames: frames, fps: fps)
    defer { try? FileManager.default.removeItem(at: url) }
    let cutTime = Double(cut) / Double(fps), end = Double(frames - 1) / Double(fps)

    let forward = try await ObjectTracker.run(media: url, from: 0, to: end, box: box(0), fps: 24)
    let b = try #require(forward.cut)
    #expect(abs(b.time - cutTime) < 1.0 / Double(fps), "cut at \(b.time)")
    #expect(!b.fromAnalysis)
    #expect(forward.samples.allSatisfy { $0.t < cutTime })
    #expect((forward.samples.last?.t ?? 0) > cutTime - 0.1)

    // Backward from shot B toward A, with an analysis cut reported late.
    let back = try await ObjectTracker.run(media: url, from: end, to: 0, box: NormRect(x: 220.0 / 320, y: 100.0 / 180, width: 40.0 / 320, height: 40.0 / 180), fps: 24, cuts: [cutTime + 0.2])
    let bb = try #require(back.cut)
    #expect(abs(bb.time - cutTime) < 1.0 / Double(fps), "back cut at \(bb.time)")
    #expect(bb.fromAnalysis)
    #expect(back.samples.allSatisfy { $0.t >= cutTime - 1e-9 })

    let (x0, x1, y0, y1): (Double, Double, Double, Double) = (60.0 / 320, 100.0 / 320, 60.0 / 180, 100.0 / 180)
    let corners: [SIMD2<Double>] = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
    let planar = try await PlanarTracker.run(media: url, from: 0, to: end, corners: corners, fps: 24)
    #expect(planar.samples.allSatisfy { $0.t < cutTime })
    if let pc = planar.cut { #expect(abs(pc.time - cutTime) < 1.0 / Double(fps)) }
}
