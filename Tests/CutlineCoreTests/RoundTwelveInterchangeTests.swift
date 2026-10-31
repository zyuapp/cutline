import Foundation
import Testing
@testable import CutlineCore

private func media(_ id: String, fps: Double = 24) -> MediaAsset {
    MediaAsset(id: id, path: "/tmp/\(id).mov", name: id, duration: 120, width: 1920, height: 1080, fps: fps, hasVideo: true, hasAudio: true)
}

/// c2 and c3 play take m in sync with their sound detached; c2's sound runs a second into c3 (L cut) and c3's starts
/// a second late, so both sound clips also play in sync with the other picture.
private func detachedProject(lCut: Bool = true) throws -> (Project, sound2: String, sound3: String) {
    var p = Project(name: "Linked")
    p.canvas.fps = 24
    p.media = [media("m"), media("n")]
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "n", start: 0, duration: 2, sourceIn: 1),
        Clip(id: "c2", kind: .media, mediaId: "m", start: 2, duration: 4, sourceIn: 10),
        Clip(id: "c3", kind: .media, mediaId: "m", start: 6, duration: 4, sourceIn: 14),
    ]
    p.tracks[1].clips = []
    let a = try p.detachAudio("c2").clip.id
    let b = try p.detachAudio("c3").clip.id
    if lCut {
        let t = try #require(p.locateClip(a)).track
        p.tracks[t].clips = p.tracks[t].clips.map { c in
            var c = c
            if c.id == a { c.duration = 5 }
            if c.id == b { c.start = 7; c.duration = 3; c.sourceIn = 15 }
            return c
        }
    }
    return (p, a, b)
}

/// Pictures to the sound clips linked to them, by media and timing (ids change on import).
private func linkedSound(_ p: Project) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for t in p.tracks where t.kind == .video {
        for c in t.clips where c.link != nil {
            let sound = p.tracks.filter { $0.kind == .audio }.flatMap(\.clips).filter { $0.link == c.link }
            out["\(c.mediaId!)@\(fmt2(c.start))"] = sound.map { "\($0.mediaId!)@\(fmt2($0.start))+\(fmt2($0.duration)) in \(fmt2($0.sourceIn))" }
        }
    }
    return out
}

private func check(_ q: Project, _ format: String, warnings: [String]) {
    let expected = ["m@2.00": ["m@2.00+5.00 in 10.00"], "m@6.00": ["m@7.00+3.00 in 15.00"]]
    #expect(linkedSound(q) == expected, "\(format): \(linkedSound(q))")
    let pictures = q.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { $0.mediaId == "m" }
    #expect(pictures.allSatisfy { $0.volume == 0 && $0.audioLead == 0 && $0.audioLag == 0 }, "\(format): detached sound stays a clip of its own")
    #expect(q.linkRangeIssues().isEmpty && q.linkSyncIssues().isEmpty, "\(format): \(q.linkRangeIssues()) \(q.linkSyncIssues())")
    #expect(!warnings.contains { $0.contains("after its picture") }, "\(format): \(warnings)")
}

@Test func fcp7XMLWritesAndReadsLinksOfDetachedSound() throws {
    let (p, a, b) = try detachedProject()
    let xml = p.xmeml()
    // c2 links itself and its sound: audio track 3, after V1's own sound (c1) and the empty A1.
    let doc = try XMLDocument(data: Data(xml.utf8))
    let item = try #require(try doc.nodes(forXPath: "//clipitem[@id='clipitem-c2']").first as? XMLElement)
    let links = item.elements(forName: "link").map { l in ["linkclipref", "mediatype", "trackindex", "clipindex"].map { l.elements(forName: $0).first?.stringValue ?? "" } }
    #expect(links == [["clipitem-c2", "video", "1", "2"], ["clipitem-\(a)", "audio", "3", "1"]], "\(links)")
    let sound = try #require(try doc.nodes(forXPath: "//clipitem[@id='clipitem-\(b)']").first as? XMLElement)
    #expect(sound.elements(forName: "link").compactMap { $0.elements(forName: "linkclipref").first?.stringValue } == ["clipitem-c3", "clipitem-\(b)"])

    let r = try Importer.xmeml(Data(xml.utf8), relativeTo: nil)
    check(r.project, "xmeml", warnings: r.warnings)
    let (inSync, _, _) = try detachedProject(lCut: false)
    let again = try Importer.xmeml(Data(inSync.xmeml().utf8), relativeTo: nil).project
    #expect(again.tracks.filter { $0.kind == .audio }.flatMap(\.clips).count == 2, "in-sync detached sound stays detached")
}

