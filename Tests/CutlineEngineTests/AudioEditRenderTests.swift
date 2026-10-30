import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

/// Writes a 48 kHz float file whose channels are sines at `freqs` (0 is silence), amplitude 0.25.
private func writeTones(_ url: URL, freqs: [Double], seconds: Double = 3) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(freqs.count), interleaved: false)!
    let n = Int(seconds * 48_000)
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for (c, f) in freqs.enumerated() {
        for i in 0..<n { buf.floatChannelData![c][i] = Float(0.25 * sin(2 * .pi * f * Double(i) / 48_000)) }
    }
    try file.write(from: buf)
}

/// The timeline's mixed sound as left and right sample arrays.
private func mix(_ built: BuiltTimeline) async throws -> (l: [Float], r: [Float]) {
    var l: [Float] = [], r: [Float] = []
    try await AudioIO.read(built, range: nil) { s, n in
        for i in 0..<n {
            l.append(s[2 * i])
            r.append(s[2 * i + 1])
        }
    }
    return (l, r)
}

private func rms(_ x: [Float], _ range: TimeRange) -> Double {
    let a = Int(range.start * 48_000), b = min(x.count, Int(range.end * 48_000))
    guard b > a else { return 0 }
    return (x[a..<b].reduce(0) { $0 + Double($1) * Double($1) } / Double(b - a)).squareRoot()
}

/// Amplitude of the `freq` component of `x` over `range`.
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

private func scratch(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func channelRoutingPicksOneMicrophone() async throws {
    let dir = try scratch("channels")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("twomic.caf")
    try writeTones(url, freqs: [440, 0], seconds: 2)
    var p = Project(name: "Channels", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(url, id: "rec")]
    p.tracks[1].clips = [Clip(id: "c", kind: .media, mediaId: "rec", start: 0, duration: 2)]
    let library = MediaLibrary()
    let stems = AudioStems(directory: dir.appendingPathComponent("stems"))
    let window = TimeRange(0.2, 1.8), full = 0.25 / 2.0.squareRoot()

    let stereo = try await mix(try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems))
    #expect(abs(rms(stereo.l, window) - full) < 0.01 && rms(stereo.r, window) < 0.001, "as recorded")

    let expected: [ChannelRouting: (Double, Double)] = [.left: (full, full), .right: (0, 0), .swap: (0, full), .monoMix: (full / 2, full / 2)]
    for (routing, levels) in expected {
        try p.tracks[1].clips[0].set("audio.channels", .string(routing.rawValue))
        let dry = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
        #expect(dry.missingStems == ["c"], "\(routing) plays from a clip stem")
        #expect(try await stems.renderMissing(p, transcripts: [:], library: library) == ["c"])
        let built = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
        #expect(built.missingStems.isEmpty)
        let out = try await mix(built)
        #expect(abs(rms(out.l, window) - levels.0) < 0.01, "\(routing) left \(rms(out.l, window))")
        #expect(abs(rms(out.r, window) - levels.1) < 0.01, "\(routing) right \(rms(out.r, window))")
    }
}

@Test func rollingAudioTrimStopsTwoLinesOverlapping() async throws {
    let dir = try scratch("rolltrim")
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.caf"), b = dir.appendingPathComponent("b.caf")
    try writeTones(a, freqs: [440])
    try writeTones(b, freqs: [1000])
    var p = Project(name: "Roll", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(a, id: "a"), try await MediaProbe.probe(b, id: "b")]
    p.tracks[1].clips = [
        Clip(id: "ca", kind: .media, mediaId: "a", start: 0, duration: 1, sourceIn: 1),
        Clip(id: "cb", kind: .media, mediaId: "b", start: 1, duration: 1, sourceIn: 1),
    ]
    let library = MediaLibrary()
    let overlap = TimeRange(0.6, 0.9)

    // Only extending the incoming sound plays both lines at once.
    var naive = p
    naive.tracks[1].clips[1].audioLead = 0.5
    let both = try await mix(try await TimelineBuilder.build(naive, transcripts: [:], library: library))
    #expect(tone(both.l, 440, overlap) > 0.1 && tone(both.l, 1000, overlap) > 0.1)

    try p.trimAudio("cb", edge: .start, delta: -0.5)
    let rolled = try await mix(try await TimelineBuilder.build(p, transcripts: [:], library: library))
    #expect(tone(rolled.l, 1000, overlap) > 0.1, "the incoming line starts early")
    #expect(tone(rolled.l, 440, overlap) < 0.01, "the outgoing line stops at the sound cut: \(tone(rolled.l, 440, overlap))")
    #expect(tone(rolled.l, 440, TimeRange(0.1, 0.4)) > 0.1)
}

@Test func declickIsAnAudioEffect() throws {
    var x = (0..<48_000).map { i -> Float in Float(0.1 * sin(2 * Double.pi * 220 * Double(i) / 48_000)) }
    x[24_000] += 0.8
    let e = Effect(id: "declick1", type: "audio.declick", params: ["sensitivity": .number(0.8)])
    let out = try #require(AudioDSP.apply(e, to: [x, x], sampleRate: 48_000))
    #expect(abs(out[0][24_000]) < 0.2 && abs(out[1][24_000]) < 0.2)
    #expect(abs(out[0][1_000] - x[1_000]) < 1e-6)
}
