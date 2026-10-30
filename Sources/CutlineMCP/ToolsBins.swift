import CutlineCore
import Foundation

extension Toolbox {
    func registerBinTools() {
        addEdit(EditTool(name: "media_organize", description: "Organize the media library like an editor's bins: put media in a bin (folders with \"/\", e.g. \"Interviews/Day 1\"), set metadata columns (scene, take, camera, angle, notes or any name), rename, or set how interlaced media is shown. Browse with media_list.", schema: Schema.object([
            "media_ids": Schema.strings("Media to change"),
            "bin": Schema.string("Bin path; empty string takes them out of any bin"),
            "metadata": ["type": "object", "additionalProperties": ["type": "string"], "description": "Columns to set, e.g. {\"scene\": \"12A\", \"take\": \"3\", \"camera\": \"A\"}; empty string removes a column"],
            "name": Schema.string("New display name (one media id only)"),
            "deinterlace": Schema.string("Interlaced media: auto (default, deinterlace when interlaced) or off to keep the woven fields", values: ["auto", "off"]),
            "field_order": Schema.string("Override the detected scan: progressive, tff (top field first) or bff", values: FieldOrder.allCases.map(\.rawValue)),
        ], required: ["media_ids"]), label: { a, _ in a.optString("bin").map { "Move to bin \($0)" } ?? "Edit media metadata" }) { p, args in
            let ids = args.strings("media_ids") ?? []
            guard !ids.isEmpty else { throw EditError("Pass media_ids") }
            if args.has("name"), ids.count != 1 { throw EditError("Rename one media file at a time") }
            for id in ids {
                guard let i = p.media.firstIndex(where: { $0.id == id }) else { throw EditError("No media \(id)") }
                if let bin = args.optString("bin") {
                    let clean = bin.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
                    p.media[i].bin = clean.isEmpty ? nil : clean
                }
                if let cols = args.raw["metadata"]?.object {
                    var m = p.media[i].metadata ?? [:]
                    for (k, v) in cols {
                        let key = k.trimmingCharacters(in: .whitespaces).lowercased()
                        if let str = v.string, !str.isEmpty { m[key] = str } else if let n = v.double { m[key] = n == n.rounded() ? String(Int(n)) : String(n) } else { m.removeValue(forKey: key) }
                    }
                    p.media[i].metadata = m.isEmpty ? nil : m
                }
                if let name = args.optString("name"), !name.isEmpty { p.media[i].name = name }
                if let d = args.optString("deinterlace") { p.media[i].deinterlace = d == "off" ? false : nil }
                if let f = try args.enumValue("field_order", FieldOrder.self) { p.media[i].fieldOrder = f }
            }
            return "Updated \(ids.joined(separator: ", "))"
        })

        add(Tool(name: "media_list", description: "Browse the media library as a list view: bins, metadata columns, keywords/ratings, format and whether each file is used on the timeline. Filter by bin, search text (name, metadata, keywords and transcript), rating, keyword, kind or unused; sort by any column.", schema: Schema.object([
            "bin": Schema.string("Only this bin and its sub-bins"),
            "search": Schema.string("Text to find in names, metadata, keywords and transcripts"),
            "keyword": Schema.string("Only media with this keyword tag"),
            "rating": Schema.string("Only media with a favorite or reject range", values: ["favorite", "reject"]),
            "kind": Schema.string("Only this kind", values: ["video", "audio", "image"]),
            "unused": Schema.bool("Only media not on the timeline"),
            "sort": Schema.string("Column to sort by: name, duration, bin, or a metadata column such as scene or take"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try session.project()
            var used: [String: Int] = [:]
            for t in p.flattenedForSound { for c in t.clips { if let m = c.mediaId { used[m, default: 0] += 1 } } }
            let search = args.optString("search")?.lowercased()
            var rows = p.media.filter { m in
                if let bin = args.optString("bin"), !(m.bin == bin || (m.bin ?? "").hasPrefix(bin + "/")) { return false }
                if let k = args.optString("keyword"), !(m.tags ?? []).contains(where: { $0.label.lowercased() == k.lowercased() }) { return false }
                if let r = args.optString("rating"), !(m.tags ?? []).contains(where: { $0.rating == r }) { return false }
                switch args.optString("kind") {
                case "video": if !m.hasVideo || m.isImage { return false }
                case "audio": if m.hasVideo { return false }
                case "image": if !m.isImage { return false }
                default: break
                }
                if args.bool("unused", default: false), used[m.id] != nil { return false }
                if let q = search {
                    let fields = [m.id, m.name, m.bin ?? "", m.reel ?? ""] + (m.metadata ?? [:]).map { "\($0.key) \($0.value)" } + (m.tags ?? []).map(\.label)
                    if !fields.contains(where: { $0.lowercased().contains(q) }) {
                        guard let t = b.transcript(m.id), t.words.map(\.normalized).joined(separator: " ").contains(q) else { return false }
                    }
                }
                return true
            }
            let sort = args.optString("sort") ?? "bin"
            rows.sort { a, c in
                func key(_ m: MediaAsset) -> String {
                    switch sort {
                    case "name": m.name.lowercased()
                    case "duration": String(format: "%012.3f", m.duration)
                    case "bin": "\(m.bin ?? "~")/\(m.name.lowercased())"
                    default: m.metadata?[sort.lowercased()].map { $0.count < 6 ? String(repeating: " ", count: 6 - $0.count) + $0 : $0 } ?? "~"
                    }
                }
                return key(a) < key(c)
            }
            guard !rows.isEmpty else { return .text(p.media.isEmpty ? "No media yet; media_import adds files." : "No media match.") }
            let columns = Array(Set(rows.flatMap { ($0.metadata ?? [:]).keys })).sorted()
            var lines = ["id | name | bin | " + (columns.isEmpty ? "" : columns.joined(separator: " | ") + " | ") + "format | keywords | on timeline"]
            for m in rows {
                let format = m.isImage ? "image \(m.width)×\(m.height)" : (m.hasVideo ? "\(m.width)×\(m.height) \(fmt2(m.fps))fps \(fmt2(m.duration))s" : "audio \(fmt2(m.duration))s") + (m.log.map { " \($0.rawValue)" } ?? "") + (m.channelSummary.map { ", " + $0 } ?? "")
                let tags = (m.tags ?? []).map { $0.rating.map { r in "★\(r)" } ?? $0.label }
                let cols = columns.map { m.metadata?[$0] ?? "–" }
                lines.append(([m.id, m.name, m.bin ?? "–"] + cols + [format, tags.isEmpty ? "–" : tags.joined(separator: ", "), used[m.id].map { "\($0) clip\($0 == 1 ? "" : "s")" } ?? "unused"]).joined(separator: " | "))
            }
            let bins = Set(p.media.compactMap(\.bin)).sorted()
            if !bins.isEmpty { lines.append("Bins: " + bins.joined(separator: ", ")) }
            return .text(lines.joined(separator: "\n"))
        })
    }
}
