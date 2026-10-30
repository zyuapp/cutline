import Foundation
import Testing
@testable import CutlineCore

private func words(_ text: String, from start: Double = 0.5, confidence: Double? = nil) -> [Word] {
    var t = start
    var out: [Word] = []
    for token in text.split(separator: " ") {
        if token == "|" { t += 0.8; continue }
        out.append(Word(text: String(token), start: t, end: t + 0.3, confidence: confidence))
        t += 0.35
    }
    return out
}

@Test func wordConfidenceIsStoredOnlyWhenKnown() throws {
    let rated = Word(text: "robot", start: 1, end: 1.2, confidence: 0.31)
    let typed = Word(text: "hand", start: 1.2, end: 1.4)
    let data = try JSONEncoder().encode([rated, typed])
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"confidence\":0.31") && json.components(separatedBy: "confidence").count == 2)
    let back = try JSONDecoder().decode([Word].self, from: data)
    #expect(back == [rated, typed])
    #expect(rated.isLowConfidence && !typed.isLowConfidence)
    let old = try JSONDecoder().decode(Word.self, from: Data(#"{"text":"hi","start":0,"end":1}"#.utf8))
    #expect(old.confidence == nil)
}

@Test func vocabularyRespellsSoundAlikeNamesOnly() {
    var t = Transcript(mediaId: "m", locale: "en-US", words: words("You're a jerk, Tom. Speed it up, Thorn. That was dumb. Tomorrow then."))
    t.words[7].confidence = 0.28
    let changes = t.applyVocabulary(["Thom", "Celia"])
    #expect(t.words.map(\.text) == ["You're", "a", "jerk,", "Thom.", "Speed", "it", "up,", "Thom.", "That", "was", "dumb.", "Tomorrow", "then."])
    #expect(changes.map(\.0) == [3, 7])
    var sure = Transcript(mediaId: "m", locale: "en-US", words: words("speed it up thorn", confidence: 0.9))
    #expect(sure.applyVocabulary(["Thom"]).isEmpty)
    #expect(Vocabulary.soundKey("Thom") == Vocabulary.soundKey("Tom"))
    #expect(Vocabulary.soundKey("Celia") != Vocabulary.soundKey("Steve"))
}

@Test func vocabularyPicksTheAlternativeThatSpellsATerm() {
    let alts = [" robe on hand?", " robe on him?", " robot hand?"]
    #expect(Vocabulary.preferred(alts, terms: ["robot hand"]) == 2)
    #expect(Vocabulary.preferred(alts, terms: []) == 0)
    #expect(Vocabulary.preferred([" robot hand?", " robe on hand?"], terms: ["robot hand"]) == 0)
    #expect(Vocabulary.preferred([" looking, Barley?", " looking, Barney?"], terms: ["Barney"]) == 1)
    var p = Project(name: "v")
    p.captions.replacements = ["cut line": "Cutline", "um": ""]
    var m = MediaAsset(id: "m", path: "/tmp/m.mov", name: "m", duration: 1, width: 1, height: 1, fps: 30, hasVideo: true, hasAudio: true)
    m.vocabulary = ["Thom", "Celia"]
    #expect(Vocabulary.terms(p, media: m, speakerNames: ["S1", "Anna", "thom"]) == ["Thom", "Celia", "Cutline", "Anna"])
}

@Test func secondPassFillsOnlyUncoveredSpeech() {
    var t = Transcript(mediaId: "m", locale: "en-US", words: words("we have to go | | | now", confidence: 0.9))
    // Words at 0.5–1.85, a gap, then "now" at 4.3.
    let speech = [TimeRange(0.4, 2.0), TimeRange(2.4, 4.0), TimeRange(4.8, 5.2)]
    let gaps = t.unheardSpeech(speech)
    #expect(gaps.count == 1 && abs(gaps[0].start - 2.4) < 1e-9 && abs(gaps[0].end - 4.0) < 1e-9)
    let found = [
        Word(text: "go", start: 2.1, end: 2.3, confidence: 0.9),
        Word(text: "right", start: 2.6, end: 2.9, confidence: 0.8),
        Word(text: "away", start: 3.0, end: 3.3, confidence: 0.6),
        Word(text: "now", start: 4.85, end: 5.1, confidence: 0.9),
    ]
    #expect(t.addRecovered(found, in: gaps) == 2)
    #expect(t.words.map(\.text) == ["we", "have", "to", "go", "right", "away", "now"])
    var unsure = Transcript(mediaId: "m", locale: "en-US", words: [])
    #expect(unsure.addRecovered([Word(text: "me", start: 2.6, end: 2.9, confidence: 0.05), Word(text: "too", start: 3, end: 3.3, confidence: 0.37)], in: gaps) == 0)
    var echo = Transcript(mediaId: "m", locale: "en-US", words: [Word(text: "space.", start: 2.0, end: 2.3, confidence: 0.9)])
    #expect(echo.addRecovered([Word(text: "space.", start: 2.5, end: 2.8, confidence: 0.9)], in: gaps) == 0)
}

@Test func isolatedReadingIsTakenWhereItIsClearlyMoreConfident() {
    var plain = Transcript(mediaId: "m", locale: "en-US", words: words("the board is | | gone now", confidence: 0.3) + words("all fine here", from: 6, confidence: 0.95))
    let isolated = Transcript(mediaId: "m", locale: "en-US", words: words("the bird is | | gone now", confidence: 0.9) + words("all fine hear", from: 6, confidence: 0.9))
    #expect(plain.lowConfidenceShare > 0.5)
    #expect(plain.adoptBetter(isolated) == 2)
    #expect(plain.words.map(\.text) == ["the", "bird", "is", "gone", "now", "all", "fine", "here"])
}
