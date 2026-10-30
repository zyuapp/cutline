import Foundation

public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
    /// The recognizer's confidence in the word, 0–1; nil for words it didn't rate or that were typed in.
    public var confidence: Double?

    public init(text: String, start: Seconds, end: Seconds, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    /// Below this confidence a word is shown as uncertain.
    public static let lowConfidence = 0.5

    public var isLowConfidence: Bool { (confidence ?? 1) < Word.lowConfidence }

    /// Lowercased with surrounding punctuation removed.
    public var normalized: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    public static let fillers: Set<String> = ["um", "uh", "umm", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm", "mhm"]

    public var isFiller: Bool { Word.fillers.contains(normalized) }
}

/// Source-time transcript of one media file.
public struct Transcript: Codable, Equatable, Sendable {
    public var mediaId: String
    public var locale: String
    public var words: [Word]
    /// Who says each word, parallel to `words`, from the media's speaker analysis when it has one. Not saved with
    /// the transcript; `ProjectBundle.transcript` fills it in.
    public var speakers: [String?]?

    enum CodingKeys: String, CodingKey { case mediaId, locale, words }

    public init(mediaId: String, locale: String, words: [Word]) {
        self.mediaId = mediaId
        self.locale = locale
        self.words = words
    }
}

public struct TimeRange: Codable, Equatable, Hashable, Sendable {
    public var start: Seconds
    public var end: Seconds

    public init(_ start: Seconds, _ end: Seconds) {
        self.start = start
        self.end = end
    }

    public var duration: Seconds { end - start }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        return e > s ? TimeRange(s, e) : nil
    }

    /// Sorts and merges overlapping or touching ranges.
    public static func merged(_ ranges: [TimeRange], tolerance: Seconds = 1e-6) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, r.start <= last.end + tolerance {
                out[out.count - 1].end = max(last.end, r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

/// Audio analysis of one media file in source time.
public struct AudioAnalysis: Codable, Equatable, Sendable {
    public var mediaId: String
    /// Level samples per second in `levels`.
    public var levelRate: Double
    /// Peak level per window in dBFS, clamped to -80.
    public var levels: [Float]
    public var silences: [TimeRange]
    public var silenceThresholdDb: Double
    public var loudnessDb: Double

    public init(mediaId: String, levelRate: Double, levels: [Float], silences: [TimeRange], silenceThresholdDb: Double, loudnessDb: Double) {
        self.mediaId = mediaId
        self.levelRate = levelRate
        self.levels = levels
        self.silences = silences
        self.silenceThresholdDb = silenceThresholdDb
        self.loudnessDb = loudnessDb
    }

    /// Finds runs below `thresholdDb` that last at least `minDuration`.
    public static func detectSilences(levels: [Float], rate: Double, thresholdDb: Double, minDuration: Seconds) -> [TimeRange] {
        var out: [TimeRange] = []
        var runStart: Int?
        for (i, l) in levels.enumerated() {
            if Double(l) < thresholdDb {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if Double(i - s) / rate >= minDuration { out.append(TimeRange(Double(s) / rate, Double(i) / rate)) }
                runStart = nil
            }
        }
        if let s = runStart, Double(levels.count - s) / rate >= minDuration {
            out.append(TimeRange(Double(s) / rate, Double(levels.count) / rate))
        }
        return out
    }

    /// Threshold relative to the speech level: the 90th percentile of loud windows minus `belowSpeechDb`.
    public static func adaptiveThreshold(levels: [Float], belowSpeechDb: Double = 30) -> Double {
        let loud = levels.filter { $0 > -70 }.sorted()
        guard !loud.isEmpty else { return -50 }
        let p90 = Double(loud[min(loud.count - 1, Int(Double(loud.count) * 0.9))])
        return min(max(p90 - belowSpeechDb, -60), -25)
    }
}

public struct VisualAnalysis: Codable, Equatable, Sendable {
    public var mediaId: String
    /// Source times where the picture changes abruptly.
    public var sceneCuts: [Seconds]

    public init(mediaId: String, sceneCuts: [Seconds]) {
        self.mediaId = mediaId
        self.sceneCuts = sceneCuts
    }
}
