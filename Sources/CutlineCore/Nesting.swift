import Foundation

/// Tracks grouped into one clip: a nested sequence plays as a single layer whose transform,
/// effects and transitions apply to the whole group. A sequence clip's `sourceIn` is the
/// offset into the sequence and its `mediaId` names the sequence.
public struct NestedSequence: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var tracks: [Track]
    public var transitions: [Transition]
    /// Set for a multicam source: one inner track per synced angle, played through the clip's angle switching.
    public var multicam: MulticamSetup?

    public init(id: String, name: String, tracks: [Track], transitions: [Transition] = []) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.transitions = transitions
    }

    public var duration: Seconds { tracks.flatMap(\.clips).map(\.end).max() ?? 0 }
}

extension Project {
    public func sequence(_ id: String) -> NestedSequence? { sequences.first { $0.id == id } }

    /// The project as seen inside a nested sequence, sharing media and canvas.
    public func inside(_ seq: NestedSequence) -> Project {
        var p = self
        p.tracks = seq.tracks
        p.transitions = seq.transitions
        p.captions.enabled = false
        return p
    }

    /// The speed a sequence clip plays its sequence at: its constant speed; ramps and reverse play it at 1×.
    public static func sequenceRate(_ clip: Clip) -> Double {
        clip.isRetimed || clip.reverse || !(clip.speed > 0) || !clip.speed.isFinite ? 1 : clip.speed
    }

    /// The stretch of its sequence a sequence clip plays, in sequence time.
    public static func sequenceWindow(_ clip: Clip) -> TimeRange {
        TimeRange(clip.sourceIn, clip.sourceIn + clip.duration * sequenceRate(clip))
    }

    /// `inner` (in sequence time, inside `sequenceWindow(clip)`) where the sequence clip plays it on the timeline:
    /// shortened and sped up by the clip's speed.
    public static func placed(_ inner: Clip, in clip: Clip) -> Clip {
        var c = inner
        let k = sequenceRate(clip)
        c.start = clip.start + (inner.start - clip.sourceIn) / k
        guard abs(k - 1) > 1e-9 else { return c }
        c.duration /= k
        c.speed *= k
        c.fadeIn /= k
        c.fadeOut /= k
        c.audioFadeIn /= k
        c.audioFadeOut /= k
        c.audioLead /= k
        c.audioLag /= k
        c.anim = c.anim.mapValues { curve in
            var curve = curve
            curve.keys = curve.keys.map { key in
                var key = key
                key.t /= k
                return key
            }
            return curve
        }
        if var ramp = c.anim["time.speed"] {
            ramp.keys = ramp.keys.map { key in
                var key = key
                if let v = key.v.number { key.v = .number(v * k) }
                return key
            }
            c.anim["time.speed"] = ramp
        }
        return c
    }

    /// A sequence clip's contents placed on this timeline, trimmed to the clip, with ids "<clip>/<inner>".
    public func expanded(_ clip: Clip) -> [(kind: TrackKind, clip: Clip)] {
        guard clip.kind == .sequence, let seq = contents(of: clip) else { return [] }
        let window = Project.sequenceWindow(clip)
        var out: [(TrackKind, Clip)] = []
        for track in seq.tracks where !(track.muted && track.kind == .audio) && !(track.hidden && track.kind == .video) {
            for inner in track.clips where inner.end > window.start + eps && inner.start < window.end - eps {
                var c = inner
                if c.start < window.start { c = Project.trimmedLeft(c, to: window.start) }
                if c.end > window.end { c = Project.trimmedRight(c, to: window.end) }
                c = Project.placed(c, in: clip)
                c.id = "\(clip.id)/\(inner.id)"
                c.volume *= clip.volume * track.volume
                out.append((track.kind, c))
                if c.kind == .sequence { out += expanded(c) }
            }
        }
        return out
    }

    /// Tracks with sequence clips replaced by their audible contents, for sound and transcripts.
    public var flattenedForSound: [Track] {
        tracks.map { t in
            var t = t
            t.clips = t.clips.flatMap { c in c.kind == .sequence ? expanded(c).filter { $0.kind == .audio || $0.clip.kind == .media }.map(\.clip) : [c] }.sorted { $0.start < $1.start }
            return t
        }
    }

