import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private func tempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// H.264 (or 10-bit HEVC) frames with a white bar whose position encodes the frame number and a red
/// square in the stored top-left corner, plus optional 16-bit PCM sine sound. CoreGraphics draws y-up.
private func writeClip(_ url: URL, width w: Int, height h: Int, fps: Int32, frames: Int, transform: CGAffineTransform = .identity, audio: Bool = false, hevc10: Bool = false) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    var compression: [String: Any] = [AVVideoAverageBitRateKey: min(w * h * 8, 150_000_000), AVVideoMaxKeyFrameIntervalKey: 15]
    if hevc10 { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: hevc10 ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: compression,
    ])
    video.expectsMediaDataInRealTime = false
    video.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(video)
    var sound: AVAssetWriterInput?
    if audio {
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        a.expectsMediaDataInRealTime = false
        writer.add(a)
        sound = a
    }
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var frame = 0
    let group = DispatchGroup()
    drive(video, group) {
        guard frame < frames else { return false }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let buffer = pb else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(gray: 0.15, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: h - h / 4, width: w / 4, height: h / 4))
        ctx.setFillColor(gray: 1, alpha: 1)
        let bar = max(2, w / 24)
        ctx.fill(CGRect(x: (frame * bar) % max(1, w - bar), y: h / 4, width: bar, height: h / 2))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        defer { frame += 1 }
        return adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }
    if let sound {
        let total = Int(Double(frames) / Double(fps) * 48_000)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var afd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &afd)
        var pos = 0
        drive(sound, group) {
            guard pos < total, let afd else { return false }
            let n = min(4_800, total - pos)
            var pcm = [Int16](repeating: 0, count: n * 2)
            for i in 0..<n {
                let v = Int16(8_000 * sin(2 * Double.pi * 440 * Double(pos + i) / 48_000))
                pcm[2 * i] = v
                pcm[2 * i + 1] = v
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: n * 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 4) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: afd, sampleCount: n, presentationTimeStamp: CMTime(value: CMTimeValue(pos), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample)
            pos += n
            return sound.append(sample!)
        }
    }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }
    #expect(frame == frames)
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}

/// Calls `step` whenever the input wants data until it returns false, then finishes the input and leaves `group`.
private func drive(_ input: AVAssetWriterInput, _ group: DispatchGroup, _ step: @escaping () -> Bool) {
    let queue = DispatchQueue(label: "cutline.test.\(input.mediaType.rawValue)")
    var finished = false
    group.enter()
    input.requestMediaDataWhenReady(on: queue) {
        while !finished, input.isReadyForMoreMediaData {
            if !step() {
                finished = true
                input.markAsFinished()
                group.leave()
            }
        }
    }
}

/// Presentation times of every video sample, without decoding.
private func sampleTimes(_ url: URL) async throws -> [Seconds] {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(out)
    #expect(reader.startReading())
    return try await runBlocking { _ in
        var times: [Seconds] = []
        while let s = out.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(s) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(s).seconds) }
        }
        return times.sorted()
    }
}

/// Luma of an image drawn into a small grid, top-left first.
private func thumb(_ img: CGImage, _ w: Int = 32, _ h: Int = 18) -> [Double] {
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (0..<(w * h)).map { (i: Int) -> Double in
        let r = Double(bytes[4 * i]), g = Double(bytes[4 * i + 1]), b = Double(bytes[4 * i + 2])
        return 0.3 * r + 0.59 * g + 0.11 * b
    }
}

private func meanDiff(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(max(a.count, 1))
}

private func upright(_ url: URL, at t: Seconds) async throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 60_000)).image
}

