import CutlineCore
import Foundation

extension Toolbox {
    func registerTrimTool() {
        addEdit(EditTool(name: "trim", description: "Fine-tune an edit. plain moves one edge; ripple moves an edge and shifts everything after it (all_tracks keeps other tracks in sync); roll moves the cut between two touching clips; slip changes which source plays without moving the clip; slide moves a clip between its neighbours, which adjust to fill. part:\"audio\" moves only the sound's edge, leaving the picture (J/L cut): edge start by −0.5 starts the sound half a second early. When that edge meets a touching clip on the same track, the sound cut rolls: the neighbour's sound shortens (or lengthens) by the same amount, so the two lines never overlap; to with part audio is where the sound edge goes. Give to (a timeline time or anchor for the edge) or by (seconds; source seconds for slip).", schema: Schema.object([
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
            let audio = args.optString("part") == "audio"
            var delta: Seconds
            if let by = args.optDouble("by") {
                delta = by
            } else if args.has("to") {
                let target = try args.time("to")
                switch audio ? .plain : mode {
                case .slip: throw EditError("slip takes by (source seconds)")
                case .slide: delta = target - c.start
                default:
                    let sound = c.audioRange
                    delta = target - (edge == .start ? (audio ? sound.start : c.start) : (audio ? sound.end : c.end))
                }
            } else {
                throw EditError("Pass to or by")
            }
            if audio { return try p.trimAudio(id, edge: edge, delta: delta) + "." }
            return try p.trim(id, mode: mode, edge: edge, delta: delta, allTracks: args.bool("all_tracks", default: false)) + "."
        })
    }
}
