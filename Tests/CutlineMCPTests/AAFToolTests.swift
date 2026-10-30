import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

@Test func exportWritesAnAAFThatTimelineImportReadsBack() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-aaf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeTone(dir.appendingPathComponent("tone.wav"))
    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180, "fps": 25])).isError)
    #expect(!(await box.call("media_import", ["paths": [.string(dir.appendingPathComponent("tone.wav").path)], "analyze": false])).isError)
    let added = await box.call("clip_add", ["media_id": "tone", "track": "A1", "start": 1, "source_in": 0.4, "duration": 2])
    #expect(!added.isError, "\(added.plainText)")

    let out = dir.appendingPathComponent("mix.aaf")
    let e = await box.call("export", ["path": .string(out.path), "aaf_handles": 1])
    #expect(!e.isError, "\(e.plainText)")
    #expect(e.plainText.contains("Interchange: mix.aaf (AAF)"), "\(e.plainText)")
    let data = try Data(contentsOf: out)
    #expect(AAFDocument.isAAF(data))
    let notes = try String(contentsOf: URL(fileURLWithPath: out.path + ".notes.txt"), encoding: .utf8)
    #expect(notes.contains("Not yet opened in Pro Tools, Media Composer or Resolve"), "\(notes)")
    // The tone is used from 0.4 s, so a 1 s handle stops at its start.
    #expect(notes.contains("Handles: 1 clip(s)"), "\(notes)")

    let back = await box.call("timeline_import", ["path": .string(out.path), "name": "From AAF"])
    #expect(!back.isError, "\(back.plainText)")
    #expect(back.plainText.contains("1 media matched to the project's, 0 added"), "\(back.plainText)")
    let p = try box.session.project()
    let clip = try #require(p.tracks.first { $0.kind == .audio }?.clips.first)
    #expect(clip.mediaId == "tone" && abs(clip.start - 1) < 0.02 && abs(clip.sourceIn - 0.4) < 0.02 && abs(clip.duration - 2) < 0.02, "\(clip) \(added.plainText)")

    let bad = await box.call("export", ["path": .string(dir.appendingPathComponent("x.mp4").path), "interchange": ["omf"]])
    #expect(bad.isError && bad.plainText.contains("aaf"), "\(bad.plainText)")
}
