import Foundation

/// A linked clip playing its media off sync from its linked picture.
public struct LinkSyncIssue: Equatable, Sendable {
    /// The clip that is off (the sound, or the later-listed clip).
    public var clip: String
    /// The clip it is measured against (the picture).
    public var reference: String
    /// Timeline seconds `clip` runs late (positive) or early (negative): at time t it plays what `reference` plays
    /// at t − offset.
    public var offset: Seconds
    public var frames: Int

    public func summary(fps: Double) -> String {
        let sign = offset > 0 ? "+" : "−"
        return "\(clip) is out of sync with linked \(reference) by \(sign)\(abs(frames)) frame\(abs(frames) == 1 ? "" : "s") (\(sign)\(fmt2(abs(offset)))s, \(offset > 0 ? "late" : "early")); clip_update {clip_id:\"\(clip)\", resync:true} slips it back"
    }
}

/// A linked sound clip whose edge left its picture's edge at a cut without the neighbour's sound making room for it.
public struct LinkRangeIssue: Equatable, Sendable {
    /// The sound clip.
    public var clip: String
    /// Its picture.
    public var reference: String
    public var edge: ClipEdge
    /// Timeline seconds the sound's edge sits after (positive) or before the picture's.
    public var drift: Seconds
    /// The picture across the cut.
    public var neighbour: String
    /// Seconds the sound plays over the neighbour's sound (positive) or the silent hole it leaves (negative).
    public var overlap: Seconds

    public func summary(fps: Double) -> String {
        let frames = Int(saturating: (abs(drift) * fps).rounded())
        let side = edge == .start ? "starts" : "ends"
        let rel = drift > 0 ? "after" : "before"
        let effect = overlap > 0 ? "plays \(fmt2(overlap))s over \(neighbour)'s sound" : "leaves \(fmt2(-overlap))s of silence before \(neighbour)'s sound"
        return "Linked \(clip) \(side) \(frames) frame\(frames == 1 ? "" : "s") (\(fmt2(abs(drift)))s) \(rel) its picture \(reference)'s \(edge.rawValue) and \(effect); clip_update {clip_id:\"\(clip)\", resync:true} puts the edge back"
    }
}

extension Project {
    /// What a forward constant-speed clip plays at timeline 0 (source seconds), or for a reversed one its source end
    /// plus start × speed; nil for speed-ramped and non-media clips.
    static func syncConstant(_ c: Clip) -> (reverse: Bool, value: Seconds)? {
        guard c.kind == .media, c.mediaId != nil, !c.isRetimed, c.speed > 0 else { return nil }
        return c.reverse ? (true, c.sourceOut + c.start * c.speed) : (false, c.sourceIn - c.start * c.speed)
    }

    /// `t` in `from`'s source time as `to`'s source time: the same for one media, else through a sync group.
    func mapSource(_ t: Seconds, from: String, to: String) -> Seconds? {
        from == to ? t : syncedTime(t, from: from, to: to)
    }

    /// Timeline seconds `o` runs late against `ref` (see `LinkSyncIssue.offset`); nil when the two can't be compared
    /// (other media without a sync group, speed ramps, different speeds or directions).
    public func linkSyncOffset(_ o: Clip, reference ref: Clip) -> Seconds? {
        guard let a = Project.syncConstant(ref), let b = Project.syncConstant(o), a.reverse == b.reverse,
              abs(o.speed - ref.speed) < 1e-6, let rm = ref.mediaId, let om = o.mediaId,
              let mapped = mapSource(a.value, from: rm, to: om) else { return nil }
        // Forward: o plays mapped at t + offset. Reversed: source runs down, so the sign flips.
        return (a.reverse ? b.value - mapped : mapped - b.value) / ref.speed
    }

    /// The picture of a link group (a clip on a video track), else its earliest clip.
    func linkReference(_ ids: [String]) -> Clip? {
        let clips = ids.compactMap { clip($0) }
        return clips.first { c in locateClip(c.id).map { tracks[$0.track].kind == .video } ?? false } ?? clips.min { $0.start < $1.start }
    }

    /// Linked clips playing their media more than half a frame off their picture.
    public func linkSyncIssues() -> [LinkSyncIssue] {
        var groups: [String: [String]] = [:]
        for t in tracks { for c in t.clips { if let l = c.link { groups[l, default: []].append(c.id) } } }
        var out: [LinkSyncIssue] = []
        for (_, ids) in groups.sorted(by: { $0.key < $1.key }) where ids.count > 1 {
            guard let ref = linkReference(ids) else { continue }
            for id in ids where id != ref.id {
                guard let o = clip(id), let off = linkSyncOffset(o, reference: ref), abs(off) >= canvas.frameDuration / 2 else { continue }
                out.append(LinkSyncIssue(clip: id, reference: ref.id, offset: off, frames: Int(saturating: (off * canvas.fps).rounded())))
            }
        }
        return out
    }

