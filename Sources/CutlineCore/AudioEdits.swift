import Foundation

extension Project {
    /// Timeline ranges where speech is heard on the given tracks (all unmuted tracks when empty),
    /// from transcripts. Words closer than `bridge` are joined into one range.
    public func speechRanges(transcripts: [String: Transcript], trackIds: [String] = [], bridge: Seconds = 0.6) -> [TimeRange] {
        let words = timelineWords(transcripts: transcripts, trackIds: trackIds)
        return TimeRange.merged(words.map { TimeRange($0.start, $0.end) }, tolerance: bridge)
    }

    /// Lowers the volume of clips while speech plays, by writing audio.volume animation.
    /// Returns how many dips were written.
    @discardableResult
    public mutating func duck(clipIds: [String], under speech: [TimeRange], amountDb: Double, attack: Seconds, release: Seconds) throws -> Int {
        let dip = pow(10, -abs(amountDb) / 20)
        var dips = 0
        for id in clipIds {
            guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
            var c = tracks[loc.track].clips[loc.clip]
            let full = c.volume
            let low = full * dip
            // Expand each speech range by attack and release, then merge so dips never fight.
            let windows = TimeRange.merged(speech.compactMap { r -> TimeRange? in
                let w = TimeRange(r.start - attack, r.end + release)
                return w.intersection(TimeRange(c.start, c.end)) != nil ? w : nil
            })
            var keys: [CurveKey] = []
            for w in windows {
                let down = max(0, w.start - c.start), up = min(c.duration, w.end - c.start)
                let inner0 = min(down + attack, up), inner1 = max(up - release, inner0)
                keys.append(CurveKey(t: down, v: .number(full), ease: .easeInOut))
                keys.append(CurveKey(t: inner0, v: .number(low), ease: .easeInOut))
                keys.append(CurveKey(t: inner1, v: .number(low), ease: .linear))
                keys.append(CurveKey(t: up, v: .number(full), ease: .easeInOut))
                dips += 1
            }
            var deduped: [CurveKey] = []
            for k in keys.sorted(by: { $0.t < $1.t }) {
                if let last = deduped.last, abs(last.t - k.t) < 1e-4 { deduped[deduped.count - 1] = k } else { deduped.append(k) }
            }
            try c.animate("audio.volume", keys: deduped)
            tracks[loc.track].clips[loc.clip] = c
        }
        return dips
    }

    /// Makes the cut between two adjacent clips a split edit. Positive `offset` is a J cut
    /// (the second clip's sound starts early); negative is an L cut (the first clip's sound runs long).
    public mutating func splitEdit(left leftId: String, right rightId: String, offset: Seconds) throws {
        guard let l = locateClip(leftId), let r = locateClip(rightId) else { throw EditError("Both clips must exist") }
        guard l.track == r.track else { throw EditError("\(leftId) and \(rightId) are on different tracks") }
        let a = tracks[l.track].clips[l.clip], b = tracks[r.track].clips[r.clip]
        guard abs(a.end - b.start) < 1e-3 else { throw EditError("\(leftId) must end where \(rightId) starts (they're \(fmt(b.start - a.end))s apart)") }
        var na = a, nb = b
        if offset >= 0 {
            nb.audioLead = offset
            na.audioLag = -offset
        } else {
            na.audioLag = -offset
            nb.audioLead = offset
        }
        guard na.audioRange.duration > 0.05, nb.audioRange.duration > 0.05 else { throw EditError("A \(fmt(abs(offset)))s split would leave no sound on one of the clips") }
        let track = tracks[l.track]
        try checkClipFits(na, track: track)
        try checkClipFits(nb, track: track)
        tracks[l.track].clips[l.clip] = na
        tracks[r.track].clips[r.clip] = nb
    }
}
