import Foundation

/// A spoken word in the reference recording's time, with the angle that should be on screen while it is said.
public struct MulticamWord: Equatable, Sendable {
    public var start: Seconds
    public var end: Seconds
    public var text: String
    /// nil keeps whoever was on screen.
    public var angle: String?

    public init(start: Seconds, end: Seconds, text: String, angle: String?) {
        self.start = start
        self.end = end
        self.text = text
        self.angle = angle
    }
}

/// One shot of a multicam edit, in the reference recording's time.
public struct MulticamShot: Equatable, Sendable {
    public var start: Seconds
    public var end: Seconds
    public var angle: String
    /// Why this angle: "speaker", "reaction" or "wide".
    public var kind: String

    public init(start: Seconds, end: Seconds, angle: String, kind: String = "speaker") {
        self.start = start
        self.end = end
        self.angle = angle
        self.kind = kind
    }

    public var duration: Seconds { end - start }
}

public struct MulticamOptions: Sendable {
    /// No shot is shorter than this; quicker interjections stay on the current angle.
    public var minShot: Seconds = 1.0
    /// How far before a new speaker's first word the cut lands, at most half the pause before it.
    public var cutLead: Seconds = 0.15
    /// Cut to the listener for `reactionLength` in turns longer than `reactionAfter`; nil for no reactions.
    public var reactionAfter: Seconds? = nil
    public var reactionLength: Seconds = 1.5
    /// Show this angle for `wideLength` in the middle of turns longer than `wideAfter`.
    public var wide: String? = nil
    public var wideAfter: Seconds = 12
    public var wideLength: Seconds = 3

    public init() {}
}

/// Plans multicam edits from who is speaking: one shot per speaker turn, cut in the pause before the new speaker
/// (never inside a word), turns shorter than the minimum shot folded into their neighbours, optional listener
/// reactions and wide shots in long turns.
public enum MulticamPlan {
    public static func shots(words raw: [MulticamWord], range: TimeRange, first: String, options o: MulticamOptions = MulticamOptions()) -> [MulticamShot] {
        let words = raw.filter { $0.end > range.start && $0.start < range.end }.sorted { $0.start < $1.start }
        // Speaker turns as runs of words.
        var turns: [(angle: String, a: Int, b: Int)] = []
        for (i, w) in words.enumerated() {
            let angle = w.angle ?? turns.last?.angle ?? first
            if let last = turns.last, last.angle == angle { turns[turns.count - 1].b = i } else { turns.append((angle, i, i)) }
        }
        guard !turns.isEmpty else { return [MulticamShot(start: range.start, end: range.end, angle: first)] }

        func cut(before i: Int) -> Seconds {
            let next = words[i], prev = words[i - 1]
            let gap = next.start - prev.end
            return gap > 0 ? next.start - min(o.cutLead, gap / 2) : next.start
        }
        func bounds() -> [Seconds] { [range.start] + turns.dropFirst().map { cut(before: $0.a) } + [range.end] }
        func coalesce() {
            var out: [(angle: String, a: Int, b: Int)] = []
            for t in turns { if let l = out.last, l.angle == t.angle { out[out.count - 1].b = t.b } else { out.append(t) } }
            turns = out
        }
        while turns.count > 1 {
            let edges = bounds()
            let lengths = turns.indices.map { edges[$0 + 1] - edges[$0] }
            guard let i = lengths.indices.min(by: { lengths[$0] < lengths[$1] }), lengths[i] < o.minShot else { break }
            if i > 0, i + 1 < turns.count, turns[i - 1].angle == turns[i + 1].angle {
                turns[i - 1].b = turns[i + 1].b
                turns.removeSubrange(i...(i + 1))
            } else if i > 0 {
                turns[i - 1].b = turns[i].b
                turns.remove(at: i)
            } else {
                turns[1].a = turns[0].a
                turns.remove(at: 0)
            }
            coalesce()
        }

        let edges = bounds()
        var shots: [MulticamShot] = []
        for (k, t) in turns.enumerated() {
            let s = edges[k], e = edges[k + 1]
            let gaps = (t.a..<t.b).map { (cut(before: $0 + 1), words[$0 + 1].start - words[$0].end) }
            var inserts: [MulticamShot] = []
            if let wide = o.wide, wide != t.angle, e - s > o.wideAfter {
                inserts.append(contentsOf: cutaway(in: s, e, gaps: gaps, angle: wide, length: o.wideLength, kind: "wide", minShot: o.minShot))
            } else if let after = o.reactionAfter, e - s > after {
                let listener = (k > 0 ? turns[k - 1].angle : nil) ?? (k + 1 < turns.count ? turns[k + 1].angle : nil)
                if let listener, listener != t.angle {
                    inserts.append(contentsOf: cutaway(in: s, e, gaps: gaps, angle: listener, length: o.reactionLength, kind: "reaction", minShot: o.minShot))
                }
            }
            var cursor = s
            for ins in inserts {
                shots.append(MulticamShot(start: cursor, end: ins.start, angle: t.angle))
                shots.append(ins)
                cursor = ins.end
            }
            shots.append(MulticamShot(start: cursor, end: e, angle: t.angle))
        }
        return shots
    }

