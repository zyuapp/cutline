import CutlineCore
import Foundation

/// Names that mean the same argument. For each tool (or recipe) the member it declares is canonical and the others
/// are rewritten to it before arguments are checked; a group the tool declares more than one member of is left
/// alone, so an alias never stands in for a different real argument.
struct ArgAliasGroup {
    let names: [String]
    /// Only these tools or recipes; nil is every one.
    var only: Set<String>? = nil
    /// Never these tools or recipes.
    var except: Set<String> = []
    /// When the tool declares none of `names`, a scalar value goes to its member of this plural group.
    var plural: [String]? = nil

    init(_ names: [String], only: Set<String>? = nil, except: Set<String> = [], plural: [String]? = nil) {
        self.names = names
        self.only = only
        self.except = except
        self.plural = plural
    }

    func applies(to tool: String) -> Bool { (only?.contains(tool) ?? true) && !except.contains(tool) }
}

extension Toolbox {
    static let argAliasGroups: [ArgAliasGroup] = [
        ArgAliasGroup(["at", "time"]),
        ArgAliasGroup(["track", "track_id"], plural: ["tracks", "track_ids"]),
        ArgAliasGroup(["tracks", "track_ids"], except: ["timeline_measure"]),
        ArgAliasGroup(["clip", "clip_id", "target"], plural: ["clips", "clip_ids"]),
        ArgAliasGroup(["clips", "clip_ids"]),
        ArgAliasGroup(["media", "media_id"], plural: ["media_ids"]),
        ArgAliasGroup(["source_in", "source_start"]),
        ArgAliasGroup(["source_out", "source_end"]),
        ArgAliasGroup(["duration", "length"]),
        ArgAliasGroup(["remove", "delete"]),
        ArgAliasGroup(["muted", "mute"]),
        ArgAliasGroup(["hidden", "hide"]),
        ArgAliasGroup(["paths", "path", "files", "file"], only: ["media_import"]),
        ArgAliasGroup(["id", "entry", "entry_id", "history_id", "version"], only: ["history"]),
        ArgAliasGroup(["comment_id", "comment", "id"], only: ["comment_reply"]),
        ArgAliasGroup(["id", "effect_id", "effect"], only: ["effect_add"]),
        ArgAliasGroup(["id", "transition_id", "transition"], only: ["transition_set"]),
        ArgAliasGroup(["operations", "ops", "steps", "edits", "patch", "patches"], only: ["batch", "project_patch"]),
        ArgAliasGroup(["cut", "cuts"], only: ["transition_set", "whip_pan"]),
        ArgAliasGroup(["edge", "side"], only: ["transition_set"]),
        ArgAliasGroup(["args", "arguments", "parameters"], only: ["recipe"]),
        ArgAliasGroup(["type", "transition_type", "kind"], only: ["transition_set"]),
        ArgAliasGroup(["params", "parameters", "settings", "options"], only: ["effect_add", "audio_bus", "transition_set"]),
        ArgAliasGroup(["set", "values", "params", "parameters"], only: ["param_set"]),
        ArgAliasGroup(["text", "words", "phrase", "content"], only: ["kinetic_text", "text_add"]),
        ArgAliasGroup(["start", "at"], only: ["clip_add", "text_add"]),
        ArgAliasGroup(["reference", "ref", "reference_clip", "match_to"], only: ["match_color", "timeline_measure"]),
        ArgAliasGroup(["look", "style"], only: ["look"]),
        ArgAliasGroup(["preset", "style"], only: ["captions_set"]),
        ArgAliasGroup(["preset", "codec"], only: ["export"]),
        ArgAliasGroup(["path", "output", "output_path", "file", "filename"], only: ["export"]),
        ArgAliasGroup(["kind", "type"], only: ["track_add"]),
        ArgAliasGroup(["platform", "target_platform"], only: ["export", "captions_set", "safe_zone_fix", "timeline_measure"]),
        ArgAliasGroup(["scope", "per"], only: ["qualify", "match_color", "effect_add"]),
        ArgAliasGroup(["timing", "on", "sync"], only: ["kinetic_text"]),
        ArgAliasGroup(["amount_db", "amount", "depth", "depth_db"], only: ["duck"]),
    ]

