import Foundation
import Testing
@testable import CutlineCore

/// Spoken sentences `gap` seconds apart, each word 0.3 s.
private func project(_ sentences: [String], gap: Double) -> (Project, [String: Transcript]) {
    var p = Project(name: "Read")
    p.media = [MediaAsset(id: "m1", path: "/tmp/m1.mov", name: "m1", duration: 120, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 100)]
    var t = 0.5
    var words: [Word] = []
    for s in sentences {
        for token in s.split(separator: " ") {
            words.append(Word(text: String(token), start: t, end: t + 0.3))
            t += 0.35
        }
        t += gap
    }
    return (p, ["m1": Transcript(mediaId: "m1", locale: "en-US", words: words)])
}

private let english = ["We have to follow our passions.", "You have your robotics.", "I want to be awesome in space.", "That is all."]
private let japanese = ["私たちは自分の情熱に従わなければならない。", "あなたにはロボット工学がある。", "私は宇宙で最高になりたい。", "以上です。"]

@Test func japaneseSubtitlesRunOnIntoPausesToBeReadable() throws {
    var (p, tr) = project(english, gap: 3)
    try p.setCaptionTranslations("ja", texts: Dictionary(uniqueKeysWithValues: japanese.enumerated().map { ($0.offset, $0.element) }), transcripts: tr)
    let rules = SubtitleRules.forLanguage("ja")
    let spoken = p.captionCues(transcripts: tr)
    let ja = p.subtitleCues(transcripts: tr, language: "ja")
    // At the spoken timing every cue but the last is too fast at 4 characters/s.
    let atSpoken = zip(spoken, japanese).map { SubtitleCue(startMs: $0.startMs, endMs: $0.endMs, lines: [$1]) }
    #expect(rules.tooFast(atSpoken).count >= 3)
    #expect(rules.tooFast(ja).isEmpty, "\(ja.map { "\($0.startMs)–\($0.endMs) \($0.text)" })")
    for (a, b) in zip(ja, ja.dropFirst()) { #expect(b.startMs - a.endMs >= 66, "two frames apart: \(a.endMs) → \(b.startMs)") }
    #expect(ja.allSatisfy { $0.endMs - $0.startMs <= 7000 })
    for c in ja {
        let cue = try #require(spoken.first { s in c.anchors.contains { a in s.words.contains { $0.anchor == a } } })
        #expect(c.startMs >= cue.startMs - 250, "starts at most 250 ms before its speech")
    }
    #expect(p.readingSpeedProblems(language: "ja", transcripts: tr).tooFast.isEmpty)
    #expect(p.tooFastCaptionCues(language: "ja", transcripts: tr).isEmpty)
}

@Test func tightSpeechKeepsTheRemainingViolationsReported() throws {
    var (p, tr) = project(english, gap: 0.8)
    try p.setCaptionTranslations("ja", texts: Dictionary(uniqueKeysWithValues: japanese.enumerated().map { ($0.offset, $0.element) }), transcripts: tr)
    let ja = p.subtitleCues(transcripts: tr, language: "ja")
    let spoken = p.subtitleCues(transcripts: tr)
    // Every cue gains time, but no pause is long enough for all of them.
    #expect(ja.first!.endMs > spoken.first!.endMs)
    let (_, count, fast) = p.readingSpeedProblems(language: "ja", transcripts: tr)
    #expect(count == ja.count && !fast.isEmpty)
    #expect(!p.tooFastCaptionCues(language: "ja", transcripts: tr).isEmpty)
}

@Test func nextCueLendsSpareTimeWithinTheLag() {
    let rules = SubtitleRules.standard
    // A long first line right before a short second one with plenty of time.
    let cues = [
        SubtitleCue(startMs: 1000, endMs: 2000, lines: ["Un texte beaucoup trop long pour une seconde."]),
        SubtitleCue(startMs: 2100, endMs: 6000, lines: ["Oui."]),
    ]
    let out = Project.retimedForReading(cues, rules: { _ in rules }, gapMs: 67, durationMs: 60_000)
    #expect(out[1].startMs == 2600, "the next cue starts at most 500 ms late: \(out[1].startMs)")
    #expect(out[0].endMs == out[1].startMs - 67)
    #expect(out[0].startMs == 750, "and the cue starts 250 ms early: \(out[0].startMs)")
    #expect(out[1].endMs == 6000)
}

@Test func longTranslationsSplitAtClauseEnds() {
    let words = "Je veux être génial, vraiment génial dans l'espace et parmi toutes les étoiles connues".split(separator: " ").enumerated().map {
        CaptionWord(text: String($0.element), start: Double($0.offset), end: Double($0.offset) + 0.5, anchor: nil, lastAnchor: nil)
    }
    let parts = Project.clauseAligned([Array(words[..<5]), Array(words[5...])], width: 42, lines: 2)
    #expect(parts[0].last?.text == "génial,", "\(parts.map { $0.map(\.text) })")
}

@Test func condensingDropsFillersAndRepeats() {
    let s = Project.condensedForSubtitles("Um, I mean, I just really want to, you know, go go home.")
    #expect(s == "I want to, go home.", "\(s ?? "nil")")
    #expect(Project.condensedForSubtitles("Go home.") == nil)
}

@Test func roomToneSpanIsTheLongestSteadyQuietStretch() {
    var levels: [Float] = []
    func add(_ seconds: Double, _ db: Float, jitter: Float = 0.5) { for i in 0..<Int(seconds * 100) { levels.append(db + (i % 2 == 0 ? jitter : -jitter)) } }
    add(3, -20)            // 0–3 speech
    add(4, -50)            // 3–7 steady room
    add(1, -20)            // 7–8 speech
    add(2, -51)            // 8–10 room with a cough
    add(5, -80, jitter: 0) // 10–15 digital silence
    add(1, -20)            // 15–16 speech
    let a = AudioAnalysis(mediaId: "m", levelRate: 100, levels: levels, silences: [], silenceThresholdDb: -40, loudnessDb: -23)
    let words = [Word(text: "a", start: 0.2, end: 2.8), Word(text: "b", start: 7.1, end: 7.9), Word(text: "c", start: 15.1, end: 15.9)]
    let span = a.roomToneSpan(words: words)
    #expect(span != nil && span!.range.start >= 3 && span!.range.end <= 7 && span!.range.duration >= 3.4, "\(String(describing: span))")
    #expect(abs((span?.levelDb ?? 0) + 50) < 1 && (span?.spreadDb ?? 9) <= 1)
    // Music over the long stretch sends it to the other one.
    let other = a.roomToneSpan(words: words, events: [SoundEvent(label: "Music", start: 3, end: 7, confidence: 0.9)])
    #expect(other != nil && other!.range.start >= 8 && other!.range.end <= 10, "\(String(describing: other))")
    // A background label is no reason to skip a stretch.
    #expect(a.roomToneSpan(words: words, events: [SoundEvent(label: "Air conditioning", start: 3, end: 7, confidence: 0.9)]) == span)
    let silent = AudioAnalysis(mediaId: "m", levelRate: 100, levels: [Float](repeating: -80, count: 500), silences: [], silenceThresholdDb: -40, loudnessDb: -80)
    #expect(silent.roomToneSpan() == nil, "digital silence holds no room tone")
}
