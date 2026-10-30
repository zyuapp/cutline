import Foundation
import Testing
@testable import CutlineCore

// MARK: Fixtures

/// Words 0.32 s long, 0.08 s apart; "|" inserts a 1.5 s pause.
private func talk(_ text: String) -> [Word] {
    var t: Seconds = 0.4
    var out: [Word] = []
    for token in text.split(separator: " ") {
        if token == "|" { t += 1.5; continue }
        out.append(Word(text: String(token), start: t, end: t + 0.32))
        t += 0.4
    }
    return out
}

private let speech = """
Welcome to cut line, the um editor that lets an agent assemble your whole video from plain words and a few Q&A comments. \
It handles captions, chapters, and exports for every major platform you might care about today. | Short. | \
Then we keep talking for a long while without any punctuation at all so the cue has to break on length and duration rules alone and still read well on screen
"""

private func talkProject() -> (Project, [String: Transcript]) {
    var p = Project(name: "Talk")
    p.media = [MediaAsset(id: "m1", path: "/tmp/talk.mov", name: "talk", duration: 90, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 80)]
    p.captions.replacements = ["cut line": "Cutline"]
    p.captions.hiddenWords = ["um"]
    return (p, ["m1": Transcript(mediaId: "m1", locale: "en-US", words: talk(speech))])
}

/// V1: c1 (m1 0–4 from 2 s), gap, c2 (m2 5–8 at 2x). V2 "Overlay": o1, two titles. A1: a1 at half volume.
private func editProject() -> (Project, [String: Transcript]) {
    var p = Project(name: "Edit & <Cut>")
    p.media = [
        MediaAsset(id: "m1", path: "/tmp/cutline test/a.mov", name: "a", duration: 20, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true),
        MediaAsset(id: "m2", path: "/tmp/b.mov", name: "b", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: false),
    ]
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 4, sourceIn: 2),
        Clip(id: "c2", kind: .media, mediaId: "m2", start: 5, duration: 3, sourceIn: 1, speed: 2),
    ]
    p.tracks[1].clips = [Clip(id: "a1", kind: .media, mediaId: "m1", start: 2, duration: 4, volume: 0.5)]
    p.tracks.append(Track(id: "V2", kind: .video, name: "Overlay", clips: [
        Clip(id: "o1", kind: .media, mediaId: "m2", start: 1.5, duration: 2),
        Clip(id: "t1", kind: .text, start: 4.2, duration: 0.6, text: TextSpec(text: "Hello & <world>")),
        Clip(id: "t2", kind: .text, start: 6, duration: 1.5, text: TextSpec(text: "Second")),
    ]))
    p.markers = [
        Marker(id: "k2", time: 4.5, label: "Break"),
        Marker(id: "k1", time: 2, label: "Hook"),
        Marker(id: "k3", time: 6, label: "Fast"),
    ]
    p.captions.trackIds = ["V1"]
    let words = [Word(text: "Hello", start: 2.2, end: 2.6), Word(text: "there.", start: 2.7, end: 3.1)]
    return (p, ["m1": Transcript(mediaId: "m1", locale: "en-US", words: words)])
}

// MARK: Subtitles

private struct ParsedCue {
    var index: String?
    var start: Int
    var end: Int
    var lines: [String]
}

private func parseTime(_ s: Substring, _ sep: Character) -> Int? {
    let parts = s.split(separator: ":")
    guard parts.count == 3 else { return nil }
    let sec = parts[2].split(separator: sep)
    guard sec.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(sec[0]), let ms = Int(sec[1]) else { return nil }
    return ((h * 60 + m) * 60 + s) * 1000 + ms
}

private func parseCues(_ body: String, numbered: Bool, sep: Character) throws -> [ParsedCue] {
    let stamp = try Regex(sep == "," ? #"^\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}$"# : #"^\d{2}:\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}:\d{2}\.\d{3}$"#)
    return try body.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .newlines).isEmpty }.map { block in
        var lines = block.split(separator: "\n").map(String.init)
        let index = numbered ? lines.removeFirst() : nil
        let timing = lines.removeFirst()
        #expect(timing.wholeMatch(of: stamp) != nil, "bad timing line \(timing)")
        let ends = timing.components(separatedBy: " --> ")
        let start = try #require(parseTime(Substring(ends[0]), sep)), end = try #require(parseTime(Substring(ends[1]), sep))
        return ParsedCue(index: index, start: start, end: end, lines: lines)
    }
}

