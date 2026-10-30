import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

private func sine(_ freq: Double, seconds: Double, amp: Double = 1) -> [Float] {
    (0..<Int(seconds * 48_000)).map { Float(amp * sin(2 * .pi * freq * Double($0) / 48_000)) }
}

private func rms(_ x: ArraySlice<Float>) -> Double {
    (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot()
}

@Test func lfeSendIsLowPassedAt120Hz() {
    let low = sine(40, seconds: 1), high = sine(1000, seconds: 1), knee = sine(120, seconds: 1)
    let skip = 4_800
    #expect(rms(SurroundMix.lowPassLFE(low)[skip...]) / rms(low[skip...]) > 0.97)
    #expect(20 * log10(rms(SurroundMix.lowPassLFE(high)[skip...]) / rms(high[skip...])) < -60)
    #expect(abs(20 * log10(rms(SurroundMix.lowPassLFE(knee)[skip...]) / rms(knee[skip...])) - -3) < 0.3)
}

@Test func loudnessWeights51Channels() {
    func measure(_ channels: [Int], ampDb: Double, layout: AudioLayout = .surround51) -> LoudnessReport {
        let n = layout.channelCount, frames = 48_000
        let tone = sine(1000, seconds: 1, amp: pow(10, ampDb / 20))
        var interleaved = [Float](repeating: 0, count: frames * n)
        for i in 0..<frames { for c in channels { interleaved[i * n + c] = tone[i] } }
        var acc = LoudnessMeter.Accumulator(layout: layout)
        interleaved.withUnsafeBufferPointer { acc.feed($0.baseAddress!, frames) }
        return acc.report()
    }
    // A stereo sine at −23 dBFS reads −23 LUFS, so the same tone in L, R and C needs 10·log10(3/2) dB less.
    let lrc = measure([0, 1, 2], ampDb: -23 - 10 * log10(1.5))
    #expect(abs(lrc.integrated - -23) < 0.2, "L+R+C \(lrc.integrated)")
    let front = measure([0], ampDb: -20), surround = measure([4], ampDb: -20)
    #expect(abs(surround.integrated - front.integrated - 10 * log10(1.41)) < 0.05)
    #expect(!measure([3], ampDb: -10).integrated.isFinite, "LFE is excluded")
    // The default stereo accumulator reads the same as a stereo layout.
    #expect(abs(measure([0, 1], ampDb: -23, layout: .stereo).integrated - -23) < 0.2)
}

/// A 2 s mono tone file.
private func writeTone(_ url: URL, freq: Double, seconds: Double = 2) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let samples = sine(freq, seconds: seconds, amp: 0.25)
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    buf.floatChannelData![0].update(from: samples, count: samples.count)
    try file.write(from: buf)
}

/// Two tone clips, the first panned front left, the second rear right.
private func surroundProject(_ dir: URL, layout: AudioLayout) async throws -> Project {
    let a = dir.appendingPathComponent("a.caf"), b = dir.appendingPathComponent("b.caf")
    try writeTone(a, freq: 440)
    try writeTone(b, freq: 660)
    var p = Project(name: "Surround", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(a, id: "a"), try await MediaProbe.probe(b, id: "b")]
    p.master.layout = layout
    var c1 = Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 1)
    try c1.set("audio.pan_x", .number(-1))
    var c2 = Clip(id: "c2", kind: .media, mediaId: "b", start: 1, duration: 1)
    try c2.set("audio.pan_x", .number(1))
    try c2.set("audio.pan_y", .number(-1))
    p.tracks[1].clips = [c1, c2]
    return p
}

/// Per-channel RMS of a file's audio over two windows, read in `layout`'s order.
private func channelLevels(_ url: URL, layout: AudioLayout, windows: [TimeRange]) async throws -> [[Double]] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let n = layout.channelCount
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: n,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        AVChannelLayoutKey: layout.channelLayoutData,
    ])
    reader.add(out)
    #expect(reader.startReading())
    var samples: [[Float]] = Array(repeating: [], count: n)
    while let s = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(s) {
        let count = CMBlockBufferGetDataLength(block) / 4
        var data = [Float](repeating: 0, count: count)
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
        for i in 0..<(count / n) { for c in 0..<n { samples[c].append(data[i * n + c]) } }
    }
    return windows.map { w in samples.map { rms($0[Int(w.start * 48_000)..<min($0.count, Int(w.end * 48_000))]) } }
}