@Test func xmemlLinksAreReadExactlyWithoutGuessing() throws {
    // Without Cutline's detached note the sound is a Premiere split edit of its own picture, never of the other one.
    let (p, _, _) = try detachedProject()
    let xml = p.xmeml().replacingOccurrences(of: "<clipcommenta>\(Project.detachedTag)</clipcommenta>", with: "")
    let q = try Importer.xmeml(Data(xml.utf8), relativeTo: nil).project
    let pics = q.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { $0.mediaId == "m" }
    #expect(pics.map { [fmt2($0.audioLead), fmt2($0.audioLag)] } == [["0.00", "1.00"], ["-1.00", "0.00"]], "\(pics)")
}

@Test func fcpxmlKeepsDetachedSoundLinked() throws {
    let (p, _, _) = try detachedProject()
    let x = p.fcpxml()
    #expect(x.contains(Project.fcpLinkKey))
    let r = try Importer.fcpxml(Data(x.utf8), relativeTo: nil)
    check(r.project, "fcpxml", warnings: r.warnings)
}

@Test func aafKeepsDetachedSoundOnItsOwnTracks() throws {
    let (p, _, _) = try detachedProject()
    let r = try Importer.aaf(p.aaf(), relativeTo: nil)
    check(r.project, "aaf", warnings: r.warnings)
    // A picture's own sound still folds back into it.
    var own = p
    own.tracks = own.tracks.map { t in var t = t; t.clips = t.clips.filter { $0.mediaId != "m" || t.kind == .video }.map { c in var c = c; c.volume = 1; c.link = nil; return c }; return t }
    let back = try Importer.aaf(own.aaf(), relativeTo: nil).project
    #expect(back.tracks.filter { $0.kind == .audio }.flatMap(\.clips).isEmpty && back.tracks[0].clips.allSatisfy { $0.volume == 1 }, "\(back.tracks)")
}

@Test func fcpxmlSourceInRoundTripsExactly() throws {
    for (canvas, mediaFps, tc) in [(29.97, 29.97, nil), (29.97, 23.976, 3603.6), (23.976, 23.976, nil), (29.97, 25, 36000)] as [(Double, Double, Seconds?)] {
        var p = Project(name: "Exact")
        p.canvas.fps = canvas
        var m = media("m", fps: mediaFps)
        m.timecodeStart = tc
        p.media = [m]
        let d = p.canvas.snap(4)
        p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "m", start: 0, duration: d, sourceIn: 10), Clip(id: "c2", kind: .media, mediaId: "m", start: d, duration: d, sourceIn: 20.04)]
        let q = try Importer.fcpxml(Data(p.fcpxml().utf8), relativeTo: nil).project
        #expect(q.tracks[0].clips.map(\.sourceIn).map { ($0 * 1e6).rounded() / 1e6 } == [10, 20.04], "\(canvas)/\(mediaFps): \(q.tracks[0].clips.map(\.sourceIn))")
    }
}

