import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

@Test func catalogSearchFindsTasksNotJustEffectNames() async {
    let box = Toolbox()
    let face = await box.call("catalog", ["search": "face blur"]).plainText
    let first = face.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
    #expect(first.hasPrefix("how-to Blur a face"), "\(face)")
    #expect(face.contains("\"type\":\"blur.gaussian\"") && face.contains("face:<media>.x"), "\(face)")

    /// The first `n` hits, each with its example lines.
    func top(_ query: String, _ n: Int = 3) async -> [String] {
        let text = await box.call("catalog", ["search": .string(query)]).plainText
        var hits: [String] = []
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix(" "), !hits.isEmpty { hits[hits.count - 1] += "\n" + line } else { hits.append(String(line)) }
        }
        return Array(hits.prefix(n))
    }
    let expected: [(String, String)] = [
        ("logo removal", "remove_object"), ("remove watermark", "remove_object"), ("stabilize", "distort.stabilize"),
        ("shaky footage", "Stabilize"), ("color match", "match_color"), ("anonymize faces", "Blur a face"),
        ("pixelate face", "Pixelate a face"), ("get rid of ums", "filler"), ("remove silences", "cut_silences"),
        ("french subtitles", "Translate"), ("slow motion", "speed_ramp"), ("green screen", "key.chroma"),
        ("vertical video for tiktok", "reframe"), ("music too loud under voice", "duck"), ("normalize loudness", "loudness_normalize"),
        ("blurring license plates", "license plate"), ("who is speaking", "speakers"), ("fade to black", "Fade"),
    ]
    for (query, want) in expected {
        let hits = await top(query)
        #expect(hits.contains { $0.localizedCaseInsensitiveContains(want) }, "\(query) → \(hits)")
    }
    let nothing = await box.call("catalog", ["search": "zzqx"]).plainText
    #expect(nothing.hasPrefix("Nothing matches"))
}

@Test func searchFoldsWordFormsAndSynonyms() {
    #expect(CatalogSearch.stem("blurring") == CatalogSearch.stem("blurr"))
    #expect(CatalogSearch.likeness(CatalogSearch.stem("stabilizing"), CatalogSearch.stem("stabilize")) > 0)
    #expect(CatalogSearch.stem("colour") == CatalogSearch.stem("color"))
    #expect(CatalogSearch.stem("subtitles") == "subtitle")
    #expect(CatalogSearch.expand("censor").contains { $0.0 == "blur" })
}

/// Every how-to call names a real tool with arguments it takes; effect_add calls use real effect types and parameters.
@Test func howToCallsAreValid() throws {
    let box = Toolbox()
    #expect(Toolbox.howTos.count >= 40)
    for h in Toolbox.howTos {
        #expect(!h.calls.isEmpty, "\(h.title)")
        for (tool, json) in h.calls {
            let args = try JSONDecoder().decode(JSON.self, from: Data(json.utf8))
            let schema = try #require(box.tools[tool]?.schema, "\(h.title): no tool \(tool)")
            let unknown = Toolbox.unknownArguments(args, schema: schema, path: "")
            #expect(unknown.isEmpty, "\(h.title): \(tool) \(unknown)")
            if tool == "recipe", let name = args["name"]?.string {
                #expect(Toolbox.recipeArgumentProblems(name, args["args"]).isEmpty, "\(h.title): \(Toolbox.recipeArgumentProblems(name, args["args"]))")
            }
            if tool == "effect_add", let type = args["type"]?.string {
                let t = try #require(EffectCatalog.type(type), "\(h.title): no effect \(type)")
                for k in args["params"]?.object?.keys.sorted() ?? [] {
                    #expect(t.params.contains { $0.name == k }, "\(h.title): \(type) has no \(k)")
                }
            }
        }
    }
}
