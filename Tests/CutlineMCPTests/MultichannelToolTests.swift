import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg not found; brew install ffmpeg to run"

@Test(.enabled(if: tools != nil, skip)) func multitrackMediaSplitsAnalyzesByChannelAndKeepsItsLoudnessTarget() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-multitrack-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cam = dir.appendingPathComponent("interview.mov")
    var args = ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25"]
    for f in [300, 500, 700, 900] { args += ["-f", "lavfi", "-i", "sine=f=\(f):sample_rate=48000"] }
    args += ["-t", "4", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:a", "-map", "4:a", "-c:v", "prores_ks", "-c:a", "pcm_s24le", cam.path]
    try await FFmpeg.run(tools!.ffmpeg, args)

    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180, "fps": 25])).isError)
    let imported = await box.call("media_import", ["paths": [.string(cam.path)], "analyze": false])
    #expect(imported.plainText.contains("4 source channels in 4 mono tracks"), "\(imported.plainText)")

    let split = await box.call("clip_add", ["media_id": "interview", "channels": "split"])
    #expect(!split.isError && split.plainText.contains("into 4 mono clip(s)"), "\(split.plainText)")
    let p = try box.session.project()
    let sounds = p.tracks.filter { $0.kind == .audio }.flatMap(\.clips)
    #expect(sounds.map { $0.channels?.rawValue ?? "" } == ["ch1", "ch2", "ch3", "ch4"])
    #expect(Set(p.tracks.flatMap(\.clips).map(\.link)).count == 1)
    let bad = await box.call("param_set", ["target": .string(sounds[0].id), "set": ["audio.channels": "ch7"]])
    #expect(bad.isError && bad.plainText.contains("ch1–ch4"), "\(bad.plainText)")

    let analyzed = await box.call("media_analyze", ["media_id": "interview", "features": ["beats"], "channel": "ch3"])
    #expect(analyzed.plainText.contains("audio from ch3"), "\(analyzed.plainText)")
    #expect(try box.session.project().mediaAsset("interview")?.analysisChannel?.rawValue == "ch3")

    let normalized = await box.call("recipe", ["name": "loudness_normalize", "args": ["target_lufs": -23]])
    #expect(!normalized.isError && normalized.plainText.contains("Kept as the master loudness target"), "\(normalized.plainText)")
    #expect((await box.call("project_status", [:])).plainText.contains("Loudness target: -23.0 LUFS"))
    // A later mix change drifts the mix; measuring shows it and delivery still meets the target.
    for c in sounds { _ = await box.call("param_set", ["target": .string(c.id), "set": ["audio.volume": 0.3]]) }
    let measured = await box.call("timeline_measure", ["what": ["sound"]])
    #expect(measured.plainText.contains("below the target"), "\(measured.plainText)")
    let wav = dir.appendingPathComponent("mix.wav")
    let delivered = await box.call("export", ["deliver": "audio", "path": .string(wav.path)])
    #expect(delivered.plainText.contains("delivered -23"), "\(delivered.plainText)")

    let refused = await box.call("export", ["preset": "dnxhr_hq", "interlaced": "bff", "path": .string(dir.appendingPathComponent("i.mov").path)])
    #expect(refused.isError && refused.plainText.contains("top field first"), "\(refused.plainText)")}
