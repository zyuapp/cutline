import Foundation

extension Project {
    /// Markers as chapters sorted by time, starting at 0 with "Intro" when the first marker is later.
    /// Empty when the project has no markers.
    public func chapters() -> [(time: Double, title: String)] {
        chapterEntries().map { ($0.time, $0.title) }
    }

    /// Chapters as YouTube description lines, e.g. "0:00 Intro". The first is at 0:00 and each lasts
    /// at least 10 s: closer markers are dropped, and one within 10 s of a generated Intro replaces it.
    public func youtubeChapterList() -> String {
        let minLength: Seconds = 10
        var kept: [(time: Seconds, title: String, generated: Bool)] = []
        for c in chapterEntries() {
            guard let last = kept.last else { kept.append(c); continue }
            if c.time - last.time >= minLength {
                kept.append(c)
            } else if last.generated {
                kept[kept.count - 1] = (last.time, c.title, false)
            }
        }
        if kept.count > 1, duration > 0, duration - kept.last!.time < minLength { kept.removeLast() }
        return kept.map { "\(Self.chapterTime($0.time)) \($0.title)" }.joined(separator: "\n")
    }

    private func chapterEntries() -> [(time: Seconds, title: String, generated: Bool)] {
        let sorted = markers.filter { $0.time >= 0 }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }
        var out = sorted.enumerated().map { i, m in
            let title = m.label.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (time: m.time < 0.0005 ? 0 : m.time, title: title.isEmpty ? "Chapter \(i + 1)" : title, generated: false)
        }
        if out[0].time > 0 { out.insert((0, "Intro", true), at: 0) }
        return out
    }

    /// "M:SS", or "H:MM:SS" from an hour.
    static func chapterTime(_ t: Seconds) -> String {
        let s = Int(max(0, t).rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
