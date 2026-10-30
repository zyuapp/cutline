import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private func writeTone(_ url: URL, freq: Double, seconds: Double = 2) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let n = Int(seconds * 48_000)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = Float(0.25 * sin(2 * .pi * freq * Double(i) / 48_000)) }
    try file.write(from: buf)
}

@Test func busToolsRouteSendAndDeliverStemsPerBus() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-bustools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, f) in [("voice", 440.0), ("score", 1000.0), ("hits", 2500.0)] { try writeTone(dir.appendingPathComponent("\(name).wav"), freq: f) }

    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180, "fps": 25])).isError)
    let imported = await box.call("media_import", ["paths": .array(["voice", "score", "hits"].map { .string(dir.appendingPathComponent("\($0).wav").path) }), "analyze": false])
    #expect(!imported.isError, "\(imported.plainText)")
    _ = await box.call("track_update", ["track_id": "A1", "name": "Dialogue", "role": "dialogue"])
    _ = await box.call("track_add", ["kind": "audio", "name": "Score"])
    _ = await box.call("track_add", ["kind": "audio", "name": "SFX"])
    for (media, track) in [("voice", "A1"), ("score", "A2"), ("hits", "A3")] {
        let r = await box.call("clip_add", ["media_id": .string(media), "track": .string(track), "start": 0])
        #expect(!r.isError, "\(r.plainText)")
    }

    let dme = await box.call("recipe", ["name": "dme_buses"])
    #expect(!dme.isError && dme.plainText.contains("A1 \"Dialogue\" (dialogue) → DIA"), "\(dme.plainText)")
    let p = try box.session.project()
    #expect(p.tracks.filter { $0.kind == .audio }.map { $0.output ?? "master" } == ["DIA", "MUS", "FX"])
    #expect(p.master.effects.map(\.type) == ["audio.limiter"])

    let verb = await box.call("audio_bus", ["bus": "VERB", "name": "Reverb", "output": "MUS", "type": "audio.delay", "params": ["time_ms": 200, "wet": 1]])
    #expect(!verb.isError && verb.plainText.contains("Nothing feeds it yet"), "\(verb.plainText)")
    let send = await box.call("track_update", ["track_id": "A1", "sends": [["bus": "VERB", "level_db": -12, "pre_fader": true]]])
    #expect(!send.isError, "\(send.plainText)")
    let loop = await box.call("audio_bus", ["bus": "MUS", "output": "VERB"])
    #expect(loop.isError && loop.plainText.contains("loops"), "\(loop.plainText)")
    let unknown = await box.call("track_update", ["track_id": "A2", "output": "NOPE"])
    #expect(unknown.isError, "\(unknown.plainText)")
    let ride = await box.call("audio_bus", ["bus": "MUS", "volume_keys": [[0, 1], [1.5, 0.5]]])
    #expect(!ride.isError && ride.plainText.contains("automation 2 keys"), "\(ride.plainText)")

    let status = await box.call("project_status", [:])
    #expect(status.plainText.contains("Mix routing"), "\(status.plainText)")
    #expect(status.plainText.contains("bus VERB \"Reverb\""))
    #expect(status.plainText.contains("send from A1 -12.0 dB pre-fader"), "\(status.plainText)")

    let stemsDir = dir.appendingPathComponent("stems")
    let stems = await box.call("export", ["deliver": "stems", "stems": "buses", "path": .string(stemsDir.path)])
    #expect(!stems.isError, "\(stems.plainText)")
    let files = Set((try? FileManager.default.contentsOfDirectory(atPath: stemsDir.path)) ?? [])
    #expect(files == ["p - DIA Dialogue.wav", "p - MUS Music.wav", "p - FX Effects.wav", "p - M&E.wav"], "\(files) \(stems.plainText)")
    #expect(stems.plainText.contains("inside their parent's stem"))

    let roleStems = await box.call("export", ["deliver": "stems", "path": .string(dir.appendingPathComponent("roles").path)])
    #expect(roleStems.plainText.contains("dialogue:") && roleStems.plainText.contains("music:") && roleStems.plainText.contains("effects:"), "\(roleStems.plainText)")

    let removed = await box.call("audio_bus", ["bus": "MUS", "action": "remove"])
    #expect(!removed.isError, "\(removed.plainText)")
    let after = try box.session.project()
    #expect(after.trackIndex("A2").map { after.tracks[$0].output } == .some(nil) && after.bus("VERB")?.output == nil)
}
