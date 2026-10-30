import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// Five 3 s stretches of speech with 1 s pauses over 20 s.
private let spoken = (0..<5).map { TimeRange(Double($0) * 4, Double($0) * 4 + 3) }

/// ch1+ch2 a lav pair speaking in `spoken`, ch3 a continuous music bed, ch4 nothing.
private func writeInterview(_ url: URL, seconds: Double = 20) throws {
    let rate = 48_000.0
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
    var settings = format.settings
    settings[AVFormatIDKey] = kAudioFormatLinearPCM
    settings[AVLinearPCMBitDepthKey] = 16
    settings[AVLinearPCMIsFloatKey] = false
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = Int(seconds * rate)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n {
        let t = Double(i) / rate
        let talk = spoken.contains { $0.start <= t && t < $0.end } ? Float(0.25 * sin(2 * .pi * 440 * t)) : 0
        buf.floatChannelData![0][i] = talk
        buf.floatChannelData![1][i] = talk * 0.8
        buf.floatChannelData![2][i] = Float(0.1 * sin(2 * .pi * 1000 * t))
        buf.floatChannelData![3][i] = 0
    }
    try file.write(from: buf)
}

private func writeNoise(_ url: URL, seconds: Double = 6) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = Int(seconds * 48_000)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = Float.random(in: -0.01...0.01) }
    try file.write(from: buf)
}

@Test func dmeBusesAndDuckUseEvidencePerChannel() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-roles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeInterview(dir.appendingPathComponent("interview.wav"))
    try writeNoise(dir.appendingPathComponent("room.wav"))

    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180, "fps": 25])).isError)
    let imported = await box.call("media_import", ["paths": .array(["interview.wav", "room.wav"].map { .string(dir.appendingPathComponent($0).path) }), "analyze": false])
    #expect(imported.plainText.contains("4 source channels"), "\(imported.plainText)")
    let split = await box.call("clip_add", ["media_id": "interview", "channels": "split"])
    #expect(!split.isError, "\(split.plainText)")

    let b = try box.session.requireBundle()
    var words: [Word] = []
    for s in spoken { var t = s.start; while t + 0.4 <= s.end { words.append(Word(text: "word", start: t, end: t + 0.4)); t += 0.5 } }
    try b.saveTranscript(Transcript(mediaId: "interview", locale: "en-US", words: words))
    try b.saveAnalysis(BeatAnalysis(mediaId: "interview", tempo: 120, beats: stride(from: 0.0, to: 20, by: 0.5).map { $0 }, downbeats: [], onsets: [], energy: []), "interview", "beats")

    let tone = await box.call("recipe", ["name": "room_tone", "args": ["start": 20, "end": 24, "media": "room", "source_start": 0, "source_end": 4]])
    #expect(!tone.isError, "\(tone.plainText)")

    var p = try box.session.project()
    func track(_ suffix: String) -> Track { p.tracks.first { $0.name.hasSuffix(suffix) }! }
    let (ch2, ch3, ch4, room) = (track("ch2"), track("ch3"), track("ch4"), track("Room tone"))
    #expect(room.clips.allSatisfy { $0.role == "dialogue.room tone" })

    let dme = await box.call("recipe", ["name": "dme_buses"])
    #expect(!dme.isError, "\(dme.plainText)")
    #expect(dme.plainText.contains("\(ch2.id) \"\(ch2.name)\" → DIA: speech "), "\(dme.plainText)")
    #expect(dme.plainText.contains("\(ch3.id) \"\(ch3.name)\" → MUS: music "), "\(dme.plainText)")
    #expect(dme.plainText.contains("\(ch4.id) \"\(ch4.name)\": no role, silent"), "\(dme.plainText)")
    p = try box.session.project()
    let out = Dictionary(uniqueKeysWithValues: p.tracks.map { ($0.id, $0.output ?? "master") })
    #expect(out[ch2.id] == "DIA" && out[ch3.id] == "MUS" && out[ch4.id] == "master" && out[room.id] == "DIA", "\(out)")
    #expect(b.analysis(ChannelLevels.self, "interview", "channels")?.levels.count == 4, "channel levels are cached")

    let refused = await box.call("recipe", ["name": "duck", "args": ["music": .string(ch2.id)]])
    #expect(refused.isError && refused.plainText.contains("carry speech"), "\(refused.plainText)")

    let duck = await box.call("recipe", ["name": "duck"])
    #expect(!duck.isError && duck.plainText.contains("Ducked 1 music clip(s) on \(ch3.id)"), "\(duck.plainText)")
    p = try box.session.project()
    #expect(p.tracks.first { $0.id == ch3.id }!.clips[0].anim["audio.volume"] != nil)
    #expect(p.tracks.filter { $0.id != ch3.id }.flatMap(\.clips).allSatisfy { $0.anim["audio.volume"] == nil }, "dialogue isn't ducked")
}
