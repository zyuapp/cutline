import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

@Test func pinnedSpeakersShowInAnalysisRead() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-pins-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = dir.appendingPathComponent("still.png")
    try writePNG(png)
    let box = Toolbox()
    _ = await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false])
    _ = await box.call("media_import", ["paths": [.string(png.path)], "analyze": false])
    let id = try #require(box.session.lastRefs["last_media"])
    let b = try box.session.requireBundle()
    let words = (0..<6).map { Word(text: "w\($0).", start: Double($0) * 10, end: Double($0) * 10 + 0.8) }
    let t = Transcript(mediaId: id, locale: "en", words: words)
    try b.saveTranscript(t)
    var s = SpeakerAnalysis(mediaId: id, speakers: ["S1", "S2"], segments: [], wordSpeakers: ["S1", "S1", "S2", "S2", "S1", "S1"], emphasis: Array(repeating: 0, count: 6))
    s.rebuildSegments(t)
    for i in s.segments.indices { s.segments[i].confidence = 0.9; s.segments[i].identity = 0.3 }
    try b.saveAnalysis(s, id, "speakers")

    let edit = await box.call("transcript_edit", ["media_id": .string(id), "from": "w2", "to": "w3", "speaker": "Anna"])
    #expect(!edit.isError && edit.plainText.contains("pinned"), "\(edit.plainText)")
    let saved = try #require(b.analysis(SpeakerAnalysis.self, id, "speakers"))
    #expect(saved.pins == [SpeakerPin(from: 2, to: 3, speaker: "Anna")])

    let read = await box.call("analysis_read", ["media_id": .string(id), "what": "speakers"]).plainText
    #expect(read.contains("Anna (pinned"), "\(read)")
    #expect(read.contains("S1 (voice 0.90, identity 0.30)"), "\(read)")
    #expect(read.contains("Low identity"), "\(read)")
}
