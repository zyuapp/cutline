import AVFoundation
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// `seconds` of 160×90 H.264 at 24 fps with a stereo 440 Hz tone, both tracks fed as the writer asks.
private func movieWithSound(_ url: URL, seconds: Int) async throws {
    let w = 160, h = 90, fps: Int32 = 24
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    sound.expectsMediaDataInRealTime = false
    writer.add(video)
    writer.add(sound)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    var afd: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &afd)
    let frames = seconds * Int(fps), samples = seconds * 48_000
    var frame = 0, pos = 0
    while frame < frames || pos < samples {
        if frame < frames, video.isReadyForMoreMediaData {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buffer = try #require(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 2 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
            frame += 1
            if frame == frames { video.markAsFinished() }
        } else if pos < samples, sound.isReadyForMoreMediaData, let afd {
            let n = min(4_800, samples - pos)
            var pcm = [Int16](repeating: 0, count: n * 2)
            for i in 0..<n { pcm[2 * i] = Int16(8_000 * sin(2 * Double.pi * 440 * Double(pos + i) / 48_000)); pcm[2 * i + 1] = pcm[2 * i] }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: n * 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 4) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: afd, sampleCount: n, presentationTimeStamp: CMTime(value: CMTimeValue(pos), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample)
            #expect(sound.append(sample!))
            pos += n
            if pos == samples { sound.markAsFinished() }
        } else {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}

/// Runs `body`, failing the test instead of hanging when it takes longer than `seconds`.
private func within<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return nil }
        guard let first = try await group.next(), let value = first else {
            group.cancelAll()
            throw EditError("timed out after \(seconds)s")
        }
        group.cancelAll()
        return value
    }
}

@Test func reversedCopyWithSoundFinishes() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-reverse-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src.mov")
    try await movieWithSound(src, seconds: 6)
    let media = try await MediaProbe.probe(src, id: "src")
    #expect(media.hasAudio)
    let out = dir.appendingPathComponent("rev.mov")
    try await within(60) { try await ReverseProxy.write(media, range: TimeRange(1, 5), maxSize: CGSize(width: 160, height: 90), to: out) }
    let asset = AVURLAsset(url: out)
    let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let a = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    #expect(abs(try await v.load(.timeRange).duration.seconds - 4) < 0.1)
    #expect(abs(try await a.load(.timeRange).duration.seconds - 4) < 0.05)
}

@Test func writerWaitGivesUpOnAnInputThatNeverTakesMore() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-stall-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
    let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    sound.expectsMediaDataInRealTime = false
    writer.add(video)
    writer.add(sound)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    // Picture only, while the sound input waits: the writer holds the picture back to interleave.
    let started = Date()
    await #expect(throws: RenderStalled.self) {
        for i in 0..<10_000 {
            try await WriterWait.ready(video, writer, "test picture", limit: 1)
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { return }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24))
        }
    }
    #expect(Date().timeIntervalSince(started) < 240)
    #expect(writer.status == .cancelled)
}

@Test func stallWatchFailsEveryRegisteredPump() async throws {
    let tripped = LockedFlag()
    let watch = StallWatch("test", limit: 0.5) { tripped.set() }
    defer { watch.stop() }
    let started = Date()
    await #expect(throws: RenderStalled.self) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceContinuation(c)
            watch.register { once.resume(.failure($0)) }
        }
    }
    #expect(tripped.isSet && Date().timeIntervalSince(started) < 240)
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
