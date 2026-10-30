import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open project: a still on V1 and a transcribed tone on A1 in two clips, "Hello there. … Next part."
private func openProject(fps: Double = 25, _ body: (inout Project) -> Void = { _ in }) async throws -> (Toolbox, ProjectBundle, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-cuts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Cuts", canvas: Canvas(width: 320, height: 180, fps: fps))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = [Clip(id: "pic", kind: .media, mediaId: "img", start: 0, duration: 3)]
    p.tracks[1].name = "Interview"
    p.tracks[1].clips = [Clip(id: "talk1", kind: .media, mediaId: "tone", start: 0, duration: 1.5), Clip(id: "talk2", kind: .media, mediaId: "tone", start: 1.5, duration: 1.5, sourceIn: 1.5)]
    body(&p)
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    try b.saveTranscript(Transcript(mediaId: "tone", locale: "en-US", words: [
        Word(text: "Hello", start: 0.2, end: 0.6), Word(text: "there.", start: 0.7, end: 1.2), Word(text: "Next", start: 1.7, end: 2.1), Word(text: "part.", start: 2.2, end: 2.6),
    ]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, b, dir)
}

@Test func exportWithVariantsRendersTheBaseToo() async throws {
    let (box, _, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let base = dir.appendingPathComponent("out/dlg.mp4"), vertical = dir.appendingPathComponent("out/dlg_vertical.mp4")
    let r = await box.call("export", ["path": .string(base.path), "variants": [["name": "vertical", "path": .string(vertical.path), "ops": [["tool": "canvas_set", "args": ["preset": "vertical"]]]]]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(FileManager.default.fileExists(atPath: base.path) && FileManager.default.fileExists(atPath: vertical.path), "\(r.plainText)")
    #expect(r.plainText.contains("Files written (2)") && r.plainText.contains(base.path) && r.plainText.contains(vertical.path), "\(r.plainText)")

    try FileManager.default.removeItem(at: base)
    let skip = await box.call("export", ["path": .string(base.path), "base": false, "variants": [["name": "vertical", "path": .string(vertical.path), "ops": []]]])
    #expect(!skip.isError && !FileManager.default.fileExists(atPath: base.path), "\(skip.plainText)")
    #expect(skip.plainText.contains("Files written (1)"), "\(skip.plainText)")
}

@Test func interlacedExportRefusesOtherRates() async throws {
    let (box, _, dir) = try await openProject(fps: 24)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("i.mov")
    let r = await box.call("export", ["preset": "prores_hq", "interlaced": "tff", "path": .string(out.path)])
    #expect(r.isError && r.plainText.contains("48 fields") && r.plainText.contains("canvas_set fps:25"), "\(r.plainText)")
    #expect(!FileManager.default.fileExists(atPath: out.path))
}

@Test func timelineTranscriptReadsNestedSequences() async throws {
    let (box, _, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nest = await box.call("sequence_nest", ["clips": ["talk1", "talk2"]])
    #expect(!nest.isError, "\(nest.plainText)")
    let r = await box.call("timeline_transcript", [:])
    let text = r.plainText
    #expect(text.contains("Hello there.") && text.contains("Next part."), "\(text)")
    #expect(text.contains("/talk1 on A1 in nested") && text.contains("4 words"), "\(text)")
}

@Test func deletingTheNextClipReportsSplitEdits() async throws {
    let (box, _, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    // talk1's sound runs 0.2 s under talk2 (an L cut); deleting talk2 keeps it.
    _ = await box.call("param_set", ["target": "talk2", "set": ["audio.lead": -0.2]])
    _ = await box.call("param_set", ["target": "talk1", "set": ["audio.lag": 0.2]])
    let lift = await box.call("clip_delete", ["clip_ids": ["talk2"], "dry_run": true])
    #expect(!lift.isError && !lift.plainText.contains("audio.lag"), "\(lift.plainText)")
    // J cut: talk2's sound starts under talk1, which stops early for it; deleting talk2 gives talk1 its sound back.
    _ = await box.call("param_set", ["target": "talk2", "set": ["audio.lead": 0.2]])
    _ = await box.call("param_set", ["target": "talk1", "set": ["audio.lag": -0.2]])
    let r = await box.call("clip_delete", ["clip_ids": ["talk2"]])
    #expect(r.plainText.contains("Split edits: talk1 sound end: 0.20s before its picture ends → at the picture cut"), "\(r.plainText)")
}

@Test func assemblePadsWordsAndCutSilencesFindsSpeechPauses() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("assemble", ["track": "A1", "replace": true, "segments": [["media_id": "tone", "start": 0.7, "end": 2.1]]])
    #expect(!r.isError && r.plainText.contains("Handles: 1 segment"), "\(r.plainText)")
    let clip = try #require(b.loadProject().tracks[1].clips.first)
    // 0.08 s before "there." (0.62, after "Hello" ends at 0.6) and up to "part." at 2.2, in whole frames.
    #expect(abs(clip.sourceIn - 0.62) < 1e-6 && clip.sourceOut >= 2.1 && clip.sourceOut <= 2.2 + 1e-6, "\(clip.sourceIn)–\(clip.sourceOut)")
    let bare = await box.call("assemble", ["track": "A1", "replace": true, "pad": 0, "segments": [["media_id": "tone", "start": 0.7, "end": 2.1]]])
    #expect(!bare.plainText.contains("Handles"), "\(bare.plainText)")

    // The tone never goes quiet, but the transcript has a 0.5 s pause between "there." and "Next".
    let level = await box.call("cut_silences", ["media_id": "tone", "by": "level", "min_pause": 0.4])
    #expect(level.isError, "\(level.plainText)")
    let speech = await box.call("cut_silences", ["media_id": "tone", "min_pause": 0.4, "keep": 0.1])
    #expect(!speech.isError && speech.plainText.contains("1 pauses ≥0.40s from gaps between transcribed words"), "\(speech.plainText)")
}

@Test func mediaRelinkFindsMovedFilesByName() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let moved = dir.appendingPathComponent("moved/deep", isDirectory: true)
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: dir.appendingPathComponent("tone.caf"), to: moved.appendingPathComponent("tone.caf"))
    try FileManager.default.moveItem(at: dir.appendingPathComponent("img.png"), to: dir.appendingPathComponent("elsewhere.png"))
    let r = await box.call("media_relink", ["folder": .string(dir.appendingPathComponent("moved").path)])
    #expect(!r.isError && r.plainText.contains("Relinked 1 of 2") && r.plainText.contains("tone → \(moved.appendingPathComponent("tone.caf").path) (by file name)"), "\(r.plainText)")
    #expect(r.plainText.contains("Still offline (1): img"), "\(r.plainText)")
    #expect(try b.loadProject().mediaAsset("tone")?.path == moved.appendingPathComponent("tone.caf").path)
}

@Test func readmeListsEveryTool() throws {
    let readme = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../README.md").standardizedFileURL, encoding: .utf8)
    let names = Toolbox().order
    #expect(readme.contains("\(names.count) MCP tools"), "README should say \(names.count) MCP tools")
    let missing = names.filter { !readme.contains("`\($0)`") }
    #expect(missing.isEmpty, "README's tool table is missing \(missing)")
}
