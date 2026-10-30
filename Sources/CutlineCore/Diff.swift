import Foundation

/// Human- and agent-readable differences between two versions of a project.
extension Project {
    public func changes(from old: Project) -> [String] {
        var out: [String] = []
        var shape = canvas
        shape.timecodeStart = old.canvas.timecodeStart
        if shape != old.canvas {
            out.append("canvas \(old.canvas.width)×\(old.canvas.height)@\(old.canvas.fps) \(old.canvas.colorSpace.rawValue) → \(canvas.width)×\(canvas.height)@\(canvas.fps) \(canvas.colorSpace.rawValue)")
        }
        if canvas.startTimecode != old.canvas.startTimecode { out.append("start timecode \(old.canvas.startTimecode) → \(canvas.startTimecode)") }
        let oldMedia = Set(old.media.map(\.id)), newMedia = Set(media.map(\.id))
        for id in newMedia.subtracting(oldMedia).sorted() { out.append("+ media \(id)") }
        for id in oldMedia.subtracting(newMedia).sorted() { out.append("- media \(id)") }
        let mediaBefore = Dictionary(old.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in media {
            guard let o = mediaBefore[m.id], o != m else { continue }
            out.append("~ media \(m.id): " + MediaAsset.changedFields(o, m).joined(separator: ", ").ifEmpty("details"))
        }

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
            if o.volumeCurve != t.volumeCurve { fields.append(t.volumeCurve == nil ? "volume automation removed" : "volume automation (\(t.volumeCurve!.keys.count) keys)") }
            if o.role != t.role { fields.append("role \(t.role ?? "auto")") }
            if o.output != t.output { fields.append("output \(o.output ?? "master")→\(t.output ?? "master")") }
            if o.sends != t.sends { fields.append("sends " + t.sends.map { "\($0.bus) \(fmt2($0.levelDb)) dB\($0.preFader ? " pre" : "")" }.joined(separator: ", ").ifEmpty("none")) }
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
        if master.layout != old.master.layout { out.append("~ master layout \(old.master.layout.title)→\(master.layout.title)") }
        out += busChanges(from: old)
        if master.effects != old.master.effects { out.append("~ master effects: " + master.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ").ifEmpty("none")) }
        let oldTr = Dictionary(uniqueKeysWithValues: old.transitions.map { ($0.id, $0) })
        let newTr = Set(transitions.map(\.id))
        for tr in transitions {
            let desc = "\(tr.id) \(tr.type) \(fmt2(tr.duration))s \(tr.from ?? "∅")→\(tr.to ?? "∅")"
            if let o = oldTr[tr.id] { if o != tr { out.append("~ transition " + desc) } } else { out.append("+ transition " + desc) }
        }
        for tr in old.transitions where !newTr.contains(tr.id) { out.append("- transition \(tr.id) \(tr.type)") }
        if captions != old.captions { out.append("~ captions: " + Captions.changedFields(old.captions, captions).joined(separator: ", ").ifEmpty("settings")) }
        if sequences != old.sequences { out.append("~ nested sequences \(old.sequences.count)→\(sequences.count)") }
        if syncGroups != old.syncGroups { out.append("~ sync groups \(old.syncGroups.count)→\(syncGroups.count)") }
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
        if let ta = a.text, let tb = b.text {
            if ta.spans != tb.spans { f.append("text spans \(ta.spans?.count ?? 0)→\(tb.spans?.count ?? 0)") }
            if ta.animator != tb.animator { f.append(tb.animator == nil ? "text animator removed" : "text animator") }
        }
        if a.mediaId != b.mediaId { f.append("media \(a.mediaId ?? "–")→\(b.mediaId ?? "–")") }
        if a.raw != b.raw, b.raw == nil { f.append("raw development cleared") }
        if a.multicam != b.multicam { f.append("angle switching (\(b.multicam?.cuts.count ?? 0) cuts\(b.multicam?.audioFollowsVideo == true ? ", sound follows picture" : ""))") }
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

extension MediaAsset {
    static func changedFields(_ a: MediaAsset, _ b: MediaAsset) -> [String] {
        var f: [String] = []
        if a.name != b.name { f.append("name \"\(a.name)\"→\"\(b.name)\"") }
        if a.bin != b.bin { f.append("bin \(a.bin ?? "none")→\(b.bin ?? "none")") }
        if a.metadata != b.metadata {
            let ma = a.metadata ?? [:], mb = b.metadata ?? [:]
            for k in Set(ma.keys).union(mb.keys).sorted() where ma[k] != mb[k] {
                f.append(mb[k].map { "\(k) \(ma[k] ?? "–")→\($0)" } ?? "-\(k)")
            }
        }
        if a.tags != b.tags { f.append("tags \(a.tags?.count ?? 0)→\(b.tags?.count ?? 0)") }
        if a.path != b.path { f.append("relinked to \(b.url.lastPathComponent)") }
        if a.reel != b.reel { f.append("reel \(b.reel ?? "none")") }
        if a.timecodeStart != b.timecodeStart { f.append("timecode start") }
        if a.log != b.log { f.append("log \(b.log.map { "\($0)" } ?? "none")") }
        if a.signalRange != b.signalRange { f.append("signal range") }
        if a.raw?.settings != b.raw?.settings { f.append("raw development \(b.raw?.settings.summary ?? "none")") }
        if a.duration != b.duration || a.width != b.width || a.height != b.height || a.fps != b.fps || a.hasVideo != b.hasVideo || a.hasAudio != b.hasAudio {
            f.append("format \(a.width)×\(a.height)@\(fmt2(a.fps)) \(fmt2(a.duration))s → \(b.width)×\(b.height)@\(fmt2(b.fps)) \(fmt2(b.duration))s")
        }
        return f
    }
}

extension Captions {
    static func changedFields(_ a: Captions, _ b: Captions) -> [String] {
        var f: [String] = []
        if a.enabled != b.enabled { f.append(b.enabled ? "on" : "off") }
        if a.style != b.style { f.append("style") }
        if a.replacements != b.replacements { f.append("replacements \(a.replacements.count)→\(b.replacements.count)") }
        if a.hiddenWords != b.hiddenWords { f.append("hidden words \(a.hiddenWords.count)→\(b.hiddenWords.count)") }
        if a.trackIds != b.trackIds { f.append("tracks \(b.trackIds.isEmpty ? "dialogue" : b.trackIds.joined(separator: ","))") }
        if a.edits != b.edits {
            let added = b.edits.filter { !a.edits.contains($0) }, removed = a.edits.filter { !b.edits.contains($0) }
            var parts: [String] = []
            for e in added { parts.append("+\(e.summary)") }
            for e in removed { parts.append("-\(e.summary)") }
            f.append("cue edits " + parts.prefix(4).joined(separator: " ") + (parts.count > 4 ? " …" : ""))
        }
        return f
    }
}

extension CaptionEdit {
    var summary: String {
        var what: [String] = []
        if let t = text { what.append("text \"\(t.prefix(24))\"") }
        if startOffset != nil || endOffset != nil { what.append("timing") }
        if hidden == true { what.append("hidden") }
        if breakBefore == true { what.append("break") }
        if mergeNext == true { what.append("merge") }
        return "\(mediaId).w\(fromWord)\(toWord != fromWord ? "–w\(toWord)" : "")(\(what.joined(separator: ",")))"
    }
}

func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