    /// Every alias `tool` accepts and the declared argument it stands for.
    static func argAliases(_ tool: String, declared: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for g in argAliasGroups where g.applies(to: tool) {
            let have = g.names.filter(declared.contains)
            var canonical: String?
            if have.count == 1 {
                canonical = have[0]
            } else if have.isEmpty, let plural = g.plural, argAliasGroups.first(where: { $0.names == plural })?.applies(to: tool) ?? true {
                let many = plural.filter(declared.contains)
                if many.count == 1 { canonical = many[0] }
            }
            guard let canonical else { continue }
            for n in g.names where !declared.contains(n) && out[n] == nil { out[n] = canonical }
        }
        return out
    }

    /// `args` with aliases rewritten to the names `schema` declares: the alias table, camelCase and kebab-case
    /// spellings, and path + value (or keys) for tools taking set/animate.
    static func applyingAliases(_ tool: String, _ args: JSON, schema: JSON) throws -> JSON {
        guard case .object(var o) = args, let props = schema["properties"]?.object else { return args }
        let declared = Set(props.keys)
        let table = argAliases(tool, declared: declared)
        func move(_ from: String, to: String) throws {
            guard let v = o.removeValue(forKey: from) else { return }
            if let have = o[to], have != v { throw EditError("'\(from)' is another name for '\(to)'; pass one of them") }
            o[to] = v
        }
        for k in o.keys.sorted() where !declared.contains(k) {
            let snake = snakeCase(k)
            if snake != k, declared.contains(snake) { try move(k, to: snake); continue }
            if let canonical = table[snake] { try move(k, to: canonical) }
        }
        // param_set {path, value} → {set: {path: value}}; {path, keys} → {animate: {path: keys}}.
        if !declared.contains("path"), let path = o["path"]?.string {
            let slot = !declared.contains("value") && o["value"] != nil && declared.contains("set") ? ("value", "set")
                : !declared.contains("keys") && o["keys"] != nil && declared.contains("animate") ? ("keys", "animate") : nil
            if let (from, into) = slot, let v = o.removeValue(forKey: from) {
                o["path"] = nil
                var dict = o[into]?.object ?? [:]
                if let have = dict[path], have != v { throw EditError("\(path) is in both \(into) and \(from); pass one") }
                dict[path] = v
                o[into] = .object(dict)
            }
        }
        return .object(o)
    }

    /// The call's arguments with aliases resolved for the tool, each batch operation's edit tool and the recipe.
    func resolvingAliases(_ tool: String, _ args: JSON?, schema: JSON) throws -> JSON? {
        guard var a = try args.map({ try Toolbox.applyingAliases(tool, $0, schema: schema) }) else { return nil }
        if tool == "batch", case .array(var ops)? = a["operations"] {
            for i in ops.indices {
                guard case .object(var op) = ops[i] else { continue }
                // {name, arguments} and {tool, params} are other spellings of {tool, args}.
                for (from, to) in [("name", "tool"), ("arguments", "args"), ("params", "args"), ("input", "args")] where op[to] == nil && op[from] != nil {
                    op[to] = op.removeValue(forKey: from)
                }
                ops[i] = .object(op)
                guard let name = op["tool"]?.string, let e = edits[name], let opArgs = op["args"] else { continue }
                op["args"] = try Toolbox.applyingAliases(name, opArgs, schema: Toolbox.withDryRun(e.schema))
                ops[i] = .object(op)
            }
            if case .object(var o) = a { o["operations"] = .array(ops); a = .object(o) }
        }
        if tool == "recipe", let name = a["name"]?.string, let spec = Toolbox.recipe(name), let rArgs = a["args"], case .object(var o) = a {
            o["args"] = try Toolbox.applyingAliases(name, rArgs, schema: spec.schema)
            a = .object(o)
        }
        return a
    }

    /// "time (for at), track_id (for track)" for catalog, nil when the tool takes no aliases.
    static func aliasSummary(_ tool: String, declared: Set<String>) -> String? {
        let table = argAliases(tool, declared: declared)
        guard !table.isEmpty else { return nil }
        return table.sorted { $0.key < $1.key }.map { "\($0.key) (for \($0.value))" }.joined(separator: ", ")
    }

    /// "mediaId" and "media-id" → "media_id".
    static func snakeCase(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "-" { out.append("_") } else if ch.isUppercase { out += (out.isEmpty ? "" : "_") + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }
}