@Test func proxiesKeepTimingOrientationAndSound() async throws {
    let dir = try tempDir("proxy")
    defer { try? FileManager.default.removeItem(at: dir) }
    // Portrait phone footage: 640×360 stored, rotated 90° clockwise for display.
    let rotated = dir.appendingPathComponent("rotated.mov")
    try await writeClip(rotated, width: 640, height: 360, fps: 30, frames: 45, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0), audio: true)
    let fast = dir.appendingPathComponent("fast.mov")
    try await writeClip(fast, width: 320, height: 180, fps: 120, frames: 120)

    for (url, quality, display) in [(rotated, Proxies.Quality.half, CGSize(width: 180, height: 320)), (fast, .quarter, CGSize(width: 80, height: 44))] {
        let media = try await MediaProbe.probe(url, id: url.lastPathComponent)
        #expect(Proxies.cached(media, quality: quality) == nil)
        let made = try await Proxies.transcode(media, quality: quality)
        defer { try? FileManager.default.removeItem(at: made.url) }
        #expect(made.realtimeFactor > 0)
        #expect(Proxies.cached(media, quality: quality) == made.url)
        #expect(try await Proxies.make(media, quality: quality) == made.url)

        let proxy = try await MediaProbe.probe(made.url, id: "p")
        #expect(abs(proxy.duration - media.duration) < 1e-3, "\(proxy.duration) vs \(media.duration)")
        #expect(CGSize(width: proxy.width, height: proxy.height) == display, "\(proxy.width)×\(proxy.height)")
        #expect(proxy.hasAudio == media.hasAudio)
        #expect(abs(proxy.fps - media.fps) < 0.5)
        let a = try await sampleTimes(url), b = try await sampleTimes(made.url)
        #expect(a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }, "\(a.count) vs \(b.count) frames")

        let track = try #require(try await AVURLAsset(url: made.url).loadTracks(withMediaType: .video).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_AppleProRes422Proxy)
        if media.hasAudio {
            let at = try #require(try await AVURLAsset(url: made.url).loadTracks(withMediaType: .audio).first)
            let src = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
            #expect(abs(try await at.load(.timeRange).duration.seconds - (try await src.load(.timeRange).duration.seconds)) < 1e-3)
        }
        // Same upright picture: red corner and bar land in the same place.
        for t in [0.0, 0.3] {
            let d = meanDiff(thumb(try await upright(url, at: t)), thumb(try await upright(made.url, at: t)))
            #expect(d < 12, "\(url.lastPathComponent) at \(t): \(d)")
        }
    }
    #expect(Proxies.shouldProxy(MediaAsset(id: "x", path: "/x", name: "X", duration: 1, width: 3840, height: 2160, fps: 30, hasVideo: true, hasAudio: false)))
    #expect(Proxies.shouldProxy(MediaAsset(id: "x", path: "/x", name: "X", duration: 1, width: 1920, height: 1080, fps: 240, hasVideo: true, hasAudio: false)))
    #expect(!Proxies.shouldProxy(MediaAsset(id: "x", path: "/x", name: "X", duration: 1, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)))
}

/// Proxy speed on heavy footage; run with CUTLINE_BENCH=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_BENCH"] != nil))
func proxyBenchmark() async throws {
    let dir = try tempDir("proxy-bench")
    defer { try? FileManager.default.removeItem(at: dir) }
    let uhd = dir.appendingPathComponent("uhd-hevc10.mov"), slow = dir.appendingPathComponent("hd-240.mov")
    try await writeClip(uhd, width: 3840, height: 2160, fps: 30, frames: 150, audio: true, hevc10: true)
    try await writeClip(slow, width: 1920, height: 1080, fps: 240, frames: 1200, hevc10: true)
    for url in [uhd, slow] {
        let media = try await MediaProbe.probe(url, id: url.lastPathComponent)
        let format = await Proxies.format(of: media)
        #expect(format.map { Proxies.bitDepth($0) } == 10)
        #expect(Proxies.shouldProxy(media, format: format))
        for quality in Proxies.Quality.allCases {
            let made = try await Proxies.transcode(media, quality: quality)
            defer { try? FileManager.default.removeItem(at: made.url) }
            #expect(try await sampleTimes(made.url).count == (try await sampleTimes(url)).count)
            print("BENCH \(url.lastPathComponent) \(quality.rawValue) \(Int(made.size.width))×\(Int(made.size.height)): \(String(format: "%.2f", made.elapsed)) s for \(String(format: "%.1f", media.duration)) s, \(String(format: "%.1f", made.realtimeFactor))x realtime")
        }
    }
}

/// A 320×180 project cutting two pieces out of a 3 s clip with sound.
private func deliveryTimeline(_ dir: URL) async throws -> (Project, BuiltTimeline) {
    let url = dir.appendingPathComponent("source.mov")
    try await writeClip(url, width: 320, height: 180, fps: 30, frames: 90, audio: true)
    var p = Project(name: "Delivery", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(url, id: "m")]
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "m", start: 0, duration: 1, sourceIn: 0.5),
        Clip(id: "c2", kind: .media, mediaId: "m", start: 1, duration: 1, sourceIn: 2),
    ]
    return (p, try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary()))
}

