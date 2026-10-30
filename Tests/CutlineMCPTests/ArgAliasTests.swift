import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

private func declared(_ schema: JSON) -> Set<String> { Set(schema["properties"]?.object?.keys.map { $0 } ?? []) }

@Test func everyToolAcceptsItsAliasesAndNoneShadowsARealArgument() throws {
    let box = Toolbox()
    var checked = 0
    for name in box.order {
        let schema = box.tools[name]!.schema
        let names = declared(schema)
        for (alias, canonical) in Toolbox.argAliases(name, declared: names) {
            #expect(!names.contains(alias), "\(name): alias \(alias) is a real argument")
            #expect(names.contains(canonical), "\(name): \(alias) maps to undeclared \(canonical)")
            let out = try #require(try box.resolvingAliases(name, [alias: "x"], schema: schema))
            #expect(out[alias] == nil && out[canonical]?.string == "x", "\(name): \(alias) → \(out.encoded())")
            #expect(throws: Never.self, "\(name) refuses \(alias)") { try box.checkArguments(name, out, schema: schema) }
            checked += 1
        }
    }
    #expect(checked > 40, "the table covers the tools: \(checked)")
}

@Test func batchOperationsAndRecipesAcceptAliasesToo() throws {
    let box = Toolbox()
    for (name, e) in box.edits {
        for (alias, canonical) in Toolbox.argAliases(name, declared: declared(Toolbox.withDryRun(e.schema))) {
            let args: JSON = ["operations": [["tool": .string(name), "args": [alias: "x"]]]]
            let out = try #require(try box.resolvingAliases("batch", args, schema: box.tools["batch"]!.schema))
            let op = out["operations"]?.array?.first?["args"]
            #expect(op?[canonical]?.string == "x" && op?[alias] == nil, "batch \(name): \(alias)")
            #expect(throws: Never.self) { try box.checkArguments("batch", out, schema: box.tools["batch"]!.schema) }
        }
    }
    for spec in Toolbox.recipes {
        let names = Set(spec.args.map(\.name))
        for (alias, canonical) in Toolbox.argAliases(spec.name, declared: names) {
            #expect(!names.contains(alias), "recipe \(spec.name): alias \(alias) is a real argument")
            let out = try #require(try box.resolvingAliases("recipe", ["name": .string(spec.name), "args": [alias: "x"]], schema: box.tools["recipe"]!.schema))
            #expect(out["args"]?[canonical]?.string == "x", "recipe \(spec.name): \(alias)")
            #expect(Toolbox.recipeArgumentProblems(spec.name, out["args"]).filter { $0.hasPrefix("doesn't take") }.isEmpty, "recipe \(spec.name) refuses \(alias)")
        }
    }
}

@Test func namesAreConsistentAndOldNamesStillWork() throws {
    let box = Toolbox()
    let schema = { (n: String) in declared(box.tools[n]!.schema) }
    #expect(schema("clip_split").contains("at") && schema("comment_add").contains("at") && schema("track_update").contains("track"))
    #expect(Toolbox.argAliases("clip_split", declared: schema("clip_split"))["time"] == "at")
    #expect(Toolbox.argAliases("track_update", declared: schema("track_update"))["track_id"] == "track")
    #expect(Toolbox.argAliases("clip_delete", declared: schema("clip_delete"))["clip_id"] == "clip_ids", "a single id goes to the plural argument")
    let measure = Toolbox.argAliases("timeline_measure", declared: schema("timeline_measure"))
    #expect(measure["track_ids"] == nil && measure["track"] == nil, "tracks there is a flag, not ids")
    #expect(Toolbox.argAliases("follow", declared: Set(Toolbox.recipe("follow")!.args.map(\.name)))["clip_id"] == nil, "follow takes both clip and target")
    #expect(Toolbox.recipeArgumentProblems("freeze_frame", ["clip": "c1"]).isEmpty, "freeze_frame takes clip like speed_ramp")

    let set = try box.resolvingAliases("param_set", ["target": "c1", "path": "transform.scale", "value": 1.2], schema: box.tools["param_set"]!.schema)
    #expect(set?["set"]?["transform.scale"]?.double == 1.2 && set?["path"] == nil && set?["value"] == nil)
    let keys = try box.resolvingAliases("param_set", ["clip": "c1", "path": "audio.volume", "keys": [[0, 1], [1, 0]]], schema: box.tools["param_set"]!.schema)
    #expect(keys?["animate"]?["audio.volume"]?.array?.count == 2 && keys?["target"]?.string == "c1")
    let camel = try box.resolvingAliases("media_remove", ["mediaId": "talk"], schema: box.tools["media_remove"]!.schema)
    #expect(camel?["media_id"]?.string == "talk")
    #expect(throws: EditError.self) { try box.resolvingAliases("clip_split", ["at": 1, "time": 2], schema: box.tools["clip_split"]!.schema) }
    let catalog = Toolbox.aliasSummary("clip_split", declared: schema("clip_split"))
    #expect(catalog?.contains("time (for at)") == true)
}

@Test func aliasesWorkThroughCallsAndListingStaysCanonical() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-aliases-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeTone(dir.appendingPathComponent("tone.wav"))
    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180, "fps": 25])).isError)
    #expect(!(await box.call("media_import", ["path": .string(dir.appendingPathComponent("tone.wav").path), "analyze": false])).isError)
    let added = await box.call("clip_add", ["mediaId": "tone", "track": "A1", "start": 0])
    #expect(!added.isError, "\(added.plainText)")
    let renamed = await box.call("track_update", ["track_id": "A1", "name": "Voice"])
    let named = try box.session.project().tracks.first { $0.id == "A1" }?.name
    #expect(!renamed.isError && named == "Voice", "\(renamed.plainText)")
    let split = await box.call("clip_split", ["time": 0.5])
    #expect(!split.isError, "\(split.plainText)")
    let note = await box.call("comment_add", ["time": 0.2, "text": "check"])
    #expect(!note.isError, "\(note.plainText)")
    let batch = await box.call("batch", ["operations": [["tool": "track_update", "args": ["track_id": "A1", "muted": true]]]])
    #expect(!batch.isError, "\(batch.plainText)")
    let typo = await box.call("clip_split", ["att": 1])
    #expect(typo.isError && typo.plainText.contains("did you mean at"), "errors suggest the canonical name: \(typo.plainText)")
    let manual = await box.call("catalog", ["tool": "clip_split"])
    #expect(manual.plainText.contains("Also accepts: ") && manual.plainText.contains("time (for at)"), "\(manual.plainText)")

    let listed = box.definitions.compactMap { $0["inputSchema"]?["properties"]?.object }
    for (props, name) in zip(listed, box.order) {
        for alias in Toolbox.argAliases(name, declared: Set(props.keys)).keys {
            #expect(props[alias] == nil, "\(name) lists alias \(alias)")
        }
    }
}
