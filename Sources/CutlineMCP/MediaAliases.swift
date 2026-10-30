import CutlineCore
import Foundation

extension Toolbox {
    static let mediaKeys: Set<String> = ["media_id", "media_ids", "media", "angles"]

    /// Rewrites media names an agent wrote the way the file was named ("camL", "tears_of_steel_720p.mov",
    /// "tears_of_steel_720p.w12") to project media ids, and rejects unknown media ids with the closest ones.
    static func resolveMediaAliases(_ args: JSON, media: [MediaAsset]) throws -> JSON {
        guard !media.isEmpty else { return args }
        let ids = Set(media.map(\.id))
        var aliases: [String: String] = [:]
        for m in media {
            for name in [m.id, m.name, URL(fileURLWithPath: m.path).lastPathComponent, URL(fileURLWithPath: m.path).deletingPathExtension().lastPathComponent] {
                let key = normalize(name)
                if let other = aliases[key], other != m.id { aliases[key] = "" } else { aliases[key] = m.id }
            }
        }
        func canonical(_ s: String) -> String? {
            if ids.contains(s) { return s }
            guard let id = aliases[normalize(s)], !id.isEmpty else { return nil }
            return id
        }
        func anchor(_ s: String) -> String {
            guard let dot = s.firstIndex(of: "."), !ids.contains(String(s[..<dot])) else { return s }
            var head = String(s[..<dot]), rest = s[dot...]
            // "clip.mov.w12": the extension is part of the name.
            if let second = rest.dropFirst().firstIndex(of: "."), canonical(head + String(s[dot..<second])) != nil, s[second...].dropFirst().first.map({ "wbdse".contains($0) }) == true {
                head += String(s[dot..<second])
                rest = s[second...]
            }
            guard let next = rest.dropFirst().first, "wbdse".contains(next), let id = canonical(head) else { return s }
            return id + rest
        }
        func walk(_ j: JSON, key: String?) throws -> JSON {
            switch j {
            case .string(let s):
                if let key, mediaKeys.contains(key) {
                    if let id = canonical(s) { return .string(id) }
                    if s.contains("/") { return j }
                    let near = media.map(\.id).sorted { editDistance($0, s.lowercased()) < editDistance($1, s.lowercased()) }.prefix(3)
                    throw EditError("No media \"\(s)\". Media ids: \(near.joined(separator: ", "))\(media.count > 3 ? ", …" : "")")
                }
                return .string(anchor(s))
            case .array(let a):
                return .array(try a.map { try walk($0, key: key) })
            case .object(let o):
                var out: [String: JSON] = [:]
                for (k, v) in o { out[k] = try walk(v, key: k) }
                return .object(out)
            default:
                return j
            }
        }
        return try walk(args, key: nil)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
