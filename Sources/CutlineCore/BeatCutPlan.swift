import Foundation

/// A span of footage a beat cut can draw from. `quality` and `energy` are on any scale (they are ranked against
/// the other footage); nil leaves the footage unscored.
public struct BeatFootage: Equatable, Sendable {
    public var mediaId: String
    public var range: TimeRange
    /// How good it looks: aesthetics, faces, sharpness.
    public var quality: Double?
    /// How much happens in it: motion.
    public var energy: Double?

    public init(mediaId: String, range: TimeRange, quality: Double? = nil, energy: Double? = nil) {
        self.mediaId = mediaId
        self.range = range
        self.quality = quality
        self.energy = energy
    }

    /// Scores from shot analysis: aesthetics, a bonus for faces at a readable size, penalties for screenshots
    /// and near-black footage; energy is the shot's motion.
    public init(shot: Shot, mediaId: String, range: TimeRange? = nil) {
        var q = ((shot.aesthetics ?? 0) + 1) / 2
        if shot.people > 0, ["close-up", "medium", "extreme close-up"].contains(shot.size) { q += 0.15 }
        if shot.utility == true { q -= 0.3 }
        if shot.brightness < 0.08 { q -= 0.2 }
        self.init(mediaId: mediaId, range: range ?? TimeRange(shot.start, shot.end), quality: q, energy: shot.motion)
    }
}

/// Chooses footage for each shot of a beat cut.
///
/// Each shot takes the footage with the best score: ranked quality, plus (when the music's energy is known)
/// how well the footage's ranked motion matches the ranked energy of that stretch of music, minus penalties for
/// the media used just before, for media used more than the others, and for source time within `spacing` seconds of
/// time already shown from that media (so neighbouring slices of one take don't follow each other). No shot shows
/// source time an earlier shot showed while any unshown moment is long enough; after that, the moment shown longest
/// ago comes back.
public enum BeatCutPlan {
    public struct Segment: Sendable {
        public var need: Seconds
        /// Music loudness over the shot, any scale; nil when unknown.
        public var energy: Double?

        public init(need: Seconds, energy: Double?) {
            self.need = need
            self.energy = energy
        }
    }

    public struct Pick: Equatable, Sendable {
        public var footage: Int
        public var sourceIn: Seconds
    }

    /// A shot that shows again a moment shown before, once every moment was used.
    public struct Reuse: Equatable, Sendable {
        public var segment: Int
        public var footage: Int
        public var sourceIn: Seconds
    }

    public struct Plan: Sendable {
        public var picks: [Pick?]
        /// Shots that show source time an earlier shot already showed.
        public var repeats: Int
        public var scored: Bool
        public var energyMatched: Bool
        public var reused: [Reuse] = []
    }

    /// Ranks in 0…1 (ties share the mean rank); nil entries stay nil.
    static func ranks(_ values: [Double?]) -> [Double?] {
        let known = values.enumerated().compactMap { i, v in v.map { (i, $0) } }.sorted { $0.1 < $1.1 }
        var out = [Double?](repeating: nil, count: values.count)
        guard known.count > 1 else {
            for (i, _) in known { out[i] = 0.5 }
            return out
        }
        var k = 0
        while k < known.count {
            var j = k
            while j + 1 < known.count, known[j + 1].1 - known[k].1 < 1e-9 { j += 1 }
            let r = Double(k + j) / 2 / Double(known.count - 1)
            for m in k...j { out[known[m].0] = r }
            k = j + 1
        }
        return out
    }

