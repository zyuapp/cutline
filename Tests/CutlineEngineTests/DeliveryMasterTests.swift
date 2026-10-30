import AVFoundation
import CoreMedia
import CutlineCore
@testable import CutlineEngine
import Foundation
import Testing

private func solidTimeline(fps: Double, timecodeStart: String? = nil, seconds: Seconds = 2) async throws -> BuiltTimeline {
    var p = Project(name: "Master", canvas: Canvas(width: 320, height: 180, fps: fps, timecodeStart: timecodeStart))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: seconds, color: RGBA(r: 0.2, g: 0.4, b: 0.8))]
    return try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
}

private func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cutline-master-\(UUID().uuidString).\(ext)")
}

@Test(arguments: [ExportPreset.prores_hq, .h264])
func exportWritesTimecodeTrackAtProjectStart(_ preset: ExportPreset) async throws {
    let built = try await solidTimeline(fps: 25, timecodeStart: "10:00:00:00")
    let url = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await Exporter.export(built, to: url, options: ExportOptions(preset: preset))
    let asset = AVURLAsset(url: url)
    #expect(try await asset.loadTracks(withMediaType: .timecode).count == 1)
    #expect(try await TimecodeTrack.read(url) == "10:00:00:00")
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let associated = try await video.loadAssociatedTracks(ofType: .timecode)
    #expect(associated.count == 1)
}

@Test func timecodeTrackIsDropFrameAt2997AndFollowsRangeStart() async throws {
    let built = try await solidTimeline(fps: 30000.0 / 1001, seconds: 3)
    let url = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await Exporter.export(built, to: url, options: ExportOptions(preset: .prores_proxy, range: TimeRange(1, 2)))
    #expect(try await TimecodeTrack.read(url) == "01:00:01;00")
    // Re-importing the export reads the same timecode back.
    let m = try await MediaProbe.probe(url, id: "export")
    #expect(m.timecodeString() == "01:00:01;00", "\(String(describing: m.timecodeLabel)) \(String(describing: m.timecodeStart)) \(m.fps)")
    #expect(abs((m.timecodeStart ?? 0) - 107_922.0 * 1001 / 30000) < 1e-6)
}

@Test func leaderPrependsBarsToneSlateAndShiftsTimecode() async throws {
    let built = try await solidTimeline(fps: 25)
    let url = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let leader = Leader(barsSeconds: 2, slateSeconds: 1, blackSeconds: 2, title: "Test", slate: [.init("Version", "v1")])
    try await Exporter.export(built, to: url, options: ExportOptions(preset: .prores, leader: leader))
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 7) < 0.05, "\(duration)")
    #expect(try await TimecodeTrack.read(url) == "00:59:55:00")

    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let bars = try await gen.image(at: CMTime(value: 1, timescale: 1)).image
    // 75% yellow is the second of seven bars, near the top.
    let yellow = try #require(pixel(bars, x: 320 * 3 / 14, y: 20))
    #expect(yellow.r > 160 && yellow.r < 220 && yellow.g > 160 && yellow.g < 220 && yellow.b < 40, "\(yellow)")
    let blue = try #require(pixel(bars, x: 320 * 13 / 14, y: 20))
    #expect(blue.r < 40 && blue.g < 40 && blue.b > 160, "\(blue)")
    let program = try await gen.image(at: CMTime(value: 6, timescale: 1)).image
    let p = try #require(pixel(program, x: 160, y: 90))
    #expect(p.b > p.r + 60, "\(p)")

    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000])
    reader.add(out)
    reader.startReading()
    var samples: [Float] = []
    while let s = out.copyNextSampleBuffer(), samples.count < 48_000 * 2 * 6 {
        guard let block = CMSampleBufferGetDataBuffer(s) else { continue }
        var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        samples += chunk
    }
    func rms(_ from: Seconds, _ to: Seconds) -> Double {
        let a = Int(from * 48_000) * 2, b = min(samples.count, Int(to * 48_000) * 2)
        guard b > a else { return 0 }
        return sqrt(samples[a..<b].map { Double($0 * $0) }.reduce(0, +) / Double(b - a))
    }
    let toneDb = 20 * log10(rms(0.5, 1.5) * sqrt(2))
    #expect(abs(toneDb - -20) < 0.5, "\(toneDb)")
    #expect(rms(2.2, 2.8) < 1e-4)
    #expect(rms(3.0, 3.04) > 0.05, "2-pop two seconds before the program")
    #expect(rms(3.2, 4.8) < 1e-4)
}

@Test func barsHaveSMPTELayout() throws {
    let img = try #require(Leader.bars(width: 700, height: 400))
    let gray = try #require(pixel(img, x: 50, y: 10))
    #expect(gray.r == 191 && gray.g == 191 && gray.b == 191)
    let white = try #require(pixel(img, x: 175, y: 390))
    #expect(white.r == 255 && white.g == 255 && white.b == 255)
}

@Test func mp4HasNoTimecodeTrack() async throws {
    let built = try await solidTimeline(fps: 25)
    let url = tempURL("mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try await Exporter.export(built, to: url, options: ExportOptions(preset: .hevc))
    #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .timecode).isEmpty)
}

@Test func unavailableCodecsExplainThemselves() {
    #expect(ExportPreset.unavailable("dnxhr_hqx", ffmpeg: false)?.contains("no system encoder") == true)
    #expect(ExportPreset.unavailable("prores_hq") == nil)
    #expect(ExportPreset.allCases.filter(\.isProRes).count == 6)
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
    var data = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(data[0]), Int(data[1]), Int(data[2]))
}

@Test(arguments: [(ExportPreset.prores_lt, "apcs"), (.prores_proxy, "apco"), (.prores_hq, "apch"), (.prores4444xq, "ap4x"), (.hevc_10bit, "hvc1")])
func presetsWriteTheirCodec(_ preset: ExportPreset, _ fourCC: String) async throws {
    let built = try await solidTimeline(fps: 24, seconds: 0.5)
    let url = tempURL(preset.fileExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    try await Exporter.export(built, to: url, options: ExportOptions(preset: preset))
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    let fd = try #require(try await track.load(.formatDescriptions).first)
    let code = CMFormatDescriptionGetMediaSubType(fd)
    let name = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii)
    #expect(name == fourCC)
}