private func formatInfo(_ url: URL) async throws -> (channels: Int, tag: AudioChannelLayoutTag?) {
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
    let fd = try #require(try await track.load(.formatDescriptions).first)
    let channels = Int(CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee.mChannelsPerFrame ?? 0)
    var size = 0
    let tag = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size)?.pointee.mChannelLayoutTag
    return (channels, tag)
}

/// The loudest channel carries nearly all the energy.
private func dominant(_ levels: [Double], _ channel: Int) -> Bool {
    let total = levels.reduce(0) { $0 + $1 * $1 }
    return total > 1e-6 && levels[channel] * levels[channel] / total > 0.95
}

@Test func exports51WithPannedClipsInTheirChannels() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-surround-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = try await surroundProject(dir, layout: .surround51)
    let library = MediaLibrary()
    let stems = AudioStems(directory: dir.appendingPathComponent("stems"))

    let dry = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    #expect(dry.missingStems == ["layout"] && dry.surround == nil)
    let mixURL = try await SurroundMix.renderSurround(p, library: library, stems: stems)
    #expect(try await formatInfo(mixURL) == (6, kAudioChannelLayoutTag_MPEG_5_1_A))
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    #expect(built.missingStems.isEmpty && built.surround == mixURL)

    let windows = [TimeRange(0.1, 0.9), TimeRange(1.1, 1.9)]
    let stem = try await channelLevels(mixURL, layout: .surround51, windows: windows)
    #expect(dominant(stem[0], 0), "front left lands in L: \(stem[0])")
    #expect(dominant(stem[1], 5), "rear right lands in Rs: \(stem[1])")
    // A mono tone panned to one speaker keeps its level there.
    #expect(abs(stem[0][0] - 0.25 / 2.0.squareRoot()) < 0.01, "L rms \(stem[0][0])")

    // Preview plays the BS.775 stereo fold-down: Rs reaches the right side at −3 dB.
    let fold = try await channelLevels(try #require(stems.cachedLayoutMix(for: p)?.foldDown), layout: .stereo, windows: windows)
    let left = [fold[0][0], fold[1][0]], right = [fold[0][1], fold[1][1]]
    #expect(left[0] > 0.15 && right[0] < 0.001 && left[1] < 0.001)
    #expect(abs(right[1] - stem[1][5] * 0.5.squareRoot()) < 0.005)

    let loud = try await LoudnessMeter.measure(built)
    #expect(loud.integrated.isFinite && loud.integrated > -40, "\(loud.summary)")

    for preset in [ExportPreset.h264, .prores] {
        let url = dir.appendingPathComponent("out-\(preset.rawValue).\(preset.fileExtension)")
        try await Exporter.export(built, to: url, options: ExportOptions(preset: preset))
        let info = try await formatInfo(url)
        #expect(info.channels == 6, "\(preset.rawValue): \(info.channels) channels")
        let levels = try await channelLevels(url, layout: .surround51, windows: windows)
        #expect(dominant(levels[0], 0), "\(preset.rawValue) front left: \(levels[0])")
        #expect(dominant(levels[1], 5), "\(preset.rawValue) rear right: \(levels[1])")
    }
    // A range export starts its sound at the range start.
    let part = dir.appendingPathComponent("part.mov")
    try await Exporter.export(built, to: part, options: ExportOptions(preset: .prores, range: TimeRange(1, 2)))
    #expect(dominant(try await channelLevels(part, layout: .surround51, windows: [TimeRange(0.1, 0.9)])[0], 5))

    let wav = dir.appendingPathComponent("mix.wav")
    try await Delivery.audio(built, to: wav, format: .wav24)
    let wavFile = try AVAudioFile(forReading: wav)
    #expect(wavFile.fileFormat.channelCount == 6 && abs(Double(wavFile.length) / 48_000 - 2) < 1e-3)
    #expect(dominant(try await channelLevels(wav, layout: .surround51, windows: windows)[1], 5))
    for format in [Delivery.AudioFormat.alac, .aac256] {
        let url = dir.appendingPathComponent("mix-\(format.rawValue).m4a")
        try await Delivery.audio(built, to: url, format: format)
        let levels = try await channelLevels(url, layout: .surround51, windows: windows)
        #expect(dominant(levels[0], 0) && dominant(levels[1], 5), "\(format.rawValue): \(levels)")
    }
    let stereo = dir.appendingPathComponent("fold.wav")
    try Delivery.downmix(wav, to: stereo, format: .wav24)
    #expect(try AVAudioFile(forReading: stereo).fileFormat.channelCount == 2)
    let mono = dir.appendingPathComponent("mono.wav")
    try await Delivery.audio(built, to: mono, format: .wav24, layout: .mono)
    #expect(try AVAudioFile(forReading: mono).fileFormat.channelCount == 1)
}