@Test func dropFrameEDLWritesNonDropSourcesInNonDropNotation() throws {
    var p = Project(name: "DF")
    p.canvas.fps = 29.97
    var film = media("film", fps: 24)
    film.timecodeStart = 3600
    var video = media("video", fps: 29.97)
    video.timecodeStart = 3603.6
    p.media = [film, video]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "film", start: 0, duration: p.canvas.snap(2), sourceIn: 10),
                         Clip(id: "c2", kind: .media, mediaId: "video", start: p.canvas.snap(2), duration: p.canvas.snap(2), sourceIn: 10)]
    let edl = p.edl(title: "DF")
    #expect(edl.contains("FCM: DROP FRAME"))
    let events = edl.split(separator: "\n").filter { $0.hasPrefix("00") }.map { $0.split(separator: " ").map(String.init) }
    #expect(events.count == 2)
    // Source times: the 24 fps film counts non-drop, the 29.97 video drop frame; record times follow the list.
    #expect(events[0][4].contains(":10:") && !events[0][4].contains(";") && !events[0][5].contains(";"), "\(events[0])")
    #expect(events[1][4].contains(";"), "\(events[1])")
    #expect(events.allSatisfy { $0[6].contains(";") && $0[7].contains(";") }, "\(events)")
    #expect(edl.contains("* \(Project.edlSourceTCTag): 01:00:10:00"), "the film's own timecode stays noted\n\(edl)")
    let q = try Importer.edl(edl, fps: 29.97, media: p.media).project
    let back = q.tracks[0].clips.map(\.sourceIn)
    #expect(back.count == 2 && abs(back[0] - 10) < 0.05 && abs(back[1] - 10) < 0.05, "\(back)")
}

@Test func beatCutSpreadsPicksAcrossATake() {
    // One take with a strong stretch and weaker shots elsewhere in it: picks keep 3 s from each other.
    let footage = [
        BeatFootage(mediaId: "take", range: TimeRange(80, 95), quality: 1),
        BeatFootage(mediaId: "take", range: TimeRange(10, 20), quality: 0.6),
        BeatFootage(mediaId: "take", range: TimeRange(40, 50), quality: 0.5),
        BeatFootage(mediaId: "other", range: TimeRange(0, 10), quality: 0.4),
    ]
    let plan = BeatCutPlan.choose(footage, segments: Array(repeating: .init(need: 1, energy: nil), count: 6))
    var shown: [(id: String, r: TimeRange)] = []
    for pick in plan.picks.compactMap({ $0 }) {
        let r = TimeRange(pick.sourceIn, pick.sourceIn + 1), id = footage[pick.footage].mediaId
        let near = shown.filter { $0.id == id }.map { max($0.r.start - r.end, r.start - $0.r.end) }.min() ?? .infinity
        #expect(near >= 3 - 1e-6, "\(id) \(r) is \(near)s from an earlier pick: \(plan.picks)")
        shown.append((id, r))
    }
    #expect(shown.count == 6)
}

@Test func timelineNamesMatchIgnoringCase() throws {
    var p = Project(name: "T")
    try p.newTimeline("Cutdown", duplicate: false)
    try p.switchTimeline(to: "main")
    #expect(p.currentTimelineName == "Main")
    try p.switchTimeline(to: " CUTDOWN ")
    #expect(p.currentTimelineName == "Cutdown")
    try p.newTimeline("cutdown v2", duplicate: false)
    try p.newTimeline("CutDown V2", duplicate: false)
    #expect(throws: EditError.self) { try p.switchTimeline(to: "CUTDOWN V2") }
}

@Test func multicamSliversAreReported() throws {
    var p = Project(name: "Multicam")
    p.canvas.fps = 30
    p.media = [media("camA", fps: 30), media("camB", fps: 30)]
    let seq = try p.createMulticam(name: "Talk", angles: [("A", "camA", 0), ("B", "camB", 0)], audio: ["A"], sync: "marker")
    var c = Clip(id: "mc", kind: .sequence, name: "Talk", mediaId: seq.id, start: 0, duration: 40, sourceIn: 0)
    c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: "A")])
    p.tracks[0].clips = [c]
    try p.switchMulticam("mc", from: 10, angle: "B")
    try p.switchMulticam("mc", from: 10.17, angle: "A")
    let issue = p.qualityIssues(transcripts: [:]).first { $0.contains("sliver") }
    #expect(issue?.contains("mc plays angle 2 B for only 0.17s") == true && issue?.contains("multicam_cut") == true, "\(p.qualityIssues(transcripts: [:]))")
    try p.switchMulticam("mc", from: 10, to: 10.17, angle: "A")
    #expect(p.sliverIssues().isEmpty)
}
