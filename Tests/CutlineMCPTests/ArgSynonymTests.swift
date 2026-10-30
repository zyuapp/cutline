import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// Names agents reach for first, per tool or recipe, and the argument each must land on.
private let toolSynonyms: [(String, String, String)] = [
    ("batch", "ops", "operations"), ("batch", "steps", "operations"), ("batch", "edits", "operations"),
    ("project_patch", "operations", "ops"), ("project_patch", "patch", "ops"),
    ("transition_set", "clip_id", "clip"), ("transition_set", "cuts", "cut"), ("transition_set", "side", "edge"),
    ("transition_set", "kind", "type"), ("transition_set", "transition_type", "type"), ("transition_set", "options", "params"),
    ("effect_add", "parameters", "params"), ("effect_add", "settings", "params"), ("effect_add", "effect", "id"), ("effect_add", "time", "at"), ("effect_add", "per", "scope"),
    ("param_set", "values", "set"), ("param_set", "params", "set"), ("param_set", "clip", "target"), ("param_set", "clip_id", "target"),
    ("clip_add", "at", "start"), ("clip_add", "media", "media_id"), ("clip_add", "length", "duration"), ("clip_add", "track_id", "track"),
    ("text_add", "content", "text"), ("text_add", "at", "start"),
    ("captions_set", "style", "preset"), ("captions_set", "target_platform", "platform"),
    ("export", "output", "path"), ("export", "file", "path"), ("export", "filename", "path"), ("export", "codec", "preset"),
    ("track_add", "type", "kind"), ("recipe", "arguments", "args"), ("recipe", "parameters", "args"),
    ("clip_split", "time", "at"), ("clip_split", "clip", "clip_id"), ("trim", "clip", "clip_id"), ("comment_add", "time", "at"),
    ("media_import", "path", "paths"), ("media_import", "files", "paths"), ("clip_delete", "clip_id", "clip_ids"),
]

private let recipeSynonyms: [(String, String, String)] = [
    ("kinetic_text", "words", "text"), ("kinetic_text", "phrase", "text"), ("kinetic_text", "on", "timing"),
    ("match_color", "ref", "reference"), ("match_color", "reference_clip", "reference"), ("match_color", "per", "scope"), ("match_color", "clip_ids", "clips"),
    ("qualify", "clip_id", "clip"), ("qualify", "time", "at"), ("qualify", "per", "scope"),
    ("look", "style", "look"), ("whip_pan", "cuts", "cut"), ("safe_zone_fix", "target_platform", "platform"),
    ("split_at_shots", "clip_ids", "clips"), ("split_at_shots", "track_id", "track"), ("speed_ramp", "clip_id", "clip"), ("duck", "amount", "amount_db"),
]

@Test func plausibleArgumentNamesReachTheRealOnes() throws {
    let box = Toolbox()
    var misses: [String] = []
    for (tool, alias, canonical) in toolSynonyms {
        let schema = try #require(box.tools[tool]?.schema, "no tool \(tool)")
        let out = try box.resolvingAliases(tool, [alias: "x"], schema: schema)
        if out?[canonical]?.string != "x" { misses.append("\(tool) \(alias)→\(canonical): \(out?.encoded() ?? "nil")"); continue }
        do { try box.checkArguments(tool, out, schema: schema) } catch { misses.append("\(tool) \(alias): \(error.localizedDescription)") }
    }
    for (recipe, alias, canonical) in recipeSynonyms {
        let out = try box.resolvingAliases("recipe", ["name": .string(recipe), "args": [alias: "x"]], schema: box.tools["recipe"]!.schema)
        if out?["args"]?[canonical]?.string != "x" { misses.append("recipe \(recipe) \(alias)→\(canonical): \(out?.encoded() ?? "nil")"); continue }
        let refused = Toolbox.recipeArgumentProblems(recipe, out?["args"]).filter { $0.hasPrefix("doesn't take") }
        if !refused.isEmpty { misses.append("recipe \(recipe) \(alias): \(refused)") }
    }
    #expect(misses.isEmpty, "\(misses.joined(separator: "\n"))")
}

