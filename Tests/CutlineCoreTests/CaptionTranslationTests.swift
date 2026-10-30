import Foundation
import Testing
@testable import CutlineCore

private func speech(_ text: String, from start: Double = 0.5) -> [Word] {
    var t = start
    var out: [Word] = []
    for token in text.split(separator: " ") {
        if token == "|" { t += 0.8; continue }
        out.append(Word(text: String(token), start: t, end: t + 0.3))
        t += 0.35
    }
    return out
}

private func project() -> (Project, [String: Transcript]) {
    var p = Project(name: "Lang")
    p.media = [MediaAsset(id: "m1", path: "/tmp/m1.mov", name: "m1", duration: 60, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 40)]
    let text = "Look, we have to follow our passions. | You have your robotics. | I just want to be awesome in space. | Done."
    return (p, ["m1": Transcript(mediaId: "m1", locale: "en-US", words: speech(text))])
}

private let french = [
    "Écoute, nous devons suivre nos passions.", "Tu as ta robotique.",
    "Je veux juste être génial dans l'espace, vraiment génial, au-delà de toutes les étoiles et de toutes les galaxies connues.", "Fini.",
]

@Test func translatedSubtitlesShareTheSpokenCueTimes() throws {
    var (p, tr) = project()
    let cues = p.captionCues(transcripts: tr)
    #expect(cues.count == 4)
    #expect(p.spokenLanguage(transcripts: tr) == "en")
    try p.setCaptionTranslations("fr", texts: Dictionary(uniqueKeysWithValues: french.enumerated().map { ($0.offset, $0.element) }), transcripts: tr)
    let fr = p.subtitleCues(transcripts: tr, language: "fr")
    let en = p.subtitleCues(transcripts: tr)
    // The long third line is split at a clause into two cues two frames apart, run on into the pauses around it to
    // read better; cues that read in time keep the spoken cue's time.
    #expect(fr.count == 5)
    #expect(fr[0].startMs == en[0].startMs && fr[0].endMs == en[0].endMs && fr[1].startMs == en[1].startMs && fr[1].endMs == en[1].endMs)
    #expect(fr[2].startMs == en[2].startMs - 250 && fr[3].endMs == en[3].startMs - 67 && fr[3].startMs - fr[2].endMs == 67)
    #expect(fr[2].lines.last?.hasSuffix(",") == true)
    #expect(fr[4].startMs == en[3].startMs && fr[4].lines == ["Fini."])
    #expect(fr.allSatisfy { $0.lines.count <= 2 && $0.lines.allSatisfy { $0.count <= 42 } })
    #expect(fr[0].lines.joined(separator: " ") == french[0])
    let srt = p.subtitles(.srt, transcripts: tr, language: "fr")
    #expect(srt.contains("Tu as ta robotique.") && !srt.contains("robotics"))
    var o = TimedTextOptions()
    o.language = "fr"
    o.translation = "fr"
    let imsc = p.timedText(.imsc, transcripts: tr, options: o)
    #expect(imsc.contains("xml:lang=\"fr\"") && imsc.contains("Fini."))
    #expect(Project.timedTextProblems(imsc, format: .imsc).isEmpty)
}

@Test func burnedInCaptionsShowTheChosenLanguage() throws {
    var (p, tr) = project()
    try p.setCaptionTranslations("fr", texts: [0: french[0], 1: french[1]], transcripts: tr)
    p.captions.language = "fr"
    let segments = p.captionSegments(transcripts: tr)
    let words = segments.flatMap(\.words)
    #expect(words.map(\.text).starts(with: ["Écoute,", "nous", "devons"]))
    #expect(words.contains { $0.text == "space." }, "untranslated cues keep the spoken words")
    let cue = p.captionCues(transcripts: tr)[0]
    let first = try #require(segments.first)
    #expect(abs(first.start - cue.start) < 1e-9)
    #expect(first.words.allSatisfy { $0.start >= cue.words[0].start - 1e-9 && $0.end <= cue.words.last!.end + 1e-9 })
}

@Test func translationsFollowCueSplitsAndReportStaleOnes() throws {
    var (p, tr) = project()
    try p.setCaptionTranslations("fr", texts: [0: french[0]], transcripts: tr)
    // Starting a new cue mid-sentence splits the translated cue; its text is shared out by length.
    p.captions.edits.append(CaptionEdit(mediaId: "m1", fromWord: 4, toWord: 4, breakBefore: true))
    let cues = p.captionCues(transcripts: tr)
    let (texts, stale) = p.cueTranslations("fr", cues: cues)
    #expect(stale == 0)
    #expect(texts[0] != nil && texts[1] != nil)
    #expect([texts[0]!, texts[1]!].joined(separator: " ") == french[0])
    // A translation whose first word no longer starts a cue is stale.
    p.captions.edits = [CaptionEdit(mediaId: "m1", fromWord: 0, toWord: 0, hidden: true)]
    #expect(p.cueTranslations("fr", cues: p.captionCues(transcripts: tr)).stale == 1)
}

@Test func translatedSubtitleFilesImportByTime() throws {
    var (p, tr) = project()
    let cues = p.captionCues(transcripts: tr)
    func t(_ ms: Int) -> String { Project.subtitleTime(ms, ",") }
    let srt = """
    1
    \(t(cues[0].startMs + 50)) --> \(t(cues[0].endMs - 50))
    <i>Écoute,</i> nous devons

    2
    \(t(cues[0].endMs - 40)) --> \(t(cues[0].endMs + 10))
    suivre nos passions.

    3
    \(t(cues[2].startMs)) --> \(t(cues[2].endMs))
    Je veux juste être génial dans l'espace.

    """
    let parsed = Project.parseSubtitles(srt)
    #expect(parsed.count == 3 && parsed[0].lines == ["Écoute, nous devons"])
    let texts = p.translationTexts(from: parsed, transcripts: tr)
    #expect(texts[0] == "Écoute, nous devons suivre nos passions.")
    #expect(texts[2] == "Je veux juste être génial dans l'espace." && texts[1] == nil)
    try p.setCaptionTranslations("fr", texts: texts, transcripts: tr)
    let vtt = Project.parseSubtitles("WEBVTT\n\n00:01.000 --> 00:02.500 align:start\nBonjour &amp; merci\n")
    #expect(vtt.first?.startMs == 1000 && vtt.first?.endMs == 2500 && vtt.first?.lines == ["Bonjour & merci"])
    let data = try JSONEncoder().encode(p.captions)
    let back = try JSONDecoder().decode(Captions.self, from: data)
    #expect(back == p.captions && back.translations["fr"]?.count == 2)
    #expect(!String(decoding: try JSONEncoder().encode(Captions()), as: UTF8.self).contains("translations"))
}
