@testable import CutlineCore
import Foundation
import Testing

private func project(volume: Double = 1) -> Project {
    var p = Project(name: "Ride")
    p.media = [MediaAsset(id: "vo", path: "/tmp/vo.wav", name: "vo", duration: 30, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)]
    var c = Clip(id: "a1", kind: .media, mediaId: "vo", start: 2, duration: 12, volume: volume)
    c.anim["audio.volume"] = Curve(keys: [CurveKey(t: 0, v: .number(0.2)), CurveKey(t: 5, v: .number(1))])
    p.tracks = [Track(id: "A1", kind: .audio, name: "Dialogue", clips: [c])]
    return p
}

@Test func phrasesSplitAtPausesAndSentenceEnds() {
    let words: [(start: Seconds, end: Seconds, text: String)] = [
        (0.0, 0.3, "Did"), (0.35, 0.6, "you"), (0.65, 1.0, "go?"), (1.2, 1.5, "Yes,"), (1.55, 1.9, "today."),
        (2.6, 2.9, "Then"), (2.95, 3.3, "what"),
    ]
    let phrases = DialogueRide.phrases(words)
    #expect(phrases.map(\.text) == ["Did you go?", "Yes, today.", "Then what"])
    #expect(phrases.map(\.range) == [TimeRange(0, 1.0), TimeRange(1.2, 1.9), TimeRange(2.6, 3.3)])
}

@Test func clipGainRideHoldsEachPhraseAtTheTargetAndRampsInPauses() throws {
    var p = project(volume: 0.8)
    let phrases = [
        RidePhrase(range: TimeRange(0.5, 2.5), lufs: -20),
        RidePhrase(range: TimeRange(3.0, 5.0), lufs: -33),
        RidePhrase(range: TimeRange(5.02, 7.0), lufs: -26),
        RidePhrase(range: TimeRange(8.0, 9.0), lufs: -50),
    ]
    let results = try p.rideClipGain("a1", phrases: phrases, targetLufs: -23, maxDb: 10, ramp: 0.2)
    #expect(results.map(\.gainDb) == [-3, 10, 3, 10])
    #expect(results.map(\.lufs) == [-23, -23, -23, -40])
    let c = try #require(p.clip("a1"))
    let curve = try #require(c.anim["audio.volume"])
    func v(_ t: Seconds) -> Double { c.number("audio.volume", at: t, default: .nan) }
    for (r, phrase) in zip(results, phrases) {
        let expected = 0.8 * pow(10, r.gainDb / 20)
        let inner = phrase.range.duration > 0.3 ? [phrase.range.start + 0.11, (phrase.range.start + phrase.range.end) / 2, phrase.range.end - 0.11] : [(phrase.range.start + phrase.range.end) / 2]
        for t in inner { #expect(abs(v(t) - min(4, expected)) < 1e-6, "t \(t): \(v(t)) vs \(expected)") }
    }
    // Ramps sit inside the pauses: the 0.5 s pause ramps over 0.2 s around its middle.
    #expect(curve.keys.contains { abs($0.t - 2.65) < 1e-6 } && curve.keys.contains { abs($0.t - 2.85) < 1e-6 })
    // A 20 ms pause still gets a short ramp straddling it.
    #expect(curve.keys.contains { abs($0.t - 4.96) < 1e-6 } && curve.keys.contains { abs($0.t - 5.06) < 1e-6 })
    #expect(curve.keys.allSatisfy { $0.t >= 0 && $0.t <= c.duration })
    #expect(curve.keys.count <= 2 * phrases.count)
}

@Test func clipGainRideRespectsTheVolumeCeilingAndNeedsSound() throws {
    var p = project(volume: 3)
    let results = try p.rideClipGain("a1", phrases: [RidePhrase(range: TimeRange(1, 2), lufs: -40), RidePhrase(range: TimeRange(3, 4), lufs: -30)], targetLufs: -23, maxDb: 12)
    #expect(results.allSatisfy { 3 * pow(10, $0.gainDb / 20) <= 4.0001 })
    #expect(p.clip("a1")?.anim["audio.volume"] == nil && abs((p.clip("a1")?.volume ?? 0) - 4) < 0.05)
    #expect(throws: EditError.self) { try p.rideClipGain("a1", phrases: [RidePhrase(range: TimeRange(1, 2), lufs: -.infinity)], targetLufs: -23, maxDb: 10) }
    #expect(throws: EditError.self) { try p.rideClipGain("nope", phrases: [], targetLufs: -23, maxDb: 10) }
}

@Test func eqCurveParsesAndInterpolatesOverLogFrequency() throws {
    let c = try #require(EQCurve(text: "100:+6 400:-6, 1000:0"))
    #expect(c.points.count == 3)
    #expect(abs(c.gain(at: 200) - 0) < 1e-9)
    #expect(c.gain(at: 50) == 6 && c.gain(at: 5000) == 0)
    #expect(c.text == "100:+6.0 400:-6.0 1000:+0.0")
    #expect(EQCurve(text: "100") == nil && EQCurve(text: "")?.points.isEmpty == true)
}
