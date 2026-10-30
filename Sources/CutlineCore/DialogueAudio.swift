import Foundation

/// A smooth EQ curve: gains in dB at frequencies in Hz, written as `"hz:dB"` pairs separated by spaces
/// (`"125:+2.0 250:-1.5"`), the form `audio.match_eq` stores in its `curve` parameter.
public struct EQCurve: Equatable, Sendable {
    public var points: [(hz: Double, db: Double)]

    public init(points: [(hz: Double, db: Double)]) {
        self.points = points.filter { $0.hz > 0 && $0.db.isFinite }.sorted { $0.hz < $1.hz }
    }

    /// Parses `"hz:dB …"`; nil when any pair is malformed.
    public init?(text: String) {
        var pts: [(Double, Double)] = []
        for pair in text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }) {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let hz = Double(parts[0]), let db = Double(parts[1].replacingOccurrences(of: "+", with: "")), hz > 0, db.isFinite else { return nil }
            pts.append((hz, db))
        }
        self.init(points: pts)
    }

    public var text: String {
        points.map { String(format: "%.0f:%+.1f", $0.hz, $0.db) }.joined(separator: " ")
    }

    /// Gain at `hz`, interpolated linearly over log frequency and held beyond the ends.
    public func gain(at hz: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if hz <= first.hz { return first.db }
        if hz >= last.hz { return last.db }
        let i = points.lastIndex { $0.hz <= hz } ?? 0
        let a = points[i], b = points[min(i + 1, points.count - 1)]
        guard b.hz > a.hz else { return a.db }
        let f = log2(hz / a.hz) / log2(b.hz / a.hz)
        return a.db + f * (b.db - a.db)
    }

    public static func == (l: EQCurve, r: EQCurve) -> Bool {
        l.points.count == r.points.count && zip(l.points, r.points).allSatisfy { $0.hz == $1.hz && $0.db == $1.db }
    }
}

/// One line of dialogue in a clip: its clip-local span and its loudness as the clip plays now, without rides.
public struct RidePhrase: Equatable, Sendable {
    public var range: TimeRange
    public var lufs: Double
    public var text: String

    public init(range: TimeRange, lufs: Double, text: String = "") {
        self.range = range
        self.lufs = lufs
        self.text = text
    }
}

/// What a clip-gain ride did to one phrase.
public struct RideResult: Sendable {
    public var phrase: RidePhrase
    /// Gain applied, dB.
    public var gainDb: Double
    /// Loudness after the ride.
    public var lufs: Double { phrase.lufs + gainDb }
}

public enum DialogueRide {
    /// Words grouped into phrases: a new phrase starts after a pause of `pause` seconds or more, or after a word
    /// ending a sentence followed by any pause over 0.12 s.
    public static func phrases(_ words: [(start: Seconds, end: Seconds, text: String)], pause: Seconds = 0.3) -> [(range: TimeRange, text: String)] {
        var out: [(range: TimeRange, text: String)] = []
        for w in words.sorted(by: { $0.start < $1.start }) where w.end > w.start {
            if var last = out.last {
                let gap = w.start - last.range.end
                let sentenceEnd = [".", "?", "!"].contains { last.text.hasSuffix($0) }
                if gap < pause && !(sentenceEnd && gap > 0.12) {
                    last.range.end = max(last.range.end, w.end)
                    last.text += " " + w.text
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append((TimeRange(w.start, w.end), w.text))
        }
        return out
    }
}

extension Project {
    /// Clip-gain rides: `audio.volume` keys that hold each phrase at `targetLufs`, changing level within the pause
    /// between phrases (a ramp of at most `ramp` seconds centered in the pause, or straddling the boundary when there
    /// is none). Gains are limited to ±`maxDb` and the volume parameter's range; the clip's static volume is the 0 dB
    /// reference. Replaces the clip's volume keys.
    @discardableResult
    public mutating func rideClipGain(_ clipId: String, phrases: [RidePhrase], targetLufs: Double, maxDb: Double, ramp: Seconds = 0.2) throws -> [RideResult] {
        guard let loc = locateClip(clipId) else { throw EditError("No clip \(clipId)") }
        var c = tracks[loc.track].clips[loc.clip]
        let spans = phrases.filter { $0.lufs.isFinite && $0.lufs > -70 }.sorted { $0.range.start < $1.range.start }
        guard !spans.isEmpty else { throw EditError("\(clipId) has no audible phrases to ride") }
        let base = c.volume > 0 ? c.volume : 1
        let limit = Clip.audioSpecs.first { $0.name == "audio.volume" }?.max ?? 4
        let ceiling = (20 * log10(limit / base) * 10).rounded(.down) / 10
        let results = spans.map { p -> RideResult in
            let g = min(max(targetLufs - p.lufs, -abs(maxDb)), abs(maxDb))
            return RideResult(phrase: p, gainDb: min((g * 10).rounded() / 10, ceiling))
        }
        let volumes = results.map { min(limit, base * pow(10, $0.gainDb / 20)) }
        var keys: [CurveKey] = []
        var holdFrom = max(0, spans[0].range.start)
        for i in spans.indices {
            var holdTo = min(c.duration, spans[i].range.end)
            var next: Seconds?
            if i + 1 < spans.count {
                let gap = spans[i + 1].range.start - spans[i].range.end
                let mid = spans[i].range.end + gap / 2
                let half = gap > 0.04 ? min(ramp / 2, gap / 2) : min(ramp / 2, 0.05)
                holdTo = min(c.duration, mid - half)
                next = mid + half
            }
            keys.append(CurveKey(t: max(0, min(holdFrom, holdTo)), v: .number(volumes[i]), ease: .easeInOut))
            keys.append(CurveKey(t: max(0, holdTo), v: .number(volumes[i]), ease: .linear))
            if let next { holdFrom = next }
        }
        var compact: [CurveKey] = []
        for k in keys.sorted(by: { $0.t < $1.t }) {
            if let last = compact.last, abs(last.t - k.t) < 1e-4 { compact[compact.count - 1] = k; continue }
            if compact.count >= 2, let last = compact.last, case .number(let a) = last.v, case .number(let b) = compact[compact.count - 2].v, case .number(let v) = k.v, abs(a - b) < 1e-9, abs(a - v) < 1e-9 {
                compact[compact.count - 1] = k
                continue
            }
            compact.append(k)
        }
        c.anim["audio.volume"] = nil
        if compact.count == 1 || Set(volumes.map { ($0 * 1e6).rounded() }).count == 1 {
            c.volume = min(limit, volumes[0])
        } else {
            try c.animate("audio.volume", keys: compact)
        }
        tracks[loc.track].clips[loc.clip] = c
        return results
    }
}
