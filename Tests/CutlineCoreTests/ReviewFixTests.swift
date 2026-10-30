import Foundation
import Testing
@testable import CutlineCore

private func spoken() -> (Project, [String: Transcript]) {
    var p = Project(name: "Fixes")
    p.media = [MediaAsset(id: "m1", path: "/tmp/m1.mov", name: "m1", duration: 60, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 40)]
    var words: [Word] = []
    var t = 0.5
    for (i, sentence) in ["Look, we have to follow our passions.", "You have your robotics.", "I just want to be awesome in space, truly awesome.", "Done."].enumerated() {
        for token in sentence.split(separator: " ") {
            words.append(Word(text: String(token), start: t, end: t + 0.3))
            t += 0.35
        }
        t += i == 0 ? 0.8 : 0.9
    }
    return (p, ["m1": Transcript(mediaId: "m1", locale: "en-US", words: words)])
}

private let japanese = [
    "私たちは情熱を追いかけなければならない、と彼は2024年にiPhoneで言いました。",
    "あなたにはロボット工学があります。",
    "私はただ宇宙で最高の存在になりたいだけなのです、本当に素晴らしい存在に。",
    "終わり。",
]

@Test func japaneseSubtitlesBreakIntoShortLinesAtGoodPlaces() throws {
    var (p, tr) = spoken()
    try p.setCaptionTranslations("ja", texts: Dictionary(uniqueKeysWithValues: japanese.enumerated().map { ($0.offset, $0.element) }), transcripts: tr)
    let ja = p.subtitleCues(transcripts: tr, language: "ja")
    let lines = ja.flatMap(\.lines)
    #expect(ja.allSatisfy { $0.lines.count <= 2 }, "\(ja.map(\.lines))")
    #expect(lines.allSatisfy { Project.columns($0) <= 26 }, "13 full-width characters a line: \(lines)")
    #expect(lines.allSatisfy { !$0.contains(" ") }, "no word spaces: \(lines)")
    #expect(lines.allSatisfy { $0.first.map { !Project.noLineStart.contains($0) } ?? true }, "kinsoku: \(lines)")
    #expect(lines.contains { $0.contains("2024年") } && lines.contains { $0.contains("iPhone") }, "numbers and Latin words stay whole: \(lines)")
    #expect(ja.map { $0.lines.joined() }.joined() == japanese.joined(), "nothing lost")
    // The first sentence breaks after its comma.
    #expect(lines.contains { $0.hasSuffix("、") }, "\(lines)")
    let srt = p.subtitles(.srt, transcripts: tr, language: "ja")
    #expect(!srt.contains("私たちは情熱を追いかけなければならない、と彼は2024年"), "\(srt)")

    p.captions.language = "ja"
    p.captions.enabled = true
    let burned = p.captionSegments(transcripts: tr)
    #expect(burned.allSatisfy { $0.lines.count <= p.captions.style.maxLines }, "\(burned.map(\.text))")
    #expect(burned.flatMap { $0.text.components(separatedBy: "\n") }.allSatisfy { Project.columns($0) <= 26 && !$0.contains(" ") }, "\(burned.map(\.text))")

    let rules = SubtitleRules.forLanguage("ja")
    #expect(rules.maxCharsPerLine == 13 && rules.charsPerSecond == 4 && rules.wide)
    #expect(SubtitleRules.forLanguage("zh-Hant").maxCharsPerLine == 16 && SubtitleRules.forLanguage("ko").maxCharsPerLine == 16)
    #expect(SubtitleRules.forLanguage("fr").maxCharsPerLine == 42)
    #expect(!rules.tooFast(ja).isEmpty, "4 characters a second is slow; long cues read too fast")
    #expect(p.subtitleRules(language: "ja", transcripts: tr) == rules && p.subtitleRules(language: nil, transcripts: tr).maxCharsPerLine == 42)
}

@Test func untranslatedCuesKeepTheirOwnLineLength() throws {
    var (p, tr) = spoken()
    try p.setCaptionTranslations("ja", texts: [0: japanese[0]], transcripts: tr)
    let ja = p.subtitleCues(transcripts: tr, language: "ja"), en = p.subtitleCues(transcripts: tr)
    #expect(Array(ja.suffix(en.count - 1).map(\.lines)) == Array(en.dropFirst().map(\.lines)), "\(ja.map(\.lines))")
}

