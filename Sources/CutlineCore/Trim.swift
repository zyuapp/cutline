import Foundation

public enum TrimMode: String, CaseIterable, Sendable {
    /// Move one edge; nothing else moves.
    case plain
    /// Move one edge and shift everything after it on the track (or on every track) to keep gaps.
    case ripple
    /// Move a cut between two touching clips: one gets longer, the other shorter.
    case roll
    /// Change which part of the source plays, keeping the clip's position and length.
    case slip
    /// Move the clip between its neighbours, which shorten or lengthen to fill.
    case slide
}

public enum ClipEdge: String, Sendable {
    case start, end
}

extension Project {
    /// Trims a clip and its linked clips alike, so linked picture and sound stay in sync: slip slips them all, slide
    /// slides them all, plain, roll and ripple trims move a linked clip's edge when it meets the trimmed edge (a split
    /// edit's offset edge stays), and clips a ripple shifts take their linked clips along. `delta` is seconds on the
    /// timeline (positive moves the edge later); for slip it is seconds of source. Returns a description of what moved.
    @discardableResult
    public mutating func trim(_ id: String, mode: TrimMode, edge: ClipEdge, delta rawDelta: Seconds, allTracks: Bool = false) throws -> String {
        guard let c = clip(id), let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        let partners = linked(id).compactMap { clip($0) }.filter { o in locateClip(o.id).map { $0.track != loc.track } ?? false }
        let starts = clipStarts
        let line = try trimOne(id, mode: mode, edge: edge, delta: rawDelta, allTracks: allTracks)
        guard abs(canvas.snap(rawDelta)) > eps else { return line }
        let tol = canvas.frameDuration / 2
        var followed: [String] = []
        for o in partners {
            let met = edge == .start ? abs(o.start - c.start) < tol : abs(o.end - c.end) < tol
            do {
                switch mode {
                case .slip:
                    guard o.kind == .media else { continue }
                    _ = try trimOne(o.id, mode: .slip, edge: edge, delta: rawDelta)
                case .slide:
                    _ = try trimOne(o.id, mode: .slide, edge: edge, delta: rawDelta)
                case .roll:
                    guard met else { continue }
                    do { _ = try trimOne(o.id, mode: .roll, edge: edge, delta: rawDelta) } catch {
                        _ = try trimOne(o.id, mode: .plain, edge: edge, delta: rawDelta)
                    }
                case .plain:
                    guard met else { continue }
                    _ = try trimOne(o.id, mode: .plain, edge: edge, delta: rawDelta)
                case .ripple:
                    guard met else { continue }
                    if allTracks {
                        // Every track already shifted; only the edge moves.
                        guard let cur = clip(o.id), let ol = locateClip(o.id) else { continue }
                        let d = canvas.snap(rawDelta)
                        var u = edge == .start ? (d > 0 ? Project.trimmedLeft(cur, to: cur.start + d) : Project.extendedLeft(cur, by: -d)) : (d < 0 ? Project.trimmedRight(cur, to: cur.end + d) : Project.extendedRight(cur, by: d))
                        if edge == .start { u.start = cur.start }
                        tracks[ol.track].clips[ol.clip] = u
                    } else {
                        _ = try trimOne(o.id, mode: .ripple, edge: edge, delta: rawDelta)
                    }
                }
            } catch {
                throw EditError("Linked \(o.id) can't \(mode.rawValue) with \(id): \(error.localizedDescription) Unlink it (clip_update unlink:true) or make room")
            }
            followed.append(o.id)
        }
        let carried = mode == .ripple ? propagateLinkedShifts(before: starts) : []
        var out = line
        if !followed.isEmpty { out += "; linked \(followed.joined(separator: ", ")) \(mode == .slip ? "slipped" : mode == .slide ? "slid" : "trimmed") with it" }
        if !carried.isEmpty { out += "; linked \(carried.joined(separator: ", ")) moved with their clips" }
        return out
    }