@Test func batchOperationsTakeOtherSpellings() throws {
    let box = Toolbox()
    let schema = box.tools["batch"]!.schema
    let out = try #require(try box.resolvingAliases("batch", ["ops": [["name": "clip_split", "arguments": ["time": 1, "clip": "c1"]]]], schema: schema))
    let op = out["operations"]?.array?.first
    #expect(op?["tool"]?.string == "clip_split" && op?["args"]?["at"]?.double == 1 && op?["args"]?["clip_id"]?.string == "c1", "\(out.encoded())")
    #expect(throws: Never.self) { try box.checkArguments("batch", out, schema: schema) }
}

/// Two touching stills on V1 and a tone on A1.
private func openProject() async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-synonyms-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Synonyms", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "img", start: 0, duration: 2), Clip(id: "c2", kind: .media, mediaId: "img", start: 2, duration: 1)]
    p.tracks[1].clips = [Clip(id: "talk", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

@Test func reviewersArgumentTrapsNowWork() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }

    let batch = await box.call("batch", ["ops": [["tool": "effect_add", "args": ["target": "c1", "type": "color.curves", "params": ["all": "0,0 0.5,0.6 1,1"]]]]])
    #expect(!batch.isError, "\(batch.plainText)")
    #expect(try box.session.project().clip("c1")?.effects.first?.params["master"] == .string("0,0 0.5,0.6 1,1"))

    let patch = await box.call("project_patch", ["operations": [["op": "replace", "path": "/name", "value": "Renamed"]]])
    let renamed = try box.session.project().name
    #expect(!patch.isError && renamed == "Renamed", "\(patch.plainText)")

    let eq = await box.call("effect_add", ["target": "talk", "type": "audio.eq", "params": ["low_cut": 80, "high_cut": 12000]])
    #expect(!eq.isError, "\(eq.plainText)")
    let eqFx = try #require(try box.session.project().clip("talk")?.effects.first)
    #expect(eqFx.params["highpass_hz"] == .number(80) && eqFx.params["lowpass_hz"] == .number(12000), "\(eqFx.params)")
    let hpf = await box.call("param_set", ["target": "talk", "set": ["fx.\(eqFx.id).hpf": 100]])
    let cut = try box.session.project().clip("talk")?.effects.first?.params["highpass_hz"]
    #expect(!hpf.isError && cut == .number(100), "\(hpf.plainText)")

    let into = await box.call("transition_set", ["clip": "c2", "edge": "in", "type": "dissolve", "duration": 0.4])
    #expect(!into.isError, "\(into.plainText)")
    let tr = try #require(try box.session.project().transitions.first)
    #expect(tr.from == "c1" && tr.to == "c2")
    let out = await box.call("transition_set", ["clip_id": "c2", "edge": "out", "type": "dip"])
    let outro = try box.session.project().transitions.contains { $0.from == "c2" && $0.to == nil }
    #expect(!out.isError && outro, "\(out.plainText)")

    let sparks = await box.call("clip_add", ["generator": "particles", "params": ["preset": "confetti"], "track": "new", "start": 0, "duration": 2])
    #expect(!sparks.isError, "\(sparks.plainText)")
    let gen = try #require(try box.session.project().tracks.flatMap(\.clips).first { $0.kind == .generator })
    #expect(gen.generatorValue("sprite", at: 1) == .string("confetti") && gen.staticValue("fx.gen.rate") == .number(60))

    let words = await box.call("recipe", ["name": "kinetic_text", "args": ["start": 0.5, "text": "Big news today", "end": 2]])
    #expect(!words.isError && words.plainText.contains("3 words appear evenly"), "\(words.plainText)")
    let kinetic = try #require(try box.session.project().tracks.flatMap(\.clips).first { $0.name == "kinetic" })
    #expect(kinetic.text?.text == "Big news today" && kinetic.text?.unitTimes == [0, 0.5, 1], "\(String(describing: kinetic.text?.unitTimes))")
    let beats = await box.call("recipe", ["name": "kinetic_text", "args": ["start": 0, "words": ["one", "two"], "timing": "beats"]])
    #expect(beats.isError && beats.plainText.contains("beats"), "no music, so no beats to time to: \(beats.plainText)")
}

@Test func particlesListThePresetAndCatalogSaysSo() async throws {
    let box = Toolbox()
    let r = await box.call("catalog", ["type": "particles"])
    #expect(r.plainText.contains("preset") && r.plainText.contains("embers"), "\(r.plainText)")
}