private func checkBroadcastRules(_ cues: [ParsedCue], maxChars: Int, maxLines: Int) {
    #expect(!cues.isEmpty)
    for (i, c) in cues.enumerated() {
        #expect(!c.lines.isEmpty && c.lines.count <= maxLines, "cue \(i + 1) has \(c.lines.count) lines")
        for line in c.lines { #expect(line.count <= maxChars, "line too long: \(line)") }
        #expect(c.end - c.start >= 1000 && c.end - c.start <= 7000, "cue \(i + 1) lasts \(c.end - c.start) ms")
        if i > 0 { #expect(c.start - cues[i - 1].end >= 100, "cue \(i + 1) starts \(c.start - cues[i - 1].end) ms after the previous") }
    }
}

@Test func srtFollowsBroadcastRules() throws {
    let (p, tr) = talkProject()
    let srt = p.subtitles(.srt, transcripts: tr)
    let cues = try parseCues(srt, numbered: true, sep: ",")
    #expect(cues.map(\.index) == cues.indices.map { "\($0 + 1)" })
    checkBroadcastRules(cues, maxChars: 42, maxLines: 2)
    let text = cues.flatMap(\.lines).joined(separator: " ")
    #expect(text.hasPrefix("Welcome to Cutline, the editor"))
    #expect(!text.lowercased().contains("cut line") && !text.contains(" um "))
    #expect(text.contains("Q&A"))
    // Sentence ends and pauses close cues.
    #expect(cues.contains { $0.lines.joined(separator: " ").hasSuffix("comments.") })
    #expect(cues.contains { $0.lines == ["Short."] })
    #expect(srt.hasPrefix("1\n00:00:00,400 --> "))
}

@Test func vttHasHeaderDotsAndEscapes() throws {
    let (p, tr) = talkProject()
    let vtt = p.subtitles(.vtt, transcripts: tr)
    #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.400 --> "))
    let cues = try parseCues(String(vtt.dropFirst("WEBVTT\n\n".count)), numbered: false, sep: ".")
    checkBroadcastRules(cues, maxChars: 42, maxLines: 2)
    #expect(cues.count == p.subtitleCues(transcripts: tr).count)
    #expect(vtt.contains("Q&amp;A") && !vtt.contains("Q&A"))
}

@Test func subtitlesRespectLineLimitsAndIgnoreCaptionCase() throws {
    var (p, tr) = talkProject()
    p.captions.style.uppercase = true
    let srt = p.subtitles(.srt, transcripts: tr, maxCharsPerLine: 16, maxLines: 1)
    checkBroadcastRules(try parseCues(srt, numbered: true, sep: ","), maxChars: 16, maxLines: 1)
    #expect(srt.contains("Welcome"))
    #expect(Project(name: "Empty").subtitles(.vtt, transcripts: [:]) == "WEBVTT\n")
    #expect(Project(name: "Empty").subtitles(.srt, transcripts: [:]) == "")
}

@Test func balancedLinesEvenOutLengths() {
    let words = "one two three four five six seven eight nine".split(separator: " ").map(String.init)
    let lines = Project.balancedLines(words, width: 50)
    #expect(lines == ["one two three four five six seven eight nine"])
    let two = Project.balancedLines(words, width: 30)
    #expect(two.count == 2)
    #expect(abs(two[0].count - two[1].count) <= 6)
    #expect(Project.subtitleTime(3_723_045, ",") == "01:02:03,045")
}

// MARK: Chapters

private func chapterProject(_ markers: [(Seconds, String)]) -> Project {
    var p = Project(name: "Ch")
    p.media = [MediaAsset(id: "m1", path: "/tmp/a.mov", name: "a", duration: 300, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m1", start: 0, duration: 120)]
    p.markers = markers.enumerated().map { Marker(id: "k\($0.offset)", time: $0.element.0, label: $0.element.1) }
    return p
}

@Test func chaptersStartAtZero() {
    let p = chapterProject([(61, "Main"), (25, "Setup"), (30, "Too close"), (115, "Outro")])
    #expect(p.chapters().map(\.time) == [0, 25, 30, 61, 115])
    #expect(p.chapters().map(\.title) == ["Intro", "Setup", "Too close", "Main", "Outro"])
    #expect(chapterProject([(0, "Start"), (50, "Next")]).chapters().map(\.title) == ["Start", "Next"])
    #expect(chapterProject([]).chapters().isEmpty)
}

@Test func youtubeChaptersAreTenSecondsApart() {
    let p = chapterProject([(61, "Main"), (25, "Setup"), (30, "Too close"), (115, "Outro")])
    #expect(p.youtubeChapterList() == "0:00 Intro\n0:25 Setup\n1:01 Main")
    // A marker right after the start takes over the generated Intro.
    #expect(chapterProject([(4, "Cold open"), (40, "Topic")]).youtubeChapterList() == "0:00 Cold open\n0:40 Topic")
    #expect(chapterProject([]).youtubeChapterList() == "")
    #expect(Project.chapterTime(3725) == "1:02:05")
    #expect(Project.chapterTime(59.9) == "0:59")
}

// MARK: OpenTimelineIO

private func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
private func value(_ item: [String: Any], _ field: String) -> Double? {
    dict(dict(item["source_range"])[field])["value"] as? Double
}

@Test func otioHasTracksClipsGapsAndMarkers() throws {
    let (p, _) = editProject()
    let root = try #require(try JSONSerialization.jsonObject(with: p.otio()) as? [String: Any])
    #expect(root["OTIO_SCHEMA"] as? String == "Timeline.1")
    #expect(dict(root["global_start_time"])["value"] as? Double == 108_000)
    let stack = dict(root["tracks"])
    #expect(stack["OTIO_SCHEMA"] as? String == "Stack.1")
    let tracks = try #require(stack["children"] as? [[String: Any]])
    #expect(tracks.map { $0["OTIO_SCHEMA"] as? String } == Array(repeating: "Track.1", count: 4))
    #expect(tracks.map { $0["name"] as? String } == ["Main", "Overlay", "Main Audio", "Music"])
    #expect(tracks.map { $0["kind"] as? String } == ["Video", "Video", "Audio", "Audio"])

    func items(_ t: Int) -> [[String: Any]] { tracks[t]["children"] as? [[String: Any]] ?? [] }
    func schemas(_ t: Int) -> [String?] { items(t).map { $0["OTIO_SCHEMA"] as? String } }
    func durations(_ t: Int) -> [Double?] { items(t).map { value($0, "duration") } }

    #expect(schemas(0) == ["Clip.2", "Gap.1", "Clip.2"])
    #expect(durations(0) == [120, 30, 90])
    let c1 = items(0)[0]
    #expect(value(c1, "start_time") == 60)
    #expect(dict(dict(c1["source_range"])["duration"])["rate"] as? Double == 30)
    #expect(c1["active_media_reference_key"] as? String == "DEFAULT_MEDIA")
    let ref = dict(dict(c1["media_references"])["DEFAULT_MEDIA"])
    #expect(ref["OTIO_SCHEMA"] as? String == "ExternalReference.1")
    #expect(ref["target_url"] as? String == "file:///tmp/cutline%20test/a.mov")
    #expect(dict(dict(ref["available_range"])["duration"])["value"] as? Double == 600)
    #expect(dict(dict(c1["metadata"])["cutline"])["clipId"] as? String == "c1")

    let c2 = items(0)[2]
    #expect(value(c2, "start_time") == 30)
    let warp = try #require((c2["effects"] as? [[String: Any]])?.first)
    #expect(warp["OTIO_SCHEMA"] as? String == "LinearTimeWarp.1")
    #expect(warp["time_scalar"] as? Double == 2)

    #expect(schemas(1) == ["Gap.1", "Clip.2", "Gap.1", "Gap.1", "Gap.1", "Gap.1"])
    #expect(durations(1) == [45, 60, 21, 18, 36, 45])
    let title = dict(dict(items(1)[3]["metadata"])["cutline"])
    #expect(title["kind"] as? String == "text")
    #expect(title["text"] as? String == "Hello & <world>")

    // Embedded audio of V1: m2 has none.
    #expect(schemas(2) == ["Clip.2", "Gap.1", "Gap.1"])
    #expect(durations(2) == [120, 30, 90])
    #expect(schemas(3) == ["Gap.1", "Clip.2"])
    #expect(durations(3) == [60, 120])

    let markers = try #require(stack["markers"] as? [[String: Any]])
    #expect(markers.map { $0["OTIO_SCHEMA"] as? String } == ["Marker.2", "Marker.2", "Marker.2"])
    #expect(markers.map { $0["name"] as? String } == ["Hook", "Break", "Fast"])
    #expect(markers.map { dict(dict($0["marked_range"])["start_time"])["value"] as? Double } == [60, 135, 180])
}

// MARK: FCPXML

private func seconds(_ s: String?) -> Double? {
    guard let s, s.hasSuffix("s") else { return nil }
    let parts = s.dropLast().split(separator: "/").compactMap { Double($0) }
    return parts.count == 2 ? parts[0] / parts[1] : parts.first
}

private func attr(_ e: XMLElement?, _ name: String) -> String? { e?.attribute(forName: name)?.stringValue }
private func elements(_ e: XMLElement?) -> [XMLElement] { e?.children?.compactMap { $0 as? XMLElement } ?? [] }

@Test func fcpxmlBuildsStorylineLanesAndTitles() throws {
    let (p, _) = editProject()
    let doc = try XMLDocument(xmlString: p.fcpxml(), options: [])
    let root = try #require(doc.rootElement())
    #expect(root.name == "fcpxml" && attr(root, "version") == "1.11")

    let format = try #require(try doc.nodes(forXPath: "/fcpxml/resources/format").first as? XMLElement)
    #expect(attr(format, "frameDuration") == "100/3000s")
    #expect(attr(format, "width") == "1920" && attr(format, "height") == "1080")
    #expect(attr(format, "name") == "FFVideoFormat1080p30")
    let assets = try doc.nodes(forXPath: "/fcpxml/resources/asset").compactMap { $0 as? XMLElement }
    #expect(assets.count == 2)
    #expect(attr(elements(assets[0]).first, "src") == "file:///tmp/cutline%20test/a.mov")
    #expect(attr(elements(assets[0]).first, "kind") == "original-media")
    #expect(attr(assets[0], "duration") == "20s" && attr(assets[0], "hasAudio") == "1")
    #expect(attr(assets[1], "hasAudio") == "0" && attr(assets[1], "format") == attr(format, "id"))
    let effect = try #require(try doc.nodes(forXPath: "/fcpxml/resources/effect").first as? XMLElement)
    #expect(attr(effect, "id") == "r_title" && attr(effect, "name") == "Basic Title")

    let project = try #require(try doc.nodes(forXPath: "/fcpxml/library/event/project").first as? XMLElement)
    #expect(attr(project, "name") == "Edit & <Cut>")
    let sequence = try #require(try doc.nodes(forXPath: "/fcpxml/library/event/project/sequence").first as? XMLElement)
    #expect(attr(sequence, "duration") == "8s" && attr(sequence, "tcStart") == "3600s")
    let spine = try #require(elements(sequence).first)
    let items = elements(spine)
    #expect(items.map(\.name) == ["asset-clip", "gap", "asset-clip"])

    let c1 = items[0]
    #expect([attr(c1, "offset"), attr(c1, "start"), attr(c1, "duration")] == ["3600s", "2s", "4s"])
    #expect(attr(c1, "ref") == attr(assets[0], "id"))
    let c1Kids = elements(c1)
    let overlay = try #require(c1Kids.first { attr($0, "lane") == "1" })
    #expect(overlay.name == "asset-clip" && attr(overlay, "ref") == attr(assets[1], "id"))
    // Offsets of connected clips are in the parent's source time: 2 s + 1.5 s.
    #expect(attr(overlay, "offset") == "7/2s" && attr(overlay, "start") == "0s" && attr(overlay, "duration") == "2s")
    let music = try #require(c1Kids.first { attr($0, "lane") == "-1" })
    #expect(attr(music, "offset") == "4s" && attr(music, "srcEnable") == "audio")
    #expect(attr(elements(music).first { $0.name == "adjust-volume" }, "amount") == "-6.02dB")
    let hook = try #require(c1Kids.first { $0.name == "marker" })
    #expect(attr(hook, "start") == "4s" && attr(hook, "value") == "Hook" && attr(hook, "duration") == "1/30s")
    #expect(c1Kids.map(\.name) == ["asset-clip", "asset-clip", "marker"])

    let gap = items[1]
    #expect(attr(gap, "offset") == "3604s" && attr(gap, "duration") == "1s")
    let t1 = try #require(elements(gap).first { $0.name == "title" })
    #expect(attr(t1, "lane") == "1" && attr(t1, "ref") == "r_title")
    #expect(attr(t1, "offset") == "1/5s" && attr(t1, "duration") == "3/5s")
    let styleRef = try #require(try t1.nodes(forXPath: "text/text-style").first as? XMLElement)
    #expect(styleRef.stringValue == "Hello & <world>")
    // Whitespace inside <text> would show in the title.
    #expect(try t1.nodes(forXPath: "text").first?.stringValue == "Hello & <world>")
    let def = try #require(try t1.nodes(forXPath: "text-style-def").first as? XMLElement)
    #expect(attr(def, "id") == attr(styleRef, "ref"))
    #expect(attr(elements(def).first, "fontSize") == "76")
    #expect(attr(elements(gap).first { $0.name == "marker" }, "start") == "1/2s")

    let c2 = items[2]
    #expect([attr(c2, "offset"), attr(c2, "start"), attr(c2, "duration")] == ["3605s", "1/2s", "3s"])
    let timepts = try c2.nodes(forXPath: "timeMap/timept").compactMap { $0 as? XMLElement }
    #expect(timepts.map { attr($0, "time") } == ["0s", "7/2s"])
    #expect(timepts.map { attr($0, "value") } == ["0s", "7s"])
    let t2 = try #require(elements(c2).first { $0.name == "title" })
    #expect(attr(t2, "offset") == "3/2s" && attr(t2, "lane") == "1")
    #expect(attr(elements(c2).first { $0.name == "marker" }, "start") == "3/2s")
    #expect(elements(c2).first?.name == "timeMap")

    // Every story time is a whole number of 30 fps frames.
    for node in try spine.nodes(forXPath: "descendant-or-self::*") {
        guard let e = node as? XMLElement, e.name != "timept" else { continue }
        for name in ["offset", "start", "duration"] {
            guard let s = attr(e, name) else { continue }
            let frames = try #require(seconds(s)) * 30
            #expect(abs(frames - frames.rounded()) < 1e-9, "\(e.name ?? "") \(name)=\(s) is off the frame grid")
        }
    }
}

@Test func fcpxmlTimesUseNTSCFrameDurations() {
    #expect(FrameGrid(fps: 29.97).fcp(1) == "1001/30000s")
    #expect(FrameGrid(fps: 23.976).fcp(24) == "1001/1000s")
    #expect(FrameGrid(fps: 30).fcp(45) == "3/2s")
    #expect(FrameGrid(fps: 25).fcp(50) == "2s")
    var p = Project(name: "NTSC", canvas: Canvas(fps: 29.97))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 2)]
    let xml = p.fcpxml()
    #expect(xml.contains("frameDuration=\"1001/30000s\""))
    #expect(xml.contains("name=\"FFVideoFormat1080p2997\""))
    #expect(xml.contains("<video ref=\"r_solid\" offset=\"8999991/2500s\" name=\"Solid\" start=\"0s\" duration=\"1001/500s\">") && xml.contains("tcStart=\"8999991/2500s\""))
}
