import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// tools/list as the client receives it. Before the briefs it was 69,434 bytes (≈17.4k tokens).
private let budget = 38_000

@Test func toolSchemasStayWithinTheirBudget() {
    let box = Toolbox()
    let bytes = JSON.array(box.definitions).encoded().utf8.count
    print("tools/list: \(box.definitions.count) tools, \(bytes) bytes, ≈\(bytes / 4) tokens")
    #expect(bytes <= budget, "tools/list is \(bytes) bytes, over the \(budget) budget: shorten the briefs in ToolDocs.swift and move detail to the tool's own description (catalog tool=<name>)")
}

@Test func briefsNameRealToolsAndArguments() throws {
    let box = Toolbox()
    func paths(_ s: JSON, _ prefix: String) -> Set<String> {
        var out = Set<String>()
        for (k, v) in s["properties"]?.object ?? [:] {
            let p = prefix.isEmpty ? k : prefix + "." + k
            out.insert(p)
            out.formUnion(paths(v, p))
            if let items = v["items"] {
                for sub in paths(items, "") { out.insert(p + "[]." + sub) }
            }
        }
        return out
    }
    for (name, brief) in Toolbox.briefs {
        let tool = try #require(box.tools[name], "brief for unknown tool \(name)")
        let known = paths(tool.schema, "")
        let stale = Set(brief.args.keys).union(brief.hide).subtracting(known)
        #expect(stale.isEmpty, "\(name) briefs arguments it doesn't have: \(stale.sorted())")
    }
}

@Test func catalogToolGivesTheFullManual() async {
    let box = Toolbox()
    let export = await box.call("catalog", ["tool": "export"])
    #expect(export.plainText.contains("QuickTime timecode track") && export.plainText.contains("preset (string: hevc, hevc_10bit"), "\(export.plainText)")
    let listed = box.definitions.first { $0["name"]?.string == "export" }
    #expect(listed?["description"]?.string?.contains("QuickTime timecode track") == false)
    let hidden = await box.call("catalog", ["tool": "media_analyze"])
    #expect(hidden.plainText.contains("log (string"), "hidden arguments stay documented: \(hidden.plainText)")
    let typo = await box.call("catalog", ["tool": "exprot"])
    #expect(typo.isError && typo.plainText.contains("did you mean export"), "\(typo.plainText)")
}

@Test func listingDropsLongEnumsAndDryRunText() {
    let box = Toolbox()
    let effect = box.definitions.first { $0["name"]?.string == "effect_add" }
    #expect(effect?["inputSchema"]?["properties"]?["type"]?["enum"] == nil)
    #expect(effect?["inputSchema"]?["properties"]?["dry_run"]?["description"] == nil)
    let export = box.definitions.first { $0["name"]?.string == "export" }
    #expect(export?["inputSchema"]?["properties"]?["preset"]?["enum"]?.array?.count == ExportPreset.allCases.count)
}