    /// Detached sound clips whose edge drifted from their silent picture's edge at a cut, so that they play over the
    /// neighbouring picture's sound or leave a hole the neighbour's sound doesn't fill. A split edit, where the
    /// neighbour's sound yields or fills in, isn't drift.
    public func linkRangeIssues() -> [LinkRangeIssue] {
        let tol = canvas.frameDuration / 2
        var out: [LinkRangeIssue] = []
        func soundSpan(_ n: Clip) -> TimeRange? {
            let parts = detachedSound(n)
            if !parts.isEmpty { return TimeRange(parts.map(\.start).min()!, parts.map(\.end).max()!) }
            return hasSound(n) && (n.volume > 1e-6 || n.anim["audio.volume"] != nil) ? n.audioRange : nil
        }
        for t in tracks where t.kind == .video {
            for (i, p) in t.clips.enumerated() {
                let sounds = detachedSound(p)
                guard !sounds.isEmpty else { continue }
                let prev = i > 0 && abs(t.clips[i - 1].end - p.start) < tol ? t.clips[i - 1] : nil
                let next = i + 1 < t.clips.count && abs(t.clips[i + 1].start - p.end) < tol ? t.clips[i + 1] : nil
                for s in sounds {
                    if let n = next, abs(s.end - p.end) >= tol, let other = soundSpan(n) {
                        if s.end > p.end, other.start < s.end - tol {
                            out.append(LinkRangeIssue(clip: s.id, reference: p.id, edge: .end, drift: s.end - p.end, neighbour: n.id, overlap: s.end - other.start))
                        } else if s.end < p.end, other.start > s.end + tol {
                            out.append(LinkRangeIssue(clip: s.id, reference: p.id, edge: .end, drift: s.end - p.end, neighbour: n.id, overlap: -(other.start - s.end)))
                        }
                    }
                    if let m = prev, abs(s.start - p.start) >= tol, let other = soundSpan(m) {
                        if s.start < p.start, other.end > s.start + tol {
                            out.append(LinkRangeIssue(clip: s.id, reference: p.id, edge: .start, drift: s.start - p.start, neighbour: m.id, overlap: other.end - s.start))
                        } else if s.start > p.start, other.end < s.start - tol {
                            out.append(LinkRangeIssue(clip: s.id, reference: p.id, edge: .start, drift: s.start - p.start, neighbour: m.id, overlap: -(s.start - other.end)))
                        }
                    }
                }
            }
        }
        return out
    }

    /// Slips the out-of-sync clips linked with `id` (or `id` itself when it is the off one) back into sync with their
    /// picture, keeping their place on the timeline; a clip whose media can't cover the slipped range moves instead.
    /// A detached sound whose edge drifted (see `linkRangeIssues`) gets that edge back on its picture's.
    @discardableResult
    public mutating func resyncLinked(_ id: String) throws -> [String] {
        guard let c = clip(id) else { throw EditError("No clip \(id)") }
        guard c.link != nil else { throw EditError("\(id) isn't linked to anything") }
        let issues = linkSyncIssues().filter { $0.clip == id || $0.reference == id || linked(id).contains($0.clip) }
        var notes: [String] = []
        for issue in linkRangeIssues() where issue.clip == id || issue.reference == id || linked(id).contains(issue.clip) {
            guard let o = clip(issue.clip), let ref = clip(issue.reference) else { continue }
            let u = issue.edge == .start
                ? (o.start < ref.start ? Project.trimmedLeft(o, to: ref.start) : Project.extendedLeft(o, by: o.start - ref.start))
                : (o.end > ref.end ? Project.trimmedRight(o, to: ref.end) : Project.extendedRight(o, by: ref.end - o.end))
            try replaceClip(u)
            notes.append("\(o.id)'s \(issue.edge.rawValue) moved back to \(ref.id)'s \(issue.edge.rawValue) at \(fmt2(issue.edge == .start ? ref.start : ref.end))s")
        }
        for issue in issues {
            guard var o = clip(issue.clip) else { continue }
            let shift = issue.offset * o.speed * (o.reverse ? -1 : 1)
            let media = o.mediaId.flatMap { mediaAsset($0) }
            let length = media.map { $0.isImage ? .infinity : $0.duration } ?? .infinity
            if o.sourceIn + shift >= -1e-6, o.sourceOut + shift <= length + 1e-6 {
                o.sourceIn = max(0, o.sourceIn + shift)
                try replaceClip(o)
                notes.append("\(o.id) slipped \(shift > 0 ? "+" : "−")\(fmt2(abs(shift)))s of source, back in sync with \(issue.reference)")
            } else {
                o.start -= issue.offset
                guard o.start >= -1e-6 else { throw EditError("\(o.id) can't be slipped or moved into sync with \(issue.reference): its media doesn't reach and it would start before 0") }
                try replaceClip(o)
                notes.append("\(o.id) moved \(issue.offset > 0 ? "−" : "+")\(fmt2(abs(issue.offset)))s (its media doesn't cover the slipped range), back in sync with \(issue.reference)")
            }
        }
        return notes
    }

