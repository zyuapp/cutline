import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg/ffprobe not found (CUTLINE_FFMPEG, PATH, /opt/homebrew/bin, /usr/local/bin); brew install ffmpeg to run"

private func encoders() async throws -> FFmpeg.Encoders {
    try await FFmpeg.encoders(tools!.ffmpeg, pixelFormatsOf: ["libx264", "libsvtav1", "libaom-av1"])
}

private func tempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A 2 s ProRes source with stereo sound, played at 1920×1080 25 fps from 10:00:00:00.
private func deliveryTimeline(_ dir: URL) async throws -> BuiltTimeline {
    let src = dir.appendingPathComponent("src.mov")
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-f", "lavfi", "-i", "sine=f=1000:sample_rate=48000", "-t", "2",
                                         "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-ac", "2", src.path])
    var p = Project(name: "Deliver", canvas: Canvas(width: 1920, height: 1080, fps: 25, timecodeStart: "10:00:00:00"))
    p.media = [try await MediaProbe.probe(src, id: "src")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "src", start: 0, duration: 2)]
    return try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
}

@Test(.enabled(if: tools?.ffprobe != nil, skip)) func tenBitH264AndAVCIntraMastersProbeAsDelivered() async throws {
    let caps = try await encoders()
    guard case .success = FFmpegDelivery.encoder(.h264_422_10bit, caps, tool: tools!.ffmpeg.path) else {
        Issue.record("this ffmpeg has no 10-bit libx264; skipping the 10-bit H.264 checks")
        return
    }
    let dir = try tempDir("h264-10")
    defer { try? FileManager.default.removeItem(at: dir) }
    let built = try await deliveryTimeline(dir)
    let probe = { (u: URL) in try await FFmpeg.probe(u, ffprobe: tools!.ffprobe!) }

    let high10 = dir.appendingPathComponent("h10.mov")
    try await Exporter.export(built, to: high10, options: ExportOptions(preset: .h264_10bit, range: TimeRange(0, 1)))
    let h = try await probe(high10)
    #expect(h.video?.codec == "h264" && h.video?.profile == "High 10" && h.video?.pixelFormat == "yuv420p10le", "\(String(describing: h.video))")
    #expect(h.video?.colorPrimaries == "bt709" && h.video?.colorTransfer == "bt709")
    #expect(h.timecode == "10:00:00:00")
    #expect(h.audio.first?.codec == "pcm_s24le")

    let longGOP = dir.appendingPathComponent("xavc-l.mxf")
    try await Exporter.export(built, to: longGOP, options: ExportOptions(preset: .h264_422_10bit))
    let l = try await probe(longGOP)
    #expect(l.formatName == "mxf" && l.video?.profile == "High 4:2:2" && l.video?.pixelFormat == "yuv422p10le", "\(String(describing: l.video))")
    #expect(l.timecode == "10:00:00:00")
    let mbps = Double((try FileManager.default.attributesOfItem(atPath: longGOP.path)[.size] as? Int) ?? 0) * 8 / l.duration / 1e6
    #expect(mbps > 1 && mbps < 60, "XAVC Long GOP picture at up to 50 Mb/s: \(mbps)")

    for preset in [ExportPreset.avc_intra_class100, .xavc_intra_class100] {
        let url = dir.appendingPathComponent("\(preset.rawValue).mxf")
        var options = ExportOptions(preset: preset, range: TimeRange(0, 1))
        options.interlaced = preset == .avc_intra_class100 ? .tff : nil
        try await Exporter.export(built, to: url, options: options)
        let a = try await probe(url)
        #expect(a.formatName == "mxf" && a.video?.profile == "High 4:2:2 Intra" && a.video?.pixelFormat == "yuv422p10le", "\(preset): \(String(describing: a.video))")
        #expect(a.video?.width == 1920 && a.video?.height == 1080)
        #expect(a.timecode == "10:00:00:00")
        #expect(a.audio.count == 2 && a.audio.allSatisfy { $0.channels == 1 && $0.codec == "pcm_s24le" })
        if preset == .avc_intra_class100 { #expect(a.fieldOrder == .tff, "\(String(describing: a.video?.fieldOrderName))") }
        // Class 100 at 1080/25 is about 110 Mb/s of fixed-size frames.
        let rate = Double((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) * 8 / a.duration / 1e6
        #expect(rate > 95 && rate < 130, "\(preset) \(rate) Mb/s")
    }
}

@Test(.enabled(if: tools?.ffprobe != nil, skip)) func av1AndHEVC422MastersProbeAsDelivered() async throws {
    let dir = try tempDir("av1")
    defer { try? FileManager.default.removeItem(at: dir) }
    let built = try await deliveryTimeline(dir)
    let caps = try await encoders()
    if case .success = FFmpegDelivery.encoder(.av1, caps, tool: tools!.ffmpeg.path) {
        let url = dir.appendingPathComponent("web.mp4")
        try await Exporter.export(built, to: url, options: ExportOptions(preset: .av1, range: TimeRange(0, 1)))
        let a = try await FFmpeg.probe(url, ffprobe: tools!.ffprobe!)
        #expect(a.video?.codec == "av1" && a.video?.profile == "Main" && a.video?.pixelFormat == "yuv420p10le", "\(String(describing: a.video))")
        #expect(a.video?.colorPrimaries == "bt709")
        #expect(a.timecode == "10:00:00:00")
        #expect(a.audio.first?.codec == "aac")
    } else {
        Issue.record("this ffmpeg has no 10-bit AV1 encoder; skipping the AV1 checks")
    }

    let hevc = dir.appendingPathComponent("mezz.mov")
    do {
        try await Exporter.export(built, to: hevc, options: ExportOptions(preset: .hevc_422_10bit, range: TimeRange(0, 1)))
    } catch {
        #expect(error.localizedDescription.contains("HEVC 4:2:2"), "\(error)")
        return
    }
    let h = try await FFmpeg.probe(hevc, ffprobe: tools!.ffprobe!)
    #expect(h.video?.codec == "hevc" && h.video?.profile == "Rext" && h.video?.pixelFormat == "yuv422p10le", "\(String(describing: h.video))")
    #expect(h.timecode == "10:00:00:00")
}

@Test func ffmpegPresetsExplainMissingEncodersAndWrongFormats() {
    let bare = FFmpeg.Encoders(names: ["mpeg2video", "dnxhd"])
    let eightBit = FFmpeg.Encoders(names: ["libx264"], pixelFormats: ["libx264": ["yuv420p", "yuv444p"]])
    func message(_ p: ExportPreset, _ e: FFmpeg.Encoders) -> String? {
        if case .failure(let error) = FFmpegDelivery.encoder(p, e, tool: "/x/ffmpeg") { return error.localizedDescription }
        return nil
    }
    #expect(message(.av1, bare)?.contains("SVT-AV1") == true)
    #expect(message(.h264_10bit, bare)?.contains("libx264") == true)
    #expect(message(.avc_intra_class100, eightBit)?.contains("8-bit") == true)
    #expect(message(.h264_10bit, FFmpeg.Encoders(names: ["libx264"], pixelFormats: ["libx264": ["yuv420p10le"]])) == nil)
    #expect(message(.av1, FFmpeg.Encoders(names: ["libaom-av1"])) == nil)
    #expect(message(.xdcam_hd422, bare) == nil)

    var p = Project(name: "Rates", canvas: Canvas(width: 1280, height: 720, fps: 25))
    #expect(FFmpegDelivery.check(p, preset: .avc_intra_class100, container: "mxf")?.contains("1920×1080") == true)
    p.canvas = Canvas(width: 1920, height: 1080, fps: 24)
    #expect(FFmpegDelivery.check(p, preset: .xavc_intra_class100, container: "mxf")?.contains("23.976") == true)
    p.canvas.fps = 50
    #expect(FFmpegDelivery.check(p, preset: .avc_intra_class100, container: "mxf") == nil)
    #expect(FFmpegDelivery.check(p, preset: .avc_intra_class100, container: "mxf", fields: .tff)?.contains("25 or 29.97") == true)
    #expect(FFmpegDelivery.check(p, preset: .av1, container: "mov")?.contains("MP4") == true)
    #expect(FFmpegDelivery.check(p, preset: .av1, container: "mp4", fields: .tff)?.contains("progressive") == true)
    #expect(FFmpegDelivery.check(p, preset: .h264_10bit, container: "mxf") != nil)
    p.canvas.colorSpace = .rec2020_pq
    #expect(FFmpegDelivery.check(p, preset: .avc_intra_class100, container: "mxf")?.contains("Rec. 709") == true)
    #expect(FFmpegDelivery.check(p, preset: .xavc_intra_class100, container: "mxf") == nil)
    #expect(ExportPreset.unavailable("imf")?.contains("audio-only MXF") == true)
    #expect(ExportPreset.unavailable("xavc_l")?.contains("h264_422_10bit") == true)
    #expect(ExportPreset.unavailable("h264_10bit", ffmpeg: false)?.contains("needs ffmpeg") == true)
}
