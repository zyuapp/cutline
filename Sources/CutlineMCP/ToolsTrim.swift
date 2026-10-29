import CutlineCore
import Foundation

extension Toolbox {
    func registerTrimTool() {
        addEdit(EditTool(name: "trim", description: "Fine-tune an edit. plain moves one edge; ripple moves an edge and shifts everything after it (all_tracks keeps other tracks in sync); roll moves the cut between two touching clips; slip changes which source plays without moving the clip; slide moves a clip between its neighbours, which adjust to fill. part:\"audio\" trims only the sound past the picture edge (J/L cut: edge start by −0.5 starts the sound half a second early). Give to (a timeline time or anchor for the edge) or by (seconds; source seconds for slip).", schema: Schema.object([
            "clip_id": Schema.string("Clip to trim"),
            "mode": Schema.string("Default plain", values: TrimMode.allCases.map(\.rawValue)),
            "edge": Schema.string("Which edge; default end (ignored by slip and slide)", values: ["start", "end"]),
            "to": Schema.time("Where the edge goes (timeline time or anchor such as \"talk.w40.end\" or \"beat:12\")"),
            "by": Schema.number("Seconds to move: positive is later"),
            "all_tracks": Schema.bool("Ripple every track, default false"),
            "part": Schema.string("video (default, the whole clip) or audio (only its sound)", values: ["video", "audio"]),
        ], required: ["clip_id"]), label: { a, _ in
            "\((a.optString("mode") ?? "plain").capitalized) trim \(a.optString("clip_id") ?? "")"
        }) { p, args in
            let id = try args.string("clip_id")
            guard let c = p.clip(id) else { throw EditError("No clip \(id)") }
            let mode = try args.enumValue("mode", TrimMode.self) ?? .plain
            let edge = ClipEdge(rawValue: args.optString("edge") ?? "end") ?? .end
            var delta: Seconds
            if let by = args.optDouble("by") {
                delta = by
            } else if args.has("to") {
                let target = try args.time("to")
                switch mode {
                case .slip: throw EditError("slip takes by (source seconds)")
                case .slide: delta = target - c.start
                default: delta = target - (edge == .start ? c.start : c.end)
                }
            } else {
                throw EditError("Pass to or by")
            }
            if args.optString("part") == "audio" {
                guard let loc = p.locateClip(id) else { throw EditError("No clip \(id)") }
                if edge == .start { p.tracks[loc.track].clips[loc.clip].audioLead -= delta } else { p.tracks[loc.track].clips[loc.clip].audioLag += delta }
                let u = p.tracks[loc.track].clips[loc.clip]
                return "\(id)'s sound now runs \(fmt2(u.audioRange.start))–\(fmt2(u.audioRange.end)) (picture \(fmt2(u.start))–\(fmt2(u.end)))."
            }
            return try p.trim(id, mode: mode, edge: edge, delta: delta, allTracks: args.bool("all_tracks", default: false)) + "."
        })
    }
}
