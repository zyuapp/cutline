import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg not found (CUTLINE_FFMPEG, PATH, /opt/homebrew/bin, /usr/local/bin); brew install ffmpeg to run"

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-ingest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func tone(_ url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
    buffer.frameLength = 24_000
    for i in 0..<24_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
    try file.write(from: buffer)
}

private func project(_ box: Toolbox, _ dir: URL, _ extra: [String: JSON] = [:]) async throws {
    var args: [String: JSON] = ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false]
    for (k, v) in extra { args[k] = v }
    let r = await box.call("project_create", .object(args))
    #expect(!r.isError, "\(r.plainText)")
}

@Test func aBadFileDoesNotStopTheGoodOnes() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try tone(dir.appendingPathComponent("CamL.wav"))
    try Data(repeating: 7, count: 4096).write(to: dir.appendingPathComponent("broken.mov"))
    let box = Toolbox()
    try await project(box, dir)
    let r = await box.call("media_import", ["paths": [.string(dir.appendingPathComponent("CamL.wav").path), .string(dir.appendingPathComponent("broken.mov").path), "/nonexistent/x.mov"], "analyze": false])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("CamL.wav → caml:"), "\(r.plainText)")
    #expect(r.plainText.contains("Not imported (2)"), "\(r.plainText)")
    #expect(r.plainText.contains("broken.mov: "), "\(r.plainText)")
    #expect(r.plainText.contains("/nonexistent/x.mov: not found"), "\(r.plainText)")
    #expect(try box.session.project().media.map(\.id) == ["caml"])

    let all = await box.call("media_import", ["paths": [.string(dir.appendingPathComponent("broken.mov").path)], "analyze": false])
    #expect(all.isError && all.plainText.contains("broken.mov"), "\(all.plainText)")
}

@Test(.enabled(if: tools != nil, skip)) func mxfImportsPlaysAndConformsToTheOriginal() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mxf = dir.appendingPathComponent("A001_C002.mxf")
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=50", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000", "-t", "2",
                                          "-filter_complex", "[0:v]interlace=scan=tff,setfield=tff[v];[1:a]asplit=2[a0][a1]", "-map", "[v]", "-map", "[a0]", "-map", "[a1]",
                                          "-c:v", "mpeg2video", "-flags", "+ildct+ilme", "-b:v", "50M", "-pix_fmt", "yuv422p", "-c:a", "pcm_s24le", "-timecode", "10:00:00:00", mxf.path])
    let box = Toolbox()
    try await project(box, dir, ["fps": 25])
    let r = await box.call("media_import", ["paths": [.string(dir.path)], "analyze": false])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("A001_C002.mxf → a001-c002:"), "\(r.plainText)")
    #expect(r.plainText.contains("transcoded") && r.plainText.contains("interlaced top field first"), "\(r.plainText)")
    let status = await box.call("project_status", [:])
    #expect(status.plainText.contains("ProRes mezzanine of ") && status.plainText.contains("A001_C002.mxf (MPEG-2") && status.plainText.contains("interlaced"), "\(status.plainText)")

    #expect(!(await box.call("clip_add", ["media_id": "a001-c002"])).isError)
    let frames = await box.call("timeline_frames", ["times": [1]])
    #expect(!frames.isError, "\(frames.plainText)")

    let off = await box.call("media_organize", ["media_ids": ["a001-c002"], "deinterlace": "off"])
    #expect(!off.isError)
    #expect(try box.session.project().mediaAsset("a001-c002")?.deinterlaces == false)

    let out = dir.appendingPathComponent("air.mxf")
    let e = await box.call("export", ["path": .string(out.path), "preset": "xdcam_hd422", "interchange": ["xml"]])
    #expect(!e.isError, "\(e.plainText)")
    #expect(e.plainText.contains("mpeg2video 4:2:2") && e.plainText.contains("MXF OP1a"), "\(e.plainText)")
    #expect(e.plainText.contains("Audio: 8 channels in 8 mono tracks, pcm_s24le 48 kHz 24-bit"), "\(e.plainText)")
    #expect(e.plainText.contains("Timecode starts at 01:00:00:00"), "\(e.plainText)")
    let xml = try String(contentsOf: dir.appendingPathComponent("air.xml"), encoding: .utf8)
    #expect(xml.contains("A001_C002.mxf") && !xml.contains("mezzanine"))
    #expect(xml.contains("<string>10:00:00:00</string>"), "\(xml)")
    // Re-importing it finds the mezzanine by its camera original instead of adding a copy.
    let back = await box.call("timeline_import", ["path": .string(dir.appendingPathComponent("air.xml").path)])
    #expect(back.plainText.contains("1 media matched to the project's, 0 added"), "\(back.plainText)")
    #expect(try box.session.project().media.map(\.id) == ["a001-c002"])
}

@Test(.enabled(if: tools != nil, skip)) func sourceTimecodeShowsAtImportAndPlacesClips() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mov = dir.appendingPathComponent("A001C002.mov")
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30000/1001", "-t", "2",
                                          "-c:v", "prores_ks", "-profile:v", "0", "-timecode", "14:22:10:05", "-metadata:s:v", "reel_name=A001", mov.path])
    let box = Toolbox()
    try await project(box, dir, ["fps": 29.97])
    let r = await box.call("media_import", ["paths": [.string(mov.path)], "analyze": false])
    #expect(r.plainText.contains("TC 14:22:10:05 (non-drop), reel A001"), "\(r.plainText)")
    let list = await box.call("media_list", [:])
    #expect(list.plainText.contains("| 14:22:10:05 | A001 |"), "\(list.plainText)")
    let add = await box.call("clip_add", ["media_id": "a001c002", "source_in": "a001c002@14:22:10:20", "duration": 1])
    #expect(!add.isError, "\(add.plainText)")
    let clip = try #require(try box.session.project().tracks[0].clips.first)
    #expect(abs(clip.sourceIn - 15.0 * 1001 / 30000) < 1e-9)
}

@Test func nearMissPresetNamesPointAtTheRealOnes() {
    #expect(ExportPreset.unavailable("dnxhd")?.contains("dnxhr_hq") == true)
    #expect(ExportPreset.unavailable("xdcam")?.contains("xdcam_hd422") == true)
}
