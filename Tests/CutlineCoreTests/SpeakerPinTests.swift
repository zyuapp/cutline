import Foundation
import Testing
@testable import CutlineCore

@Test func speakerEditsPinWordsAndFollowWordChanges() throws {
    var t = Transcript(mediaId: "m", locale: "en", words: (0..<8).map { Word(text: "w\($0).", start: Double($0), end: Double($0) + 0.8) })
    var s = SpeakerAnalysis(mediaId: "m", speakers: ["S1", "S2"], segments: [], wordSpeakers: ["S1", "S1", "S1", "S1", "S2", "S2", "S2", "S2"], emphasis: Array(repeating: 0, count: 8))
    s.rebuildSegments(t)
    #expect(s.pins == nil && s.namedSpeakers.isEmpty)

    s.assign(2...3, to: "Anna", transcript: t)
    #expect(s.pins == [SpeakerPin(from: 2, to: 3, speaker: "Anna")])
    #expect(s.segments.first { $0.speaker == "Anna" }?.via == "pinned")
    #expect(s.pinnedWords(count: 8) == [nil, nil, "Anna", "Anna", nil, nil, nil, nil])
    #expect(s.namedSpeakers == ["Anna"])

    s.rename(["Anna": "Ann", "S2": "Ben"], transcript: t)
    #expect(s.pins == [SpeakerPin(from: 2, to: 3, speaker: "Ann")])
    #expect(s.namedSpeakers == ["Ann", "Ben"])

    // One word becomes three before the pin: the pin moves with its words.
    let n = try t.replaceWords(0...0, with: "a b c")
    s.spliceWords(0..<1, count: n)
    #expect(s.pins == [SpeakerPin(from: 4, to: 5, speaker: "Ann")])
    #expect(s.wordSpeakers.count == t.words.count)
    let decoded = try JSONDecoder().decode(SpeakerAnalysis.self, from: JSONEncoder().encode(s))
    #expect(decoded == s)
    #expect(SpeakerAnalysis.isAutomatic("S12") && !SpeakerAnalysis.isAutomatic("Sam"))
}
