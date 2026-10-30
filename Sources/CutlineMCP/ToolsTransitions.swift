import CutlineCore
import Foundation

extension Toolbox {
    func registerTransitionTools() {
        addEdit(EditTool(name: "transition_set", description: "Add, change or remove transitions. Across a cut between adjacent clips (cut \"clip_a|clip_b\", or several, or track:\"V1\" for every cut on a track) the clips keep their timing and the transition borrows media past each edge (handles); it fails with the available handle when there isn't enough. With only to (or only from) the clip transitions in (or out) over what lies beneath it, e.g. a b-roll wiping in over the talking head. Types: dissolve, dip (to black/white), flash, wipe, iris, slide, push, zoom, whip, blur, spin, glitch; catalog type=<transition> lists params. part both (default) also crossfades the sound; audio gives an audio-only crossfade. On a split edit (J/L cut) the sound crossfade sits on the sound cut, not the picture cut. With track, cuts that can't take the transition (too little handle, too short) are skipped and listed instead of failing the rest. Setting a transition on the same clips again replaces it.", schema: Schema.object([
            "cut": ["description": "\"clip_a|clip_b\" or a list of them", "anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]],
            "track": Schema.string("Every cut between touching clips on this track"),
            "from": Schema.string("Outgoing clip, alone for a transition out"),
            "to": Schema.string("Incoming clip, alone for a transition in"),
            "id": Schema.string("Existing transition id to change or remove"),
            "type": Schema.string("Transition type, default dissolve", values: TransitionCatalog.all.map(\.id)),
            "duration": Schema.number("Seconds, default 0.5"),
            "align": Schema.string("Where it sits on the cut, default center", values: TransitionAlign.allCases.map(\.rawValue)),
            "part": Schema.string("Picture, sound or both, default both", values: TransitionPart.allCases.map(\.rawValue)),
            "ease": Schema.string("Progress easing, default easeInOut", values: Easing.allCases.map(\.rawValue)),
            "params": ["type": "object", "description": "Type parameters, e.g. {\"direction\": \"left\"} or {\"color\": \"#FFFFFF\"}"],
            "remove": Schema.bool("Remove the matching transitions"),
        ]), label: { a, _ in
            a.bool("remove", default: false) ? "Remove transition" : "Add \(a.optString("type") ?? "dissolve") transition"
        }) { p, args in
            var pairs: [(String?, String?)] = []
            var fromTrack = Set<String>()
            for s in args.strings("cut") ?? [] { pairs.append(try Toolbox.cutPair(s)) }
            if let tid = args.optString("track") {
                guard let i = p.trackIndex(tid) else { throw EditError("No track \(tid)") }
                let clips = p.tracks[i].clips
                for (a, b) in zip(clips, clips.dropFirst()) where abs(b.start - a.end) < p.canvas.frameDuration / 2 && a.kind != .adjustment && b.kind != .adjustment {
                    pairs.append((a.id, b.id))
                    fromTrack.insert("\(a.id)|\(b.id)")
                }
                if pairs.isEmpty { throw EditError("\(tid) has no touching clips") }
            }
            if args.has("from") || args.has("to") { pairs.append((args.optString("from"), args.optString("to"))) }
            if let id = args.optString("id") {
                guard let tr = p.transitions.first(where: { $0.id == id }) else { throw EditError("No transition \(id)") }
                pairs = [(tr.from, tr.to)]
            }
            guard !pairs.isEmpty else { throw EditError("Pass cut \"clip_a|clip_b\", track, from/to, or id") }

            var lines: [String] = []
            var skipped: [String] = []
            for (from, to) in pairs {
                let existing = p.transitions.firstIndex { $0.from == from && $0.to == to }
                if args.bool("remove", default: false) {
                    guard let existing else { throw EditError("No transition on \(from ?? "∅")|\(to ?? "∅")") }
                    lines.append("Removed \(p.transitions[existing].id).")
                    p.transitions.remove(at: existing)
                    continue
                }
                var tr = existing.map { p.transitions[$0] } ?? Transition(id: p.nextTransitionId(), from: from, to: to, type: "dissolve", duration: 0.5)
                if let t = args.optString("type") {
                    if t != tr.type { tr.params = [:] }
                    tr.type = t
                }
                guard let spec = TransitionCatalog.type(tr.type) else { throw EditError("Unknown transition \(tr.type). Types: \(TransitionCatalog.all.map(\.id).joined(separator: ", "))") }
                if let d = args.optDouble("duration") { tr.duration = d }
                if let s = args.optString("align") {
                    guard let v = TransitionAlign(rawValue: s) else { throw EditError("align is center, start or end") }
                    tr.align = v
                    tr.cutOffset = nil
                }
                if let s = args.optString("part") {
                    guard let v = TransitionPart(rawValue: s) else { throw EditError("part is video, audio or both") }
                    tr.part = v
                }
                if let s = args.optString("ease") {
                    guard let v = Easing(rawValue: s) else { throw EditError("Unknown ease \(s)") }
                    tr.ease = v
                }
                for (k, v) in args.raw["params"]?.object ?? [:] {
                    guard let ps = spec.spec(k) else { throw EditError("\(tr.type) has no parameter \(k). Parameters: \(spec.params.map(\.name).joined(separator: ", ").ifEmptyText("none"))") }
                    tr.params[k] = try ps.validate(try Toolbox.paramValue(v), path: k)
                }
                if from == nil || to == nil, tr.part == .audio { throw EditError("Audio-only transitions need both clips; fade a single clip with audio.fade_in/out") }
                var probe = p
                probe.transitions.removeAll { $0.id == tr.id }
                do {
                    try probe.checkTransition(tr)
                } catch let error as EditError where fromTrack.contains("\(from ?? "")|\(to ?? "")") {
                    skipped.append("\(from ?? "")|\(to ?? ""): \(error.message)")
                    continue
                }
                if let existing { p.transitions[existing] = tr } else { p.transitions.append(tr) }
                lines.append(Toolbox.describeTransition(tr, p))
            }
            if !skipped.isEmpty {
                guard !lines.isEmpty else { throw EditError("No cut could take the transition:\n" + skipped.joined(separator: "\n")) }
                lines.append("Skipped \(skipped.count) cut(s):\n" + skipped.map { "  " + $0 }.joined(separator: "\n"))
            }
            return lines.joined(separator: "\n")
        })
    }

    static func cutPair(_ s: String) throws -> (String?, String?) {
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty || !parts[1].isEmpty else { throw EditError("cut is \"clip_a|clip_b\"") }
        return (parts[0].isEmpty ? nil : parts[0], parts[1].isEmpty ? nil : parts[1])
    }

    static func describeTransition(_ tr: Transition, _ p: Project) -> String {
        guard let picture = try? p.window(tr) else { return "\(tr.id) \(tr.type)" }
        let sound = tr.hasAudio ? try? p.audioWindow(tr) : nil
        let w = tr.hasVideo ? picture : sound ?? picture
        var s = "\(tr.id) \(tr.type) \(fmt2(tr.duration))s on \(w.trackId) \(tr.from ?? "∅")→\(tr.to ?? "∅"), \(fmt2(w.start))–\(fmt2(w.end))s"
        if !tr.params.isEmpty { s += " " + tr.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
        if tr.part != .both { s += ", \(tr.part.rawValue) only" }
        if let sound, abs(sound.start - picture.start) > 1e-3 {
            s += tr.hasVideo ? "; the sound crossfades on the split edit's sound cut, \(fmt2(sound.start))–\(fmt2(sound.end))s" : ", on the split edit's sound cut"
        }
        var borrow: [String] = []
        if w.tail > 0, let f = tr.from { borrow.append("\(fmt2(w.tail))s after \(f)") }
        if w.head > 0, let t = tr.to { borrow.append("\(fmt2(w.head))s before \(t)") }
        if !borrow.isEmpty { s += " (borrows " + borrow.joined(separator: " and ") + ")" }
        return s + "."
    }

    static func describeTransitionType(_ t: EffectType) -> String {
        var lines = ["\(t.id) (transition): \(t.summary)."]
        lines += t.params.map { "  " + $0.line }
        let example = t.params.first.map { ", \"params\": {\"\($0.name)\": \($0.defaultValue)}" } ?? ""
        lines.append("Example: transition_set {\"cut\": \"clip_a|clip_b\", \"type\": \"\(t.id)\", \"duration\": 0.5\(example)}")
        return lines.joined(separator: "\n")
    }
}