@Test func cjkUnitsKeepKinsokuNumbersAndWords() {
    #expect(Project.textUnits("「東京」へ行った。") == ["「東", "京」", "へ", "行っ", "た。"])
    #expect(Project.textUnits("円周率は3.14です") == ["円", "周", "率", "は", "3.14", "で", "す"])
    #expect(Project.textUnits("COVID-19の50%") == ["COVID-19", "の", "50%"])
    #expect(Project.textUnits("Hello world") == ["Hello", "world"])
    #expect(Project.joinWords(["東京", "へ", "iPhone", "and", "Mac"]) == "東京へiPhone and Mac")
}

@Test func timedTextSidecarsShareTheLeaderOffset() {
    let (p, tr) = spoken()
    var o = TimedTextOptions()
    o.offset = 30
    let imsc = p.timedText(.imsc, transcripts: tr, options: o)
    let srt = p.subtitles(.srt, transcripts: tr, offset: 30)
    let firstSRT = srt.components(separatedBy: "\n")[1].components(separatedBy: " --> ")[0].replacingOccurrences(of: ",", with: ".")
    #expect(imsc.contains("begin=\"\(firstSRT)\""), "\(firstSRT) in \(imsc.prefix(1500))")
    #expect(firstSRT.hasPrefix("00:00:30"))
}

@Test func edlSourceTimecodeIsValidAtTheListRate() throws {
    var p = Project(name: "Mixed", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    p.media = [
        MediaAsset(id: "film", path: "/tmp/film.mov", name: "film", duration: 60, width: 1920, height: 1080, fps: 24, hasVideo: true, hasAudio: false),
        MediaAsset(id: "fast", path: "/tmp/fast.mov", name: "fast", duration: 60, width: 1920, height: 1080, fps: 60, hasVideo: true, hasAudio: false),
    ]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "film", start: 0, duration: 2, sourceIn: 14 + 23.0 / 24),
        Clip(id: "b", kind: .media, mediaId: "fast", start: 2, duration: 2, sourceIn: 14 + 59.0 / 60),
    ]
    let edl = p.edl(title: "Mixed")
    let events = edl.split(separator: "\n").filter { $0.first?.isNumber == true }
    for e in events {
        for tc in e.split(separator: " ").suffix(4) {
            let ff = Int(tc.split(whereSeparator: { ":;".contains($0) }).last!)!
            #expect(ff < 25, "\(tc) in \(e)")
        }
    }
    #expect(edl.contains("* SOURCE TC: 00:00:14:23"), "\(edl)")
    #expect(edl.contains("* SOURCE TC: 00:00:14:59"), "\(edl)")
    #expect(events[1].contains(" 00:00:15:00 "), "frame 59 of 60 is nearest the next second at 25 fps: \(events[1])")
    let notes = p.interchangeLosses(.edl)
    #expect(notes.contains { $0.contains("Mixed-rate sources") && $0.contains("film 24 fps") && $0.contains("approximate") }, "\(notes)")
    #expect(!p.interchangeLosses(.xml).contains { $0.contains("Mixed-rate") })
}

@Test func positionAliasesPlaceFromTheTopLeft() throws {
    var c = Clip(id: "logo", kind: .media, mediaId: "m", start: 0, duration: 4)
    try c.set("transform.pos_x", .number(0.85))
    try c.set("transform.pos_y", .number(0.15))
    #expect(abs(c.transform.x - 0.35) < 1e-9 && abs(c.transform.y + 0.35) < 1e-9)
    #expect(c.staticValue("transform.pos_x")?.number.map { abs($0 - 0.85) < 1e-9 } == true)
    try c.animate("transform.pos_x", keys: [CurveKey(t: 0, v: .number(0.1)), CurveKey(t: 4, v: .number(0.9))])
    #expect(c.anim["transform.pos_x"] == nil && c.anim["transform.x"]?.keys.map(\.v) == [.number(0.1 - 0.5), .number(0.9 - 0.5)])
    #expect(abs(c.number("transform.pos_x", at: 4) - 0.9) < 1e-9 && abs(c.resolvedTransform(at: 4).x - 0.4) < 1e-9)
    #expect(c.animationKeys("transform.pos_x")?.last?.v.number.map { abs($0 - 0.9) < 1e-9 } == true)
}

