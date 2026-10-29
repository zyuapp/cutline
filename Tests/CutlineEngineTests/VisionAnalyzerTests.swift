import AVFoundation
import AppKit
import CoreVideo
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// 4 s at 10 fps: a light yellow frame for 2 s, then dark navy with "HELLO 123".
private func makeTwoShotVideo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vision-\(UUID().uuidString).mov")
    let w = 640, h = 360, fps: Int32 = 10
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<(4 * Int(fps)) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let second = i >= 2 * Int(fps)
        ctx.setFillColor(second ? CGColor(red: 0.05, green: 0.05, blue: 0.2, alpha: 1) : CGColor(red: 1, green: 0.95, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if second {
            let text = NSAttributedString(string: "HELLO 123", attributes: [.font: NSFont.boldSystemFont(ofSize: 72), .foregroundColor: CGColor(gray: 1, alpha: 1)])
            ctx.textPosition = CGPoint(x: 120, y: 150)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

@Test func visionAnalyzerDescribesSyntheticShots() async throws {
    let url = try await makeTwoShotVideo()
    defer { try? FileManager.default.removeItem(at: url) }
    let a = try await VisionAnalyzer.analyze(url: url, mediaId: "synthetic", sceneCuts: [2], duration: 4)
    #expect(a.shots.count == 2)
    let first = a.shots[0], second = a.shots[1]
    #expect(first.start == 0 && first.end == 2 && second.end == 4)
    #expect(second.text.contains { $0.uppercased().contains("HELLO") }, "text \(second.text)")
    #expect(first.brightness > second.brightness + 0.3, "\(first.brightness) vs \(second.brightness)")
    #expect(first.size == "no people" && first.people == 0)
    #expect(first.motion < 0.05)
    let fp0 = try #require(first.featurePrint), fp1 = try #require(second.featurePrint)
    #expect(ShotAnalysis.similarity(fp0, fp0) > ShotAnalysis.similarity(fp0, fp1))
    #expect(a.shot(at: 3)?.index == 1)
}

@Test func longShotsSplitIntoSubShots() {
    let spans = Shot.spans(cuts: [3], duration: 20)
    #expect(spans.count == 4)
    let expected: [Seconds] = [0, 3, 3 + 17.0 / 3, 3 + 34.0 / 3]
    for (s, e) in zip(spans.map(\.start), expected) { #expect(abs(s - e) < 1e-9) }
    #expect(spans.allSatisfy { $0.duration <= 8 })
    #expect(spans.last?.end == 20)
}

@Test func faceTracksLinkAcrossSamplesAndBreakAtCuts() {
    let a = { (x: Double) in NormRect(x: x, y: 0.2, width: 0.2, height: 0.3) }
    let b = { (x: Double) in NormRect(x: x, y: 0.5, width: 0.1, height: 0.15) }
    let detections: [(t: Seconds, boxes: [NormRect])] = [
        (0.25, [a(0.1), b(0.7)]),
        (0.75, [b(0.72), a(0.12)]),
        (1.25, [a(0.15)]),
        (1.75, [a(0.18), NormRect(x: 0.4, y: 0.8, width: 0.05, height: 0.05)]),
        (2.25, [a(0.18)]),
        (2.75, [a(0.2)]),
    ]
    let tracks = FaceTrack.link(detections, cuts: [2])
    #expect(tracks.count == 3)
    #expect(tracks.map(\.id) == [0, 1, 2])
    #expect(tracks[0].samples.map(\.t) == [0.25, 0.75, 1.25, 1.75])
    #expect(tracks[0].samples.allSatisfy { $0.box.height == 0.3 })
    #expect(tracks[1].samples.map(\.t) == [0.25, 0.75])
    #expect(tracks[2].samples.map(\.t) == [2.25, 2.75])
}

@Test func similarShotsRanksByFeaturePrint() {
    let shots = [
        Shot(index: 0, start: 0, end: 1, featurePrint: [1, 0, 0]),
        Shot(index: 1, start: 1, end: 2, featurePrint: [0, 1, 0]),
        Shot(index: 2, start: 2, end: 3, featurePrint: [0.9, 0.1, 0]),
        Shot(index: 3, start: 3, end: 4),
        Shot(index: 4, start: 4, end: 5, featurePrint: [0.5, 0.5, 0.1]),
    ]
    let a = ShotAnalysis(mediaId: "m", shots: shots, faces: [], samplesPerSecond: 2)
    let similar = a.similarShots(to: 0, limit: 2)
    #expect(similar.map(\.0.index) == [2, 4])
    #expect(similar[0].1 > similar[1].1)
    #expect(a.similarShots(to: 3, limit: 5).isEmpty)
    #expect(a.shot(at: 5)?.index == 4)
    #expect(a.shot(at: 6) == nil)
}

@Test func soundWindowsMergeIntoEvents() {
    let w = { (l: String, s: Double, c: Double) in SoundEvent(label: l, start: s, end: s + 1.5, confidence: c) }
    let events = SoundEvents.merge([w("music", 0, 0.8), w("music", 0.75, 0.9), w("dog", 0.75, 0.4), w("music", 4, 0.7), w("laughter", 1.5, 0.6)])
    #expect(events.map(\.label) == ["music", "laughter", "music"])
    #expect(events[0].start == 0 && events[0].end == 2.25 && events[0].confidence == 0.9)
}

@Test func soundEventDetectorHandlesATone() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let frames = AVAudioFrameCount(44_100 * 3)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 44_100) }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    let result = try await SoundEventDetector.analyze(url: url, mediaId: "tone")
    #expect(result.mediaId == "tone")
    for e in result.events {
        #expect(e.start >= 0 && e.end > e.start && e.end <= 3.6 && e.duration >= 0.5, "\(e)")
        #expect(e.confidence >= 0.5 && e.confidence <= 1)
    }
}
