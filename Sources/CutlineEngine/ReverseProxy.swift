import AVFoundation
import CoreImage
import CryptoKit
import CutlineCore
import Foundation

/// Backwards copies of source ranges, so reversed clips play through AVComposition.
/// Proxy time 0 is the end of the range; picture is upright high-bitrate H.264, sound reversed PCM.
public enum ReverseProxy {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/reverse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        WriterWait.sweepTemporaries(in: dir)
        return dir
    }()
    static let lock = NSLock()
    nonisolated(unsafe) static var inFlight: [String: Task<URL, Error>] = [:]

    public static func url(for media: MediaAsset, range: TimeRange, maxSize: CGSize) async throws -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: media.path)
        let stamp = "\(media.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(fmt(range.start))|\(fmt(range.end))|\(Int(maxSize.width))x\(Int(maxSize.height))|v2"
        let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let url = directory.appendingPathComponent("\(key).mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let task = lock.withLock { () -> Task<URL, Error> in
            if let t = inFlight[String(key)] { return t }
            let t = Task<URL, Error> {
                let tmp = directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
                do {
                    try await write(media, range: range, maxSize: maxSize, to: tmp)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    throw error
                }
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
                return url
            }
            inFlight[String(key)] = t
            return t
        }
        defer { lock.withLock { _ = inFlight.removeValue(forKey: String(key)) } }
        return try await task.value
    }

    static func write(_ media: MediaAsset, range: TimeRange, maxSize: CGSize, to url: URL) async throws {
        let asset = AVURLAsset(url: media.url)
        let fps = min(60, max(24, media.fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = maxSize
        let count = max(1, Int((range.duration * fps).rounded()))
        let first = try await gen.image(at: CMTime(seconds: range.start, preferredTimescale: 60000)).image
        let w = first.width / 2 * 2, h = first.height / 2 * 2

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(w * h) * fps * 0.3), AVVideoMaxKeyFrameIntervalKey: 10, AVVideoAllowFrameReorderingKey: false],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(video)

        var audioInput: AVAssetWriterInput?
        var pcm: [Float] = []
        if media.hasAudio, let track = try await asset.loadTracks(withMediaType: .audio).first {
            pcm = try await runBlocking { _ in try readAudio(asset, track: track, range: range) }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write a reversed copy") }
        writer.startSession(atSourceTime: .zero)
        // Picture and sound are fed concurrently: the writer interleaves them and holds back whichever runs ahead.
        let soundInput = audioInput, samples = pcm
        do {
            async let pictures: Void = {
                let ctx = CIContext()
                for i in 0..<count {
                    let t = max(range.start, range.end - (Double(i) + 0.5) / fps)
                    let img = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 60000)).image
                    try await WriterWait.ready(video, writer, "The reversed copy of \(media.name)")
                    guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? EditError("Cannot allocate frames") }
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    guard let pb else { throw EditError("Cannot allocate a frame") }
                    ctx.render(CIImage(cgImage: img), to: pb)
                    guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps.rounded()))) else {
                        throw writer.error ?? EditError("Cannot write frame \(i) of the reversed copy")
                    }
                }
                video.markAsFinished()
            }()
            async let sound: Void = {
                guard let soundInput else { return }
                try await appendReversed(samples, to: soundInput, writer: writer, name: media.name)
            }()
            _ = try await (pictures, sound)
        } catch {
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Cannot finish the reversed copy") }
    }

    /// Appends interleaved stereo float PCM backwards, a second per sample buffer.
    static func appendReversed(_ pcm: [Float], to input: AVAssetWriterInput, writer: AVAssetWriter, name: String) async throws {
        let frames = pcm.count / 2
        var reversed = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            reversed[2 * f] = pcm[2 * (frames - 1 - f)]
            reversed[2 * f + 1] = pcm[2 * (frames - 1 - f) + 1]
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard let fd else { throw EditError("Cannot describe the reversed sound") }
        let chunk = 48_000
        var start = 0
        while start < frames {
            let n = min(chunk, frames - start)
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 8, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: n * 8, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw EditError("Cannot allocate the reversed sound") }
            reversed.withUnsafeBytes { raw in
                if let base = raw.baseAddress { _ = CMBlockBufferReplaceDataBytes(with: base + start * 8, blockBuffer: block, offsetIntoDestination: 0, dataLength: n * 8) }
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: n, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample else { throw EditError("Cannot make a reversed sound buffer") }
            try await WriterWait.ready(input, writer, "The reversed sound of \(name)")
            guard input.append(sample) else { throw writer.error ?? EditError("Cannot write the reversed sound") }
            start += n
        }
        input.markAsFinished()
    }

    static func readAudio(_ asset: AVAsset, track: AVAssetTrack, range: TimeRange) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 48_000), end: CMTime(seconds: range.end, preferredTimescale: 48_000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read audio") }
        var samples: [Float] = []
        while let buf = out.nextSample(), let block = CMSampleBufferGetDataBuffer(buf) {
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }
}