@Test func clipsOutsideTheFrameOrTransparentAreFlagged() throws {
    var p = Project(name: "Logo")
    p.media = [
        MediaAsset(id: "bg", path: "/tmp/bg.mov", name: "bg", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: false),
        MediaAsset(id: "logo", path: "/tmp/logo.png", name: "logo", duration: 0, width: 400, height: 400, fps: 0, hasVideo: true, hasAudio: false, isImage: true),
    ]
    p.tracks[0].clips = [Clip(id: "bg1", kind: .media, mediaId: "bg", start: 0, duration: 4)]
    let v2 = p.addTrack(kind: .video, name: "Logo")
    var logo = Clip(id: "logo1", kind: .media, mediaId: "logo", start: 0, duration: 4)
    logo.transform.scale = 0.2
    try logo.set("transform.x", .number(0.85))
    try logo.set("transform.y", .number(0.15))
    p.tracks[p.trackIndex(v2.id)!].clips = [logo]
    #expect(p.qualityIssues(transcripts: [:]).contains { $0.contains("logo1") && $0.contains("outside the frame") }, "\(p.qualityIssues(transcripts: [:]))")

    try logo.set("transform.pos_x", .number(0.85))
    try logo.set("transform.pos_y", .number(0.15))
    p.tracks[p.trackIndex(v2.id)!].clips = [logo]
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.contains("logo1") }, "\(p.qualityIssues(transcripts: [:]))")

    // Sliding in from off-frame is fine; a layer that is never opaque is not.
    var slide = logo
    try slide.animate("transform.x", keys: [CurveKey(t: 0, v: .number(1.2)), CurveKey(t: 1, v: .number(0))])
    p.tracks[p.trackIndex(v2.id)!].clips = [slide]
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.contains("logo1") })
    logo.transform.opacity = 0
    p.tracks[p.trackIndex(v2.id)!].clips = [logo]
    #expect(p.qualityIssues(transcripts: [:]).contains { $0.contains("logo1") && $0.contains("fully transparent") })

    var title = Clip(id: "t1", kind: .text, start: 0, duration: 2, text: TextSpec(text: "Hello"))
    title.text?.x = 0.5
    title.transform.x = 0.85
    p.tracks[p.trackIndex(v2.id)!].clips = [title]
    #expect(p.qualityIssues(transcripts: [:]).contains { $0.contains("t1") && $0.contains("outside the frame") })
}

@Test func contiguousTakesShareTheirEdit() {
    let words = (0..<6).map { i in Word(text: "w\(i)", start: 24 + Double(i) * 0.4, end: 24 + Double(i) * 0.4 + 0.3) }
    let t = Transcript(mediaId: "m", locale: "en-US", words: words)
    let requested = [
        SourceSegment(mediaId: "m", sourceIn: words[0].start, sourceOut: words[2].end),
        SourceSegment(mediaId: "m", sourceIn: words[3].start, sourceOut: words[5].end),
    ]
    let padded = requested.map { $0.withHandles(t, before: 0.08, after: 0.12, fps: 30, duration: 60) }
    #expect(padded[1].sourceIn < padded[0].sourceOut, "handles overlap before butting")
    let butted = SourceSegment.butted(padded, requested: requested, fps: 30)
    #expect(abs(butted[0].sourceOut - butted[1].sourceIn) < 1e-9, "\(butted)")
    #expect(butted[0].sourceOut >= words[2].end - 1e-9 && butted[1].sourceIn <= words[3].start + 1e-9, "the edit sits in the gap: \(butted)")
    #expect(butted[0].sourceIn == padded[0].sourceIn && butted[1].sourceOut >= words[5].end)
    let frames = (butted[0].sourceOut - butted[0].sourceIn) * 30
    #expect(abs(frames - frames.rounded()) < 1e-6)
    // Takes far apart, or out of order, keep their handles.
    let apart = [requested[0], SourceSegment(mediaId: "m", sourceIn: 40, sourceOut: 42)]
    #expect(SourceSegment.butted(apart, requested: apart, fps: 30) == apart)
}

@Test func curvesMergeKeysAtTheSameTime() {
    let c = Curve(keys: [CurveKey(t: 0, v: .number(1)), CurveKey(t: 1, v: .number(3)), CurveKey(t: 1e-7, v: .number(2))])
    #expect(c.keys.count == 2 && c.keys[0].v == .number(2) && c.keys[0].t == 0, "\(c.keys)")
    #expect(c.value(at: 0) == .number(2))
}

@Test func titleCardsShowNoPlaceholderText() {
    for (type, field) in [("title.card", "kicker"), ("title.card", "subtitle"), ("title.lower_third_modern", "subtitle"), ("title.quote", "author"), ("title.end_card", "button"), ("title.data_callout", "label")] {
        #expect(GeneratorCatalog.defaultValue(type: type, name: field, params: [:]) == .string(""), "\(type).\(field)")
    }
    let card = Clip(id: "g", kind: .generator, start: 0, duration: 4, effects: [Effect(id: "gen", type: "title.card", params: ["title": .string("Part Two")])])
    #expect(card.generatorText(at: 2)?.text == "Part Two")
}
