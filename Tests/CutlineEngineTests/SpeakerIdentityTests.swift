import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// Words of the lines in `range` (0-based line numbers) of a two-voice scene with alternating lines.
private func words(ofLines range: ClosedRange<Int>, _ scene: SpokenScene) -> [Int] {
    var line = 0
    var out: [Int] = []
    for i in scene.transcript.words.indices {
        if i > 0, scene.truth[i] != scene.truth[i - 1] { line += 1 }
        if range.contains(line) { out.append(i) }
    }
    return out
}

@Test(.enabled(if: voicesAvailable(["Samantha", "Daniel"])))
func pinnedTurnsNameTheirVoicesAcrossScenes() async throws {
    // Two scenes 10 s apart; pins only in the first.
    let gaps = (0..<28).map { $0 == 13 ? 10.0 : [0.12, 0.25, 0.4, 0.18][$0 % 4] }
    let scene = try await spokenScene(voices: ["Samantha", "Daniel"], gaps: gaps)
    let n = scene.transcript.words.count
    var pinned = [String?](repeating: nil, count: n)
    for w in words(ofLines: 0...0, scene) { pinned[w] = "Anna" }
    for w in words(ofLines: 1...1, scene) { pinned[w] = "Ben" }
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript, enrollment: Diarizer.Enrollment(pinned: pinned))
    #expect(Set(result.speakers) == ["Anna", "Ben"], "\(result.speakers)")
    let right = scene.truth.indices.filter { result.wordSpeakers[$0] == (scene.truth[$0] == 0 ? "Anna" : "Ben") }.count
    #expect(Double(right) / Double(n) >= 0.9)
    #expect(result.pins == [SpeakerPin(from: 0, to: words(ofLines: 0...0, scene).last!, speaker: "Anna"), SpeakerPin(from: words(ofLines: 1...1, scene)[0], to: words(ofLines: 1...1, scene).last!, speaker: "Ben")])
    #expect(result.segments.first?.via == "pinned")
    let second = result.segments.filter { $0.start > scene.transcript.words[words(ofLines: 13...13, scene).last!].end + 5 }
    #expect(!second.isEmpty && second.allSatisfy { $0.via == "named" && ($0.identity ?? 0) >= Diarizer.carryIdentity }, "\(second)")

    // Names from an earlier analysis name the voices they mostly cover; pins win over them.
    var earlier = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript)
    let first = try #require(earlier.wordSpeakers[0])
    earlier.rename([first: "Anna"], transcript: scene.transcript)
    let renamed = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript, enrollment: Diarizer.Enrollment(earlier, wordCount: n))
    #expect(renamed.wordSpeakers[0] == "Anna" && renamed.speakers.contains("Anna") && renamed.speakers.count == 2, "\(renamed.speakers)")
    #expect(renamed.pins == nil)
}

@Test func enrollmentReadsPinsAndNames() {
    var a = SpeakerAnalysis(mediaId: "m", speakers: ["S1", "S2"], segments: [], wordSpeakers: ["S1", "S1", "S2", "S2"], emphasis: [0, 0, 0, 0])
    #expect(Diarizer.Enrollment(a, wordCount: 4) == nil)
    a.wordSpeakers[0] = "Anna"
    a.pins = [SpeakerPin(from: 2, to: 3, speaker: "Ben")]
    let e = Diarizer.Enrollment(a, wordCount: 4)
    #expect(e?.pinned == [nil, nil, "Ben", "Ben"])
    #expect(e?.named == ["Anna", nil, nil, nil])
    #expect(Diarizer.Enrollment(a, wordCount: 5) == nil)
}

@Test func unitsSplitWherePinsChange() {
    let words = (0..<6).map { Word(text: $0 == 5 ? "end." : "w", start: Double($0), end: Double($0) + 0.9) }
    let units = [Diarizer.Segment(start: 0, end: 5.9, words: Array(0..<6))]
    let split = Diarizer.splitAtPins(units, [nil, nil, "A", "A", nil, nil], words: words)
    #expect(split.map(\.words) == [[0, 1], [2, 3], [4, 5]])
}

/// Face tracks are clustered into people; tracks on screen together never join.
@Test func faceTracksClusterIntoPeople() {
    func track(_ id: Int, _ t0: Double, _ t1: Double) -> FaceTrack {
        FaceTrack(id: id, samples: [FaceSample(t: t0, box: NormRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)), FaceSample(t: t1, box: NormRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3))])
    }
    let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]
    let near: [Float] = [0.96, 0.28, 0]
    let tracks = [track(1, 0, 2), track(2, 0, 2), track(3, 10, 12), track(4, 20, 22)]
    let prints: [Int: [[Float]]] = [1: [a], 2: [near], 3: [near], 4: [b]]
    let people = FaceIdentity.cluster(prints, tracks: tracks, threshold: 0.5)
    // 1 and 2 look alike but share the screen; 3 joins the closer of them.
    #expect(people[1] != people[2])
    #expect(people[3] == people[2] || people[3] == people[1])
    #expect(people[4] != people[1] && people[4] != people[2])
    // Tracks of one person count as one talking face.
    let units = [Diarizer.Segment(start: 0, end: 2, words: [0]), Diarizer.Segment(start: 10, end: 12, words: [1])]
    let spans = [ActiveSpeakers.Span(start: 0, end: 2, speaker: "S1", face: 2, activity: 0.05, margin: 3), ActiveSpeakers.Span(start: 10, end: 12, speaker: "S1", face: 3, activity: 0.05, margin: 3)]
    var named = tracks
    for i in named.indices { named[i].person = people[named[i].id] }
    let (faceOf, _) = Diarizer.faceLinks(ActiveSpeakers(mediaId: "m", spans: spans, speakerFaces: [:]), tracks: named, units: units)
    #expect(people[3] == people[2] ? faceOf[0] == faceOf[1] : faceOf[0] != faceOf[1])
}
