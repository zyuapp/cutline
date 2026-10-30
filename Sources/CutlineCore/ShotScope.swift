import Foundation

extension Shot {
    /// Spans of a media file between its scene cuts, in source seconds (long takes are not split).
    public static func ranges(cuts: [Seconds], duration: Seconds) -> [TimeRange] {
        let bounds = [0] + cuts.filter { $0 > 0.01 && $0 < duration - 0.01 }.sorted() + [max(duration, 0)]
        return zip(bounds, bounds.dropFirst()).filter { $0.1 > $0.0 }.map { TimeRange($0.0, $0.1) }
    }
}

extension Clip {
    /// The source span the clip plays, low to high.
    public var sourceSpan: TimeRange { TimeRange(min(sourceIn, sourceOut), max(sourceIn, sourceOut)) }

    /// The shots (source spans between `cuts`) this clip plays, in play order, each cut to what the clip plays of it.
    public func shots(cuts: [Seconds], mediaDuration: Seconds) -> [TimeRange] {
        let span = sourceSpan
        let out = Shot.ranges(cuts: cuts, duration: max(mediaDuration, span.end)).compactMap { r -> TimeRange? in
            let lo = max(r.start, span.start), hi = min(r.end, span.end)
            return hi - lo > 1e-3 ? TimeRange(lo, hi) : nil
        }
        return reverse ? out.reversed() : out
    }

    /// The effect stack as it acts at timeline time `t`: effects limited to a shot the clip isn't showing are turned off.
    public func effects(atTimeline t: Seconds) -> [Effect] {
        guard effects.contains(where: { $0.sourceRange != nil }) else { return effects }
        let s = sourceTime(atTimeline: t)
        return effects.map { e in
            var e = e
            if !e.acts(atSource: s) { e.enabled = false }
            return e
        }
    }

    /// Timeline span where the clip shows source span `r`.
    public func timelineSpan(ofSource r: TimeRange) -> TimeRange {
        let a = timelineTime(atSource: r.start), b = timelineTime(atSource: r.end)
        return TimeRange(max(start, min(a, b)), min(end, max(a, b)))
    }
}

extension Project {
    /// Splits a clip at each of its media's scene cuts (source seconds) that falls inside it, on the frame grid.
    /// Returns the ids of the pieces in timeline order; cuts closer than a frame to an edge are skipped. Each piece
    /// keeps only the shot-limited effects of its own shot, now acting throughout it.
    @discardableResult
    public mutating func splitAtShots(_ id: String, cuts: [Seconds]) throws -> [String] {
        guard let c = clip(id) else { throw EditError("No clip \(id)") }
        let span = c.sourceSpan
        let times = cuts.filter { $0 > span.start + 1e-6 && $0 < span.end - 1e-6 }
            .map { canvas.snap(c.timelineTime(atSource: $0)) }
            .filter { $0 > c.start + canvas.frameDuration / 2 && $0 < c.end - canvas.frameDuration / 2 }
        var pieces = [id]
        for t in Set(times).sorted(by: >) {
            let (_, right) = try splitClip(id, at: t)
            pieces.insert(right, at: 1)
        }
        for pid in pieces {
            guard let loc = locateClip(pid) else { continue }
            var piece = tracks[loc.track].clips[loc.clip]
            let span = piece.sourceSpan
            for e in piece.effects {
                guard let r = e.sourceRange else { continue }
                if r.end <= span.start + 1e-3 || r.start >= span.end - 1e-3 {
                    piece.effects.removeAll { $0.id == e.id }
                    for key in piece.anim.keys where key.hasPrefix("fx.\(e.id).") { piece.anim[key] = nil }
                } else if r.start <= span.start + 1e-3, r.end >= span.end - 1e-3, let i = piece.effects.firstIndex(where: { $0.id == e.id }) {
                    piece.effects[i].sourceRange = nil
                }
            }
            tracks[loc.track].clips[loc.clip] = piece
        }
        return pieces
    }
}
