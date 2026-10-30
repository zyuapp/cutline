import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

/// A mono 48 kHz float file: a sine at `freq`, amplitude 0.25, for `on` seconds, then silence to `seconds`.
private func writeBurst(_ url: URL, freq: Double, seconds: Double = 3, on: Double? = nil) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let n = Int(seconds * 48_000), lit = Int((on ?? seconds) * 48_000)
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = i < lit ? Float(0.25 * sin(2 * .pi * freq * Double(i) / 48_000)) : 0 }
    try file.write(from: buf)
}

private func left(_ built: BuiltTimeline) async throws -> [Float] {
    var l: [Float] = []
    try await AudioIO.read(built, range: nil) { s, n in for i in 0..<n { l.append(s[2 * i]) } }
    return l
}

private func rms(_ x: [Float], _ range: TimeRange) -> Double {
    let a = Int(range.start * 48_000), b = min(x.count, Int(range.end * 48_000))
    guard b > a else { return 0 }
    return (x[a..<b].reduce(0) { $0 + Double($1) * Double($1) } / Double(b - a)).squareRoot()
}

private func tone(_ x: [Float], _ freq: Double, _ range: TimeRange) -> Double {
    let a = Int(range.start * 48_000), b = min(x.count, Int(range.end * 48_000))
    var re = 0.0, im = 0.0
    for i in a..<b {
        let ph = 2 * .pi * freq * Double(i) / 48_000
        re += Double(x[i]) * cos(ph)
        im += Double(x[i]) * sin(ph)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(max(b - a, 1))
}

private final class Rig {
    let dir: URL
    let library = MediaLibrary()
    let stems: AudioStems
    var project = Project(name: "Buses", canvas: Canvas(width: 320, height: 180, fps: 30))

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-buses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stems = AudioStems(directory: dir.appendingPathComponent("stems"))
        project.tracks = [Track(id: "V1", kind: .video, name: "Main")]
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Adds an audio track playing a tone (silent after `on` seconds).
    func track(_ id: String, freq: Double, on: Double? = nil, role: String? = nil) async throws {
        let url = dir.appendingPathComponent("\(id).caf")
        try writeBurst(url, freq: freq, on: on)
        project.media.append(try await MediaProbe.probe(url, id: "m\(id)"))
        var t = Track(id: id, kind: .audio, name: id, clips: [Clip(id: "c\(id)", kind: .media, mediaId: "m\(id)", start: 0, duration: 3)])
        t.role = role
        project.tracks.append(t)
    }

    func index(_ id: String) -> Int { project.trackIndex(id)! }

    /// The rendered mix's left channel.
    func render(_ p: Project? = nil) async throws -> [Float] {
        let p = p ?? project
        try p.validate()
        try await stems.renderMissing(p, transcripts: [:], library: library)
        let built = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
        #expect(built.missingStems.isEmpty, "\(built.missingStems)")
        return try await left(built)
    }

    /// A stem as export delivers it: pre-master, through the buses.
    func stem(_ p: Project) async throws -> [Float] {
        var p = p
        p.master.effects = []
        return try await render(p)
    }
}

@Test func sendToAnEchoBusIsWetOnlyOnThatBus() async throws {
    let rig = try Rig()
    try await rig.track("A1", freq: 440, on: 1)
    rig.project.buses = [AudioBus(id: "ECHO", effects: [Effect(id: "delay1", type: "audio.delay", params: ["time_ms": .number(300), "feedback": .number(0), "wet": .number(1)])])]
    rig.project.tracks[rig.index("A1")].sends = [AudioSend(bus: "ECHO", levelDb: -6)]

    let mix = try await rig.render()
    let echoWindow = TimeRange(1.08, 1.25)
    #expect(tone(mix, 440, TimeRange(0.4, 0.9)) > 0.15, "dry plus echo while the tone plays")
    #expect(tone(mix, 440, echoWindow) > 0.05, "the echo continues after the tone stops: \(tone(mix, 440, echoWindow))")

    let echo = try await rig.stem(rig.project.isolatingBus("ECHO"))
    let direct = try await rig.stem(rig.project.isolatingBus(nil))
    #expect(tone(echo, 440, echoWindow) > 0.05, "the echo bus carries the wet signal")
    #expect(rms(echo, TimeRange(0.02, 0.25)) < 0.003, "the echo bus is fully wet: nothing before the first repeat")
    #expect(rms(direct, echoWindow) < 0.003, "the direct path stays dry: \(rms(direct, echoWindow))")
    #expect(abs(tone(direct, 440, TimeRange(0.4, 0.9)) - 0.25) < 0.02)
    #expect(abs(tone(echo, 440, TimeRange(0.4, 0.9)) - 0.25 * 0.5) < 0.02, "a −6 dB send: \(tone(echo, 440, TimeRange(0.4, 0.9)))")
}

@Test func busVolumeAutomationRidesTheSubmix() async throws {
    let rig = try Rig()
    try await rig.track("A1", freq: 440)
    try await rig.track("A2", freq: 1000)
    rig.project.buses = [AudioBus(id: "MUS", volumeCurve: Curve(keys: [CurveKey(t: 0, v: .number(1), ease: .linear), CurveKey(t: 1, v: .number(1), ease: .linear), CurveKey(t: 2, v: .number(0.25), ease: .linear)]))]
    rig.project.tracks[rig.index("A2")].output = "MUS"

    // Until the bus mix renders, the preview plays the plain mix.
    let before = try await TimelineBuilder.build(rig.project, transcripts: [:], library: rig.library, stems: rig.stems)
    #expect(before.missingStems == ["buses"])
    let plain = try await left(before)
    #expect(abs(tone(plain, 1000, TimeRange(2.2, 2.8)) - 0.25) < 0.02, "the fallback is the unrouted mix")

    let mix = try await rig.render()
    #expect(abs(tone(mix, 1000, TimeRange(0.2, 0.8)) - 0.25) < 0.02)
    #expect(abs(tone(mix, 1000, TimeRange(2.2, 2.8)) - 0.0625) < 0.01, "the bus fader ducked the music: \(tone(mix, 1000, TimeRange(2.2, 2.8)))")
    #expect(abs(tone(mix, 440, TimeRange(2.2, 2.8)) - 0.25) < 0.02, "the track on the master is untouched")
    let built = try await TimelineBuilder.build(rig.project, transcripts: [:], library: rig.library, stems: rig.stems)
    #expect(try await built.composition.loadTracks(withMediaType: .audio).count == 1, "playback is the rendered bus mix")

    rig.project.buses[0].muted = true
    #expect(tone(try await rig.render(), 1000, TimeRange(0.2, 0.8)) < 0.005, "a muted bus is silent")
    rig.project.buses[0].muted = false
    rig.project.buses.append(AudioBus(id: "DIA", solo: true))
    rig.project.tracks[rig.index("A1")].output = "DIA"
    let soloed = try await rig.render()
    #expect(tone(soloed, 1000, TimeRange(0.2, 0.8)) < 0.005 && tone(soloed, 440, TimeRange(0.2, 0.8)) > 0.2, "solo plays only DIA")
}

@Test func busStemsSumToTheMasterAndMEDropsDialogue() async throws {
    let rig = try Rig()
    try await rig.track("A1", freq: 440, role: "dialogue")
    try await rig.track("A2", freq: 1000, role: "music")
    try await rig.track("A3", freq: 2500, role: "effects")
    rig.project.buses = [
        AudioBus(id: "DIA", effects: [Effect(id: "comp", type: "audio.compressor", params: ["threshold": .number(-24), "headroom": .number(6)])]),
        AudioBus(id: "MUS", volume: 0.7),
        AudioBus(id: "VERB", effects: [Effect(id: "delay1", type: "audio.delay", params: ["time_ms": .number(120), "feedback": .number(0.2), "wet": .number(1)])], output: "MUS"),
    ]
    rig.project.tracks[rig.index("A1")].output = "DIA"
    rig.project.tracks[rig.index("A1")].sends = [AudioSend(bus: "VERB", levelDb: -12, preFader: true)]
    rig.project.tracks[rig.index("A2")].output = "MUS"
    rig.project.master.gainDb = -2

    let master = try await rig.stem(rig.project)
    var sum = [Float](repeating: 0, count: master.count)
    let parts = rig.project.topLevelBuses.map { rig.project.isolatingBus($0.id) } + [rig.project.isolatingBus(nil)]
    #expect(parts.count == 3)
    for part in parts {
        let s = try await rig.stem(part)
        for i in 0..<min(s.count, sum.count) { sum[i] += s[i] }
    }
    let window = TimeRange(0.1, 2.9)
    let db = 20 * log10(rms(sum, window) / rms(master, window))
    #expect(abs(db) < 0.1, "bus stems sum to the master: \(db) dB")
    let residual = zip(master, sum).map { $0 - $1 }
    #expect(rms(residual, window) < rms(master, window) * 0.01)

    let me = try await rig.stem(rig.project.keepingRoles(rig.project.roles(transcripts: [:])) { $0 != "dialogue" })
    #expect(tone(me, 440, window) < 0.002, "M&E has no dialogue, not even its reverb send: \(tone(me, 440, window))")
    #expect(tone(me, 1000, window) > 0.1 && tone(me, 2500, window) > 0.1)
}

@Test func clipRoleMovesRoomToneToTheAmbienceStem() async throws {
    let rig = try Rig()
    let speech = rig.dir.appendingPathComponent("speech.caf"), room = rig.dir.appendingPathComponent("room.caf")
    try writeBurst(speech, freq: 440)
    try writeBurst(room, freq: 3000)
    rig.project.media = [try await MediaProbe.probe(speech, id: "speech"), try await MediaProbe.probe(room, id: "room")]
    var dia = Track(id: "A1", kind: .audio, name: "Dialogue", clips: [
        Clip(id: "line", kind: .media, mediaId: "speech", start: 0, duration: 1.5),
        Clip(id: "tone", kind: .media, mediaId: "room", start: 1.5, duration: 1.5, sourceIn: 1),
    ])
    dia.role = "dialogue"
    dia.clips[1].role = "ambience"
    dia.output = "DIA"
    rig.project.tracks.append(dia)
    rig.project.buses = [AudioBus(id: "DIA")]

    let roles = rig.project.roles(transcripts: [:])
    #expect(rig.project.audioRoles(roles) == ["dialogue": ["A1"], "ambience": ["A1"]])
    let dialogue = try await rig.stem(rig.project.keepingRoles(roles) { $0 == "dialogue" })
    let ambience = try await rig.stem(rig.project.keepingRoles(roles) { $0 == "ambience" })
    #expect(tone(dialogue, 440, TimeRange(0.2, 1.3)) > 0.2 && tone(dialogue, 3000, TimeRange(1.7, 2.8)) < 0.002)
    #expect(tone(ambience, 3000, TimeRange(1.7, 2.8)) > 0.2 && tone(ambience, 440, TimeRange(0.2, 1.3)) < 0.002)

    var plain = rig.project
    plain.buses = []
    plain.tracks[plain.trackIndex("A1")!].output = nil
    let ambienceDirect = try await rig.stem(plain.keepingRoles(roles) { $0 == "ambience" })
    #expect(tone(ambienceDirect, 3000, TimeRange(1.7, 2.8)) > 0.2 && tone(ambienceDirect, 440, TimeRange(0.2, 1.3)) < 0.002, "without buses too")
}

@Test func surroundMasterMixesThroughBuses() async throws {
    let rig = try Rig()
    try await rig.track("A1", freq: 440)
    rig.project.master.layout = .surround51
    rig.project.buses = [AudioBus(id: "DIA", volume: 0.5)]
    rig.project.tracks[rig.index("A1")].output = "DIA"
    rig.project.tracks[rig.index("A1")].clips[0].surround = SurroundPan(x: 0, y: 1, center: 1)
    try await rig.stems.renderMissing(rig.project, transcripts: [:], library: rig.library)
    let made = try #require(rig.stems.cachedLayoutMix(for: rig.project))
    let (x, _) = try AudioDSP.read(made.mix)
    #expect(x.count == 6)
    #expect(abs(tone(x[2], 440, TimeRange(0.2, 2.8)) - 0.125) < 0.015, "the bus halves the centred clip: \(tone(x[2], 440, TimeRange(0.2, 2.8)))")
    #expect(tone(x[0], 440, TimeRange(0.2, 2.8)) < 0.01)
}
