import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg/ffprobe not found (CUTLINE_FFMPEG, PATH, /opt/homebrew/bin, /usr/local/bin); brew install ffmpeg to run"

private func writeSine(_ url: URL, freq: Double, amplitude: Double, seconds: Double = 2) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let n = Int(seconds * 48_000)
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = Float(amplitude * sin(2 * .pi * freq * Double(i) / 48_000)) }
    try file.write(from: buf)
}

/// Amplitude of a sine at `freq` in `x[a..<b]`.
private func tone(_ x: [Float], _ freq: Double, from a: Int, to b: Int) -> Double {
    var re = 0.0, im = 0.0
    for i in a..<min(b, x.count) {
        let ph = 2 * .pi * freq * Double(i) / 48_000
        re += Double(x[i]) * cos(ph)
        im += Double(x[i]) * sin(ph)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(max(min(b, x.count) - a, 1))
}

private func rms(_ x: [Float], from a: Int, to b: Int) -> Double {
    let s = x[a..<min(b, x.count)]
    return (s.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(s.count, 1))).squareRoot()
}

/// Every channel of one audio stream, decoded by ffmpeg to float.
private func decode(_ url: URL, stream: Int, channels: Int) async throws -> [[Float]] {
    let raw = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-decode-\(UUID().uuidString).f32")
    defer { try? FileManager.default.removeItem(at: raw) }
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-map", "0:a:\(stream)", "-f", "f32le", "-acodec", "pcm_f32le", raw.path])
    let data = try Data(contentsOf: raw)
    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let frames = samples.count / channels
    return (0..<channels).map { c in (0..<frames).map { samples[$0 * channels + c] } }
}

