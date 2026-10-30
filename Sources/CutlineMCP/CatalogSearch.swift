import CutlineCore
import Foundation

/// A common editing task and the calls that do it.
struct HowTo {
    let title: String
    /// Other ways people ask for it.
    let keywords: String
    let summary: String
    /// (tool, JSON arguments) in order; "<clip>", "<media>"… are placeholders.
    let calls: [(String, String)]
}

/// One searchable thing: a how-to, effect, transition, generator, recipe, tool or effect parameter.
struct SearchEntry {
    enum Kind: String { case howTo = "how-to", term, effect, transition, generator, recipe, tool, param }
    let kind: Kind
    let name: String
    let keywords: String
    let text: String
    /// Lines shown under the hit: concrete calls.
    let examples: [String]
}

enum CatalogSearch {
    static let stopWords: Set<String> = [
        "a", "an", "the", "to", "of", "on", "in", "my", "i", "how", "do", "can", "with", "for", "and", "or", "is", "it", "its",
        "this", "that", "me", "you", "want", "make", "get", "use", "using", "from", "video", "clip", "footage", "some", "into",
        "at", "by", "be", "so", "what", "which", "way", "need", "should", "would", "like", "please", "all", "every",
    ]

    /// Words people use for the same thing; a query word also matches the rest of its group at reduced weight.
    static let synonyms: [[String]] = [
        ["blur", "soften", "defocus", "obscure", "censor", "anonymize", "anonymise", "pixelate", "mosaic", "redact", "privacy", "hide"],
        ["face", "head", "person", "people", "identity", "someone", "faces"],
        ["remove", "erase", "delete", "clean", "eliminate", "inpaint", "rid", "out"],
        ["logo", "watermark", "bug", "brand", "branding"],
        ["stabilize", "stabilise", "steady", "shaky", "shake", "wobble", "jitter", "handheld", "stabilization", "stabilisation"],
        ["color", "colour", "grade", "grading", "tone", "colorist"],
        ["match", "consistent", "continuity", "same", "matching"],
        ["silence", "pause", "gap", "dead", "air", "quiet", "tighten"],
        ["filler", "um", "uh", "ums", "uhs", "hesitation", "stammer"],
        ["caption", "subtitle", "srt", "vtt", "cc", "closed", "subtitles", "captions"],
        ["loudness", "lufs", "normalize", "normalise", "level", "levels", "loud"],
        ["noise", "hiss", "denoise", "background", "noisy", "static", "buzz"],
        ["slow", "slowmo", "slowmotion", "speed", "ramp", "fast", "timelapse", "faster", "slower"],
        ["fade", "dissolve", "crossfade", "transition", "fades"],
        ["title", "text", "lower", "third", "name", "headline", "typography"],
        ["vertical", "portrait", "tiktok", "reels", "shorts", "aspect", "reframe", "916", "square", "crop"],
        ["green", "chroma", "key", "keying", "bluescreen", "greenscreen"],
        ["cutout", "segment", "segmentation", "isolate", "backdrop"],
        ["follow", "track", "tracking", "attach", "stick", "pin"],
        ["zoom", "ken", "burns", "scale", "punch", "push"],
        ["beat", "rhythm", "bpm", "beats", "tempo"],
        ["sync", "align", "dual", "clap", "synchronize"],
        ["export", "render", "deliver", "output", "upload", "publish", "save"],
        ["undo", "revert", "back", "restore"],
        ["speaker", "voice", "who", "diarize", "diarization", "talker", "speakers"],
        ["music", "song", "soundtrack", "score"],
        ["duck", "ducking", "dip", "under"],
        ["skin", "beauty", "smooth", "retouch", "complexion"],
        ["bright", "brighten", "exposure", "dark", "darken", "light", "relight"],
        ["translate", "translation", "language", "foreign"],
        ["freeze", "hold", "still", "pause"],
        ["word", "words", "transcript", "flub", "mistake", "misheard"],
    ]

