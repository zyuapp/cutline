import AVFoundation
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// A short gray H.264 movie.
private func writeMovie(_ w: Int, _ h: Int, frames: Int = 6) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
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
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetBytesPerRow(buffer) * h)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
}

/// Files the built composition's picture reads.
private func pictureSources(_ built: BuiltTimeline) -> Set<String> {
    Set(built.composition.tracks(withMediaType: .video).flatMap(\.segments).compactMap { $0.sourceURL?.lastPathComponent })
}

@Test func proxySettingChangesThePreviewBuildButNeverExport() async throws {
    let url = try await writeMovie(320, 180)
    defer { try? FileManager.default.removeItem(at: url) }
    var media = MediaAsset(id: "m", path: url.path, name: "m", duration: 0.25, width: 320, height: 180, fps: 24, hasVideo: true, hasAudio: false)
    var p = Project(name: "Proxy", canvas: Canvas(width: 320, height: 180, fps: 24))
    p.playback = Playback(mode: .auto, proxySize: .quarter)
    #expect(!p.wantsProxy(media, heavy: false), "light footage gets no proxy in auto")
    media.proxy = .always
    #expect(p.wantsProxy(media, heavy: false))
    p.media = [media]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 0.25)]
    let made = try await Proxies.transcode(media, quality: .quarter)
    defer { try? FileManager.default.removeItem(at: made.url) }
    #expect(made.size == CGSize(width: 80, height: 46) || made.size == CGSize(width: 80, height: 44), "\(made.size)")

    let preview = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary(proxyQuality: .half))
    #expect(pictureSources(preview).contains(made.url.lastPathComponent), "preview plays the proxy at the project's size")
    let export = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
    #expect(pictureSources(export).contains(url.lastPathComponent) && !pictureSources(export).contains(made.url.lastPathComponent), "export reads the original")

    var original = p
    original.playback = Playback(mode: .original, proxySize: .quarter)
    let plain = try await TimelineBuilder.build(original, transcripts: [:], library: MediaLibrary(proxyQuality: .half))
    #expect(pictureSources(plain).contains(url.lastPathComponent), "playback original")
    var never = p
    never.media[0].proxy = .never
    #expect(pictureSources(try await TimelineBuilder.build(never, transcripts: [:], library: MediaLibrary(proxyQuality: .half))).contains(url.lastPathComponent), "proxy never")
    var half = p
    half.playback = Playback(mode: .auto, proxySize: .half)
    #expect(pictureSources(try await TimelineBuilder.build(half, transcripts: [:], library: MediaLibrary(proxyQuality: .half))).contains(url.lastPathComponent), "no proxy at the chosen size yet")
}

@Test func proxySizesFitTheirTargets() {
    #expect(Proxies.size(of: CGSize(width: 3840, height: 2160), quality: .sd) == CGSize(width: 1280, height: 720))
    #expect(Proxies.size(of: CGSize(width: 3840, height: 2160), quality: .hd) == CGSize(width: 1920, height: 1080))
    #expect(Proxies.Quality(.sd) == .sd && Proxies.Quality(.hd) == .hd)
    let p = try? JSONDecoder().decode(Playback.self, from: Data(#"{"mode":"proxy","proxySize":"720"}"#.utf8))
    #expect(p == Playback(mode: .proxy, proxySize: .sd))
}