    /// A cutaway starting at the word gap nearest the middle of `s…e` (preferring longer pauses), ending at the first
    /// gap at least `length` later, leaving at least `minShot` of the turn on either side.
    static func cutaway(in s: Seconds, _ e: Seconds, gaps: [(at: Seconds, pause: Seconds)], angle: String, length: Seconds, kind: String, minShot: Seconds) -> [MulticamShot] {
        let mid = (s + e) / 2 - length / 2
        let starts = gaps.filter { $0.at - s >= minShot && e - $0.at >= length + minShot }
        guard let start = starts.min(by: { abs($0.at - mid) - $0.pause * 2 < abs($1.at - mid) - $1.pause * 2 }) else { return [] }
        guard let end = gaps.first(where: { $0.at >= start.at + length && e - $0.at >= minShot }) else { return [] }
        return [MulticamShot(start: start.at, end: end.at, angle: angle, kind: kind)]
    }

    /// Who is speaking by whose microphone is loudest: each angle's word levels (dB, nil when unmeasured) are taken
    /// relative to that angle's 90th percentile, so mics with different gain compare fairly. Returns an angle per word
    /// (nil when no level) and the median margin in dB between the loudest and the next angle; a margin of a few dB
    /// means each person has their own mic, close to zero means every camera hears the same sound.
    public static func loudestAngles(_ levels: [String: [Double?]]) -> (angles: [String?], margin: Double) {
        let names = levels.keys.sorted()
        let n = levels.values.map(\.count).max() ?? 0
        guard names.count >= 2, n > 0 else { return ([String?](repeating: names.first, count: n), 0) }
        var reference: [String: Double] = [:]
        for name in names {
            let v = levels[name]!.compactMap { $0 }.sorted()
            reference[name] = v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count - 1) * 0.9))]
        }
        var out: [String?] = []
        var margins: [Double] = []
        for i in 0..<n {
            let rel = names.compactMap { name -> (String, Double)? in
                guard i < levels[name]!.count, let l = levels[name]![i] else { return nil }
                return (name, l - reference[name]!)
            }.sorted { $0.1 > $1.1 }
            guard let best = rel.first else { out.append(nil); continue }
            out.append(best.0)
            if rel.count > 1 { margins.append(best.1 - rel[1].1) }
        }
        let sorted = margins.sorted()
        return (out, sorted.isEmpty ? 0 : sorted[sorted.count / 2])
    }
}

extension Project {
    /// Switches the picture to another synced angle from each cut's time, like cutting in a multicam editor: the clip
    /// under the cut on `trackId` splits there and its later part plays the new angle in sync (see `syncGroups`).
    /// Returns a line per cut.
    @discardableResult
    public mutating func switchAngles(_ cuts: [(at: Seconds, angle: String)], trackId: String) throws -> [String] {
        guard let ti = trackIndex(trackId) else { throw EditError("No track \(trackId)") }
        var lines: [String] = []
        for c in cuts.sorted(by: { $0.at < $1.at }) {
            let t = canvas.snap(c.at)
            guard let media = mediaAsset(c.angle), media.hasVideo else { throw EditError("No video media \(c.angle)") }
            guard let clip = tracks[ti].clips.first(where: { t >= $0.start - eps && t < $0.end - eps }), clip.kind == .media, let from = clip.mediaId else {
                throw EditError("No media clip on \(trackId) at \(fmt2(t))s to switch")
            }
            if from == c.angle { lines.append("\(fmt2(t))s: already \(c.angle)"); continue }
            var id = clip.id
            if t > clip.start + eps { id = try splitClip(clip.id, at: t).1 }
            var target = self.clip(id)!
            guard let sourceIn = syncedTime(target.sourceIn, from: from, to: c.angle) else {
                throw EditError("\(from) and \(c.angle) aren't synced; sync them first (recipe multicam_switch with angles, or sync_audio)")
            }
            target.mediaId = c.angle
            target.name = media.name
            target.sourceIn = sourceIn
            try replaceClip(target)
            lines.append("\(fmt2(t))–\(fmt2(target.end))s: \(from) → \(c.angle) (\(target.id))")
        }
        return lines
    }
}