    /// Lowercased word stem: plural, -ing, -ed and British spellings folded.
    static func stem(_ w: String) -> String {
        var s = w.lowercased()
        if s.hasSuffix("'s") { s.removeLast(2) }
        for (a, b) in [("isation", "ize"), ("ization", "ize"), ("ise", "ize"), ("our", "or")] where s.hasSuffix(a) && s.count > a.count + 2 {
            s = String(s.dropLast(a.count)) + b
        }
        if s.hasSuffix("ies"), s.count > 4 { return String(s.dropLast(3)) + "y" }
        if s.hasSuffix("ing"), s.count > 5 { s.removeLast(3); return s }
        if s.hasSuffix("ed"), s.count > 4 { s.removeLast(2); return s }
        if s.hasSuffix("es"), s.count > 4, ["sh", "ch", "x", "ss"].contains(where: { s.dropLast(2).hasSuffix($0) }) { return String(s.dropLast(2)) }
        if s.hasSuffix("s"), !s.hasSuffix("ss"), s.count > 3 { s.removeLast() }
        return s
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !stopWords.contains($0) }.map(stem)
    }

    /// 1 for the same stem, 0.8 when one stem is a short extension of the other ("stabiliz", "stabilize").
    static func likeness(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let (s, l) = a.count < b.count ? (a, b) : (b, a)
        return s.count >= 4 && l.hasPrefix(s) && l.count - s.count <= 3 ? 0.8 : 0
    }

    static let synonymIndex: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for group in synonyms {
            let stems = Set(group.map(stem))
            for s in stems { out[s, default: []].formUnion(stems) }
        }
        return out
    }()

    /// Query word → stems it matches with their weight.
    static func expand(_ q: String) -> [(String, Double)] {
        var out = [(q, 1.0)]
        for s in synonymIndex[q] ?? [] where s != q { out.append((s, 0.6)) }
        for (key, group) in synonymIndex where key != q && likeness(key, q) > 0 { for s in group where s != q { out.append((s, 0.5)) } }
        return out
    }

    struct Indexed {
        let entry: SearchEntry
        let name: Set<String>
        let keywords: Set<String>
        let text: Set<String>
    }

    static func rank(_ query: String, in entries: [SearchEntry], limit: Int = 8) -> [SearchEntry] {
        let q = Array(NSOrderedSet(array: tokens(query))) as! [String]
        guard !q.isEmpty else { return [] }
        let indexed = entries.map { e in
            Indexed(entry: e, name: Set(tokens(e.name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " "))), keywords: Set(tokens(e.keywords)), text: Set(tokens(e.text)))
        }
        var df: [String: Int] = [:]
        for i in indexed { for t in i.name.union(i.keywords).union(i.text) { df[t, default: 0] += 1 } }
        func idf(_ t: String) -> Double { log(1 + Double(entries.count) / Double(1 + (df[t] ?? 0))) }
        let phrase = q.joined(separator: " ")
        let kindWeight: [SearchEntry.Kind: Double] = [.howTo: 1.5, .term: 1.5, .recipe: 1.2, .effect: 1.1, .transition: 1, .generator: 1, .tool: 0.9, .param: 0.6]
        var scored: [(Double, Int)] = []
        for (n, i) in indexed.enumerated() {
            var total = 0.0, matched = 0
            for word in q {
                var best = 0.0
                for (s, w) in expand(word) {
                    for (field, weight) in [(i.name, 3.0), (i.keywords, 2.5), (i.text, 1.0)] {
                        if field.contains(s) { best = max(best, weight * w * idf(s)); continue }
                        for t in field { let l = likeness(s, t); if l > 0 { best = max(best, weight * w * l * idf(t)) } }
                    }
                }
                if best > 0 { matched += 1; total += best }
            }
            guard matched > 0 else { continue }
            let coverage = Double(matched) / Double(q.count)
            var score = total * coverage * coverage * (kindWeight[i.entry.kind] ?? 1)
            let named = tokens(i.entry.name + " " + i.entry.keywords).joined(separator: " ")
            if q.count > 1, named.contains(phrase) { score *= 1.5 }
            scored.append((score, n))
        }
        scored.sort { $0.0 > $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        guard let top = scored.first?.0 else { return [] }
        return scored.prefix(limit).filter { $0.0 >= top * 0.12 }.map { entries[$0.1] }
    }
}

