import Foundation

/// Human- and agent-readable differences between two versions of a project.
extension Project {
    public func changes(from old: Project) -> [String] {
        var out: [String] = []
        if canvas != old.canvas {
            out.append("canvas \(old.canvas.width)×\(old.canvas.height)@\(old.canvas.fps) → \(canvas.width)×\(canvas.height)@\(canvas.fps)")
        }
        let oldMedia = Set(old.media.map(\.id)), newMedia = Set(media.map(\.id))
        for id in newMedia.subtracting(oldMedia).sorted() { out.append("+ media \(id)") }
        for id in oldMedia.subtracting(newMedia).sorted() { out.append("- media \(id)") }

        let oldTracks = Dictionary(uniqueKeysWithValues: old.tracks.map { ($0.id, $0) })
        let newTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for t in tracks where oldTracks[t.id] == nil { out.append("+ track \(t.id) \"\(t.name)\"") }
        for t in old.tracks where newTracks[t.id] == nil { out.append("- track \(t.id)") }
        for t in tracks {
            guard let o = oldTracks[t.id] else { continue }
            var fields: [String] = []
            if o.name != t.name { fields.append("name") }
            if o.muted != t.muted { fields.append(t.muted ? "muted" : "unmuted") }
            if o.hidden != t.hidden { fields.append(t.hidden ? "hidden" : "shown") }
            if o.volume != t.volume { fields.append("volume \(fmt2(o.volume))→\(fmt2(t.volume))") }
            if o.effects != t.effects { fields.append("effects") }
            if !fields.isEmpty { out.append("~ track \(t.id): " + fields.joined(separator: ", ")) }
        }

        var oldClips: [String: (Clip, String)] = [:]
        for t in old.tracks { for c in t.clips { oldClips[c.id] = (c, t.id) } }
        var seen = Set<String>()
        for t in tracks {
            for c in t.clips {
                seen.insert(c.id)
                guard let (o, oldTrack) = oldClips[c.id] else {
                    out.append("+ \(c.id) on \(t.id) \(fmt2(c.start))–\(fmt2(c.end))")
                    continue
                }
                let fields = Clip.changedFields(o, c, movedTrack: oldTrack != t.id ? "\(oldTrack)→\(t.id)" : nil)
                if !fields.isEmpty { out.append("~ \(c.id): " + fields.joined(separator: ", ")) }
            }
        }
        for (id, (c, t)) in oldClips.sorted(by: { $0.key < $1.key }) where !seen.contains(id) {
            out.append("- \(id) from \(t) \(fmt2(c.start))–\(fmt2(c.end))")
        }
        if master.gainDb != old.master.gainDb { out.append("~ master gain \(fmt2(old.master.gainDb))→\(fmt2(master.gainDb)) dB") }
        if master.effects != old.master.effects { out.append("~ master effects: " + master.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ").ifEmpty("none")) }
        let oldTr = Dictionary(uniqueKeysWithValues: old.transitions.map { ($0.id, $0) })
        let newTr = Set(transitions.map(\.id))
        for tr in transitions {
            let desc = "\(tr.id) \(tr.type) \(fmt2(tr.duration))s \(tr.from ?? "∅")→\(tr.to ?? "∅")"
            if let o = oldTr[tr.id] { if o != tr { out.append("~ transition " + desc) } } else { out.append("+ transition " + desc) }
        }
        for tr in old.transitions where !newTr.contains(tr.id) { out.append("- transition \(tr.id) \(tr.type)") }
        if captions != old.captions { out.append("~ captions") }
        if markers != old.markers { out.append("~ markers \(old.markers.count)→\(markers.count)") }
        if abs(duration - old.duration) > 1e-6 { out.append("duration \(fmt2(old.duration))→\(fmt2(duration))") }
        return out
    }
}

extension Clip {
    static func changedFields(_ a: Clip, _ b: Clip, movedTrack: String?) -> [String] {
        var f: [String] = []
        if let movedTrack { f.append("track \(movedTrack)") }
        if a.start != b.start || a.duration != b.duration { f.append("\(fmt2(a.start))–\(fmt2(a.end)) → \(fmt2(b.start))–\(fmt2(b.end))") }
        if a.sourceIn != b.sourceIn { f.append("source_in \(fmt2(a.sourceIn))→\(fmt2(b.sourceIn))") }
        if a.speed != b.speed { f.append("speed \(fmt2(a.speed))→\(fmt2(b.speed))") }
        for spec in b.fixedSpecs where !["name"].contains(spec.name) {
            let va = a.staticValue(spec.name), vb = b.staticValue(spec.name)
            if va != vb, let vb { f.append("\(spec.name) \(va.map(\.description) ?? "–")→\(vb)") }
        }
        if a.name != b.name { f.append("name") }
        let ea = Dictionary(uniqueKeysWithValues: a.effects.map { ($0.id, $0) })
        let eb = Dictionary(uniqueKeysWithValues: b.effects.map { ($0.id, $0) })
        for e in b.effects where ea[e.id] == nil { f.append("+fx \(e.id) (\(e.type))") }
        for e in a.effects where eb[e.id] == nil { f.append("-fx \(e.id)") }
        for e in b.effects {
            guard let o = ea[e.id], o != e else { continue }
            let keys = Set(o.params.keys).union(e.params.keys).filter { o.params[$0] != e.params[$0] }.sorted()
            var parts = keys.map { "\($0) \(o.params[$0].map(\.description) ?? "default")→\(e.params[$0].map(\.description) ?? "default")" }
            if o.mix != e.mix { parts.append("mix \(fmt2(o.mix))→\(fmt2(e.mix))") }
            if o.enabled != e.enabled { parts.append(e.enabled ? "enabled" : "disabled") }
            f.append("fx \(e.id) " + parts.joined(separator: ", "))
        }
        if a.effects.map(\.id) != b.effects.map(\.id) && Set(a.effects.map(\.id)) == Set(b.effects.map(\.id)) { f.append("effect order") }
        for path in Set(a.anim.keys).union(b.anim.keys).sorted() where a.anim[path] != b.anim[path] {
            if let c = b.anim[path] { f.append("animate \(path) (\(c.keys.count) keys)") } else { f.append("stop animating \(path)") }
        }
        return f
    }
}

func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
