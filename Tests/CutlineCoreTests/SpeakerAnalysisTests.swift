import Foundation
import Testing
@testable import CutlineCore

@Test func speakerAtLooksUpSegments() throws {
    let a = SpeakerAnalysis(mediaId: "m", speakers: ["S1", "S2"], segments: [
        SpeakerSegment(start: 0, end: 2, speaker: "S1"),
        SpeakerSegment(start: 2.5, end: 4, speaker: "S2"),
        SpeakerSegment(start: 4, end: 6, speaker: "S1"),
    ], wordSpeakers: ["S1", nil], emphasis: [0.2, 0])
    #expect(a.speaker(at: 0) == "S1")
    #expect(a.speaker(at: 1.99) == "S1")
    #expect(a.speaker(at: 2.2) == nil)
    #expect(a.speaker(at: 3) == "S2")
    #expect(a.speaker(at: 4) == "S1")
    #expect(a.speaker(at: 6) == nil)
    #expect(a.speaker(at: -1) == nil)
    let decoded = try JSONDecoder().decode(SpeakerAnalysis.self, from: JSONEncoder().encode(a))
    #expect(decoded == a)
}