@Test func deliveryWritesStillsSequencesAudioAndGIF() async throws {
    let dir = try tempDir("delivery")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (_, built) = try await deliveryTimeline(dir)

    let stills = try await Delivery.stills(built, times: [0, 0.5, 1.5], to: dir.appendingPathComponent("stills"), format: .png)
    #expect(stills.map(\.lastPathComponent) == ["still_000000.png", "still_000015.png", "still_000045.png"])
    for url in stills {
        let img = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(img.width == 320 && img.height == 180)
    }
    let small = try await Delivery.stills(built, times: [1], to: dir.appendingPathComponent("stills"), format: .jpeg, size: CGSize(width: 160, height: 90))
    let jpeg = try #require(CGImageSourceCreateWithURL(small[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(jpeg.width == 160 && jpeg.height == 90)
    let tiff = try await Delivery.stills(built, times: [1], to: dir.appendingPathComponent("stills"), format: .tiff16)
    let deep = try #require(CGImageSourceCreateWithURL(tiff[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(deep.bitsPerComponent == 16)
    _ = try await Delivery.stills(built, times: [1], to: dir.appendingPathComponent("stills"), format: .heic)

    let seqDir = dir.appendingPathComponent("seq")
    let count = try await Delivery.imageSequence(built, range: TimeRange(0.5, 1.5), to: seqDir, format: .png)
    let files = try FileManager.default.contentsOfDirectory(atPath: seqDir.path).sorted()
    #expect(count == 30 && files.count == 30, "\(count) frames, \(files.count) files")
    #expect(files.first == "frame_000001.png" && files.last == "frame_000030.png")
    // The sequence's frame 16 is timeline 1.0 s, the first frame of c2.
    let frame16 = try #require(CGImageSourceCreateWithURL(seqDir.appendingPathComponent("frame_000016.png") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    let still = try #require(CGImageSourceCreateWithURL(small[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    let frame17 = try #require(CGImageSourceCreateWithURL(seqDir.appendingPathComponent("frame_000017.png") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(frame16.width == 320 && meanDiff(thumb(frame16), thumb(still)) < 3)
    #expect(meanDiff(thumb(frame17), thumb(still)) > 4)

    for format in Delivery.AudioFormat.allCases {
        let url = dir.appendingPathComponent("mix-\(format.rawValue).\(format.fileExtension)")
        try await Delivery.audio(built, to: url, format: format)
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        let tolerance = format == .aac256 ? 0.05 : 1e-3
        #expect(abs(seconds - 2) < tolerance, "\(format.rawValue): \(seconds) s")
        #expect(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 2)
        let settings = file.fileFormat.settings
        switch format {
        case .wav24, .aiff24: #expect(settings[AVLinearPCMBitDepthKey] as? Int == 24 && settings[AVLinearPCMIsFloatKey] as? Bool == false)
        case .wav32f: #expect(settings[AVLinearPCMBitDepthKey] as? Int == 32 && settings[AVLinearPCMIsFloatKey] as? Bool == true)
        case .aac256: #expect(settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        case .alac: #expect(settings[AVFormatIDKey] as? UInt32 == kAudioFormatAppleLossless)
        }
        if format == .wav24 {
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buf)
            let peak = (0..<Int(buf.frameLength)).reduce(Float(0)) { max($0, abs(buf.floatChannelData![0][$1])) }
            #expect(peak > 0.1, "peak \(peak)")
        }
    }
    let part = dir.appendingPathComponent("part.wav")
    try await Delivery.audio(built, range: TimeRange(0.25, 1.25), to: part, format: .wav24)
    let partFile = try AVAudioFile(forReading: part)
    #expect(abs(Double(partFile.length) / 48_000 - 1) < 1e-3)

    let gif = dir.appendingPathComponent("social.gif")
    try await Delivery.gif(built, range: TimeRange(0, 1), to: gif, fps: 10, width: 160)
    let src = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
    #expect(CGImageSourceGetCount(src) == 10)
    let first = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(first.width == 160 && first.height == 90)
}

@Test func consolidateTrimKeepsTimelinePixels() async throws {
    let dir = try tempDir("consolidate")
    defer { try? FileManager.default.removeItem(at: dir) }
    let (p, built) = try await deliveryTimeline(dir)
    let times = [0.0, 0.5, 0.9, 1.0, 1.6]
    let before = try await Frames.timeline(built, times: times, maxSize: CGSize(width: 320, height: 180))

    let (trimmed, bytes) = try await Consolidate.collect(p, to: dir.appendingPathComponent("trimmed"), trim: true, handles: 0.1)
    #expect(bytes > 0)
    #expect(trimmed.media.map(\.id) == ["m_t1", "m_t2"])
    let c2 = try #require(trimmed.clip("c2"))
    #expect(c2.mediaId == "m_t2" && abs(c2.sourceIn - 0.1) < 1e-9)
    #expect(trimmed.media.allSatisfy { $0.path.hasPrefix(dir.appendingPathComponent("trimmed").path) && $0.duration < 1.5 })
    try trimmed.validate()

    let rebuilt = try await TimelineBuilder.build(trimmed, transcripts: [:], library: MediaLibrary())
    let after = try await Frames.timeline(rebuilt, times: times, maxSize: CGSize(width: 320, height: 180))
    for (a, b) in zip(before, after) {
        let d = meanDiff(thumb(a.image, 64, 36), thumb(b.image, 64, 36))
        #expect(d < 2, "frame at \(a.time): \(d)")
    }
    // Neighbouring frames differ, so the comparison catches a copy off by one frame.
    let next = try await Frames.timeline(built, times: [0.5 + 1.0 / 30], maxSize: CGSize(width: 320, height: 180))
    #expect(meanDiff(thumb(next[0].image, 64, 36), thumb(before[1].image, 64, 36)) > 2)

    let (whole, wholeBytes) = try await Consolidate.collect(p, to: dir.appendingPathComponent("whole"), trim: false)
    #expect(whole.media.map(\.id) == ["m"] && whole.clip("c2")?.sourceIn == 2)
    #expect(wholeBytes == (try FileManager.default.attributesOfItem(atPath: p.media[0].path)[.size] as? Int64))
}
