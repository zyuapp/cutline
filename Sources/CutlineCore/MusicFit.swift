import Foundation

/// Plays a song in a different length by cutting out or repeating whole bars, joined on downbeats.
public enum MusicFit {
    public struct Plan: Equatable, Sendable {
        /// Source spans played back to back.
        public var pieces: [TimeRange]
        /// Seconds left to trim from the end (with a fade) to land exactly on the target.
        public var overshoot: Seconds
        public var length: Seconds { pieces.reduce(0) { $0 + $1.duration } }
    }

    /// `song` is the source span to fit; `downbeats` are source times. The cut sits as close to the middle as the bars allow,
    /// and the plan never ends short of `target` when the song is long enough to cover it.
    public static func plan(song: TimeRange, downbeats: [Seconds], target: Seconds) throws -> Plan {
        guard target > 0 else { throw EditError("Target length must be positive") }
        let bars = downbeats.filter { $0 > song.start + 0.05 && $0 < song.end - 0.05 }.sorted()
        let change = target - song.duration
        if abs(change) < 0.02 { return Plan(pieces: [song], overshoot: 0) }
        if change < 0 && target < (bars.first ?? song.end) - song.start + 0.5 {
            return Plan(pieces: [song], overshoot: song.duration - target)
        }
        guard bars.count >= 2 else { throw EditError("Need at least two analyzed downbeats to cut the music on bars; run media_analyze features:[\"beats\"]") }
        let middle = song.start + target / 2

        if change < 0 {
            let remove = -change
            var best: (i: Int, j: Int, score: Double)?
            for i in bars.indices {
                for j in (i + 1)..<bars.count {
                    let cut = bars[j] - bars[i]
                    if cut > remove + 1e-6 { break }
                    // Remove at most `remove`, so the rest trims from the tail; prefer cuts near the middle.
                    let score = (remove - cut) + 0.02 * abs(bars[i] - middle)
                    if best == nil || score < best!.score { best = (i, j, score) }
                }
            }
            guard let b = best else { return Plan(pieces: [song], overshoot: song.duration - target) }
            let pieces = [TimeRange(song.start, bars[b.i]), TimeRange(bars[b.j], song.end)]
            let plan = Plan(pieces: pieces, overshoot: 0)
            return Plan(pieces: pieces, overshoot: max(0, plan.length - target))
        }

        let extra = change
        var best: (i: Int, j: Int, repeats: Int, score: Double)?
        for i in bars.indices {
            for j in (i + 1)..<bars.count {
                let section = bars[j] - bars[i]
                guard section > 1e-3 else { continue }
                let repeats = max(1, Int((extra / section).rounded(.up)))
                guard repeats <= 16 else { continue }
                let score = (Double(repeats) * section - extra) + 0.5 * Double(repeats - 1) + 0.02 * abs(bars[i] - middle)
                if best == nil || score < best!.score { best = (i, j, repeats, score) }
            }
        }
        guard let b = best else { throw EditError("The music is too short to loop to \(target)s") }
        var pieces = [TimeRange(song.start, bars[b.j])]
        for _ in 1..<b.repeats { pieces.append(TimeRange(bars[b.i], bars[b.j])) }
        pieces.append(TimeRange(bars[b.i], song.end))
        let length = pieces.reduce(0) { $0 + $1.duration }
        return Plan(pieces: pieces, overshoot: max(0, length - target))
    }
}

extension Project {
    /// Replaces a music clip with bar-cut pieces that play for `length` seconds, ending on the song's own ending
    /// (or a fade where the bars can't land exactly).
    public mutating func fitMusic(clipId: String, length: Seconds, downbeats: [Seconds], fadeOut: Seconds = 1.5) throws -> String {
        guard let loc = locateClip(clipId) else { throw EditError("No clip \(clipId)") }
        let clip = tracks[loc.track].clips[loc.clip]
        guard clip.kind == .media, clip.mediaId != nil, clip.speed == 1, !clip.reverse else { throw EditError("\(clipId) must be a media clip at normal speed") }
        let song = TimeRange(clip.sourceIn, clip.sourceOut)
        let plan = try MusicFit.plan(song: song, downbeats: downbeats, target: length)
        let trackId = tracks[loc.track].id
        tracks[loc.track].clips.remove(at: loc.clip)
        var t = clip.start
        var ids: [String] = []
        let declick = 0.02
        for (k, piece) in plan.pieces.enumerated() {
            var c = clip
            c.id = k == 0 ? clip.id : Project.newClipId()
            c.start = canvas.snap(t)
            c.sourceIn = piece.start
            c.duration = piece.duration
            c.audioFadeIn = k == 0 ? clip.audioFadeIn : declick
            c.audioFadeOut = declick
            c.anim = [:]
            if k == plan.pieces.count - 1 {
                c.duration = max(0.1, piece.duration - plan.overshoot)
                c.audioFadeOut = plan.overshoot > 0.05 ? min(fadeOut, c.duration) : max(declick, clip.audioFadeOut)
            }
            c.duration = canvas.snap(c.start + c.duration) - c.start
            _ = try addClip(c, trackId: trackId, mode: .overwrite)
            ids.append(c.id)
            t = c.start + c.duration
        }
        let joins = plan.pieces.count - 1
        let how = length < song.duration ? "cut \(fmt2(song.duration - (plan.length)))s of bars" : "repeated \(fmt2(plan.length - song.duration))s of bars"
        return "Fit \(clipId) to \(fmt2(t - clip.start))s (was \(fmt2(song.duration))s): \(how) at \(joins) downbeat join\(joins == 1 ? "" : "s")" + (plan.overshoot > 0.05 ? ", last \(fmt2(plan.overshoot))s trimmed with a \(fmt2(fadeOut))s fade" : ", ending on the song's own ending") + ". Pieces: " + ids.joined(separator: ", ")
    }
}
