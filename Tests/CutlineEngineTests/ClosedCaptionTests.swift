import AVFoundation
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let ntsc = 30000.0 / 1001

private func expectRoundTrip(_ cues: [TimedText], mode: CEA608.Mode, fps: Double = ntsc, channel: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) {
    let runs = CEA608.encode(cues, fps: fps, mode: mode, channel: channel)
    let decoded = CEA608.decode(runs, fps: fps, channel: channel)
    let frame = 1 / fps + 1e-9
    #expect(decoded.map(\.text) == cues.map(\.text), sourceLocation: sourceLocation)
    for (d, c) in zip(decoded, cues) {
        #expect(abs(d.start - c.start) <= frame, "\(c.text) starts at \(d.start), not \(c.start)", sourceLocation: sourceLocation)
        #expect(abs(d.end - c.end) <= frame, "\(c.text) ends at \(d.end), not \(c.end)", sourceLocation: sourceLocation)
    }
}

@Test func popOnRoundTripKeepsTextAndTiming() {
    expectRoundTrip([
        TimedText(start: 1, end: 2.5, text: "Hello world"),
        TimedText(start: 3, end: 5, text: "Second caption\n<i>with italics</i> and ♪ música"),
        TimedText(start: 5, end: 7, text: "Ça va? ¿Qué tal? 50% done"),
        TimedText(start: 9.2, end: 10, text: "Ünïcödé «ok» {x}*"),
        TimedText(start: 11, end: 14, text: "one\ntwo\nthree\nfour"),
        TimedText(start: 14.5, end: 16, text: "Hello <i>world</i>"),
    ], mode: .popOn)
}

@Test func rollUpRoundTripKeepsTextAndTiming() {
    let cues = [
        TimedText(start: 1, end: 2, text: "first line"),
        TimedText(start: 2, end: 3.5, text: "second line follows"),
        TimedText(start: 5, end: 6, text: "after a pause"),
    ]
    expectRoundTrip(cues, mode: .rollUp2)
    expectRoundTrip(cues, mode: .rollUp3)
}

@Test func paintOnRoundTripKeepsTextAndTiming() {
    expectRoundTrip([
        TimedText(start: 1, end: 2.5, text: "painted on\nsecond row"),
        TimedText(start: 4, end: 5, text: "again"),
    ], mode: .paintOn)
}

@Test func channelTwoIsSeparateFromChannelOne() {
    let cues = [TimedText(start: 1, end: 2, text: "CC2 text")]
    expectRoundTrip(cues, mode: .popOn, channel: 2)
    let runs = CEA608.encode(cues, fps: ntsc, channel: 2)
    #expect(CEA608.decode(runs, fps: ntsc, channel: 1).isEmpty)
    #expect(runs.flatMap(\.pairs).contains(0x1C2F))
}

