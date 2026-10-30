import Foundation

/// Gaps between transcribed words sorted into pauses to cut and gaps to keep: a pause is quiet and has no music or
/// other sound in it; a gap under music, over other sound (action, effects, ambience louder than the room) or loud
/// next to the speech around it is part of the program.
public struct SpeechPauses: Sendable {
    public enum Reason: String, Sendable { case music, sound, loud }

    public var cut: [TimeRange] = []
    public var kept: [(range: TimeRange, reason: Reason, detail: String)] = []

    /// `levels` is the media's audio analysis; `sounds` its sound events. A gap counts as music or sound when events
    /// of that kind cover at least `cover` of it; as loud when its median level is within `margin` dB of the speech's.
    public init(gaps: [TimeRange], words: [Word], sounds: [SoundEvent]?, levels: AudioAnalysis?, includeMusic: Bool, cover: Double = 0.3, margin: Double = 12) {
        let music = TimeRange.merged((sounds ?? []).filter { Project.isMusicLabel($0.label) }.map { TimeRange($0.start, $0.end) })
        let other = (sounds ?? []).filter { e in
            !Project.isMusicLabel(e.label) && !Project.isSpeechLabel(e.label) && !["silence", "speech", "breathing"].contains(e.label.lowercased())
        }
        func covered(_ g: TimeRange, _ spans: [TimeRange]) -> Double {
            spans.compactMap { $0.intersection(g)?.duration }.reduce(0, +) / max(g.duration, 1e-6)
        }
        func median(_ r: TimeRange) -> Float? {
            guard let a = levels, a.levelRate > 0, !a.levels.isEmpty else { return nil }
            let lo = max(0, Int((r.start * a.levelRate).rounded(.down))), hi = min(a.levels.count, Int((r.end * a.levelRate).rounded(.up)))
            guard hi > lo else { return nil }
            let s = a.levels[lo..<hi].sorted()
            return s[s.count / 2]
        }
        var speechLevels: [Float] = []
        if let a = levels, a.levelRate > 0 {
            for w in words where w.end > w.start {
                let lo = max(0, Int(w.start * a.levelRate)), hi = min(a.levels.count, Int((w.end * a.levelRate).rounded(.up)))
                if hi > lo { speechLevels += a.levels[lo..<hi] }
            }
        }
        let speech: Float? = speechLevels.isEmpty ? nil : speechLevels.sorted()[speechLevels.count / 2]
        for g in gaps {
            if !includeMusic, covered(g, music) >= cover {
                kept.append((g, .music, "music"))
                continue
            }
            let heard = other.filter { $0.end > g.start && $0.start < g.end }
            if !includeMusic, covered(g, TimeRange.merged(heard.map { TimeRange($0.start, $0.end) })) >= cover {
                let labels = Array(Set(heard.map(\.label))).sorted().prefix(3)
                kept.append((g, .sound, labels.joined(separator: ", ")))
                continue
            }
            if !includeMusic, let s = speech, let m = median(g), Double(m) > Double(s) - margin, Double(m) > (levels?.silenceThresholdDb ?? -60) {
                kept.append((g, .loud, "\(Int(m.rounded())) dB against speech at \(Int(s.rounded())) dB"))
                continue
            }
            cut.append(g)
        }
    }

    /// "kept 12 gaps (48.2s): 7 under music, 3 with other sound (car, explosion), 2 as loud as the speech".
    public var keptSummary: String? {
        guard !kept.isEmpty else { return nil }
        let total = kept.map(\.range.duration).reduce(0, +)
        var parts: [String] = []
        let music = kept.filter { $0.reason == .music }, sound = kept.filter { $0.reason == .sound }, loud = kept.filter { $0.reason == .loud }
        if !music.isEmpty { parts.append("\(music.count) under music") }
        if !sound.isEmpty {
            let labels = Array(Set(sound.flatMap { $0.detail.components(separatedBy: ", ") })).sorted().prefix(4)
            parts.append("\(sound.count) with other sound (\(labels.joined(separator: ", ")))")
        }
        if !loud.isEmpty { parts.append("\(loud.count) not quiet (\(loud[0].detail))") }
        return "kept \(kept.count) gap\(kept.count == 1 ? "" : "s") between words (\(fmt2(total))s) that aren't pauses: " + parts.joined(separator: ", ")
    }
}
