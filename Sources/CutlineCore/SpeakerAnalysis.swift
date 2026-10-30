import Foundation

/// A source-time span attributed to one speaker.
public struct SpeakerSegment: Codable, Equatable, Sendable {
    public var start: Seconds
    public var end: Seconds
    public var speaker: String
    /// 0…1: how clearly the voice in this turn belongs to `speaker` rather than another; nil when unscored.
    public var confidence: Double?
    /// 0…1: how surely this turn's speaker is the same person as that speaker's turns in other scenes; nil when the
    /// speaker is heard in this scene only.
    public var identity: Double?
    /// Where the speaker came from when not from voice clustering alone: "pinned" (set with transcript_edit),
    /// "enrolled" (nearest pinned voice in the scene), "named" (a pinned speaker's voice in another scene) or "face".
    public var via: String?

    public init(start: Seconds, end: Seconds, speaker: String, confidence: Double? = nil, identity: Double? = nil, via: String? = nil) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.confidence = confidence
        self.identity = identity
        self.via = via
    }
}

/// Words whose speaker was set by hand; re-analysis keeps them and labels the rest of their voice to match.
public struct SpeakerPin: Codable, Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var speaker: String

    public init(from: Int, to: Int, speaker: String) {
        self.from = from
        self.to = to
        self.speaker = speaker
    }
}

/// Who speaks when in one media file, and how strongly each word is stressed.
public struct SpeakerAnalysis: Codable, Equatable, Sendable {
    public var mediaId: String
    /// "S1", "S2"… in order of first appearance.
    public var speakers: [String]
    /// Sorted, non-overlapping; adjacent segments have different speakers.
    public var segments: [SpeakerSegment]
    /// Parallel to the transcript's words.
    public var wordSpeakers: [String?]
    /// Parallel to the transcript's words, 0…1. Fillers are 0.
    public var emphasis: [Float]
    /// Word ranges whose speaker was set by hand, oldest first.
    public var pins: [SpeakerPin]?

    public init(mediaId: String, speakers: [String], segments: [SpeakerSegment], wordSpeakers: [String?], emphasis: [Float], pins: [SpeakerPin]? = nil) {
        self.mediaId = mediaId
        self.speakers = speakers
        self.segments = segments
        self.wordSpeakers = wordSpeakers
        self.emphasis = emphasis
        self.pins = pins
    }

    /// Speakers named by hand rather than numbered S1, S2….
    public var namedSpeakers: [String] { speakers.filter { !SpeakerAnalysis.isAutomatic($0) } }

    public static func isAutomatic(_ name: String) -> Bool { name.range(of: #"^S\d+$"#, options: .regularExpression) != nil }

    /// The speaker pinned on each of `count` words, later pins winning.
    public func pinnedWords(count: Int) -> [String?] {
        var out = [String?](repeating: nil, count: count)
        for p in pins ?? [] {
            let lo = max(0, p.from), hi = min(count - 1, p.to)
            if lo <= hi { for i in lo...hi { out[i] = p.speaker } }
        }
        return out
    }

    /// The speaker of the segment containing `t`, if any.
    public func speaker(at t: Seconds) -> String? {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo < segments.count, segments[lo].start <= t else { return nil }
        return segments[lo].speaker
    }
}