@Test func popOnStreamUsesStandardCodesWithOddParity() {
    let runs = CEA608.encode([TimedText(start: 2, end: 4, text: "Hi")], fps: 30)
    let pairs = runs.flatMap(\.pairs)
    #expect(pairs.allSatisfy(CEA608.hasOddParity))
    // RCL, ENM, PAC row 15 indent 12, tab offset 3, "Hi", EOC, EDM — each control code doubled.
    #expect(pairs == [0x9420, 0x9420, 0x94AE, 0x94AE, 0x9476, 0x9476, 0x9723, 0x9723, 0xC8E9, 0x942F, 0x942F, 0x942C, 0x942C])
    #expect(runs.count == 2)
    #expect(abs(runs[0].time + 9.0 / 30 - 2) < 1e-9, "EOC lands on the cue start")
    #expect(abs(runs[1].time - 4) < 1e-9)
    #expect(CEA608.parity(0x00) == 0x80 && CEA608.parity(0x20) == 0x20 && CEA608.parity(0x14) == 0x94 && CEA608.parity(0x2C) == 0x2C)
    for b in UInt8(0)...0x7F { #expect(CEA608.parity(b).nonzeroBitCount % 2 == 1) }
}

@Test func charactersOutsideTheSetAreReplaced() {
    let decoded = CEA608.decode(CEA608.encode([TimedText(start: 1, end: 2, text: "naïve “quotes” – ok… Ōsaka 🎬 ＡＢ")], fps: ntsc), fps: ntsc)
    #expect(decoded.map(\.text) == ["naïve “quotes” - ok... Osaka AB"])
    // Extended characters follow a standard fallback that decoders back over.
    let pairs = CEA608.encode([TimedText(start: 1, end: 2, text: "Ü")], fps: ntsc).flatMap(\.pairs)
    #expect(pairs.contains(0xD580) && pairs.contains(0x92A4))
}

@Test func longCuesWrapToThirtyTwoColumnsAndFourRows() {
    let text = Array(repeating: "caption", count: 30).joined(separator: " ")
    let decoded = CEA608.decode(CEA608.encode([TimedText(start: 4, end: 9, text: text)], fps: ntsc), fps: ntsc)
    #expect(decoded.count == 2)
    #expect(decoded.allSatisfy { $0.text.split(separator: "\n").allSatisfy { $0.count <= 32 } })
    #expect(decoded.first?.text.split(separator: "\n").count == 4)
    #expect(decoded.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ") == text)
    #expect(abs(decoded[0].start - 4) < 0.05 && abs(decoded[1].end - 9) < 0.05)
}

@Test func lateCaptionsAreDelayedNotDropped() {
    let cues = [TimedText(start: 0, end: 1, text: String(repeating: "x", count: 32) + "\n" + String(repeating: "y", count: 32))]
    let decoded = CEA608.decode(CEA608.encode(cues, fps: ntsc), fps: ntsc)
    #expect(decoded.map(\.text) == [cues[0].text])
    // 40 pairs to load: shown at frame 40 and kept for at least two frames.
    #expect(abs(decoded[0].start - 40 / ntsc) < 1e-9)
    #expect(decoded[0].end > decoded[0].start)
}

@Test func sccWritesDropFrameTimecodesAndHexPairs() throws {
    let scc = CEA608.scc([TimedText(start: 1, end: 2, text: "Hi"), TimedText(start: 61, end: 62, text: "Later")], fps: ntsc)
    let lines = scc.components(separatedBy: "\n")
    #expect(lines[0] == "Scenarist_SCC V1.0")
    #expect(lines[1].isEmpty)
    let body = lines.dropFirst(2).filter { !$0.isEmpty }
    #expect(body.count == 4)
    let pattern = try Regex(#"^\d\d:\d\d:\d\d;\d\d\t[0-9a-f]{4}( [0-9a-f]{4})*$"#)
    for line in body { #expect(line.wholeMatch(of: pattern) != nil, "\(line)") }
    #expect(lines.dropFirst(2).enumerated().allSatisfy { ($0.offset % 2 == 1) == $0.element.isEmpty }, "blank line between entries")
    #expect(body[0].hasPrefix("00:00:00;21\t9420 9420 94ae 94ae"))
    #expect(body[0].hasSuffix("942f 942f"))
    #expect(body[1] == "00:00:02;00\t942c 942c")
    #expect(body[2].hasSuffix("942f 942f") && body[3] == "00:01:02;00\t942c 942c")

    // On the delivered file's timecode: program at 01:00:00;00, or 00:59:30;00 with a 30 s leader before it.
    let tc = TimecodeFormat(fps: ntsc)
    let program = CEA608.scc([TimedText(start: 1, end: 2, text: "Hi")], fps: ntsc, start: 107_892, format: tc).components(separatedBy: "\n").filter { !$0.isEmpty }
    #expect(program[1].hasPrefix("01:00:00;21\t") && program[2] == "01:00:02;00\t942c 942c", "\(program)")
    let leader = CEA608.scc([TimedText(start: 1 + 900 / ntsc, end: 2 + 900 / ntsc, text: "Hi")], fps: ntsc, start: tc.frames("00:59:30;00")!, format: tc).components(separatedBy: "\n").filter { !$0.isEmpty }
    #expect(leader[2] == "01:00:02;00\t942c 942c", "\(leader)")
    let ndf = CEA608.scc([TimedText(start: 1, end: 2, text: "Hi")], fps: ntsc, start: 108_000, format: TimecodeFormat(fps: ntsc, dropFrame: false))
    #expect(ndf.contains("\n01:00:02:00\t942c 942c"), "\(ndf)")

    #expect(CEA608.timecode(1799, fps: ntsc) == "00:00:59;29")
    #expect(CEA608.timecode(1800, fps: ntsc) == "00:01:00;02")
    #expect(CEA608.timecode(17982, fps: ntsc) == "00:10:00;00")
    #expect(CEA608.timecode(107892, fps: ntsc) == "01:00:00;00")
    #expect(CEA608.timecode(90, fps: 30) == "00:00:03:00")
    #expect(CEA608.timecode(24, fps: 24000.0 / 1001) == "00:00:01:00")
}

@Test func sampleBuffersCarryCdatAtomsPerFrame() throws {
    let runs = CEA608.encode([TimedText(start: 0.5, end: 1, text: "Hi")], fps: 30)
    let samples = try CEA608.captionSampleBuffers(runs, fps: 30, duration: 2)
    let fd = try #require(samples.first.flatMap(CMSampleBufferGetFormatDescription))
    #expect(CMFormatDescriptionGetMediaType(fd) == kCMMediaType_ClosedCaption)
    #expect(CMFormatDescriptionGetMediaSubType(fd) == kCMClosedCaptionFormatType_CEA608)
    let total = samples.reduce(0.0) { $0 + CMSampleBufferGetDuration($1).seconds }
    #expect(abs(total - 2) < 1e-9)
    let block = try #require(CMSampleBufferGetDataBuffer(samples[1]))
    var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
    #expect(bytes == [0, 0, 0, 10] + Array("cdat".utf8) + [0x94, 0x20])
}

private func captionTimeline() async throws -> BuiltTimeline {
    var p = Project(name: "Captions", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 3, color: RGBA(r: 0.2, g: 0.4, b: 0.8))]
    return try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
}

@Test(arguments: [ExportPreset.prores, .h264])
func exportEmbedsReadableClosedCaptions(_ preset: ExportPreset) async throws {
    let built = try await captionTimeline()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-cc-\(UUID().uuidString).\(preset.fileExtension)")
    defer { try? FileManager.default.removeItem(at: url) }
    let cues = [TimedText(start: 0.6, end: 1.4, text: "Hello"), TimedText(start: 1.8, end: 2.6, text: "Closed\n<i>captions</i>")]
    try await Exporter.export(built, to: url, options: ExportOptions(preset: preset, closedCaptions: cues))

    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .closedCaption).first)
    let fd = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(fd) == kCMClosedCaptionFormatType_CEA608)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)

    let decoded = CEA608.decode(try await CEA608.read(asset), fps: 30)
    #expect(decoded.map(\.text) == cues.map(\.text))
    for (d, c) in zip(decoded, cues) {
        #expect(abs(d.start - c.start) <= 1.0 / 30 + 1e-6 && abs(d.end - c.end) <= 1.0 / 30 + 1e-6, "\(d)")
    }
}
