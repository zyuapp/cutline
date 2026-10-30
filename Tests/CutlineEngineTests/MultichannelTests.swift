import AVFoundation
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg not found; brew install ffmpeg to run"

private func scratch(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func ffmpeg(_ args: [String]) async throws {
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + args)
}

/// One lavfi input per source: a sine at that frequency, or silence for 0.
private func toneInputs(_ freqs: [Double], seconds: Double) -> [String] {
    freqs.flatMap { f in ["-f", "lavfi", "-i", f > 0 ? "sine=f=\(Int(f)):sample_rate=48000:d=\(seconds)" : "anullsrc=channel_layout=mono:sample_rate=48000:d=\(seconds)"] }
}

/// A QuickTime file with one mono PCM track per frequency.
private func monoTracks(_ url: URL, _ freqs: [Double], seconds: Double = 3) async throws {
    try await ffmpeg(toneInputs(freqs, seconds: seconds) + freqs.indices.flatMap { ["-map", "\($0):a"] } + ["-c:a", "pcm_s24le", "-t", "\(seconds)", url.path])
}

/// A poly WAV: one track with a channel per frequency.
private func polyWAV(_ url: URL, _ freqs: [Double], seconds: Double = 3) async throws {
    let labels = freqs.indices.map { "[\($0):a]" }.joined()
    try await ffmpeg(toneInputs(freqs, seconds: seconds) + ["-filter_complex", "\(labels)amerge=inputs=\(freqs.count)[a]", "-map", "[a]", "-c:a", "pcm_s24le", "-t", "\(seconds)", url.path])
}