    mutating func trimOne(_ id: String, mode: TrimMode, edge: ClipEdge, delta rawDelta: Seconds, allTracks: Bool = false) throws -> String {
        guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        let t = loc.track
        let delta = canvas.snap(rawDelta)
        guard abs(delta) > eps else { return "No change" }
        let clips = tracks[t].clips
        let c = clips[loc.clip]
        let prev = loc.clip > 0 ? clips[loc.clip - 1] : nil
        let next = loc.clip + 1 < clips.count ? clips[loc.clip + 1] : nil
        func touching(_ a: Clip?, _ b: Clip?) -> Bool {
            guard let a, let b else { return false }
            return abs(b.start - a.end) < canvas.frameDuration / 2
        }
        switch mode {
        case .plain, .ripple:
            let remaining = edge == .start ? c.duration - delta : c.duration + delta
            guard remaining >= canvas.frameDuration else { throw EditError("\(id) would be shorter than a frame") }
            var updated: Clip
            if edge == .start {
                updated = delta > 0 ? Project.trimmedLeft(c, to: c.start + delta) : Project.extendedLeft(c, by: -delta)
                if mode == .ripple { updated.start = c.start }
            } else {
                updated = delta < 0 ? Project.trimmedRight(c, to: c.end + delta) : Project.extendedRight(c, by: delta)
            }
            tracks[t].clips[loc.clip] = updated
            if mode == .ripple {
                let shift = edge == .start ? -delta : delta
                let pivot = c.end
                for ti in tracks.indices where ti == t || allTracks {
                    for i in tracks[ti].clips.indices where tracks[ti].clips[i].id != id && tracks[ti].clips[i].start >= pivot - eps {
                        tracks[ti].clips[i].start = canvas.snap(tracks[ti].clips[i].start + shift)
                    }
                }
                if allTracks { for i in markers.indices where markers[i].time >= pivot - eps { markers[i].time += shift } }
                return "\(id) \(edge.rawValue) \(delta > 0 ? "+" : "")\(fmt2(delta))s; later clips moved \(shift > 0 ? "+" : "")\(fmt2(shift))s"
            }
            return "\(id) \(edge.rawValue) \(delta > 0 ? "+" : "")\(fmt2(delta))s"
        case .roll:
            let (left, right) = edge == .end ? (c, next) : (prev, c)
            guard let left, let right, touching(left, right) else { throw EditError("Roll needs a clip touching \(id)'s \(edge.rawValue)") }
            guard left.duration + delta >= canvas.frameDuration, right.duration - delta >= canvas.frameDuration else { throw EditError("The roll would make a clip shorter than a frame") }
            let li = tracks[t].clips.firstIndex { $0.id == left.id }!, ri = li + 1
            tracks[t].clips[li] = delta > 0 ? Project.extendedRight(left, by: delta) : Project.trimmedRight(left, to: left.end + delta)
            tracks[t].clips[ri] = delta > 0 ? Project.trimmedLeft(right, to: right.start + delta) : Project.extendedLeft(right, by: -delta)
            return "Cut between \(left.id) and \(right.id) moved \(delta > 0 ? "+" : "")\(fmt2(delta))s to \(fmt2(left.end + delta))"
        case .slip:
            guard c.kind == .media else { throw EditError("Only media clips slip") }
            tracks[t].clips[loc.clip].sourceIn = c.sourceIn + delta
            return "\(id) now plays source \(fmt2(c.sourceIn + delta))–\(fmt2(c.sourceOut + delta))"
        case .slide:
            if let prev, touching(prev, c) {
                guard prev.duration + delta >= canvas.frameDuration else { throw EditError("\(prev.id) would be shorter than a frame") }
            } else if delta < 0, let prev, c.start + delta < prev.end - eps {
                throw EditError("\(id) would overlap \(prev.id)")
            }
            if let next, touching(c, next) {
                guard next.duration - delta >= canvas.frameDuration else { throw EditError("\(next.id) would be shorter than a frame") }
            } else if delta > 0, let next, c.end + delta > next.start + eps {
                throw EditError("\(id) would overlap \(next.id)")
            }
            if let prev, touching(prev, c), let pi = tracks[t].clips.firstIndex(where: { $0.id == prev.id }) {
                tracks[t].clips[pi] = delta > 0 ? Project.extendedRight(prev, by: delta) : Project.trimmedRight(prev, to: prev.end + delta)
            }
            if let next, touching(c, next), let ni = tracks[t].clips.firstIndex(where: { $0.id == next.id }) {
                tracks[t].clips[ni] = delta > 0 ? Project.trimmedLeft(next, to: next.start + delta) : Project.extendedLeft(next, by: -delta)
            }
            tracks[t].clips[loc.clip].start = canvas.snap(c.start + delta)
            return "\(id) slid \(delta > 0 ? "+" : "")\(fmt2(delta))s to \(fmt2(c.start + delta))–\(fmt2(c.end + delta))"
        }
    }

    /// Lengthens a clip at its end, using more source.
    static func extendedRight(_ c: Clip, by d: Seconds) -> Clip {
        var c = c
        if c.kind == .media && c.reverse { c.sourceIn -= d * c.speed(atLocal: c.duration) }
        c.duration += d
        return c
    }

    /// Lengthens a clip at its start, using earlier source and shifting its animation.
    static func extendedLeft(_ c: Clip, by d: Seconds) -> Clip {
        var c = c
        c.start -= d
        c.duration += d
        if (c.kind == .media && !c.reverse) || c.kind == .sequence { c.sourceIn -= d * c.speed(atLocal: 0) }
        c.anim = c.anim.mapValues { $0.shifted(by: d) }
        return c
    }
}
