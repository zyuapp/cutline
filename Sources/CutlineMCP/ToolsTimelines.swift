import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerTimelineTools() {
        add(Tool(name: "timeline_import", description: "Bring another editor's timeline (.fcpxml/.fcpxmld, .otio, .edl, FCP7 .xml or .aaf from Media Composer or Pro Tools) into the open project as a new timeline, reusing the project's media where the files match (EDL sources also match by reel and clip name). Use it to conform an offline edit or a colorist's/editor's revision against footage you already have. The new timeline becomes current; timelines switches back.", schema: Schema.object([
            "path": Schema.string("Timeline file"),
            "name": Schema.string("Name of the new timeline (default: the file name)"),
            "edl_fps": Schema.number("Frame rate for EDLs (default: the project's)"),
        ], required: ["path"])) { [unowned self] args in
            let file = session.resolve(try args.string("path"))
            let current = try session.project()
            let name = args.optString("name") ?? file.deletingPathExtension().lastPathComponent
            var imported: Project
            var notes: [String]
            if file.pathExtension.lowercased() == "edl" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw EditError("Cannot read \(file.path)") }
                let r = try Importer.edl(text, into: current, fps: args.optDouble("edl_fps"))
                imported = r.project
                notes = r.warnings.isEmpty ? [] : ["Import notes: " + r.warnings.prefix(12).joined(separator: "; ")]
                if !r.missingMedia.isEmpty { notes.append("Offline sources: " + r.missingMedia.prefix(10).joined(separator: ", ")) }
            } else {
                (imported, notes) = try await importTimeline(file, name: name, edlFps: args.optDouble("edl_fps") ?? current.canvas.fps)
            }
            var counts: (matched: Int, added: Int, warnings: [String]) = (0, 0, [])
            let p = try session.edit("Import timeline \(name)") { p in counts = try p.adoptTimeline(imported, name: name) }
            try? session.sendPreview(["action": "rebuild"])
            if !counts.warnings.isEmpty { notes.append("Conform notes: " + counts.warnings.prefix(12).joined(separator: "; ") + (counts.warnings.count > 12 ? "; …\(counts.warnings.count - 12) more" : "")) }
            return .text("Imported \(file.lastPathComponent) as timeline \(name): \(p.tracks.flatMap(\.clips).count) clips, \(fmt2(p.duration))s; \(counts.matched) media matched to the project's, \(counts.added) added.\n" + notes.joined(separator: "\n") + "\n" + footer(p))
        })

        addEdit(EditTool(name: "timelines", description: "Several timelines in one project, like sequences in Premiere or timelines in Resolve: a 9:16 cutdown, a trailer, alternate versions, all sharing the media and analysis. Every other tool edits the current timeline. action: list (default), new (empty, or duplicate:true to copy the current one), switch, rename, delete. The preview shows the current timeline.", schema: Schema.object([
            "action": Schema.string("What to do", values: ["list", "new", "switch", "rename", "delete"]),
            "name": Schema.string("Timeline to create, switch to, rename or delete"),
            "new_name": Schema.string("For rename"),
            "duplicate": Schema.bool("For new: start as a copy of the current timeline (default false: empty, same frame)"),
        ]), label: { a, _ in
            switch a.optString("action") ?? "list" {
            case "new": "New timeline \(a.optString("name") ?? "")"
            case "switch": "Switch to timeline \(a.optString("name") ?? "")"
            case "rename": "Rename timeline to \(a.optString("new_name") ?? "")"
            case "delete": "Delete timeline \(a.optString("name") ?? "")"
            default: "Timelines"
            }
        }) { p, args in
            let action = args.optString("action") ?? "list"
            switch action {
            case "list": break
            case "new": try p.newTimeline(try args.string("name"), duplicate: args.bool("duplicate", default: false))
            case "switch": try p.switchTimeline(to: try args.string("name"))
            case "rename": try p.renameTimeline(args.optString("name") ?? p.currentTimelineName, to: try args.string("new_name"))
            case "delete": try p.deleteTimeline(try args.string("name"))
            default: throw EditError("action is list, new, switch, rename or delete")
            }
            let others = p.timelines.map { t in "  \(t.name): \(t.canvas.width)×\(t.canvas.height), \(Frames.timecode(t.tracks.flatMap(\.clips).map(\.end).max() ?? 0)), \(t.tracks.reduce(0) { $0 + $1.clips.count }) clips" }
            return "Current timeline: \(p.currentTimelineName) (\(p.canvas.width)×\(p.canvas.height), \(Frames.timecode(p.duration)))" + (others.isEmpty ? "" : "\nOther timelines:\n" + others.joined(separator: "\n"))
        })
    }
}
