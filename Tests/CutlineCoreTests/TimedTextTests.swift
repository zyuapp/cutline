import Foundation
import Testing
@testable import CutlineCore

/// Two speakers trading sentences: "<media>.w<i>" words 0.3 s apart, half a second between sentences.
private func dialogueProject(fps: Double = 30000.0 / 1001) -> (Project, [String: Transcript]) {
    let sentences = ["Did you bring the cables?", "Yes, they are in the van & ready.", "Which van, the blue one?", "No, the white one by the gate.", "Okay. I will grab them now."]
    var words: [Word] = []
    var t = 0.5
    for s in sentences {
        for w in s.split(separator: " ") {
            words.append(Word(text: String(w), start: t, end: t + 0.25))
            t += 0.3
        }
        t += 0.5
    }
    var p = Project(name: "Scene <1>")
    p.canvas.fps = fps
    p.media = [MediaAsset(id: "m1", path: "/tmp/scene.mov", name: "scene", duration: 30, width: 1920, height: 1080, fps: fps, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: t + 1)]
    return (p, ["m1": Transcript(mediaId: "m1", locale: "en-US", words: words)])
}

@Test func timedTextSidecarsShareCuesAndPassProfileChecks() throws {
    let (p, tr) = dialogueProject()
    let cues = p.subtitleCues(transcripts: tr)
    #expect(cues.count >= 3)
    for format in TimedTextFormat.allCases {
        let xml = p.timedText(format, transcripts: tr)
        #expect(Project.timedTextProblems(xml, format: format).isEmpty, "\(format): \(Project.timedTextProblems(xml, format: format))")
        let doc = try XMLDocument(xmlString: xml, options: [])
        let ps = try doc.nodes(forXPath: "//*[local-name()='p']")
        #expect(ps.count == cues.count, "\(format)")
        #expect(xml.contains("xmlns=\"http://www.w3.org/ns/ttml\""))
        #expect(xml.contains("ttp:timeBase=\"media\"") && xml.contains("ttp:cellResolution=\"32 15\"") && xml.contains("xml:lang=\"en\""))
        #expect(xml.contains("begin=\"00:00:00.500\""))
        #expect(xml.contains("van &amp; ready"))
        switch format {
        case .ttml, .imsc:
            #expect(xml.contains("ttp:frameRate=\"30\"") && xml.contains("ttp:frameRateMultiplier=\"1000 1001\""))
            #expect(xml.contains("ttp:contentProfiles=\"http://www.w3.org/ns/ttml/profile/imsc1.1/text\"") == (format == .imsc))
        case .ebuttd:
            #expect(!xml.contains("ttp:frameRate") && xml.contains("urn:ebu:tt:distribution:2018-04") && xml.contains("ebutts:linePadding"))
        }
    }
    // Lines are those of the .srt.
    let srtLines = p.subtitleCues(transcripts: tr).flatMap(\.lines)
    let imsc = try XMLDocument(xmlString: p.timedText(.imsc, transcripts: tr), options: [])
    #expect(try imsc.nodes(forXPath: "//*[local-name()='span']").compactMap(\.stringValue) == srtLines)
}

@Test func timedTextPlacesRegionsAndColorsSpeakers() throws {
    let (p, tr) = dialogueProject(fps: 25)
    var o = TimedTextOptions()
    o.position = "top"
    o.speakerColors = true
    // Sentences alternate speakers; a cue takes its words' most common speaker.
    var speakerOfWord: [String] = []
    var who = 0
    for w in tr["m1"]!.words {
        speakerOfWord.append(who % 2 == 0 ? "S1" : "S2")
        if w.text.hasSuffix("?") || w.text.hasSuffix(".") { who += 1 }
    }
    let xml = p.timedText(.imsc, transcripts: tr, options: o) { anchor in Project.parseWordAnchor(anchor).map { speakerOfWord[$0.word] } }
    #expect(Project.timedTextProblems(xml, format: .imsc).isEmpty)
    #expect(xml.contains("tts:displayAlign=\"before\"") && xml.contains("region=\"top\""))
    #expect(xml.contains("ttm:agent=\"agent_speaker1\"") && xml.contains("ttm:agent=\"agent_speaker2\""))
    #expect(xml.contains("tts:color=\"#FFFF00\""))
    #expect(xml.contains("ttp:frameRate=\"25\"") && !xml.contains("frameRateMultiplier"))
    let ebu = p.timedText(.ebuttd, transcripts: tr, options: o) { anchor in Project.parseWordAnchor(anchor).map { speakerOfWord[$0.word] } }
    #expect(Project.timedTextProblems(ebu, format: .ebuttd).isEmpty)
    #expect(!ebu.contains("ttm:agent") && ebu.contains("style=\"speaker2\""))
}

