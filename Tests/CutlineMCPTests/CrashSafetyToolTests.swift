import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// A project with a 3 s tone on A1 whose level analysis has only quiet runs a few hundredths long.
private func choppyProject() async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-crash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writeTone(dir.appendingPathComponent("tone.wav"))
    var p = Project(name: "Crash", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("tone.wav"), id: "tone")]
    p.tracks[1].clips = [Clip(id: "a", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    var levels: [Float] = []
    while levels.count < 300 { levels += [-20, -20, -20, -60, -60, -60] }
    try b.saveAudioAnalysis(AudioAnalysis(mediaId: "tone", levelRate: 100, levels: levels, silences: [], silenceThresholdDb: -50, loudnessDb: -23))
    try b.saveTranscript(Transcript(mediaId: "tone", locale: "en-US", words: [Word(text: "Hello", start: 0.2, end: 0.8), Word(text: "there.", start: 1, end: 1.6)]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

@Test func roomToneWithShortQuietRunsReportsInsteadOfCrashing() async throws {
    let (box, dir) = try await choppyProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("recipe", ["name": "room_tone", "args": ["start": 10.1, "end": 11.7]])
    #expect(r.isError && r.plainText.contains("no quiet stretch"), "\(r.plainText)")
    let m = await box.call("recipe", ["name": "room_tone", "args": ["start": 1, "end": 2, "media": "tone"]])
    #expect(m.isError && m.plainText.contains("no quiet stretch"), "\(m.plainText)")
}

@Test func nonFiniteAndHugeNumbersAreRefused() async throws {
    let (box, dir) = try await choppyProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let huge = await box.call("param_set", ["target": "a", "set": ["audio.volume": 1e300]])
    #expect(huge.isError && huge.plainText.contains("finite number"), "\(huge.plainText)")
    for bad in ["nan", "inf", "-infinity", "1e400", "nan:00"] {
        let r = await box.call("clip_add", ["media": "tone", "track": "A1", "at": .string(bad)])
        #expect(r.isError, "\(bad): \(r.plainText)")
    }
    let anchor = await box.call("clip_add", ["media": "tone", "track": "A1", "at": "a.end+1e400"])
    #expect(anchor.isError, "\(anchor.plainText)")
    #expect(Args(["n": "nan"]).optDouble("n") == nil)
    #expect(Args(["n": 1e300]).optString("n") == "1e+300")
    #expect(Args(["n": "1e300"]).optInt("n") == nil)
}

@Test func recipesRefuseDegenerateShapes() async throws {
    let (box, dir) = try await choppyProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let thin = await box.call("recipe", ["name": "reframe", "args": ["aspect": "1:1e-300"]])
    #expect(thin.isError && thin.plainText.contains("aspect"), "\(thin.plainText)")
    let tall = await box.call("recipe", ["name": "reframe", "args": ["aspect": "9:16", "height": 100_000_000]])
    #expect(tall.isError && tall.plainText.contains("height"), "\(tall.plainText)")
}

@Test func wordEditsWithEmptyOrNegativeWordsAreRefused() async throws {
    let (box, dir) = try await choppyProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let blank = await box.call("transcript_edit", ["media_id": "tone", "insert": ["text": "  ", "start": 2, "end": 2.5], "speaker": "S1"])
    #expect(blank.isError && blank.plainText.contains("at least one word"), "\(blank.plainText)")
    let negative = await box.call("caption_edit", ["from": "tone.w-1", "to": "tone.w1", "text": "x"])
    #expect(negative.isError && negative.plainText.contains("No word"), "\(negative.plainText)")
}

@Test func negativeCountsAreTreatedAsNone() async throws {
    let (box, dir) = try await choppyProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("history", ["limit": -1])
    #expect(!r.isError, "\(r.plainText)")
}
