import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

@Test func lastReferencesWorkInAnyTool() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-last-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = dir.appendingPathComponent("still.png")
    try writePNG(png)
    let box = Toolbox()
    _ = await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false])

    let none = await box.call("effect_add", ["target": "$last_clip", "type": "stylize.vignette"])
    #expect(none.isError && none.plainText.contains("$last_clip refers to nothing yet"), "\(none.plainText)")
    let batchName = await box.call("effect_add", ["target": "$c0", "type": "stylize.vignette"])
    #expect(batchName.isError && batchName.plainText.contains("batch variable") && batchName.plainText.contains("$last_clip"), "\(batchName.plainText)")

    let imported = await box.call("media_import", ["paths": [.string(png.path)], "analyze": false])
    #expect(imported.plainText.contains("$last = "), "\(imported.plainText)")
    let media = try #require(box.session.lastRefs["last_media"])

    let added = await box.call("clip_add", ["media_id": "$last_media", "start": 0, "duration": 2])
    #expect(!added.isError, "\(added.plainText)")
    let clip = try #require(box.session.lastRefs["last_clip"])
    #expect(added.plainText.contains("$last = \(clip) (clip)"), "\(added.plainText)")
    #expect(try box.session.project().clip(clip)?.mediaId == media)

    let fx = await box.call("effect_add", ["target": "$last", "type": "stylize.vignette"])
    #expect(!fx.isError, "\(fx.plainText)")
    let effect = try #require(box.session.lastRefs["last_effect"])
    #expect(box.session.lastRefs["last"] == effect && fx.plainText.contains("$last = \(effect) (effect)"))
    let set = await box.call("param_set", ["target": "$last_clip", "set": ["fx.$last_effect.amount": 1.2]])
    #expect(!set.isError, "\(set.plainText)")
    #expect(try box.session.project().clip(clip)?.effects.first?.params["amount"] == .number(1.2))

    // Free text keeps a literal "$last".
    let title = await box.call("text_add", ["text": "$last", "start": 3, "duration": 1])
    #expect(!title.isError, "\(title.plainText)")
    #expect(try box.session.project().tracks.flatMap(\.clips).contains { $0.text?.text == "$last" })

    // Inside batch, $last follows each operation and as: names still work.
    let batch = await box.call("batch", ["operations": [
        ["tool": "clip_add", "args": ["media_id": .string(media), "start": 5, "duration": 1], "as": "b"],
        ["tool": "effect_add", "args": ["target": "$last_clip", "type": "blur.gaussian"]],
        ["tool": "param_set", "args": ["target": "$b", "set": ["opacity": 0.5]]],
    ]])
    #expect(!batch.isError, "\(batch.plainText)")
    let made = try #require(box.session.lastRefs["last_clip"])
    #expect(made != clip)
    let p = try box.session.project()
    #expect(p.clip(made)?.effects.contains { $0.type == "blur.gaussian" } == true && p.clip(made)?.transform.opacity == 0.5)
}

@Test func lastPatternLeavesOtherDollarsAlone() throws {
    let refs = ["last": "clip_a", "last_clip": "clip_a", "last_track": "V2"]
    #expect(try Toolbox.resolveLast("$last_clip.end+1", refs) == "clip_a.end+1")
    #expect(try Toolbox.resolveLast("$last_track", refs) == "V2")
    #expect(try Toolbox.resolveLast(["track_ids": ["$last_track", "A1"]], refs) == ["track_ids": ["V2", "A1"]])
    #expect(try Toolbox.resolveLast("$5 off", refs) == "$5 off")
    #expect(throws: EditError.self) { try Toolbox.resolveLast("$lastly", refs) }
}
