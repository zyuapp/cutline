import Foundation

/// Time a ripple opens or closes on the timeline.
enum RippleSpan {
    /// `amount` seconds pushed in at `at`.
    case open(at: Seconds, amount: Seconds)
    /// `range` taken out; what follows closes up.
    case close(TimeRange)

    /// Where clips start moving.
    var point: Seconds {
        switch self {
        case .open(let at, _): at
        case .close(let r): r.end
        }
    }

    var shift: Seconds {
        switch self {
        case .open(_, let amount): amount
        case .close(let r): -r.duration
        }
    }
}

extension Project {
    /// Carries a ripple to the tracks `scope` (indices). On sync-locked tracks clips spanning the edit point split
    /// (open) or lose the closed range (close), and later clips move. Tracks with sync lock off keep their clips,
    /// except clips linked to a clip outside them, which follow their link. With `carryLinked`, a clip spanning the
    /// point whose linked clip starts after it (a J cut's sound) moves whole instead, when that leaves room.
    /// Clips in `skip` are left to the caller. Returns a note per track that changed or was spared.
    @discardableResult
    mutating func rippleTracks(_ scope: [Int], _ span: RippleSpan, skip: Set<String> = [], carryLinked: Bool = false) -> [String] {
        let before = tracks
        let existing = Set(tracks.flatMap(\.clips).map(\.id))
        let unlocked = Set(scope.filter { !tracks[$0].syncLock })
        let anchored = Set(tracks.indices.filter { !unlocked.contains($0) }.flatMap { tracks[$0].clips.compactMap(\.link) })
        let point = canvas.snap(span.point), shift = span.shift
        let movers: Set<String> = carryLinked ? Set(tracks.indices.filter { !unlocked.contains($0) }.flatMap { i in
            tracks[i].clips.filter { $0.start >= point - eps && !skip.contains($0.id) }.compactMap(\.link)
        }) : []
        var spared: [String] = []
        for t in scope {
            let followerOnly = unlocked.contains(t)
            func acts(_ c: Clip) -> Bool {
                guard !skip.contains(c.id) else { return false }
                return !followerOnly || !existing.contains(c.id) || (c.link.map(anchored.contains) ?? false)
            }
            let reach: Seconds = { if case .close(let r) = span { return r.start } else { return point } }()
            func whole(_ c: Clip) -> Bool { c.start < point - eps && c.end > reach + eps && (c.link.map(movers.contains) ?? false) }
            if followerOnly, tracks[t].clips.contains(where: { $0.end > point + eps && !acts($0) }) { spared.append(tracks[t].id) }
            switch span {
            case .open(let at, _):
                for c in tracks[t].clips where acts(c) && !whole(c) && at > c.start + eps && at < c.end - eps {
                    _ = try? splitClip(c.id, at: at)
                }
                if !followerOnly { isolateSound(trackIndex: t, around: TimeRange(at, at)) }
                for i in tracks[t].clips.indices where acts(tracks[t].clips[i]) && (tracks[t].clips[i].start >= at - eps || whole(tracks[t].clips[i])) {
                    tracks[t].clips[i].start = canvas.snap(tracks[t].clips[i].start + shift)
                }
            case .close(let r):
                let carried = Set(tracks[t].clips.filter { acts($0) && whole($0) }.filter { c in
                    let s = c.start + shift
                    return !tracks[t].clips.contains { $0.id != c.id && $0.start < r.start - eps && min($0.end, r.start) > s + eps }
                }.map(\.id))
                clearRange(trackIndex: t, r, keep: { !acts($0) || carried.contains($0.id) }, isolating: !followerOnly)
                for i in tracks[t].clips.indices where acts(tracks[t].clips[i]) && (tracks[t].clips[i].start >= r.end - eps || carried.contains(tracks[t].clips[i].id)) {
                    tracks[t].clips[i].start = canvas.snap(tracks[t].clips[i].start + shift)
                }
            }
            tracks[t].clips.sort { $0.start < $1.start }
        }
        relinkPieces(existing: existing)
        var notes = rippleNotes(before: before, tracks: scope, splitting: span.shift > 0)
        if !spared.isEmpty { notes.append("\(spared.joined(separator: ", ")) (sync lock off) left in place") }
        return notes
    }

    /// Clip pieces an edit cut off a linked clip get a link of their own, shared with the pieces cut from its
    /// partners, so the halves on either side of the cut move apart.
    mutating func relinkPieces(existing: Set<String>) {
        var fresh: [String: String] = [:]
        let groups = Dictionary(grouping: tracks.flatMap(\.clips).filter { $0.link != nil }, by: { $0.link! })
        let mixed = Set(groups.filter { g in g.value.contains { existing.contains($0.id) } && g.value.contains { !existing.contains($0.id) } }.keys)
        guard !mixed.isEmpty else { return }
        for t in tracks.indices {
            for i in tracks[t].clips.indices {
                let c = tracks[t].clips[i]
                guard let l = c.link, mixed.contains(l), !existing.contains(c.id) else { continue }
                if fresh[l] == nil { fresh[l] = IDs.make("lnk") }
                tracks[t].clips[i].link = fresh[l]
            }
        }
    }

    /// What a ripple did on each of `tracks` (indices), compared with `before`: clips moved, split, cut or removed.
    func rippleNotes(before: [Track], tracks scope: [Int], splitting: Bool = false) -> [String] {
        var out: [String] = []
        for t in scope {
            let now = tracks[t]
            guard let old = before.first(where: { $0.id == now.id }) else { continue }
            let was = Dictionary(old.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ids = Set(now.clips.map(\.id))
            var moved: [String: Int] = [:], cut: [String] = []
            for c in now.clips {
                guard let o = was[c.id] else { continue }
                if abs(c.duration - o.duration) > eps { cut.append(c.id) } else if abs(c.start - o.start) > eps { moved[signed(c.start - o.start), default: 0] += 1 }
            }
            let added = now.clips.filter { was[$0.id] == nil }.count
            let removed = old.clips.filter { !ids.contains($0.id) }.map(\.id)
            var parts = moved.sorted { $0.key < $1.key }.map { "\($0.value) clip\($0.value == 1 ? "" : "s") moved \($0.key)s" }
            if !cut.isEmpty { parts.append((splitting && added > 0 ? "split " : "cut ") + cut.joined(separator: ", ")) }
            if !removed.isEmpty { parts.append("removed " + removed.joined(separator: ", ")) }
            if !parts.isEmpty { out.append("\(now.id): " + parts.joined(separator: ", ")) }
        }
        return out
    }

    private func signed(_ x: Seconds) -> String { (x > 0 ? "+" : "−") + fmt2(abs(x)) }
}
