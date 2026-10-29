import CutlineCore
import Foundation

extension Toolbox {
    func registerNestTool() {
        addEdit(EditTool(name: "sequence_nest", description: "Group clips into a nested sequence that plays as one clip, so one transform, effect stack, mask, transition or speed setting applies to the whole group (e.g. scale a finished split screen, grade a montage, wipe a stack of titles in together). unnest puts a nested clip's contents back on the timeline. Nested clips can be trimmed, moved and split like any clip; source_in picks where inside the sequence it starts.", schema: Schema.object([
            "clips": Schema.strings("Clips to nest (across tracks)"),
            "name": Schema.string("Name of the nested sequence"),
            "unnest": Schema.string("A nested clip to expand back onto the timeline"),
        ]), label: { a, _ in a.has("unnest") ? "Unnest \(a.optString("unnest") ?? "")" : "Nest \(a.strings("clips")?.count ?? 0) clips" }) { p, args in
            if let id = args.optString("unnest") {
                let placed = try p.unnest(id)
                return "Expanded \(id) into \(placed.count) clips: " + placed.joined(separator: ", ")
            }
            guard let ids = args.strings("clips") else { throw EditError("Pass clips or unnest") }
            let clip = try p.nest(ids, name: args.optString("name"))
            return "Nested \(ids.count) clips into \(clip.id) (\(fmt2(clip.start))–\(fmt2(clip.end))s, sequence \(clip.mediaId ?? "")). Style it like any clip: param_set, effect_add, transition_set."
        })
    }
}
