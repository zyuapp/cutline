import CutlineCore
import Foundation

/// "$last", "$last_clip", "$last_track", "$last_media" and "$last_effect": the most recent ids tool calls in this
/// session created, usable in any argument.
extension Toolbox {
    static let lastKinds = ["clip", "effect", "track", "media"]
    /// Tools whose new ids aren't creations: they switch, reload or restore project state.
    static let notCreating: Set<String> = ["history", "project_open", "project_create", "timelines", "timeline_import"]
    static let lastPattern = try! NSRegularExpression(pattern: #"\$last(?:_(clip|track|media|effect))?(?![A-Za-z0-9_])"#)
    /// Arguments holding free text, where a "$word" is literal.
    static let literalKeys: Set<String> = ["text", "label", "name", "note", "script", "title", "description", "replacements"]

    /// Ids in `after` that `before` lacks, by kind in `lastKinds` order; clips on video tracks come first.
    static func created(_ before: Project?, _ after: Project) -> [(kind: String, ids: [String])] {
        func clips(_ p: Project) -> [String] {
            let tracks = p.tracks.filter { $0.kind == .video } + p.tracks.filter { $0.kind != .video }
            return tracks.flatMap { $0.clips.map(\.id) }
        }
        func effects(_ p: Project) -> [String] {
            p.tracks.flatMap { t in t.clips.flatMap { $0.effects.map(\.id) } + t.effects.map(\.id) } + p.master.effects.map(\.id) + p.buses.flatMap { $0.effects.map(\.id) }
        }
        let pairs: [(String, (Project) -> [String])] = [("clip", clips), ("effect", effects), ("track", { $0.tracks.map(\.id) }), ("media", { $0.media.map(\.id) })]
        return pairs.compactMap { kind, ids in
            let old = Set(before.map(ids) ?? [])
            var seen = Set<String>()
            let new = ids(after).filter { !old.contains($0) && seen.insert($0).inserted }
            return new.isEmpty ? nil : (kind, new)
        }
    }

    /// Records what a call created and describes it for the result.
    func recordCreated(_ tool: String, before: Project?, after: Project?) -> String? {
        guard let after, !Toolbox.notCreating.contains(tool) else { return nil }
        let made = Toolbox.created(before, after)
        guard let first = made.first else { return nil }
        session.lastRefs["last"] = first.ids[0]
        var parts = ["$last = \(first.ids[0]) (\(first.kind))"]
        for m in made {
            session.lastRefs["last_" + m.kind] = m.ids[0]
            if m.kind != first.kind { parts.append("$last_\(m.kind) = \(m.ids[0])") }
        }
        return parts.joined(separator: ", ")
    }

    /// `s` with "$last…" references replaced by `refs`.
    static func replacingLast(_ s: String, _ refs: [String: String]) throws -> String {
        guard s.contains("$last") else { return s }
        var out = s
        for m in lastPattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let kind = Range(m.range(at: 1), in: s).map { "last_" + s[$0] } ?? "last"
            guard let id = refs[kind] else {
                throw EditError("$\(kind) refers to nothing yet: no \(kind == "last" ? "clip, effect, track or media" : String(kind.dropFirst(5))) has been created in this session")
            }
            out.replaceSubrange(Range(m.range, in: out)!, with: id)
        }
        return out
    }

    /// `j` with "$last…" references in strings and object keys replaced by `refs` ("last", "last_clip"…). With
    /// `strict`, a "$name" (only batch binds names) is refused with a hint.
    static func resolveLast(_ j: JSON, _ refs: [String: String], key: String? = nil, strict: Bool = true) throws -> JSON {
        switch j {
        case .string(let s):
            guard s.contains("$"), !literalKeys.contains(key ?? "") else { return j }
            let out = try replacingLast(s, refs)
            if strict, out == s, s.range(of: #"^\$[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_.+-]*)?$"#, options: .regularExpression) != nil {
                throw EditError("\"\(s)\" names nothing yet: add as:\"\(s.dropFirst().split(separator: ".").first ?? "")\" to the call that creates it (any tool, or a batch operation), or use $last, $last_clip, $last_track, $last_media or $last_effect for the ids the latest calls created")
            }
            return .string(out)
        case .array(let a): return .array(try a.map { try resolveLast($0, refs, key: key, strict: strict) })
        case .object(let o):
            var out: [String: JSON] = [:]
            for (k, v) in o { out[try replacingLast(k, refs)] = try resolveLast(v, refs, key: k, strict: strict) }
            return .object(out)
        default: return j
        }
    }
}
