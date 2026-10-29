import CutlineCore
import Foundation

extension Toolbox {
    func registerPatchTool() {
        addEdit(EditTool(name: "project_patch", description: "Last resort for anything the other tools can't express: apply RFC 6902 JSON Patch operations to project.json (project_status detail=json shows it). Ops: add, remove, replace, move, copy, test; paths are JSON pointers such as /tracks/0/clips/2/transform/scale or /markers/-. The result is validated and recorded as one undoable step.", schema: Schema.object([
            "ops": ["type": "array", "description": "[{op, path, value?, from?}]", "items": ["type": "object"]],
        ], required: ["ops"]), label: { a, _ in "Patch project (\(a.raw["ops"]?.array?.count ?? 0) ops)" }) { p, args in
            guard let ops = args.raw["ops"]?.array, !ops.isEmpty else { throw EditError("Pass ops") }
            var doc = JSON.from(p)
            for (i, op) in ops.enumerated() {
                do { try JSONPatch.apply(op, to: &doc) } catch let e as EditError { throw EditError("ops[\(i)]: \(e.message)") }
            }
            let data = try JSONEncoder().encode(doc)
            do {
                p = try JSONDecoder().decode(Project.self, from: data)
            } catch let DecodingError.keyNotFound(key, ctx) {
                throw EditError("The patched project is missing \(key.stringValue) at /\(ctx.codingPath.map(\.stringValue).joined(separator: "/"))")
            } catch let DecodingError.typeMismatch(_, ctx) {
                throw EditError("Wrong type at /\(ctx.codingPath.map(\.stringValue).joined(separator: "/")): \(ctx.debugDescription)")
            } catch let DecodingError.dataCorrupted(ctx) {
                throw EditError("Invalid value at /\(ctx.codingPath.map(\.stringValue).joined(separator: "/")): \(ctx.debugDescription)")
            }
            try p.validate()
            return "Applied \(ops.count) patch operation(s)."
        })
    }
}

/// RFC 6902 over the JSON value type.
enum JSONPatch {
    static func apply(_ op: JSON, to doc: inout JSON) throws {
        guard let kind = op["op"]?.string, let path = op["path"]?.string else { throw EditError("Each op needs op and path") }
        let tokens = try pointer(path)
        switch kind {
        case "add": try set(&doc, tokens, try value(op), insert: true)
        case "replace":
            _ = try get(doc, tokens)
            try set(&doc, tokens, try value(op), insert: false)
        case "remove": try remove(&doc, tokens)
        case "move", "copy":
            guard let from = op["from"]?.string else { throw EditError("\(kind) needs from") }
            let src = try pointer(from)
            let v = try get(doc, src)
            if kind == "move" { try remove(&doc, src) }
            try set(&doc, tokens, v, insert: true)
        case "test":
            guard try get(doc, tokens) == (try value(op)) else { throw EditError("test failed at \(path)") }
        default: throw EditError("Unknown op \(kind)")
        }
    }

    static func value(_ op: JSON) throws -> JSON {
        guard case .object(let o) = op, let v = o["value"] else { throw EditError("Missing value") }
        return v
    }

    static func pointer(_ s: String) throws -> [String] {
        guard s.isEmpty || s.hasPrefix("/") else { throw EditError("Paths start with /, got \(s)") }
        return s.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    static func get(_ doc: JSON, _ tokens: [String]) throws -> JSON {
        var cur = doc
        for t in tokens {
            switch cur {
            case .object(let o):
                guard let v = o[t] else { throw EditError("No \(t) at that path") }
                cur = v
            case .array(let a):
                guard let i = Int(t), a.indices.contains(i) else { throw EditError("Index \(t) out of range (0…\(a.count - 1))") }
                cur = a[i]
            default: throw EditError("Can't descend into a value at \(t)")
            }
        }
        return cur
    }

    static func set(_ doc: inout JSON, _ tokens: [String], _ v: JSON, insert: Bool) throws {
        guard let first = tokens.first else { doc = v; return }
        let rest = Array(tokens.dropFirst())
        switch doc {
        case .object(var o):
            if rest.isEmpty { o[first] = v } else {
                guard var child = o[first] else { throw EditError("No \(first) at that path") }
                try set(&child, rest, v, insert: insert)
                o[first] = child
            }
            doc = .object(o)
        case .array(var a):
            if rest.isEmpty {
                if first == "-" { a.append(v) } else {
                    guard let i = Int(first), i >= 0, i <= a.count else { throw EditError("Index \(first) out of range") }
                    if insert { a.insert(v, at: i) } else {
                        guard i < a.count else { throw EditError("Index \(first) out of range") }
                        a[i] = v
                    }
                }
            } else {
                guard let i = Int(first), a.indices.contains(i) else { throw EditError("Index \(first) out of range") }
                var child = a[i]
                try set(&child, rest, v, insert: insert)
                a[i] = child
            }
            doc = .array(a)
        default: throw EditError("Can't set inside a value at \(first)")
        }
    }

    static func remove(_ doc: inout JSON, _ tokens: [String]) throws {
        guard let first = tokens.first else { throw EditError("Can't remove the whole project") }
        let rest = Array(tokens.dropFirst())
        switch doc {
        case .object(var o):
            if rest.isEmpty {
                guard o.removeValue(forKey: first) != nil else { throw EditError("No \(first) to remove") }
            } else {
                guard var child = o[first] else { throw EditError("No \(first) at that path") }
                try remove(&child, rest)
                o[first] = child
            }
            doc = .object(o)
        case .array(var a):
            guard let i = Int(first), a.indices.contains(i) else { throw EditError("Index \(first) out of range") }
            if rest.isEmpty { a.remove(at: i) } else {
                var child = a[i]
                try remove(&child, rest)
                a[i] = child
            }
            doc = .array(a)
        default: throw EditError("Can't remove inside a value")
        }
    }
}