    /// After `new` replaced `old` (one clip's speed, source range, start or length changed), puts its linked clips
    /// back where sync puts them: same-media partners that were in sync keep the source they cover, and an edge that
    /// met `old`'s edge follows `new`'s. Other partners move by the change in start. Returns the partners moved.
    @discardableResult
    public mutating func followLinked(old: Clip, new: Clip, ripple: Bool = false, only: Set<String>? = nil) throws -> [String] {
        var moved: [String] = []
        let tol = canvas.frameDuration / 2
        for oid in linked(old.id) where only?.contains(oid) ?? true {
            guard var o = clip(oid) else { continue }
            let before = o
            if let off = linkSyncOffset(o, reference: old), abs(off) < tol, !o.reverse, !new.reverse, !new.isRetimed, new.speed > 0,
               let nm = new.mediaId, let om = o.mediaId, nm == om {
                let startMet = abs(o.start - old.start) < tol, endMet = abs(o.end - old.end) < tol
                let oIn = startMet ? new.sourceIn : o.sourceIn
                let oOut = endMet ? new.sourceOut : o.sourceOut
                guard oOut > oIn else { throw EditError("Linked \(oid) would have no source left; unlink it first") }
                o.speed = new.speed
                o.sourceIn = oIn
                o.start = new.start + (oIn - new.sourceIn) / new.speed
                o.duration = (oOut - oIn) / new.speed
            } else {
                // The content moves by the change in start less the source trimmed off the head; edges that met follow.
                let forward = old.kind == .media && new.kind == .media && !old.reverse && !new.reverse && !old.isRetimed && !new.isRetimed && abs(old.speed - new.speed) < 1e-9
                let shift = (new.start - old.start) - (forward ? (new.sourceIn - old.sourceIn) / old.speed : 0)
                let startMet = abs(o.start - old.start) < tol, endMet = abs(o.end - old.end) < tol
                if abs(shift) > eps { o.start += shift }
                if startMet, abs(o.start - new.start) > eps {
                    o = o.start < new.start ? Project.trimmedLeft(o, to: new.start) : Project.extendedLeft(o, by: o.start - new.start)
                }
                if endMet, abs(o.end - new.end) > eps {
                    o = o.end > new.end ? Project.trimmedRight(o, to: new.end) : Project.extendedRight(o, by: new.end - o.end)
                }
                guard o.duration >= canvas.frameDuration - eps else { throw EditError("Linked \(oid) would be shorter than a frame; unlink it first") }
            }
            guard o != before else { continue }
            guard o.start >= -tol else { throw EditError("Linked \(oid) would start before 0") }
            do { try replaceClip(o, ripple: ripple) } catch { throw EditError("Linked \(oid) can't follow \(old.id): \(error.localizedDescription) Unlink it (clip_update unlink:true) or make room") }
            moved.append(oid)
        }
        return moved
    }

    /// After an edit changed clips beside the ones it targeted (a slide's or roll's neighbours, clips an overwrite
    /// cut), applies each change to the changed clip's linked clips the edit left alone. Clips in `skip` had their
    /// links handled by the caller. Returns the linked clips moved.
    @discardableResult
    public mutating func followSideEffects(before: [String: Clip], skip: Set<String> = []) throws -> [String] {
        func same(_ a: Clip, _ b: Clip) -> Bool {
            abs(a.start - b.start) < eps && abs(a.duration - b.duration) < eps && abs(a.sourceIn - b.sourceIn) < eps && a.speed == b.speed
        }
        var moved: [String] = []
        for x in tracks.flatMap(\.clips).sorted(by: { $0.id < $1.id }) where !skip.contains(x.id) && x.link != nil {
            guard let old = before[x.id], !same(old, x) else { continue }
            let partners = linked(x.id).filter { o in
                guard !skip.contains(o), !moved.contains(o), let b = before[o], let now = clip(o) else { return false }
                return same(b, now)
            }
            guard !partners.isEmpty else { continue }
            moved += try followLinked(old: old, new: x, only: Set(partners))
        }
        return moved
    }

    public var clipsById: [String: Clip] {
        Dictionary(tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Moves the linked partners of clips whose start moved (relative to `before`) by the same amount, when the
    /// partner itself didn't move. Returns the partners moved.
    @discardableResult
    public mutating func propagateLinkedShifts(before: [String: Seconds]) -> [String] {
        var shifts: [String: Seconds] = [:]
        for t in tracks { for c in t.clips { if let s = before[c.id], abs(c.start - s) > eps { shifts[c.id] = c.start - s } } }
        var moved: [String] = []
        for (id, d) in shifts.sorted(by: { $0.key < $1.key }) {
            for o in linked(id) where shifts[o] == nil && !moved.contains(o) {
                guard let loc = locateClip(o) else { continue }
                tracks[loc.track].clips[loc.clip].start = canvas.snap(tracks[loc.track].clips[loc.clip].start + d)
                tracks[loc.track].clips.sort { $0.start < $1.start }
                moved.append(o)
            }
        }
        return moved
    }

    public var clipStarts: [String: Seconds] {
        Dictionary(tracks.flatMap(\.clips).map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
    }
}