@Test func exports71AndMono() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-surround71-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let library = MediaLibrary()
    let stems = AudioStems(directory: dir.appendingPathComponent("stems"))
    let windows = [TimeRange(0.1, 0.9), TimeRange(1.1, 1.9)]

    var p = try await surroundProject(dir, layout: .surround71)
    // Master effects run per channel pair and keep the image.
    p.master.effects = [Effect(id: "lim", type: "audio.limiter", params: [:])]
    try await stems.renderMissing(p, transcripts: [:], library: library)
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    let mix = try #require(built.surround)
    #expect(try await formatInfo(mix) == (8, kAudioChannelLayoutTag_MPEG_7_1_C))
    let stem = try await channelLevels(mix, layout: .surround71, windows: windows)
    #expect(dominant(stem[0], 0) && dominant(stem[1], 7), "\(stem)")
    for preset in [ExportPreset.prores, .hevc] {
        let url = dir.appendingPathComponent("out71-\(preset.rawValue).\(preset.fileExtension)")
        try await Exporter.export(built, to: url, options: ExportOptions(preset: preset))
        #expect(try await formatInfo(url).channels == 8)
        let levels = try await channelLevels(url, layout: .surround71, windows: windows)
        #expect(dominant(levels[0], 0) && dominant(levels[1], 7), "\(preset.rawValue): \(levels)")
    }
    await #expect(throws: EditError.self) { try await Delivery.audio(built, to: dir.appendingPathComponent("71.m4a"), format: .aac256) }

    p.master.layout = .mono
    p.master.effects = []
    try await stems.renderMissing(p, transcripts: [:], library: library)
    let monoBuilt = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    let url = dir.appendingPathComponent("mono.mp4")
    try await Exporter.export(monoBuilt, to: url, options: ExportOptions(preset: .h264))
    #expect(try await formatInfo(url).channels == 1)
    let levels = try await channelLevels(url, layout: .mono, windows: windows)
    #expect(levels[0][0] > 0.1 && levels[1][0] > 0.1, "\(levels)")
}

@Test func surroundFollowsClipsThroughTrackEffectsAndKeepsStereoWidth() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-surroundfx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let library = MediaLibrary()
    let stems = AudioStems(directory: dir.appendingPathComponent("stems"))
    let windows = [TimeRange(0.1, 0.9), TimeRange(1.1, 1.9)]

    // A track with effects is panned as its processed stereo stem, following the clip playing at each moment.
    var p = try await surroundProject(dir, layout: .surround51)
    p.tracks[1].effects = [Effect(id: "w", type: "audio.width", params: ["width": .number(1)])]
    let mix = try await SurroundMix.renderSurround(p, library: library, stems: stems)
    let levels = try await channelLevels(mix, layout: .surround51, windows: windows)
    #expect(levels[0][0] > 0.1 && levels[0][1] < 0.001 && levels[0][5] < 0.001, "\(levels[0])")
    #expect(levels[1][5] > levels[1][4] && levels[1][0] < 0.001 && levels[1][1] < 0.001, "\(levels[1])")

    // A stereo source keeps its left channel in L and its right in R.
    let st = dir.appendingPathComponent("st.caf")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let file = try AVAudioFile(forWriting: st, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
    buf.frameLength = 96_000
    buf.floatChannelData![0].update(from: sine(440, seconds: 2, amp: 0.25), count: 96_000)
    buf.floatChannelData![1].update(repeating: 0, count: 96_000)
    try file.write(from: buf)
    var q = Project(name: "Stereo", canvas: Canvas(width: 320, height: 180, fps: 30))
    q.media = [try await MediaProbe.probe(st, id: "st")]
    q.master.layout = .surround51
    q.tracks[1].clips = [Clip(id: "c", kind: .media, mediaId: "st", start: 0, duration: 2)]
    let stereo = try await channelLevels(try await SurroundMix.renderSurround(q, library: library, stems: stems), layout: .surround51, windows: windows)
    #expect(dominant(stereo[0], 0), "\(stereo[0])")
}
