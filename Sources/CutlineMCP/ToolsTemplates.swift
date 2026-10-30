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

    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        let dir = directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/templates", isDirectory: true)
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
        add(Tool(name: "template_save", description: "Save part of the edit as a reusable template (lower thirds, intros, transitions packs, looks): the chosen clips with their effects, animation and transitions, kept in timing relative to each other. Mark text to fill in later with fields {placeholder: clip_id}; text containing {{name}} also becomes a field. Reuse with recipe template {name, at, values}. Templates are shared across projects. A studio's graphics package travels as files: export writes templates to a .cutline-template file (or one per template into a folder) and import reads such files or folders into this machine's templates.", schema: Schema.object([
            "name": Schema.string("Template name; with export alone, the saved template to export"),
            "clips": Schema.strings("Clips to include"),
            "summary": Schema.string("What it is for"),
            "fields": ["type": "object", "description": "{placeholder: clip id} turns that title's text into a field"],
            "export": Schema.string("Write the template (just saved from clips, or the saved one named name; every saved template without either) to this .cutline-template file, or one file per template into this folder"),
            "import": Schema.string("Read templates from a .cutline-template or template .json file, or every such file in a folder, into the saved templates; name renames a single one"),
        ])) { [unowned self] args in
            if let path = args.optString("import") { return .text(try importTemplates(path, rename: args.optString("name"))) }
            guard let ids = args.strings("clips"), !ids.isEmpty else {
                guard let path = args.optString("export") else { throw EditError("Pass name and clips to save a template, export to write saved templates to a file, or import to read them") }
                return .text(try exportTemplates(args.optString("name").map { [$0] }, to: path))
            }
            let p = try session.project()
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
                    // Placeholders in titles and in graphics' text parameters (lower thirds, text on a path…).
                    let texts = [c.text?.text].compactMap { $0 } + c.effects.filter { GeneratorCatalog.type($0.type) != nil }.flatMap { $0.params.values.compactMap(\.string) }
                    let re = try? NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#)
                    for text in texts {
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
            var text = "Saved template \"\(tpl.name)\": \(ids.count) clips on \(layers.count) layer(s), \(fmt2(tpl.duration))s" + (fields.isEmpty ? "" : ", fields " + fields.keys.sorted().joined(separator: ", ")) + ". Use recipe template {name: \"\(tpl.name)\", at: <time>\(fields.isEmpty ? "" : ", values: {...}")}."
            if let path = args.optString("export") { text += "\n" + (try exportTemplates([tpl.name], to: path)) }
            return .text(text)
        })
    }

    /// A shareable file of templates, with the media their clips reference so another machine can relink them.
    struct TemplatePackage: Codable {
        struct Media: Codable {
            var id: String
            var name: String
            var path: String
        }

        var format = "cutline-template"
        var version = 1
        var templates: [EditTemplate]
        var media: [Media]
    }

    static let templateExtension = "cutline-template"

    /// Writes saved templates (`names`, or all) to a package file, or one package per template into a folder.
    func exportTemplates(_ names: [String]?, to path: String) throws -> String {
        let all = EditTemplate.all()
        let picked: [EditTemplate]
        if let names {
            picked = try names.map { n in
                guard let t = all.first(where: { $0.name == n }) ?? (try? JSONDecoder().decode(EditTemplate.self, from: Data(contentsOf: EditTemplate.url(n)))) else {
                    throw EditError("No template \(n). Templates: \(all.map(\.name).joined(separator: ", ").ifEmptyText("none"))")
                }
                return t
            }
        } else {
            picked = all
        }
        guard !picked.isEmpty else { throw EditError("No templates to export; save one with template_save {name, clips}") }
        let project = try? session.project()
        func package(_ ts: [EditTemplate]) -> TemplatePackage {
            let ids = Set(ts.flatMap { $0.layers.flatMap { $0.clips.compactMap(\.mediaId) } })
            let media = ids.sorted().map { id in project?.mediaAsset(id).map { TemplatePackage.Media(id: id, name: $0.name, path: $0.path) } ?? TemplatePackage.Media(id: id, name: id, path: "") }
            return TemplatePackage(templates: ts, media: media)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        let folder = path.hasSuffix("/") || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for t in picked {
                try enc.encode(package([t])).write(to: url.appendingPathComponent(Toolbox.safeName(t.name) + "." + Toolbox.templateExtension), options: .atomic)
            }
            return "Exported \(picked.count) template(s) to \(url.path)/: " + picked.map(\.name).joined(separator: ", ") + ". Share the folder; template_save {import: <folder>} reads it on another machine."
        }
        let file = url.pathExtension.isEmpty ? url.appendingPathExtension(Toolbox.templateExtension) : url
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pkg = package(picked)
        try enc.encode(pkg).write(to: file, options: .atomic)
        let media = pkg.media.isEmpty ? "" : " It references media \(pkg.media.map { $0.path.isEmpty ? $0.id : "\($0.id) (\(($0.path as NSString).lastPathComponent))" }.joined(separator: ", ")), which the receiving project needs under the same ids."
        return "Exported \(picked.count) template(s) to \(file.path): " + picked.map(\.name).joined(separator: ", ") + "." + media
    }

    /// Reads template packages or single template files (a file or every one in a folder) into the saved templates.
    func importTemplates(_ path: String, rename: String?) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw EditError("No template file or folder at \(path)") }
        let files = isDir.boolValue
            ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).filter { [Toolbox.templateExtension, "json"].contains($0.pathExtension) }.sorted { $0.path < $1.path }
            : [url]
        var templates: [EditTemplate] = []
        var media: [TemplatePackage.Media] = []
        var skipped: [String] = []
        for f in files {
            guard let data = try? Data(contentsOf: f) else { skipped.append(f.lastPathComponent); continue }
            if let pkg = try? JSONDecoder().decode(TemplatePackage.self, from: data), pkg.format == "cutline-template" {
                guard pkg.version <= 1 else { throw EditError("\(f.lastPathComponent) is template format \(pkg.version); this Cutline reads version 1") }
                templates += pkg.templates
                media += pkg.media
            } else if let t = try? JSONDecoder().decode(EditTemplate.self, from: data) {
                templates.append(t)
            } else {
                skipped.append(f.lastPathComponent)
            }
        }
        guard !templates.isEmpty else { throw EditError("No Cutline templates in \(path)" + (skipped.isEmpty ? "" : " (unreadable: \(skipped.joined(separator: ", ")))")) }
        if let rename {
            guard templates.count == 1 else { throw EditError("name renames a single template; \(path) holds \(templates.count)") }
            templates[0].name = rename
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var lines: [String] = []
        for t in templates {
            let replaced = FileManager.default.fileExists(atPath: EditTemplate.url(t.name).path)
            try enc.encode(t).write(to: EditTemplate.url(t.name), options: .atomic)
            lines.append("\(t.name)\(replaced ? " (replaced)" : ""): \(t.layers.reduce(0) { $0 + $1.clips.count }) clips, \(fmt2(t.duration))s" + (t.fields.isEmpty ? "" : ", fields " + t.fields.keys.sorted().joined(separator: ", ")))
        }
        var out = "Imported \(templates.count) template(s): " + lines.joined(separator: "; ") + ". Insert with recipe template {name, at, values}."
        let needed = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let project = try? session.project()
        let missing = needed.values.filter { project?.mediaAsset($0.id) == nil }.sorted { $0.id < $1.id }
        if !missing.isEmpty { out += " They use media this project lacks: " + missing.map { "\($0.id) (\($0.path.isEmpty ? $0.name : $0.path))" }.joined(separator: ", ") + "." }
        if !skipped.isEmpty { out += " Skipped unreadable files: \(skipped.joined(separator: ", "))." }
        return out
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
        let values = (a.value("values")?.object ?? [:]).compactMapValues(\.string)
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
                    func fill(_ s: String) -> String {
                        var s = s
                        for (k, v) in values { s = s.replacingOccurrences(of: "{{\(k)}}", with: v) }
                        for (k, v) in tpl.fields { s = s.replacingOccurrences(of: "{{\(k)}}", with: v) }
                        return s
                    }
                    if var text = c.text {
                        text.text = fill(text.text)
                        c.text = text
                    }
                    for i in c.effects.indices where GeneratorCatalog.type(c.effects[i].type) != nil {
                        for (k, v) in c.effects[i].params { if let s = v.string, s.contains("{{") { c.effects[i].params[k] = .string(fill(s)) } }
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
            p.relink(idMap)
            return "Inserted \(tpl.name) at \(fmt2(at))s: " + made.joined(separator: ", ")
        }
    }
}