    public static func choose(_ footage: [BeatFootage], segments: [Segment], spacing: Seconds = 3) -> Plan {
        let quality = ranks(footage.map(\.quality))
        let motion = ranks(footage.map(\.energy))
        let music = ranks(segments.map(\.energy))
        let scored = quality.contains { $0 != nil }
        let matched = motion.contains { $0 != nil } && music.contains { $0 != nil }
        let mediaIds = Array(Set(footage.map(\.mediaId)))
        var used: [String: [TimeRange]] = [:]
        var mediaUses: [String: Int] = Dictionary(uniqueKeysWithValues: mediaIds.map { ($0, 0) })
        var footageUses = [Int](repeating: 0, count: footage.count)
        var previous: String?
        var picks: [Pick?] = []
        var repeats = 0

        func overlaps(_ r: TimeRange, _ id: String) -> Bool {
            (used[id] ?? []).contains { $0.start < r.end - 1e-6 && r.start < $0.end - 1e-6 }
        }
        /// Seconds between `r` and the nearest time already shown from `id`, up to `spacing`.
        func clearance(_ r: TimeRange, _ id: String) -> Seconds {
            (used[id] ?? []).reduce(spacing) { m, u in min(m, max(0, u.start - r.end, r.start - u.end)) }
        }
        /// The window to use in a footage span: the free stretch farthest (up to `spacing`) from shown time, then
        /// nearest the middle; `clear` is its distance from shown time.
        func window(_ f: BeatFootage, need: Seconds) -> (start: Seconds, fresh: Bool, clear: Seconds) {
            let middle = f.range.start + (f.range.duration - need) / 2
            var starts = [middle, f.range.start, f.range.end - need]
            for u in used[f.mediaId] ?? [] { starts += [u.end, u.start - need, u.end + spacing, u.start - spacing - need] }
            let free = starts.filter { $0 >= f.range.start - 1e-6 && $0 + need <= f.range.end + 1e-6 && !overlaps(TimeRange($0, $0 + need), f.mediaId) }
                .map { (start: $0, clear: clearance(TimeRange($0, $0 + need), f.mediaId)) }
            let best = free.min { a, b in
                abs(a.clear - b.clear) > 1e-6 ? a.clear > b.clear : abs(a.start - middle) < abs(b.start - middle)
            }
            guard let best else { return (middle, false, 0) }
            return (best.start, true, best.clear)
        }

        /// Moments shown so far and the shot that last showed each.
        var shown: [(footage: Int, start: Seconds, last: Int)] = []
        var reused: [Reuse] = []
        for (si, seg) in segments.enumerated() {
            let low = mediaUses.values.min() ?? 0
            var best: (score: Double, index: Int, start: Seconds)?
            for (i, f) in footage.enumerated() where f.range.duration >= seg.need - 1e-6 {
                let w = window(f, need: seg.need)
                guard w.fresh else { continue }
                var score = (quality[i] ?? 0.5)
                if let m = motion[i], let e = music[si] { score += 0.8 * (1 - abs(m - e)) }
                if mediaIds.count > 1, previous == f.mediaId { score -= 0.35 }
                score -= 0.25 * Double((mediaUses[f.mediaId] ?? 0) - low)
                score -= 0.1 * Double(footageUses[i])
                if spacing > 0 { score -= 0.4 * (1 - w.clear / spacing) }
                if best.map({ score > $0.score + 1e-9 }) ?? true { best = (score, i, w.start) }
            }
            if best == nil {
                // Every moment long enough has been shown: show again the one shown longest ago.
                if let k = shown.indices.filter({ footage[shown[$0].footage].range.duration >= seg.need - 1e-6 }).min(by: { shown[$0].last < shown[$1].last }) {
                    let f = footage[shown[k].footage]
                    let start = min(max(shown[k].start, f.range.start), f.range.end - seg.need)
                    best = (0, shown[k].footage, start)
                    shown[k].last = si
                    repeats += 1
                    reused.append(Reuse(segment: si, footage: shown[k].footage, sourceIn: start))
                }
            } else {
                shown.append((best!.index, best!.start, si))
            }
            guard let best else { picks.append(nil); continue }
            let f = footage[best.index]
            used[f.mediaId, default: []].append(TimeRange(best.start, best.start + seg.need))
            mediaUses[f.mediaId, default: 0] += 1
            footageUses[best.index] += 1
            previous = f.mediaId
            picks.append(Pick(footage: best.index, sourceIn: best.start))
        }
        return Plan(picks: picks, repeats: repeats, scored: scored, energyMatched: matched && scored, reused: reused)
    }
}

extension Transform {
    /// The x and y offsets that frame a fill-scaled picture so `subjects` (boxes in fractions of the source frame)
    /// stay in view: horizontally centered, faces a little above center for headroom. Subjects that don't fit
    /// together fall back to the largest one. Offsets stay inside the picture's overflow, so no edge shows.
    public static func fillOffset(sourceAspect: Double, canvasAspect: Double, scale: Double = 1, subjects: [NormRect], faces: Bool) -> (x: Double, y: Double)? {
        guard let largest = subjects.max(by: { $0.area < $1.area }), sourceAspect > 0, canvasAspect > 0 else { return nil }
        let pw = max(1, sourceAspect / canvasAspect) * scale, ph = max(1, canvasAspect / sourceAspect) * scale
        let roomX = max(0, (pw - 1) / 2), roomY = max(0, (ph - 1) / 2)
        guard roomX > 0.001 || roomY > 0.001 else { return nil }
        var box = subjects.dropFirst().reduce(subjects[0]) { $0.union($1) }
        if box.width * pw > 0.95 || box.height * ph > 0.9 { box = largest }
        let x = min(roomX, max(-roomX, (0.5 - box.midX) * pw))
        // Faces sit at 40% of the frame height; their top stays at least 5% below the frame's top.
        var target = faces ? 0.4 : 0.5
        if faces { target = max(target, 0.05 + box.height * ph / 2) }
        let y = min(roomY, max(-roomY, target - 0.5 - (box.midY - 0.5) * ph))
        return (x, y)
    }
}

extension Project {
    /// Musical loudness per beat of every audible music clip, in timeline time, sorted (0…1 from beat analysis).
    public func timelineBeatEnergy(_ index: AnchorIndex) -> [(t: Seconds, energy: Double)] {
        var out: [(t: Seconds, energy: Double)] = []
        for track in tracks where !track.muted {
            for c in track.clips where c.kind == .media {
                guard let id = c.mediaId, index.music.contains(id), let b = index.beats[id], b.energy.count == b.beats.count else { continue }
                for (t, e) in zip(b.beats, b.energy) where t >= c.sourceIn - 1e-6 && t < c.sourceOut - 1e-6 {
                    out.append((c.timelineTime(atSource: t), Double(e)))
                }
            }
        }
        return out.sorted { $0.t < $1.t }
    }
}