/// Dialogue 440 Hz, music 1 kHz, effects 2.5 kHz and an "Atmos" ambience track at 3.5 kHz, each with its role.
private final class Rig {
    let dir: URL
    let library = MediaLibrary()
    let stems: AudioStems
    var project = Project(name: "Tracks", canvas: Canvas(width: 320, height: 180, fps: 25, timecodeStart: "10:00:00:00"))
    static let tones: [(id: String, name: String, role: String, freq: Double, amp: Double)] = [
        ("A1", "Dialogue", "dialogue", 440, 0.2), ("A2", "Score", "music", 1000, 0.1), ("A3", "SFX", "effects", 2500, 0.05), ("A4", "Atmos", "effects", 3500, 0.025),
    ]

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-tracks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stems = AudioStems(directory: dir.appendingPathComponent("stems"))
        project.tracks = [Track(id: "V1", kind: .video, name: "Main")]
        for t in Rig.tones {
            let url = dir.appendingPathComponent("\(t.id).caf")
            try writeSine(url, freq: t.freq, amplitude: t.amp)
            project.media.append(try await MediaProbe.probe(url, id: "m\(t.id)"))
            var track = Track(id: t.id, kind: .audio, name: t.name, clips: [Clip(id: "c\(t.id)", kind: .media, mediaId: "m\(t.id)", start: 0, duration: 2)])
            track.role = t.role
            project.tracks.append(track)
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func built(_ p: Project) async throws -> BuiltTimeline {
        try await stems.renderMissing(p, transcripts: [:], library: library)
        return try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    }

    func jobs(_ specs: [AudioTrackSpec]) async throws -> [AudioTracks.Job] {
        var out: [AudioTracks.Job] = []
        for s in specs {
            if s.content != .mix, let source = try project.audioTrackSource(s.content, roles: [:], layout: specs) {
                out.append(AudioTracks.Job(s, timeline: try await built(source)))
            } else {
                out.append(AudioTracks.Job(s))
            }
        }
        return out
    }
}

@Test(.enabled(if: tools?.ffprobe != nil, skip)) func broadcastEightChannelMasterCarriesNamedTracksThatSumToTheMix() async throws {
    let rig = try await Rig()
    let specs = try AudioTrackSpec.parse("broadcast_8ch")
    var options = ExportOptions(preset: .prores_hq)
    options.audioTracks = try await rig.jobs(specs)
    options.audioTracksReport = AudioTracks.Report()
    let url = rig.dir.appendingPathComponent("master.mov")
    try await Exporter.export(try await rig.built(rig.project), to: url, options: options)

    let info = try await FFmpeg.probe(url, ffprobe: tools!.ffprobe!)
    #expect(info.audio.map(\.channels) == [2, 2, 1, 1, 1, 1], "\(info.audio.map(\.channels))")
    #expect(info.audio.map(\.title) == ["Mix", "M&E", "DIA", "MUS", "FX", "AMB"], "\(info.audio.map(\.title))")
    #expect(info.audio.allSatisfy { $0.codec == "pcm_s24le" && $0.sampleRate == 48_000 })
    #expect(info.timecode == "10:00:00:00")
    #expect(options.audioTracksReport?.tracks.count == 6)

    let mix = try await decode(url, stream: 0, channels: 2)
    let me = try await decode(url, stream: 1, channels: 2)
    let stems = try await [2, 3, 4, 5].asyncMap { try await decode(url, stream: $0, channels: 1)[0] }
    let a = 4_800, b = 86_400
    // Each stem carries its own tone and nothing else.
    for (i, t) in Rig.tones.enumerated() {
        for (j, other) in Rig.tones.enumerated() {
            let level = tone(stems[i], other.freq, from: a, to: b)
            if i == j { #expect(level > other.amp * 0.3, "\(t.name) at \(other.freq) Hz: \(level)") } else { #expect(level < 1e-4, "\(t.name) leaks \(other.freq) Hz: \(level)") }
        }
    }
    #expect(tone(me[0], 440, from: a, to: b) < 1e-4 && tone(me[0], 1000, from: a, to: b) > 0.02)
    // DIA + MUS + FX + AMB is the mono fold of the mix within 0.1 dB, with a residual far below it.
    let fold = (0..<mix[0].count).map { (mix[0][$0] + mix[1][$0]) / 2 }
    let sum = (0..<fold.count).map { i in stems.reduce(Float(0)) { $0 + ($1.indices.contains(i) ? $1[i] : 0) } }
    let ratio = 20 * log10(rms(sum, from: a, to: b) / rms(fold, from: a, to: b))
    let residual = 20 * log10(rms((0..<fold.count).map { sum[$0] - fold[$0] }, from: a, to: b) / rms(fold, from: a, to: b))
    #expect(abs(ratio) < 0.1, "stems sum to the mix within \(ratio) dB")
    #expect(residual < -60, "residual \(residual) dB")
}

@Test(.enabled(if: tools?.ffprobe != nil, skip)) func audioTracksPackIntoOneTrackOrMonoMXFWithLeaderToneAndConformedMix() async throws {
    let rig = try await Rig()
    rig.project.master.loudnessTarget = -23
    let specs = try AudioTrackSpec.parse("mix,me,dia,mus,fx,amb,tone,silence")
    var options = ExportOptions(preset: .prores_hq, leader: Leader(barsSeconds: 1, slateSeconds: 1, blackSeconds: 2))
    options.audioTracks = try await rig.jobs(specs)
    options.audioPacking = .channels
    options.audioTracksReport = AudioTracks.Report()
    let built = try await rig.built(rig.project)
    let packed = rig.dir.appendingPathComponent("packed.mov")
    try await Exporter.export(built, to: packed, options: options)
    let p = try await FFmpeg.probe(packed, ffprobe: tools!.ffprobe!)
    #expect(p.audio.count == 1 && p.audio.first?.channels == 10, "\(p.audio.map(\.channels))")
    #expect(abs(p.duration - 6) < 0.1)
    let ch = try await decode(packed, stream: 0, channels: 10)
    // Bars tone at −20 dBFS on program tracks and the tone track, nothing on the silent one.
    let bars = Float(pow(10, -20.0 / 20))
    for c in 0..<9 { #expect(abs(tone(ch[c], 1000, from: 2_400, to: 40_000) - Double(bars)) < 0.01, "channel \(c + 1) bars") }
    #expect(rms(ch[9], from: 0, to: ch[9].count) < 1e-6)
    #expect(abs(tone(ch[8], 1000, from: 200_000, to: 280_000) - Double(bars)) < 0.01, "tone track carries tone through the program")
    // The mix is conformed; the stems aren't.
    let tracks = try #require(options.audioTracksReport?.tracks)
    #expect(abs((tracks[0].loudness?.integrated ?? 0) + 23) < 0.3, "\(String(describing: tracks[0].loudness))")
    #expect(tracks[0].conform != nil && tracks[2].conform == nil)
    let dia = tone(ch[4], 440, from: 4 * 48_000 + 4_800, to: 4 * 48_000 + 86_400)
    #expect(abs(dia - 0.2) < 0.02, "DIA keeps its level: \(dia)")

    // MXF: every channel its own mono track.
    var mxf = ExportOptions(preset: .h264_422_10bit)
    mxf.audioTracks = try await rig.jobs(try AudioTrackSpec.parse("broadcast_8ch"))
    let url = rig.dir.appendingPathComponent("master.mxf")
    try await Exporter.export(built, to: url, options: mxf)
    let m = try await FFmpeg.probe(url, ffprobe: tools!.ffprobe!)
    #expect(m.formatName == "mxf" && m.audio.count == 8 && m.audio.allSatisfy { $0.channels == 1 && $0.codec == "pcm_s24le" }, "\(m.audio.map(\.channels))")
    #expect(m.timecode == "10:00:00:00")
    for (k, t) in Rig.tones.enumerated() {
        let x = try await decode(url, stream: 4 + k, channels: 1)[0]
        #expect(tone(x, t.freq, from: 4_800, to: 86_400) > t.amp * 0.3, "MXF track \(5 + k) carries \(t.name)")
    }
}

@Test func dialogueGatedLoudnessMeasuresAndConformsOnlyWhereDialoguePlays() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-gate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 0–3 s quiet dialogue-level tone, 3–9 s much louder music.
    let url = dir.appendingPathComponent("mix.caf")
    let n = 9 * 48_000
    let file = try AVAudioFile(forWriting: url, settings: AudioLayout.stereo.floatFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var x = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
    for i in 0..<n {
        let v = Float((i < 3 * 48_000 ? 0.05 : 0.4) * sin(2 * .pi * 1000 * Double(i) / 48_000))
        x[0][i] = v
        x[1][i] = v
    }
    try AudioIO.write(x, to: file)
    let speech = [TimeRange(0, 3)]
    let gated = try LoudnessMeter.measure(file: url, layout: .stereo, dialogue: speech)
    let alone = try LoudnessMeter.measure(file: url, layout: .stereo, range: TimeRange(0, 3))
    let dialogue = try #require(gated.dialogue)
    #expect(abs(dialogue - alone.integrated) < 0.3, "gated \(dialogue), dialogue alone \(alone.integrated)")
    #expect(gated.integrated > dialogue + 10)
    #expect(abs(gated.dialogueSeconds - 3) < 0.01)
    #expect(try LoudnessMeter.measure(file: url, layout: .stereo).dialogue == nil)

    let out = dir.appendingPathComponent("conformed.caf")
    let conform = try await LoudnessConform.run(url, layout: .stereo, frames: 0..<Int64(n), target: -27, ceiling: -2, dialogue: speech, to: out)
    #expect(abs((conform.after.dialogue ?? 0) + 27) < 0.3, "\(conform.summary)")
    #expect(conform.after.truePeakDb <= -1.9)
    #expect(conform.summary.contains("dialogue-gated"))
}

extension Array {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await f(e)) }
        return out
    }
}
