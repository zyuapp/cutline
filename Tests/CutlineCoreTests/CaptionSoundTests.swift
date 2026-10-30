import Foundation
import Testing
@testable import CutlineCore

/// Words 0.3 s long, 0.05 s apart from `start`.
private func words(_ text: String, from start: Double) -> [Word] {
    text.split(separator: " ").enumerated().map { i, t in Word(text: String(t), start: start + Double(i) * 0.35, end: start + Double(i) * 0.35 + 0.3) }
}

/// a plays m 0–3.5 s, b plays m from `bIn` after it; m says one sentence from 0.2 s and another from 3.6 s.
private func cut(bIn: Double = 3.5, split: Double? = -0.4, dissolve: Seconds? = 1) throws -> (Project, [String: Transcript]) {
    var p = Project(name: "Sound")
    p.canvas.fps = 25
    p.media = [MediaAsset(id: "m", path: "/tmp/m.mov", name: "M", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 3.5, sourceIn: 0),
        Clip(id: "b", kind: .media, mediaId: "m", start: 3.5, duration: 6, sourceIn: bIn),
    ]
    if let split { try p.splitEdit(left: "a", right: "b", offset: split) }
    if let dissolve { p.transitions = [Transition(id: "t1", from: "a", to: "b", type: "dissolve", duration: dissolve)] }
    let w = words("You're a jerk, Tom. We are", from: 0.2) + words("Look, Celia, we have to follow our passions. I'm not freed out", from: 3.6) + words("I'm freaked out now.", from: 9.0)
    return (p, ["m": Transcript(mediaId: "m", locale: "en", words: w)])
}

@Test func crossfadedCutsCaptionEachSideUpToTheSoundCut() throws {
    let (p, tr) = try cut(bIn: 8.6, split: nil, dissolve: 1.5)
    let text = p.resolvingAudioTransitions().captionCues(transcripts: tr).map(\.text).joined(separator: " ")
    #expect(text == "You're a jerk, Tom. We are I'm freaked out now.")
}

@Test func aWordHeardFromTwoClipsAtOnceIsCaptionedOnce() throws {
    var (p, tr) = try cut(split: nil, dissolve: nil)
    var copy = p.tracks[0].clips[0]
    copy.id = "a2"
    copy.start = 0.1
    p.tracks[1].clips = [copy]
    p.tracks[1].name = "Dialogue 2"
    let words = p.captionTimelineWords(transcripts: tr).map(\.text)
    #expect(words.prefix(6) == ["You're", "a", "jerk,", "Tom.", "We", "are"])
    #expect(words.filter { $0 == "jerk," }.count == 1)
}

@Test func captionsReadTheSameBeforeAndAfterAudioTransitionsResolve() throws {
    for (bIn, split, dissolve) in [(3.5, -0.4, 1.0), (3.5, 0.4, 1.0), (3.2, -0.4, 1.0), (8.6, nil, 1.5), (8.6, -0.4, 1.0), (3.5, nil, 2.0)] as [(Double, Double?, Double?)] {
        let (p, tr) = try cut(bIn: bIn, split: split, dissolve: dissolve)
        let resolved = p.resolvingAudioTransitions()
        let plain = p.captionCues(transcripts: tr).map(\.text)
        #expect(resolved.captionCues(transcripts: tr).map(\.text) == plain)
        #expect(resolved.subtitleCues(transcripts: tr).map(\.text) == p.subtitleCues(transcripts: tr).map(\.text))
    }
}