/// Appends an iXML chunk naming the tracks, as a field recorder writes it.
private func addIXML(_ url: URL, names: [String]) throws {
    var data = try Data(contentsOf: url)
    let tracks = names.enumerated().map { "<TRACK><CHANNEL_INDEX>\($0.offset + 1)</CHANNEL_INDEX><INTERLEAVE_INDEX>\($0.offset + 1)</INTERLEAVE_INDEX><NAME>\($0.element)</NAME></TRACK>" }.joined()
    var xml = Data("<?xml version=\"1.0\"?><BWFXML><TRACK_LIST><TRACK_COUNT>\(names.count)</TRACK_COUNT>\(tracks)</TRACK_LIST></BWFXML>".utf8)
    if xml.count % 2 == 1 { xml.append(0) }
    func le(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
    data.append(Data("iXML".utf8) + le(xml.count) + xml)
    data.replaceSubrange(4..<8, with: le(data.count - 8))
    try data.write(to: url)
}

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

/// Amplitude of the `freq` component of `x` between `a` and `b` seconds.
private func tone(_ x: [Float], _ freq: Double, _ a: Seconds = 0.5, _ b: Seconds = 2.5) -> Double {
    let i0 = Int(a * 48_000), i1 = min(x.count, Int(b * 48_000))
    var re = 0.0, im = 0.0
    for i in i0..<i1 {
        let ph = 2 * .pi * freq * Double(i) / 48_000
        re += Double(x[i]) * cos(ph)
        im += Double(x[i]) * sin(ph)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(max(i1 - i0, 1))
}

private func readMono(_ url: URL) throws -> [Float] {
    let (x, _) = try AudioDSP.read(url)
    return x[0]
}

/// Renders a clip of `media` with `routing` and returns the mix.
private func routed(_ media: MediaAsset, _ routing: String, dir: URL) async throws -> (l: [Float], r: [Float]) {
    var p = Project(name: "Route", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [media]
    var c = Clip(id: "c", kind: .media, mediaId: media.id, start: 0, duration: 3)
    try c.set("audio.channels", .string(routing))
    p.tracks[1].clips = [c]
    try p.validate()
    let library = MediaLibrary(), stems = AudioStems(directory: dir.appendingPathComponent("stems"))
    #expect(try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems).missingStems == ["c"])
    try await stems.renderMissing(p, transcripts: [:], library: library)
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    #expect(built.missingStems.isEmpty)
    return try await mix(built)
}

private let freqs: [Double] = [300, 500, 700, 900]
private let level = 0.125

@Test(.enabled(if: tools != nil, skip)) func fourMonoTrackMovRoutesAnyChannel() async throws {
    let dir = try scratch("monotracks")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("cam.mov")
    try await monoTracks(url, freqs)
    let m = try await MediaProbe.probe(url, id: "cam")
    #expect(m.audioChannels?.map(\.track) == [1, 2, 3, 4])
    #expect(m.channelSummary?.hasPrefix("4 source channels in 4 mono tracks") == true, "\(m.channelSummary ?? "")")

    let ch3 = try await routed(m, "ch3", dir: dir)
    #expect(abs(tone(ch3.l, 700) - level) < 0.01 && abs(tone(ch3.r, 700) - level) < 0.01, "ch3 \(tone(ch3.l, 700))")
    #expect(tone(ch3.l, 300) < 0.002 && tone(ch3.l, 900) < 0.002)

    let pair = try await routed(m, "ch3+ch4", dir: dir)
    #expect(abs(tone(pair.l, 700) - level) < 0.01 && tone(pair.l, 900) < 0.002)
    #expect(abs(tone(pair.r, 900) - level) < 0.01 && tone(pair.r, 700) < 0.002)

    let sum = try await routed(m, "mix:1,3", dir: dir)
    for side in [sum.l, sum.r] {
        #expect(abs(tone(side, 300) - level / 2) < 0.006 && abs(tone(side, 700) - level / 2) < 0.006 && tone(side, 500) < 0.002)
    }
}

@Test(.enabled(if: tools != nil, skip)) func polyWAVChannelsAreNamedAndRoutable() async throws {
    let dir = try scratch("polywav")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("recorder.wav")
    let six: [Double] = [200, 300, 500, 700, 1100, 1300]
    try await polyWAV(url, six)
    try addIXML(url, names: ["Mix L", "Mix R", "Boom", "Lav 1", "Lav 2", "Lav 3"])
    let m = try await MediaProbe.probe(url, id: "rec")
    #expect(m.audioChannels?.count == 6 && Set(m.audioChannels!.map(\.track)) == [1])
    #expect(m.audioChannels?.map(\.name) == ["Mix L", "Mix R", "Boom", "Lav 1", "Lav 2", "Lav 3"])

    let lav2 = try await routed(m, "ch5", dir: dir)
    #expect(abs(tone(lav2.l, 1100) - level) < 0.01, "ch5 \(tone(lav2.l, 1100))")
    for f in [200.0, 300, 500, 700, 1300] { #expect(tone(lav2.l, f) < 0.002, "\(f) leaks") }
}

@Test(.enabled(if: tools != nil, skip)) func mezzanineOfMonoTrackMXFKeepsChannelNumbers() async throws {
    let dir = try scratch("mxfchannels")
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("cam.mxf")
    try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25"] + toneInputs([300, 500, 700], seconds: 3)
        + ["-t", "3", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:a", "-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "8M", "-c:a", "pcm_s24le", src.path])
    guard case .ready(let m) = try await MediaIngest.prepare(src, id: "mxf", cache: dir.appendingPathComponent("cache"), tools: tools) else { Issue.record("deferred"); return }
    // 1+2 became one stereo track; ch3 is the next track.
    #expect(m.audioChannels?.map(\.track) == [1, 1, 2], "\(String(describing: m.audioChannels))")
    let ch3 = try await routed(m, "ch3", dir: dir)
    #expect(abs(tone(ch3.l, 700) - level) < 0.01 && tone(ch3.l, 300) < 0.002 && tone(ch3.l, 500) < 0.002)
}

@Test(.enabled(if: tools != nil, skip)) func analysisAndSyncHearTheChosenChannel() async throws {
    let dir = try scratch("analysischannel")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("cam.mov")
    try await monoTracks(url, [300, 0, 700, 900])
    let m = try await MediaProbe.probe(url, id: "cam")
    let cache = dir.appendingPathComponent("cache")

    let ch3 = try #require(try await SourceChannels.analysisSource(m, channel: ChannelRouting(rawValue: "ch3"), cache: cache))
    let x = try readMono(ch3.url)
    #expect(abs(tone(x, 700) - level) < 0.01 && tone(x, 300) < 0.002 && tone(x, 900) < 0.002)

    // By default every channel with sound is heard, the silent one left out.
    let auto = try #require(try await SourceChannels.analysisSource(m, channel: nil, cache: cache))
    #expect(auto.heard.contains("ch1, ch3, ch4") && auto.heard.contains("1 silent"), "\(auto.heard)")
    let y = try readMono(auto.url)
    for f in [300.0, 700, 900] { #expect(abs(tone(y, f) - level / 3) < 0.006, "\(f): \(tone(y, f))") }
    await #expect(throws: EditError.self) { _ = try await SourceChannels.analysisSource(m, channel: ChannelRouting(rawValue: "ch6"), cache: cache) }

    // Transcription's audio analysis reads the chosen channel.
    var heard = m
    heard.path = ch3.url.path
    let levels = try await AudioAnalyzer.analyze(media: heard)
    #expect(levels.loudnessDb > -30)

    // Dual-system sync: the recorder's ch3 is the camera's sound half a second later; its other channels are unrelated noise.
    let cam = dir.appendingPathComponent("camera.mov"), rec = dir.appendingPathComponent("recorder.mov")
    try await ffmpeg(["-f", "lavfi", "-i", "anoisesrc=seed=7:d=6:sample_rate=48000:amplitude=0.3,lowpass=f=3000", "-c:a", "pcm_s24le", cam.path])
    try await ffmpeg(["-f", "lavfi", "-i", "anoisesrc=seed=1:d=6:sample_rate=48000:amplitude=0.3", "-f", "lavfi", "-i", "anoisesrc=seed=2:d=6:sample_rate=48000:amplitude=0.3",
                      "-f", "lavfi", "-i", "anoisesrc=seed=7:d=6:sample_rate=48000:amplitude=0.3,lowpass=f=3000,adelay=500", "-f", "lavfi", "-i", "anoisesrc=seed=3:d=6:sample_rate=48000:amplitude=0.3",
                      "-map", "0:a", "-map", "1:a", "-map", "2:a", "-map", "3:a", "-c:a", "pcm_s24le", "-t", "6", rec.path])
    let recMedia = try await MediaProbe.probe(rec, id: "rec")
    let source = try #require(try await SourceChannels.analysisSource(recMedia, channel: ChannelRouting(rawValue: "ch3"), cache: cache))
    let synced = try await AudioSync.offset(reference: cam, other: source.url, maxOffset: 3)
    #expect(abs(synced.offset - 0.5) < 0.01 && synced.confidence > 0.5, "\(synced)")
}

@Test(.enabled(if: tools != nil, skip)) func dnxhrInterlacedExportsAsDNxHD1080i() async throws {
    let dir = try scratch("dnxi")
    defer { try? FileManager.default.removeItem(at: dir) }
    var p = Project(name: "Fields", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 0.4, color: RGBA(r: 0.2, g: 0.4, b: 0.8))]
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
    for (preset, ext, pix) in [(ExportPreset.dnxhr_hq, "mov", "yuv422p"), (.dnxhr_hq, "mxf", "yuv422p"), (.dnxhr_hqx, "mov", "yuv422p10le"), (.dnxhr_sq, "mxf", "yuv422p")] {
        let url = dir.appendingPathComponent("\(preset.rawValue).\(ext)")
        var options = ExportOptions(preset: preset)
        options.interlaced = .tff
        try await Exporter.export(built, to: url, options: options)
        let info = try await FFmpeg.probe(url, ffprobe: try #require(tools?.ffprobe))
        #expect(info.video?.codec == "dnxhd" && info.video?.pixelFormat == pix, "\(preset) \(ext): \(String(describing: info.video))")
        let frames = try await FFmpeg.run(try #require(tools?.ffprobe), ["-v", "error", "-select_streams", "v", "-read_intervals", "%+#2", "-show_entries", "frame=interlaced_frame,top_field_first", "-of", "csv=p=0", url.path])
        let rows = frames.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(!rows.isEmpty && rows.allSatisfy { $0 == "1,1" }, "\(preset) \(ext) frames: \(rows)")
    }
    // Profiles and orders DNx can't interlace are refused before anything renders.
    for (preset, fields) in [(ExportPreset.dnxhr_hqx, FieldOrder.bff), (.dnxhr_lb, .tff)] {
        #expect(FFmpegDelivery.check(p, preset: preset, container: "mov", fields: fields) != nil)
        let url = dir.appendingPathComponent("refused-\(preset.rawValue).mov")
        var options = ExportOptions(preset: preset)
        options.interlaced = fields
        await #expect(throws: EditError.self) { try await Exporter.export(built, to: url, options: options) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    p.canvas = Canvas(width: 1280, height: 720, fps: 25)
    #expect(FFmpegDelivery.check(p, preset: .dnxhr_hq, container: "mov", fields: .tff)?.contains("1920×1080") == true)
}

@Test(.enabled(if: tools != nil, skip)) func failedExportsLeaveNoFile() async throws {
    let dir = try scratch("failedexport")
    defer { try? FileManager.default.removeItem(at: dir) }
    // ffmpeg's DNxHR encoder refuses frames this small after the intermediate rendered, so the encode itself fails.
    var p = Project(name: "Tiny", canvas: Canvas(width: 160, height: 90, fps: 25))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 0.3, color: RGBA(r: 1, g: 0, b: 0))]
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
    for ext in ["mov", "mxf"] {
        let url = dir.appendingPathComponent("tiny.\(ext)")
        try Data("old export".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await Exporter.export(built, to: url, options: ExportOptions(preset: .dnxhr_hq)) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "\(ext) left behind")
    }
    // A check that fails before writing leaves an unrelated file alone.
    let other = dir.appendingPathComponent("keep.mov")
    try Data("keep".utf8).write(to: other)
    var hdr = p
    hdr.canvas.colorSpace = .rec2020_pq
    let hdrBuilt = try await TimelineBuilder.build(hdr, transcripts: [:], library: MediaLibrary())
    await #expect(throws: EditError.self) { try await Exporter.export(hdrBuilt, to: other, options: ExportOptions(preset: .h264)) }
    #expect(FileManager.default.fileExists(atPath: other.path))
}

/// Integrated loudness and true peak of a file's first audio track.
private func loudness(of url: URL) async throws -> LoudnessReport {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(out)
    #expect(reader.startReading())
    var acc = LoudnessMeter.Accumulator()
    while let s = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(s) {
        let n = CMBlockBufferGetDataLength(block) / 8
        var data = [Float](repeating: 0, count: n * 2)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 8, destination: &data)
        data.withUnsafeBufferPointer { acc.feed($0.baseAddress!, n) }
    }
    return acc.report()
}

@Test(.enabled(if: tools != nil, skip)) func loudnessTargetHoldsAfterMixChanges() async throws {
    let dir = try scratch("loudtarget")
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("speech.wav"), spiky = dir.appendingPathComponent("spiky.wav")
    try await ffmpeg(["-f", "lavfi", "-i", "anoisesrc=seed=4:d=4:sample_rate=48000:amplitude=0.5,volume='if(lt(mod(t,1),0.6),1,0.1)':eval=frame", "-ac", "2", "-c:a", "pcm_f32le", src.path])
    // A quiet tone with sharp clicks: a wide crest factor, so a loud target needs the true-peak limiter.
    try await ffmpeg(["-f", "lavfi", "-i", "aevalsrc=0.05*sin(2*PI*440*t)+if(lt(mod(t\\,0.25)\\,0.001)\\,0.9\\,0):s=48000:d=4", "-ac", "2", "-c:a", "pcm_f32le", spiky.path])
    var p = Project(name: "Loud", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [try await MediaProbe.probe(src, id: "talk"), try await MediaProbe.probe(spiky, id: "spiky")]
    p.tracks[1].clips = [Clip(id: "c", kind: .media, mediaId: "talk", start: 0, duration: 4)]
    p.master.loudnessTarget = -23
    let library = MediaLibrary(), stems = AudioStems(directory: dir.appendingPathComponent("stems"))

    for (i, volume) in [1.0, 0.1].enumerated() {
        p.tracks[1].clips[0].volume = volume
        let built = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
        let raw = try await LoudnessMeter.measure(built)
        let wav = dir.appendingPathComponent("mix\(i).wav")
        let conform = try #require(try await Delivery.audio(built, to: wav, format: .wav24))
        #expect(abs(conform.before.integrated - raw.integrated) < 0.3)
        let delivered = try await loudness(of: wav)
        #expect(abs(delivered.integrated - -23) < 0.5, "volume \(volume): \(delivered.integrated) LUFS (\(conform.summary))")
        #expect(delivered.truePeakDb <= -1.5 + 0.2, "true peak \(delivered.truePeakDb)")
        #expect(abs(conform.after.integrated - delivered.integrated) < 0.3)
    }

    // A loud target the peaks can't take without limiting; the movie's sound meets it too.
    p.master.loudnessTarget = -12
    p.master.truePeakCeiling = -2
    p.tracks[1].clips = [Clip(id: "s", kind: .media, mediaId: "spiky", start: 0, duration: 4)]
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    let movie = dir.appendingPathComponent("loud.mov")
    let conform = try #require(try await Exporter.export(built, to: movie, options: ExportOptions(preset: .prores_proxy)))
    #expect(conform.limitedDb > 1, "\(conform.summary)")
    let delivered = try await loudness(of: movie)
    #expect(abs(delivered.integrated - -12) < 0.6, "\(delivered.integrated) (\(conform.summary))")
    #expect(delivered.truePeakDb <= -2 + 0.2, "true peak \(delivered.truePeakDb)")

    // Without a target the mix is delivered as it is.
    p.master.loudnessTarget = nil
    let plain = try await TimelineBuilder.build(p, transcripts: [:], library: library, stems: stems)
    #expect(try await Delivery.audio(plain, to: dir.appendingPathComponent("plain.wav"), format: .wav24) == nil)
}
