import Foundation

/// A stretch of a recording that holds only its room's background sound, picked from analysis for room_tone and
/// fill_gaps.
public struct RoomToneSpan: Equatable, Sendable {
    public var range: TimeRange
    /// Median level over the span, dBFS.
    public var levelDb: Double
    /// 90th minus 10th percentile level over the span, dB: how steady the background is.
    public var spreadDb: Double
    /// Quiet stretches considered.
    public var candidates: Int

    public var summary: String {
        "\(fmt2(range.start))–\(fmt2(range.end))s (\(fmt2(range.duration))s, background \(Int(levelDb.rounded())) dBFS, varies \(String(format: "%.1f", spreadDb)) dB)"
    }
}

extension AudioAnalysis {
    /// The best room-tone span: the longest steady quiet stretch with no transcribed word (±`pad`), no speech,
    /// music or other foreground sound event, and real background sound (not digital silence). Quiet is within
    /// `quietDb` of the recording's noise floor (its 10th-percentile level). Long stretches give their steadiest
    /// `maxLength` seconds. Nil when no stretch reaches `minLength`.
    public func roomToneSpan(words: [Word] = [], events: [SoundEvent] = [], exclude: [TimeRange] = [], within: TimeRange? = nil,
                             minLength: Seconds = 0.5, maxLength: Seconds = 6, quietDb: Double = 6, pad: Seconds = 0.2) -> RoomToneSpan? {
        guard levelRate > 0, !levels.isEmpty else { return nil }
        let sorted = levels.map(Double.init).sorted()
        let live = sorted.filter { $0 > -79 }
        guard !live.isEmpty else { return nil }
        let floor = live[live.count / 10]
        let busy = TimeRange.merged((words.map { TimeRange($0.start - pad, $0.end + pad) }
            + events.filter { !AudioAnalysis.isBackgroundLabel($0.label) }.map { TimeRange($0.start - pad, $0.end + pad) }
            + exclude).sorted { $0.start < $1.start })
        let lo = within.map { max(0, Int(($0.start * levelRate).rounded(.up))) } ?? 0
        let hi = within.map { min(levels.count, Int(($0.end * levelRate).rounded(.down))) } ?? levels.count
        guard hi > lo else { return nil }
        var runs: [Range<Int>] = []
        var start: Int?
        var b = busy.startIndex
        for i in lo...hi {
            var quiet = false
            if i < hi {
                let t = (Double(i) + 0.5) / levelRate
                while b < busy.endIndex, busy[b].end < t { b += 1 }
                let l = Double(levels[i])
                quiet = l > -79 && l <= floor + quietDb && !(b < busy.endIndex && busy[b].start <= t)
            }
            if quiet { if start == nil { start = i } } else if let s = start { runs.append(s..<i); start = nil }
        }
        // A short click inside a quiet stretch is part of it; the edges lose a tenth of a second each.
        let margin = Int((0.1 * levelRate).rounded())
        let minCount = Int((minLength * levelRate).rounded())
        let maxCount = max(minCount, Int((maxLength * levelRate).rounded()))
        func stats(_ r: Range<Int>) -> (median: Double, spread: Double) {
            let v = levels[r].map(Double.init).sorted()
            return (v[v.count / 2], v[min(v.count - 1, v.count * 9 / 10)] - v[v.count / 10])
        }
        var best: (range: Range<Int>, score: Double, median: Double, spread: Double)?
        var candidates = 0
        for run in runs {
            let r = (run.lowerBound + (run.lowerBound > lo ? margin : 0))..<(run.upperBound - (run.upperBound < hi ? margin : 0))
            guard r.count >= minCount else { continue }
            candidates += 1
            var pick = r
            var s = stats(r)
            if r.count > maxCount {
                let step = max(1, Int((0.25 * levelRate).rounded()))
                var i = r.lowerBound
                while i + maxCount <= r.upperBound {
                    let w = i..<(i + maxCount)
                    let ws = stats(w)
                    if ws.spread < s.spread || pick.count != maxCount { pick = w; s = ws }
                    i += step
                }
            }
            let score = Double(pick.count) / levelRate / (1 + max(0, s.spread - 3) / 3)
            if score > best?.score ?? 0 { best = (pick, score, s.median, s.spread) }
        }
        guard let best else { return nil }
        return RoomToneSpan(range: TimeRange(Double(best.range.lowerBound) / levelRate, Double(best.range.upperBound) / levelRate), levelDb: best.median, spreadDb: best.spread, candidates: candidates)
    }

    /// Sound-event labels that are a room's background rather than something happening in it.
    static func isBackgroundLabel(_ label: String) -> Bool {
        let l = label.lowercased()
        return ["silence", "noise", "hum", "room tone", "ambien", "air conditioning", "mechanical fan", "white noise", "pink noise", "static"].contains { l.contains($0) }
    }
}
