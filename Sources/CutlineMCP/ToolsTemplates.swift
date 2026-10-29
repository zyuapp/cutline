import CutlineCore
import Foundation

/// A reusable piece of edit: clips with their effects and animation, relative to its start.
struct EditTemplate: Codable {
    struct Layer: Codable {
        var kind: TrackKind
        var name: String
        var clips: [Clip]
    }

    var name: String
    var summary: String
    var duration: Seconds
    var layers: [Layer]
    var transitions: [Transition]
    /// Text fields filled in on use, by placeholder name.
    var fields: [String: String]

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(Toolbox.safeName(name) + ".json") }

    static func all() -> [EditTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(EditTemplate.self, from: Data(contentsOf: $0)) }.sorted { $0.name < $1.name }
    }
}

extension Toolbox {
    func registerTemplateTool() {
        add(Tool(name: "template_save", description: "Save part of the edit as a reusable template (lower thirds, intros, transitions packs, looks): the chosen clips with their effects, animation and transitions, kept in timing relative to each other. Mark text to fill in later with fields {placeholder: clip_id}; text containing {{name}} also becomes a field. Reuse with recipe template {name, at, values}. Templates are shared across projects.", schema: Schema.object([
            "name": Schema.string("Template name"),
            "clips": Schema.strings("Clips to include"),
            "summary": Schema.string("What it is for"),
            "fields": ["type": "object", "description": "{placeholder: clip id} turns that title's text into a field"],
        ], required: ["name", "clips"])) { [unowned self] args in
            let p = try session.project()
            let ids = try args.strings("clips") ?? { throw EditError("Pass clips") }()
            var byTrack: [(Track, [Clip])] = []
            for t in p.tracks {
                let picked = t.clips.filter { ids.contains($0.id) }
                if !picked.isEmpty { byTrack.append((t, picked)) }
            }
            let found = Set(byTrack.flatMap { $0.1.map(\.id) })
            if let missing = ids.first(where: { !found.contains($0) }) { throw EditError("No clip \(missing)") }
            let start = byTrack.flatMap(\.1).map(\.start).min() ?? 0
            let end = byTrack.flatMap(\.1).map(\.end).max() ?? 0
            var fields: [String: String] = [:]
            let fieldClips = (args.raw["fields"]?.object ?? [:]).compactMapValues(\.string)
            let layers = byTrack.map { t, clips in
                EditTemplate.Layer(kind: t.kind, name: t.name, clips: clips.map { c in
                    var c = c
                    c.start -= start
                    if let key = fieldClips.first(where: { $0.value == c.id })?.key, c.text != nil {
                        fields[key] = c.text!.text
                        c.text!.text = "{{\(key)}}"
                    }
                    if let text = c.text?.text {
                        let re = try? NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#)
                        for m in re?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                            if let r = Range(m.range(at: 1), in: text), fields[String(text[r])] == nil { fields[String(text[r])] = String(text[r]) }
                        }
                    }
                    return c
                })
            }
            let transitions = p.transitions.filter { tr in [tr.from, tr.to].compactMap { $0 }.allSatisfy { found.contains($0) } }
            let tpl = EditTemplate(name: try args.string("name"), summary: args.optString("summary") ?? "", duration: end - start, layers: layers, transitions: transitions, fields: fields)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(tpl).write(to: EditTemplate.url(tpl.name))
            return .text("Saved template \"\(tpl.name)\": \(ids.count) clips on \(layers.count) layer(s), \(fmt2(tpl.duration))s" + (fields.isEmpty ? "" : ", fields " + fields.keys.sorted().joined(separator: ", ")) + ". Use recipe template {name: \"\(tpl.name)\", at: <time>\(fields.isEmpty ? "" : ", values: {...}")}.")
        })
    }

    /// Places a template at a time on new tracks above everything, filling its text fields.
    func applyTemplate(_ a: Args, dry: Bool) throws -> ToolResult {
        guard let name = a.optString("template") ?? a.optString("name") else {
            let all = EditTemplate.all()
            return .text(all.isEmpty ? "No templates yet; save one with template_save." : all.map { "\($0.name): \($0.summary.ifEmptyText("no description")) (\(fmt2($0.duration))s, fields: \($0.fields.keys.sorted().joined(separator: ", ").ifEmptyText("none")))" }.joined(separator: "\n"))
        }
        guard let data = try? Data(contentsOf: EditTemplate.url(name)), let tpl = try? JSONDecoder().decode(EditTemplate.self, from: data) else {
            throw EditError("No template \(name). Templates: \(EditTemplate.all().map(\.name).joined(separator: ", ").ifEmptyText("none"))")
        }
        let at = try a.optTime("at") ?? 0
        let values = (a.raw["values"]?.object ?? [:]).compactMapValues(\.string)
        return try runEdit("Insert template \(tpl.name)", dry: dry) { p in
            var idMap: [String: String] = [:]
            var made: [String] = []
            for layer in tpl.layers {
                let track = p.addTrack(kind: layer.kind, name: layer.name)
                for var c in layer.clips {
                    if let mid = c.mediaId, p.mediaAsset(mid) == nil { throw EditError("The template uses media \(mid), which this project doesn't have; import it with that id first") }
                    let new = Project.newClipId()
                    idMap[c.id] = new
                    c.id = new
                    c.start += at
                    if var text = c.text {
                        for (k, v) in values { text.text = text.text.replacingOccurrences(of: "{{\(k)}}", with: v) }
                        for (k, v) in tpl.fields { text.text = text.text.replacingOccurrences(of: "{{\(k)}}", with: v) }
                        c.text = text
                    }
                    try p.addClip(c, trackId: track.id, mode: .place)
                    made.append("\(new) on \(track.id)")
                }
            }
            for var tr in tpl.transitions {
                tr.id = p.nextTransitionId()
                tr.from = tr.from.flatMap { idMap[$0] }
                tr.to = tr.to.flatMap { idMap[$0] }
                p.transitions.append(tr)
            }
            return "Inserted \(tpl.name) at \(fmt2(at))s: " + made.joined(separator: ", ")
        }
    }
}
