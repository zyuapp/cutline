import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg/ffprobe not found; brew install ffmpeg to run"

/// A 2 s clip with sound, then a 1 s clip without: the timeline's sound ends a second before its picture.
private func shortSoundTimeline(_ dir: URL, width: Int = 1920, height: Int = 1080) async throws -> BuiltTimeline {
    let sound = dir.appendingPathComponent("sound.mov"), silent = dir.appendingPathComponent("silent.mov")
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000", "-t", "2",
                                         "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-ac", "2", sound.path])
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "smptebars=size=320x180:rate=25", "-t", "1",
                                         "-c:v", "prores_ks", "-profile:v", "0", silent.path])
    var p = Project(name: "Short sound", canvas: Canvas(width: width, height: height, fps: 25))
    p.media = [try await MediaProbe.probe(sound, id: "sound"), try await MediaProbe.probe(silent, id: "silent")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "sound", start: 0, duration: 2), Clip(id: "c2", kind: .media, mediaId: "silent", start: 2, duration: 1)]
    return try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-reliability-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test(.enabled(if: tools?.ffprobe != nil, skip)) func mastersRunTheirWholeRangeWhenTheSoundEndsEarly() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let built = try await shortSoundTimeline(dir)
    let probe = { (u: URL) in try await FFmpeg.probe(u, ffprobe: tools!.ffprobe!) }

    let xdcam = dir.appendingPathComponent("xdcam.mxf")
    try await Exporter.export(built, to: xdcam, options: ExportOptions(preset: .xdcam_hd422))
    let x = try await probe(xdcam)
    #expect(abs((x.video?.duration ?? 0) - 3) < 0.05, "picture \(String(describing: x.video?.duration))")
    #expect(x.audio.count == 8 && x.audio.allSatisfy { abs(($0.duration ?? 0) - 3) < 0.05 }, "\(x.audio.map(\.duration))")

    let tail = dir.appendingPathComponent("tail.mxf")
    try await Exporter.export(built, to: tail, options: ExportOptions(preset: .xdcam_hd422, range: TimeRange(2, 3)))
    let t = try await probe(tail)
    #expect(abs((t.video?.duration ?? 0) - 1) < 0.05 && t.audio.allSatisfy { abs(($0.duration ?? 0) - 1) < 0.05 }, "\(String(describing: t.video?.duration)) \(t.audio.map(\.duration))")

    let dnx = dir.appendingPathComponent("dnx.mxf")
    try await Exporter.export(built, to: dnx, options: ExportOptions(preset: .dnxhr_lb))
    let d = try await probe(dnx)
    #expect(abs((d.video?.duration ?? 0) - 3) < 0.05 && d.audio.count == 2 && d.audio.allSatisfy { abs(($0.duration ?? 0) - 3) < 0.05 }, "\(d.audio.map(\.duration))")

    for (preset, ext) in [(ExportPreset.prores, "mov"), (.hevc, "mp4")] {
        let url = dir.appendingPathComponent("tail-\(preset.rawValue).\(ext)")
        try await Exporter.export(built, to: url, options: ExportOptions(preset: preset, range: TimeRange(2, 3)))
        let m = try #require(try await ExportVerifier.measure(url))
        #expect(m.audio.count == 1 && m.audio[0].channels == 2 && abs(m.audio[0].seconds - 1) < 0.05, "\(preset): \(m.audio)")
        #expect(abs((m.videoSeconds ?? 0) - 1) < 0.05)
    }
}

@Test func verifierFlagsShortPictureAndMissingSound() {
    let e = ExportExpectation(duration: 34, fps: 25, audioChannels: 8)
    #expect(e.frames == 850)
    let ok = ExportVerifier.Measured(videoSeconds: 34, audio: Array(repeating: (1, 34.0), count: 8))
    #expect(ExportVerifier.problems(ok, e).isEmpty)
    let truncated = ExportVerifier.Measured(videoSeconds: 32, audio: Array(repeating: (1, 32.0), count: 8))
    let found = ExportVerifier.problems(truncated, e)
    #expect(found.contains { $0.contains("800 frames") } && found.contains { $0.contains("ends at 32.00s") }, "\(found)")
    let silent = ExportVerifier.Measured(videoSeconds: 2, audio: [])
    #expect(ExportVerifier.problems(silent, ExportExpectation(duration: 2, fps: 25, audioChannels: 2)).contains { $0.contains("no audio track") })
    let short = ExportVerifier.Measured(videoSeconds: 2, audio: [(2, 0.1)])
    #expect(ExportVerifier.problems(short, ExportExpectation(duration: 2, fps: 25, audioChannels: 2)).contains { $0.contains("before the picture") })
}

@Test(.enabled(if: tools?.ffprobe != nil, skip)) func fittedTimelineLetterboxesIntoTheDeliveryFrame() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let built = try await shortSoundTimeline(dir, width: 862, height: 360).fitted(width: 1920, height: 1080)
    let url = dir.appendingPathComponent("boxed.mov")
    try await Exporter.export(built, to: url, options: ExportOptions(preset: .prores, range: TimeRange(0, 1)))
    let info = try await FFmpeg.probe(url, ffprobe: tools!.ffprobe!)
    #expect(info.video?.width == 1920 && info.video?.height == 1080)
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let (img, _) = try await gen.image(at: CMTime(value: 1, timescale: 2))
    var pixels = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
    let ctx = try #require(CGContext(data: &pixels, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    func luma(_ x: Int, _ y: Int) -> Int { let o = (y * 1920 + x) * 4; return (Int(pixels[o]) + Int(pixels[o + 1]) + Int(pixels[o + 2])) / 3 }
    // 862×360 scales to 1920×802: black bars of 139 rows above and below.
    let row = { (y: Int) in stride(from: 0, to: 1920, by: 16).map { luma($0, y) }.reduce(0, +) / 120 }
    #expect(row(40) < 25 && row(1040) < 25, "bars \(row(40)) \(row(1040))")
    #expect(row(540) > 40, "picture \(row(540))")
}