extension Toolbox {
    /// Every searchable entry: how-tos, effects and their parameters, transitions, generators, recipes and tools.
    func searchEntries() -> [SearchEntry] {
        var out = Toolbox.howTos.map { h in
            SearchEntry(kind: .howTo, name: h.title, keywords: h.keywords, text: h.summary, examples: h.calls.map { "\($0.0) \($0.1)" })
        }
        for t in Toolbox.editorTerms {
            out.append(SearchEntry(kind: .term, name: t.term, keywords: t.aliases, text: t.summary, examples: t.calls.map { "\($0.0) \($0.1)" }))
        }
        for t in EffectCatalog.listed {
            let first = t.params.first { $0.name != "limit" }
            let example = "effect_add {\"target\":\"<clip>\",\"type\":\"\(t.id)\"" + (first.map { ",\"params\":{\"\($0.name)\":\($0.defaultValue.jsonText)}" } ?? "") + "}"
            out.append(SearchEntry(kind: .effect, name: t.id, keywords: t.category, text: t.summary + ". " + t.params.map(\.name).joined(separator: " "), examples: [example + "  (catalog type=\(t.id) for every parameter)"]))
            for p in t.params where !EffectCatalog.limitSpecs.contains(where: { $0.name == p.name }) {
                out.append(SearchEntry(kind: .param, name: "\(t.id).\(p.name)", keywords: "", text: p.summary, examples: ["param_set {\"target\":\"<clip>\",\"set\":{\"fx.<effect id>.\(p.name)\":\(p.defaultValue.jsonText)}}"]))
            }
        }
        if let limit = EffectCatalog.type("blur.gaussian")?.params.filter({ p in EffectCatalog.limitSpecs.contains { $0.name == p.name } }) {
            for p in limit {
                out.append(SearchEntry(kind: .param, name: "<effect>.\(p.name)", keywords: "window secondary", text: p.summary, examples: ["effect_add {\"target\":\"<clip>\",\"type\":\"color.adjust\",\"params\":{\"\(p.name)\":\(p.defaultValue.jsonText)}}"]))
            }
        }
        for t in TransitionCatalog.all {
            out.append(SearchEntry(kind: .transition, name: t.id, keywords: "transition", text: t.summary, examples: ["transition_set {\"cut\":\"<clip_a>|<clip_b>\",\"type\":\"\(t.id)\",\"duration\":0.5}"]))
        }
        for t in GeneratorCatalog.all {
            out.append(SearchEntry(kind: .generator, name: t.id, keywords: "generator graphic", text: t.summary, examples: ["clip_add {\"generator\":\"\(t.id)\",\"start\":0,\"duration\":4}"]))
        }
        for r in Toolbox.recipes {
            out.append(SearchEntry(kind: .recipe, name: r.name, keywords: r.group, text: r.summary + " " + r.listedArgs.map { "\($0.name) \($0.doc)" }.joined(separator: " "),
                                   examples: ["recipe {\"name\":\"\(r.name)\",\"args\":{…}}  args: " + r.listedArgs.map(\.name).joined(separator: ", ") + " (catalog recipe=\(r.name))"]))
        }
        for name in order {
            guard let t = tools[name] else { continue }
            out.append(SearchEntry(kind: .tool, name: name, keywords: Toolbox.briefs[name]?.text ?? "", text: t.description, examples: ["catalog tool=\(name) for every argument"]))
        }
        return out
    }

    func catalogSearch(_ query: String) -> String {
        let hits = CatalogSearch.rank(query, in: searchEntries())
        guard !hits.isEmpty else { return "Nothing matches \"\(query)\". Try a task in plain words (\"blur a face\", \"remove silences\"), or call catalog with no arguments for every effect." }
        var lines = ["Best matches for \"\(query)\" (placeholders in <>):"]
        for h in hits {
            let summary = h.kind == .tool ? (Toolbox.briefs[h.name]?.text ?? h.text) : h.text
            lines.append("\(h.kind.rawValue) \(h.name): " + Toolbox.excerpt(summary, h.kind == .howTo || h.kind == .term ? 320 : 160))
            lines += h.examples.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}

extension ParamValue {
    var jsonText: String {
        switch self {
        case .number(let v): return v.rounded() == v && abs(v) < 1e9 ? String(Int(v)) : String(v)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return "\"\(s)\""
        }
    }
}
