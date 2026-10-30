import Foundation
import Testing
@testable import CutlineCore

/// Words 0.3 s long, 0.05 s apart; "|" is a 0.8 s pause.
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

private let script = """
So today we are going to look at how the editor builds every one of its captions. | \
It reads the words you said and groups them into short readable blocks of text with captions. | \
Then it times each block. | Done.
"""

private func project(_ text: String = script) -> (Project, [String: Transcript]) {
    var p = Project(name: "Cues")
    p.media = [MediaAsset(id: "m1", path: "/tmp/m1.mov", name: "m1", duration: 60, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 40)]
    return (p, ["m1": Transcript(mediaId: "m1", locale: "en", words: speech(text))])
}

@Test func everyCaptionOutputSharesTheCues() {
    var (p, tr) = project()
    p.captions.style.maxWordsPerLine = 12
    let cues = p.captionCues(transcripts: tr)
    let srt = p.subtitleCues(transcripts: tr)
    let cc = p.subtitleCues(transcripts: tr, maxCharsPerLine: 32, maxLines: 4)
    let burned = p.captionSegments(transcripts: tr)
    #expect(cues.count >= 4)
    #expect(srt.count == cues.count && cc.count == cues.count && burned.count == cues.count)
    for (i, c) in cues.enumerated() {
        #expect(srt[i].startMs == c.startMs && srt[i].endMs == c.endMs)
        #expect(cc[i].startMs == c.startMs && cc[i].endMs == c.endMs)
        #expect(abs(burned[i].start - c.start) < 1e-9)
        #expect(burned[i].words.map(\.text) == c.words.map(\.text))
        #expect(srt[i].lines.joined(separator: " ") == c.text && cc[i].lines.joined(separator: " ") == c.text)
        #expect(cc[i].lines.allSatisfy { $0.count <= 32 })
    }
}

@Test func burnedInPagesSplitACueWithoutChangingSubtitles() {
    var (p, tr) = project()
    p.captions.style.maxWordsPerLine = 3
    p.captions.style.maxLines = 1
    let cues = p.captionCues(transcripts: tr)
    let burned = p.captionSegments(transcripts: tr)
    #expect(burned.count > cues.count)
    #expect(p.subtitleCues(transcripts: tr).count == cues.count)
    for c in cues {
        let pages = burned.filter { $0.start >= c.start - 1e-9 && $0.start < c.end }
        #expect(pages.flatMap(\.words).map(\.text) == c.words.map(\.text))
        #expect(pages.allSatisfy { $0.words.count <= 3 && $0.lines.count == 1 })
        for (a, b) in zip(pages, pages.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
    }
}

@Test func aSentenceEndNeverSitsAlone() {
    let (p, tr) = project()
    let cues = p.captionCues(transcripts: tr)
    for (prev, cue) in zip(cues, cues.dropFirst()) where cue.words.count == 1 {
        #expect(Project.endsSentence(prev.words.last!.text), "orphan \"\(cue.text)\" after \"\(prev.text)\"")
    }
    #expect(!cues.contains { $0.text == "captions." })
    // A standalone one-word sentence after a pause stays its own cue.
    #expect(cues.last?.text == "Done.")
}

@Test func narrowSubtitlesSplitInsideSharedCues() {
    let (p, tr) = project()
    let cues = p.captionCues(transcripts: tr)
    let narrow = p.subtitleCues(transcripts: tr, maxCharsPerLine: 16, maxLines: 1)
    #expect(narrow.count > cues.count)
    #expect(narrow.allSatisfy { $0.lines.count == 1 && $0.lines[0].count <= 16 })
    // Each narrow cue's text lies inside one shared cue.
    #expect(narrow.allSatisfy { n in cues.contains { $0.text.contains(n.text) } })
}

@Test func mergingCuesJoinsThemEverywhereAndFollowsCuts() throws {
    var (p, tr) = project()
    var cues = p.captionCues(transcripts: tr)
    let i = try #require(cues.firstIndex { $0.text == "Then it times each block." })
    let before = cues.count
    try p.mergeCaptionCue(i, transcripts: tr)
    cues = p.captionCues(transcripts: tr)
    #expect(cues.count == before - 1)
    #expect(cues.contains { $0.text == "Then it times each block. Done." })
    #expect(p.subtitleCues(transcripts: tr).contains { $0.text == "Then it times each block. Done." })
    #expect(p.captionSegments(transcripts: tr).contains { $0.words.map(\.text).joined(separator: " ") == "Then it times each block. Done." })
    #expect(p.captions.edits.contains { $0.mergeNext == true })

    // The merge follows the words when the clip moves.
    p.tracks[0].clips[0].start = 3
    #expect(p.captionCues(transcripts: tr).contains { $0.text == "Then it times each block. Done." })

    // Too long to merge.
    let (q0, tr2) = project()
    var q = q0
    let long = q.captionCues(transcripts: tr2)
    #expect(throws: EditError.self) { try q.mergeCaptionCue(0, transcripts: tr2) }
    #expect(q.captionCues(transcripts: tr2) == long)
}

@Test func breakBeforeStillSplitsAndMergeUndoesIt() throws {
    var (p, tr) = project()
    // "It reads the words…" starts at w17; break before "words" (w20).
    p.captions.edits = [CaptionEdit(mediaId: "m1", fromWord: 20, toWord: 20, breakBefore: true)]
    var cues = p.captionCues(transcripts: tr)
    let k = try #require(cues.firstIndex { $0.text == "It reads the" })
    #expect(cues[k + 1].words.first?.text == "words")
    try p.mergeCaptionCue(k, transcripts: tr)
    cues = p.captionCues(transcripts: tr)
    #expect(!cues.contains { $0.text == "It reads the" })
    #expect(!p.captions.edits.contains { $0.breakBefore == true })
}