@Test func timedTextChecksCatchBrokenDocuments() {
    #expect(!Project.timedTextProblems("<tt", format: .ttml).isEmpty)
    let bare = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"00:00:02.000\" end=\"00:00:01.000\" style=\"nope\">hi</p></div></body></tt>"
    let problems = Project.timedTextProblems(bare, format: .ebuttd)
    #expect(problems.contains("tt has no xml:lang"))
    #expect(problems.contains("ttp:timeBase is not media"))
    #expect(problems.contains("no ttp:cellResolution"))
    #expect(problems.contains { $0.contains("ends before it begins") })
    #expect(problems.contains { $0.contains("missing style nope") })
    #expect(problems.contains { $0.contains("text outside a span") })
    #expect(Project.timedTextProblems(bare, format: .imsc).contains("no positive integer ttp:frameRate"))
}

@Test func lowerThirdsCountAsTitles() throws {
    var c = Clip(id: "g1", kind: .generator, start: 1, duration: 4)
    c.effects = [Effect(id: "gen", type: "lower_third", params: ["title": .string("Celia"), "subtitle": .string("Robotics"), "y": .number(0.84)])]
    let words = try #require(c.generatorText(at: 2))
    #expect(words.text == "Celia — Robotics" && words.y == 0.84 && words.background == nil)
    c.effects[0].params["style"] = .string("box")
    #expect(c.generatorText(at: 2)?.background != nil)
    c.effects[0].params["progress"] = .number(0)
    #expect(c.generatorText(at: 2) == nil)
    var arrow = Clip(id: "g2", kind: .generator, start: 0, duration: 2)
    arrow.effects = [Effect(id: "gen", type: "shape.arrow")]
    #expect(arrow.generatorText(at: 1) == nil)
    var counter = Clip(id: "g3", kind: .generator, start: 0, duration: 2)
    counter.effects = [Effect(id: "gen", type: "counter", params: ["to": .number(50), "progress": .number(0.5), "suffix": .string("%")])]
    #expect(counter.generatorText(at: 1)?.text == "25%")

    // A lower third in the caption band while words are spoken is flagged like a title.
    var (p, tr) = dialogueProject(fps: 30)
    c.effects[0].params["progress"] = .number(1)
    p.tracks.append(Track(id: "V2", kind: .video, name: "Graphics", clips: [c]))
    p.captions.enabled = true
    #expect(p.qualityIssues(transcripts: tr).contains { $0.hasPrefix("g1 “Celia — Robotics” sits on the captions") })
}

@Test func beatCutFillsBeforeTheFirstBeatOrMovesTheMusic() throws {
    func project() -> Project {
        var p = Project(name: "Beats")
        p.canvas.fps = 24
        p.media = [
            MediaAsset(id: "m1", path: "/tmp/a.mov", name: "a", duration: 30, width: 1920, height: 1080, fps: 24, hasVideo: true, hasAudio: false),
            MediaAsset(id: "song", path: "/tmp/s.m4a", name: "s", duration: 60, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
        ]
        p.tracks[1].clips = [Clip(id: "music", kind: .media, mediaId: "song", start: 0, duration: 20)]
        return p
    }
    let beats = (0..<9).map { 0.375 + Double($0) * 0.5 }
    let pool: [(mediaId: String, range: TimeRange)] = [("m1", TimeRange(0, 10)), ("m1", TimeRange(10, 20))]

    var p = project()
    let note = try p.beatCut(pool: pool, beats: beats, every: 1, trackId: "V1", from: 0)
    var clips = p.tracks[0].clips
    #expect(clips.first?.start == 0)
    #expect(abs(clips[0].end - p.canvas.snap(0.875)) < 1e-6)
    for (a, b) in zip(clips, clips.dropFirst()) { #expect(abs(a.end - b.start) < 1e-6) }
    #expect(note.contains("before the first beat"))
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.hasPrefix("gap on V1") })

    p = project()
    _ = try p.beatCut(pool: pool, beats: beats, every: 1, trackId: "V1", from: 0, align: .firstBeat, music: ["music"])
    clips = p.tracks[0].clips
    let music = try #require(p.clip("music"))
    let shift = p.canvas.snap(0.375)
    #expect(clips.first?.start == 0 && music.start == 0)
    #expect(abs(music.sourceIn - shift) < 1e-9 && abs(music.duration - (20 - shift)) < 1e-9)
    #expect(abs(clips[1].start - p.canvas.snap(0.875 - shift)) < 1e-6)

    // Without a range start the cut still begins on the first beat.
    p = project()
    _ = try p.beatCut(pool: pool, beats: beats, every: 1, trackId: "V1")
    #expect(p.tracks[0].clips.first?.start == p.canvas.snap(0.375))
}

@Test func rebuiltTurnsKeepTheLowestConfidence() {
    let t = Transcript(mediaId: "m", locale: "en", words: (0..<4).map { Word(text: "w", start: Double($0), end: Double($0) + 0.5) })
    var s = SpeakerAnalysis(mediaId: "m", speakers: ["S1", "S2"], segments: [
        SpeakerSegment(start: 0, end: 1.5, speaker: "S1", confidence: 0.9),
        SpeakerSegment(start: 2, end: 3.5, speaker: "S2", confidence: 0.4),
    ], wordSpeakers: ["S1", "S1", "S2", "S2"], emphasis: [0, 0, 0, 0])
    s.rename(["S2": "S1"], transcript: t)
    #expect(s.segments.count == 1 && s.segments[0].confidence == 0.4)
}
