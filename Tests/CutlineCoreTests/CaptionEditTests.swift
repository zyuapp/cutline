import Testing
@testable import CutlineCore

private func words(_ text: String, from start: Double, step: Double = 0.4) -> [Word] {
    text.split(separator: " ").enumerated().map { i, w in
        Word(text: String(w), start: start + Double(i) * step, end: start + Double(i) * step + step * 0.8)
    }
}

/// V1 dialogue (m1) plus an audio track named "Ambience" (m2) whose recording has speech in it.
private func scene() -> (Project, [String: Transcript]) {
    var p = Project(name: "Scene")
    p.media = [
        MediaAsset(id: "m1", path: "/tmp/a.mov", name: "a", duration: 20, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "m2", path: "/tmp/amb.wav", name: "amb", duration: 20, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 10)]
    p.tracks[1].name = "Ambience"
    p.tracks[1].clips = [Clip(id: "a1", kind: .media, mediaId: "m2", start: 0, duration: 10, volume: 0.3)]
    return (p, [
        "m1": Transcript(mediaId: "m1", locale: "en", words: words("We need to leave now. The storm is coming fast.", from: 1)),
        "m2": Transcript(mediaId: "m2", locale: "en", words: words("crowd chatter somewhere far away", from: 2)),
    ])
}

@Test func captionsReadDialogueTracksByDefault() {
    var (p, tr) = scene()
    let text = p.captionSegments(transcripts: tr).map(\.text).joined(separator: " ")
    #expect(text.contains("storm") && !text.contains("chatter"))
    #expect(p.overlappingSpeech(transcripts: tr).isEmpty)

    p.tracks[1].name = "A1"
    #expect(p.captionSegments(transcripts: tr).map(\.text).joined(separator: " ").contains("chatter"))
    #expect(!p.overlappingSpeech(transcripts: tr).isEmpty)

    p.tracks[0].role = "dialogue"
    #expect(!p.captionSegments(transcripts: tr).map(\.text).joined(separator: " ").contains("chatter"))
}

@Test func captionEditsRewriteRetimeHideAndBreak() throws {
    var (p, tr) = scene()
    // "The storm is coming fast." is m1.w5–w9.
    p.captions.edits = [CaptionEdit(mediaId: "m1", fromWord: 6, toWord: 6, text: "hurricane"), CaptionEdit(mediaId: "m1", fromWord: 0, toWord: 0, startOffset: -0.2)]
    let segs = p.captionSegments(transcripts: tr)
    #expect(segs.map(\.text).joined(separator: " ").contains("The hurricane is coming fast."))
    #expect(abs(segs[0].start - 0.8) < 1e-9)
    #expect(segs.flatMap(\.words).contains { $0.anchor == "m1.w6" && $0.text == "hurricane" })

    p.captions.edits = [CaptionEdit(mediaId: "m1", fromWord: 0, toWord: 4, hidden: true)]
    #expect(p.captionSegments(transcripts: tr).map(\.text).joined(separator: " ") == "The storm is coming fast.")

    p.captions.edits = [CaptionEdit(mediaId: "m1", fromWord: 2, toWord: 2, breakBefore: true)]
    #expect(p.captionSegments(transcripts: tr).first?.text == "We need")
    #expect(p.subtitleCues(transcripts: tr).first?.text == "We need")

    // Edits follow the words when the clip moves.
    p.tracks[0].clips[0].start = 5
    #expect(p.captionSegments(transcripts: tr).first.map { abs($0.start - 6) < 1e-9 } == true)
}

@Test func subtitlesClipToExportRange() {
    let (p, tr) = scene()
    let all = p.subtitleCues(transcripts: tr)
    let part = p.subtitleCues(transcripts: tr, range: TimeRange(2, 4))
    #expect(!part.isEmpty && part.count <= all.count)
    #expect(part.allSatisfy { $0.startMs >= 0 && $0.endMs <= 2000 })
    #expect(p.subtitles(.srt, transcripts: tr, range: TimeRange(2, 4)).hasPrefix("1\n00:00:00,000 --> "))
    #expect(p.subtitleCues(transcripts: tr, range: TimeRange(15, 20)).isEmpty)
}

