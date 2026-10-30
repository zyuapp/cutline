import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private func writeSine(_ url: URL, freq: Double, seconds: Double = 2) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let n = Int(seconds * 48_000)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * freq * Double(i) / 48_000)) }
    try file.write(from: buf)
}

@Test func exportWritesAudioTrackLayoutsAndChecksMasteringPlatforms() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-masters-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sounds = [("voice", 440.0, "Dialogue", "dialogue"), ("score", 1000.0, "Score", "music"), ("hits", 2500.0, "SFX", "effects"), ("wind", 3500.0, "Atmos", "effects.ambience")]
    for (name, f, _, _) in sounds { try writeSine(dir.appendingPathComponent("\(name).wav"), freq: f) }

    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180, "fps": 25])).isError)
    let imported = await box.call("media_import", ["paths": .array(sounds.map { .string(dir.appendingPathComponent("\($0.0).wav").path) }), "analyze": false])
    #expect(!imported.isError, "\(imported.plainText)")
    for (i, (media, _, name, role)) in sounds.enumerated() {
        let track = "A\(i + 1)"
        if i > 0 { _ = await box.call("track_add", ["kind": "audio", "name": .string(name)]) }
        let updated = await box.call("track_update", ["track_id": .string(track), "name": .string(name), "role": .string(role)])
        #expect(!updated.isError, "\(updated.plainText)")
        let added = await box.call("clip_add", ["media_id": .string(media), "track": .string(track), "start": 0])
        #expect(!added.isError, "\(added.plainText)")
    }

    let master = dir.appendingPathComponent("master.mov")
    let eight = await box.call("export", ["path": .string(master.path), "preset": "prores_hq", "audio_tracks": "broadcast_8ch"])
    #expect(!eight.isError, "\(eight.plainText)")
    #expect(eight.plainText.contains("Audio tracks (6 named tracks): ch1-2 Mix (stereo)") && eight.plainText.contains("ch8 AMB (mono)"), "\(eight.plainText)")
    let sheet = try String(contentsOf: dir.appendingPathComponent("master.tracks.txt"), encoding: .utf8)
    #expect(sheet.split(separator: "\n").count == 9 && sheet.contains("5\tDIA\tdia\tmono"), "\(sheet)")
    if let probe = FFmpeg.tools()?.ffprobe {
        let info = try await FFmpeg.probe(master, ffprobe: probe)
        #expect(info.audio.map(\.title) == ["Mix", "M&E", "DIA", "MUS", "FX", "AMB"], "\(info.audio.map(\.title))")
    }

    let packed = await box.call("export", ["path": .string(dir.appendingPathComponent("packed.mov").path), "preset": "prores_hq",
                                           "audio_tracks": [["content": "mix"], ["content": "dia", "name": "Dialogue"]], "audio_tracks_as": "channels"])
    #expect(!packed.isError && packed.plainText.contains("one 3-channel track") && packed.plainText.contains("ch3 Dialogue (mono)"), "\(packed.plainText)")

    let mp4 = await box.call("export", ["path": .string(dir.appendingPathComponent("web.mp4").path), "audio_tracks": "mix,me"])
    #expect(mp4.isError && mp4.plainText.contains("QuickTime"), "\(mp4.plainText)")
    let unknown = await box.call("export", ["path": .string(master.path), "preset": "prores_hq", "audio_tracks": [["content": "voice"]]])
    #expect(unknown.isError && unknown.plainText.contains("bus:<id>"), "\(unknown.plainText)")

    let dpp = await box.call("export", ["platform": "broadcast_uk_dpp", "check_only": true])
    #expect(dpp.plainText.contains("UK DPP") && dpp.plainText.contains("1920×1080") && dpp.plainText.contains("start at 10:00:00:00"), "\(dpp.plainText)")
    #expect(!dpp.plainText.contains("audio track layout"), "the platform's own layout applies: \(dpp.plainText)")

    let netflix = await box.call("export", ["platform": "netflix_master", "check_only": true])
    #expect(netflix.plainText.contains("Dialogue-gated loudness") && netflix.plainText.contains("over 2.0s of dialogue"), "\(netflix.plainText)")
    #expect(netflix.plainText.contains("dialogue-gated") && !netflix.plainText.contains("IMSC 1.1 timed-text sidecar;"), "\(netflix.plainText)")
    let noIMSC = await box.call("export", ["platform": "netflix_master", "check_only": true, "subtitles": "sidecar"])
    #expect(noIMSC.plainText.contains("IMSC 1.1 timed-text sidecar"), "\(noIMSC.plainText)")
}
