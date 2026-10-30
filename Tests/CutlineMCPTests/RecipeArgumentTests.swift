import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Recipe names handled by `case "…"` labels between two markers of a source file.
private func recipeCases(_ file: String, from start: String, to end: String) throws -> Set<String> {
    let text = try String(contentsOf: packageRoot.appendingPathComponent("Sources/CutlineMCP/\(file)"), encoding: .utf8)
    let lo = try #require(text.range(of: start)), hi = try #require(text.range(of: end, range: lo.upperBound..<text.endIndex))
    let body = String(text[lo.upperBound..<hi.lowerBound])
    var names = Set<String>()
    let line = try NSRegularExpression(pattern: #"^\s*case ("[a-z_]+"(?:, "[a-z_]+")*):"#, options: .anchorsMatchLines)
    for m in line.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
        let labels = String(body[Range(m.range(at: 1), in: body)!])
        for part in labels.split(separator: ",") { names.insert(part.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) }
    }
    return names
}

@Test func everyDispatchedRecipeHasASchemaAndBack() throws {
    let handled = try recipeCases("ToolsAudio.swift", from: #"add(Tool(name: "recipe""#, to: "func measureSound")
        .union(try recipeCases("ToolsRecipes.swift", from: "func moreRecipes(", to: "static func shotIndex"))
    #expect(handled == Set(Toolbox.recipeNames), "dispatched but undeclared: \(handled.subtracting(Toolbox.recipeNames).sorted()); declared but not dispatched: \(Set(Toolbox.recipeNames).subtracting(handled).sorted())")
    #expect(Toolbox.recipeNames.count == Set(Toolbox.recipeNames).count)
    for r in Toolbox.recipes { #expect(Toolbox.recipeDescription.contains(r.name), "\(r.name)") }
}

@Test func recipeArgumentsAreChecked() async {
    let box = Toolbox()
    let loud = await box.call("recipe", ["name": "loudness_normalize", "args": ["target": -23]])
    #expect(loud.isError && loud.plainText.contains("'args.target' (did you mean target_lufs?)"), "\(loud.plainText)")
    let ramp = await box.call("recipe", ["name": "speed_ramp", "args": ["clip": "c", "from": 1, "to": 2]])
    #expect(ramp.isError && ramp.plainText.contains("'args.from'") && ramp.plainText.contains("'args.to'"), "\(ramp.plainText)")
    let duck = await box.call("recipe", ["name": "duck", "args": ["bogus_arg": 1]])
    #expect(duck.isError && duck.plainText.contains("'args.bogus_arg' (arguments: amount_db, attack, music, release, under)"), "\(duck.plainText)")
    let kind = await box.call("recipe", ["name": "speed_ramp", "args": ["clip": "c", "speed": "fast"]])
    #expect(kind.isError && kind.plainText.contains("'speed' must be a number"), "\(kind.plainText)")
    let nested = await box.call("recipe", ["name": "beat_cut", "args": ["sources": [["media": "a", "begin": 0]]]])
    #expect(nested.plainText.contains("'args.sources[0].begin'"), "\(nested.plainText)")
    let unknown = await box.call("recipe", ["name": "duk"])
    #expect(unknown.isError && unknown.plainText.contains("did you mean duck"), "\(unknown.plainText)")
    let alias = await box.call("recipe", ["name": "template", "args": ["name": "x"]])
    #expect(!alias.plainText.contains("doesn't take"), "\(alias.plainText)")
}

@Test func catalogDescribesRecipeArguments() async {
    let box = Toolbox()
    let one = await box.call("catalog", ["recipe": "loudness_normalize"])
    #expect(one.plainText.contains("target_lufs (number)") && one.plainText.contains("ceiling_db"), "\(one.plainText)")
    let all = await box.call("catalog", ["recipe": "all"])
    #expect(all.plainText.contains("remove_object {clip, track, box") && !all.plainText.contains("name,"), "\(all.plainText)")
    let nested = await box.call("catalog", ["recipe": "multicam_switch"])
    #expect(nested.plainText.contains("    angle (string)"), "\(nested.plainText)")
}

/// A plausible value for each argument, so recipes get past their first checks.
private func sample(_ a: RecipeArg) -> JSON {
    let named: [String: JSON] = [
        "clip": "c1", "media": "tone", "audio": "tone", "edit": "c1|c2", "cut": "c1|c2", "aspect": "1:1", "look": "noir",
        "align": "fill", "corner": "top_left", "layout": "lr", "signal": "auto", "target": "face:img", "template": "missing",
        "into": "A1", "angles": ["tone", "img"], "music": ["A1"], "under": ["A1"], "clips": ["c1", "c2"], "reference": "c1",
        "speakers": ["S1": "tone"], "values": ["title": "x"], "effect": ["type": "color.wheels", "params": ["saturation": 0.1]],
        "box": ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2], "sources": [["media": "img", "start": 0, "end": 1]],
        "cuts": [["at": 1, "angle": "img"]], "source_start": 0.5, "source_end": 2, "end": 3, "target_lufs": -20, "ceiling_db": -1,
        "strength": 0.5, "x": 0.5, "y": 0.5, "play": "ch1", "channel": "ch1", "camera_channel": "ch1", "audio_channel": "ch1",
    ]
    if let v = named[a.name] { return v }
    switch a.kind {
    case .string: return "V1"
    case .number: return 0.5
    case .integer: return 1
    case .bool: return false
    case .color: return "#FF0000"
    case .time, .sourceTime: return 1
    case .ids: return ["c1"]
    case .times: return [1]
    case .object: return [:]
    case .objects: return []
    case .any: return true
    }
}

@Test func recipesOnlyReadTheArgumentsTheyDeclare() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-recipes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var project = Project(name: "Recipes", canvas: Canvas(width: 320, height: 180, fps: 30))
    project.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    project.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "img", start: 0, duration: 2), Clip(id: "c2", kind: .media, mediaId: "img", start: 2, duration: 2)]
    project.tracks[1].clips = [Clip(id: "a1", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    let bundleURL = dir.appendingPathComponent("p.cutline")
    let bundle = try ProjectBundle.create(at: bundleURL, project: project)
    try bundle.saveTranscript(Transcript(mediaId: "tone", locale: "en-US", words: [Word(text: "Hello", start: 0.2, end: 0.6), Word(text: "there.", start: 0.7, end: 1.2)]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundleURL.path)])

    for spec in Toolbox.recipes {
        let all = Dictionary(uniqueKeysWithValues: spec.listedArgs.map { ($0.name, sample($0)) })
        var calls: [[String: JSON]] = [[:], all]
        for a in spec.listedArgs { calls.append(all.filter { $0.key != a.name }) }
        var read = Set<String>()
        for args in calls {
            box.lastRecipeReads = nil
            let r = await box.call("recipe", ["name": .string(spec.name), "args": .object(args), "dry_run": true])
            #expect(!r.plainText.contains("doesn't take"), "\(spec.name): \(r.plainText)")
            read.formUnion(box.lastRecipeReads?.names ?? [])
        }
        let declared = Set(spec.args.map(\.name))
        #expect(read.isSubset(of: declared), "\(spec.name) reads undeclared \(read.subtracting(declared).sorted())")
        #expect(!read.isEmpty, "\(spec.name) read nothing")
    }
}