    /// Moves clips into a new nested sequence and puts one sequence clip in their place.
    public mutating func nest(_ ids: [String], name: String?) throws -> Clip {
        guard !ids.isEmpty else { throw EditError("Pass clips to nest") }
        var picked: [(track: Int, clip: Clip)] = []
        for id in ids {
            guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
            picked.append((loc.track, tracks[loc.track].clips[loc.clip]))
        }
        let start = picked.map(\.clip.start).min()!, end = picked.map(\.clip.end).max()!
        let host = picked.map(\.track).min()!
        guard tracks[host].kind == .video || picked.allSatisfy({ tracks[$0.track].kind == .audio }) else { throw EditError("Nest picture clips from video tracks") }
        var inner: [Track] = []
        for ti in Set(picked.map(\.track)).sorted() {
            var t = tracks[ti]
            t.clips = picked.filter { $0.track == ti }.map { var c = $0.clip; c.start -= start; return c }.sorted { $0.start < $1.start }
            inner.append(t)
        }
        let seqId = IDs.make("seq")
        let nestedIds = Set(ids)
        let moved = transitions.filter { tr in [tr.from, tr.to].compactMap { $0 }.allSatisfy { nestedIds.contains($0) } }
        sequences.append(NestedSequence(id: seqId, name: name ?? "Nested \(sequences.count + 1)", tracks: inner, transitions: moved))
        transitions.removeAll { tr in moved.contains(tr) }
        for (ti, c) in picked { tracks[ti].clips.removeAll { $0.id == c.id } }
        let clip = Clip(id: Project.newClipId(), kind: .sequence, name: name, mediaId: seqId, start: start, duration: end - start)
        if let blocker = tracks[host].clips.first(where: { $0.start < end - eps && $0.end > start + eps }) {
            throw EditError("\(blocker.id) on \(tracks[host].id) sits inside the nested span; include it or move it first")
        }
        tracks[host].clips.append(clip)
        tracks[host].clips.sort { $0.start < $1.start }
        return clip
    }

    /// Puts a sequence clip's contents back on the timeline, on matching or new tracks.
    public mutating func unnest(_ id: String) throws -> [String] {
        guard let loc = locateClip(id), tracks[loc.track].clips[loc.clip].kind == .sequence else { throw EditError("\(id) is not a nested sequence clip") }
        let clip = tracks[loc.track].clips[loc.clip]
        guard let seq = contents(of: clip) else { throw EditError("Missing sequence \(clip.mediaId ?? "")") }
        tracks[loc.track].clips.remove(at: loc.clip)
        var placed: [String] = []
        var idMap: [String: String] = [:]
        for (i, track) in seq.tracks.enumerated() {
            let window = Project.sequenceWindow(clip)
            let clips: [Clip] = track.clips.compactMap { inner in
                guard inner.end > window.start + eps && inner.start < window.end - eps else { return nil }
                var c = inner
                if c.start < window.start { c = Project.trimmedLeft(c, to: window.start) }
                if c.end > window.end { c = Project.trimmedRight(c, to: window.end) }
                c = Project.placed(c, in: clip)
                if locateClip(c.id) != nil { idMap[c.id] = Project.newClipId(); c.id = idMap[c.id]! }
                return c
            }
            let snapshot = tracks
            func free(_ ti: Int) -> Bool {
                snapshot[ti].kind == track.kind && clips.allSatisfy { c in !snapshot[ti].clips.contains { $0.start < c.end - eps && $0.end > c.start + eps } }
            }
            let preferred = i == 0 && snapshot[loc.track].kind == track.kind ? loc.track : nil
            var ti: Int
            if let preferred, free(preferred) { ti = preferred } else if let f = snapshot.indices.first(where: free) { ti = f } else {
                let t = addTrack(kind: track.kind, name: track.name)
                ti = trackIndex(t.id)!
            }
            tracks[ti].clips += clips
            tracks[ti].clips.sort { $0.start < $1.start }
            placed += clips.map(\.id)
        }
        for var tr in seq.transitions {
            tr.from = tr.from.map { idMap[$0] ?? $0 }
            tr.to = tr.to.map { idMap[$0] ?? $0 }
            tr.id = nextTransitionId()
            transitions.append(tr)
        }
        if !tracks.flatMap(\.clips).contains(where: { $0.kind == .sequence && $0.mediaId == seq.id }) { sequences.removeAll { $0.id == seq.id } }
        return placed
    }
}

extension Project {
    /// Source time in `to` of the moment at source time `t` in `from`, when both are in one sync group.
    public func syncedTime(_ t: Seconds, from: String, to: String) -> Seconds? {
        guard let g = syncGroups.first(where: { $0[from] != nil && $0[to] != nil }) else { return nil }
        return t - g[from]! + g[to]!
    }

    /// Records that media were recorded together, merging with any group that shares one of them.
    public mutating func addSyncGroup(_ offsets: [String: Seconds]) {
        var merged = offsets
        syncGroups.removeAll { g in
            guard let shared = g.keys.first(where: { offsets[$0] != nil }) else { return false }
            let shift = offsets[shared]! - g[shared]!
            for (k, v) in g where merged[k] == nil { merged[k] = v + shift }
            return true
        }
        syncGroups.append(merged)
    }
}
