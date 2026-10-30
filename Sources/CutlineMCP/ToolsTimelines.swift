import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerTimelineTools() {
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
