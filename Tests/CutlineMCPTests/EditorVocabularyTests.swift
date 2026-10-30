import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

/// The first `n` hits of a catalog search, each with its example lines.
private func top(_ box: Toolbox, _ query: String, _ n: Int = 3) async -> [String] {
    let text = await box.call("catalog", ["search": .string(query)]).plainText
    var hits: [String] = []
    for line in text.split(separator: "\n").dropFirst() {
        if line.hasPrefix(" "), !hits.isEmpty { hits[hits.count - 1] += "\n" + line } else { hits.append(String(line)) }
    }
    return Array(hits.prefix(n))
}

@Test func editorVocabularyFindsTheFeatureBehindEachTerm() async {
    let box = Toolbox()
    let expected: [(String, String)] = [
        ("proxy", "media_organize"), ("proxy", "playback"), ("compound clip", "sequence_nest"), ("nested sequence", "sequence_nest"),
        ("imf", "Not available"), ("dolby vision", "Not available"), ("dcp", "Not available"),
        ("three point edit insert overwrite", "\"mode\":\"overwrite\""), ("three point edit insert overwrite", "insert ripples"),
        ("replace edit", "clip_update"), ("burn in timecode", "timecode_burn"), ("surround 5.1 mix", "surround51"),
        ("roles", "role"), ("subroles", "audio.role"), ("j cut", "split_edit"), ("l-cut", "split_edit"), ("ripple", "\"mode\":\"ripple\""),
        ("roll edit", "\"mode\":\"roll\""), ("slip", "\"mode\":\"slip\""), ("slide", "\"mode\":\"slide\""), ("lift", "\"ripple\":false"),
        ("extract", "range_delete"), ("match frame", "media_frames"), ("fit to fill", "allow_stretch"), ("storyline", "track"),
        ("adjustment layer", "adjustment"), ("power window", "limit"), ("node", "node_mode"), ("lut", "color.lut"),
        ("cst color space transform", "log"), ("scopes", "scopes"), ("waveform vectorscope", "scopes"), ("stems", "stems"),
        ("deliverables", "variants"), ("render queue", "variants"), ("multicam", "multicam_create"), ("rolling credits", "credits"),
        ("luma key", "key.luma"), ("difference key", "key.difference"), ("sky replacement", "sky_replace"), ("optimized media", "proxy"),
        ("aaf omf turnover", "aaf"), ("bars and tone slate", "leader"), ("warp stabilizer", "distort.stabilize"), ("content aware fill", "remove_object"),
        ("fusion", "Not available"), ("ofx plugin", "Not available"), ("mogrt", "template"), ("trim paths", "fx.gen.ring.trim_end"),
    ]
    for (query, want) in expected {
        let hits = await top(box, query)
        #expect(hits.contains { $0.localizedCaseInsensitiveContains(want) }, "\(query) → \(hits)")
    }
}

/// Every term's calls name real tools with arguments they take; recipes and effects get real arguments.
@Test func editorTermCallsAreValid() throws {
    let box = Toolbox()
    #expect(Toolbox.editorTerms.count >= 80, "\(Toolbox.editorTerms.count) terms")
    var names = Set<String>()
    for t in Toolbox.editorTerms {
        #expect(names.insert(t.term).inserted, "duplicate term \(t.term)")
        #expect(!t.calls.isEmpty, "\(t.term)")
        for (tool, json) in t.calls {
            let args = try JSONDecoder().decode(JSON.self, from: Data(json.utf8))
            let schema = try #require(box.tools[tool]?.schema, "\(t.term): no tool \(tool)")
            let unknown = Toolbox.unknownArguments(args, schema: schema, path: "")
            #expect(unknown.isEmpty, "\(t.term): \(tool) \(unknown)")
            if tool == "recipe", let name = args["name"]?.string {
                #expect(Toolbox.recipeArgumentProblems(name, args["args"]).isEmpty, "\(t.term): \(Toolbox.recipeArgumentProblems(name, args["args"]))")
            }
            if tool == "effect_add", let type = args["type"]?.string {
                let e = try #require(EffectCatalog.type(type), "\(t.term): no effect \(type)")
                for k in args["params"]?.object?.keys.sorted() ?? [] { #expect(e.params.contains { $0.name == k }, "\(t.term): \(type) has no \(k)") }
            }
            if tool == "clip_add", let gen = args["generator"]?.string {
                let g = try #require(GeneratorCatalog.type(gen), "\(t.term): no generator \(gen)")
                for k in args["params"]?.object?.keys.sorted() ?? [] { #expect(g.params.contains { $0.name == k }, "\(t.term): \(gen) has no \(k)") }
            }
        }
    }
}

@Test func catalogOverviewNamesShapeLayerPaths() async {
    let overview = await Toolbox().call("catalog", [:]).plainText
    #expect(overview.contains("fx.gen.<shape id>.<property>"), "\(overview.prefix(200))")
}