@Test func transcriptCorrectionsKeepSpeakersParallel() throws {
    var t = Transcript(mediaId: "m1", locale: "en", words: words("hello their friend how are you", from: 0))
    var s = SpeakerAnalysis(mediaId: "m1", speakers: ["S1"], segments: [SpeakerSegment(start: 0, end: 3, speaker: "S1")], wordSpeakers: Array(repeating: "S1", count: 6), emphasis: Array(repeating: 0, count: 6))
    let n = try t.replaceWords(1...1, with: "there my")
    s.spliceWords(1..<2, count: n)
    #expect(t.words.map(\.text) == ["hello", "there", "my", "friend", "how", "are", "you"])
    #expect(s.wordSpeakers.count == 7 && s.emphasis.count == 7)
    #expect(t.words[1].start == 0.4 && abs(t.words[2].end - 0.72) < 1e-9)

    s.assign(4...6, to: "S2", transcript: t)
    #expect(s.speakers == ["S1", "S2"])
    #expect(s.segments.map(\.speaker) == ["S1", "S2"])
    #expect(s.speaker(at: 1.7) == "S2")

    s.rename(["S1": "Anna", "S2": "Anna"], transcript: t)
    #expect(s.speakers == ["Anna"] && s.segments.count == 1)

    let r = t.insertWords("oh well", start: 2.9, end: 3.1)
    #expect(r == 7..<9 && t.words.count == 9)
    #expect(throws: EditError.self) { try t.replaceWords(8...12, with: "x") }
}

@Test func beatCutLeavesNoGapsOnOffGridBeats() throws {
    var p = Project(name: "Beats")
    p.canvas.fps = 25
    p.media = [MediaAsset(id: "m1", path: "/tmp/a.mov", name: "a", duration: 30, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false)]
    let beats = (0..<12).map { 0.013 + Double($0) * 0.4873 }
    _ = try p.beatCut(pool: [("m1", TimeRange(0, 10)), ("m1", TimeRange(10, 20))], beats: beats, every: 1, trackId: "V1")
    let clips = p.tracks[0].clips
    #expect(clips.count == 11)
    for (a, b) in zip(clips, clips.dropFirst()) { #expect(abs(a.end - b.start) < 1e-6) }
    // Spans are entered at their middle, not their first frames.
    #expect(clips[0].sourceIn > 4)
}

@Test func musicFitsByCuttingOrRepeatingBars() throws {
    let bars = stride(from: 1.0, to: 60, by: 2.0).map { $0 }
    let short = try MusicFit.plan(song: TimeRange(0, 60), downbeats: bars, target: 44)
    #expect(short.pieces.count == 2 && abs(short.length - 44) < 1e-9 && short.overshoot == 0)
    #expect(bars.contains(short.pieces[0].end) && bars.contains(short.pieces[1].start))
    #expect(short.pieces[1].end == 60)

    let odd = try MusicFit.plan(song: TimeRange(0, 60), downbeats: bars, target: 44.3)
    #expect(odd.length >= 44.3 && odd.overshoot < 2)

    let long = try MusicFit.plan(song: TimeRange(0, 60), downbeats: bars, target: 100)
    #expect(long.length >= 100 && long.length - 100 < 2 && long.pieces.last?.end == 60)

    var p = Project(name: "Music")
    p.media = [MediaAsset(id: "song", path: "/tmp/s.m4a", name: "s", duration: 60, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)]
    p.tracks[1].clips = [Clip(id: "mu", kind: .media, mediaId: "song", start: 2, duration: 60)]
    _ = try p.fitMusic(clipId: "mu", length: 30, downbeats: bars)
    let clips = p.tracks[1].clips
    #expect(clips.first?.id == "mu" && clips.first?.start == 2)
    #expect(abs(clips.last!.end - 32) < 0.05)
    for (a, b) in zip(clips, clips.dropFirst()) { #expect(abs(a.end - b.start) < 1e-6) }
}

@Test func titleSpansSplitTextWhereStyleChanges() {
    var s = TextSpec(text: "Meet Ada, the first")
    s.spans = [TextSpan(match: "ada", color: .black), TextSpan(from: 2, to: 6, weight: 900)]
    let pieces = s.styledPieces()
    #expect(pieces.map(\.text) == ["Me", "et ", "Ad", "a", ", the first"])
    #expect(pieces[2].style?.color == .black && pieces[2].style?.weight == 900)
    #expect(pieces[1].style?.color == nil && pieces[4].style == nil)
    #expect(pieces.map(\.text).joined() == s.text)
}
