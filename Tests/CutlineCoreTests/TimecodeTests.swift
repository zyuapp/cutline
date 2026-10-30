import Foundation
import Testing
@testable import CutlineCore

// MARK: Counting

@Test func labelsCountFramesAndRealTimeIsFramesTimesTheirDuration() throws {
    // (fps, label, frames from midnight, real seconds)
    let cases: [(Double, String, Int, Seconds)] = [
        (24000.0 / 1001, "10:00:00:00", 864_000, 36036),
        (24000.0 / 1001, "01:00:00:00", 86400, 3603.6),
        (24, "10:00:00:00", 864_000, 36000),
        (24, "01:00:00:00", 86400, 3600),
        (25, "10:00:00:00", 900_000, 36000),
        (25, "01:00:00:00", 90000, 3600),
        (30000.0 / 1001, "10:00:00:00", 1_080_000, 36036),
        (30000.0 / 1001, "10:00:00;00", 1_078_920, 35999.964),
        (30000.0 / 1001, "01:00:00:00", 108_000, 3603.6),
        (30000.0 / 1001, "01:00:00;00", 107_892, 3599.9964),
        (60000.0 / 1001, "10:00:00:00", 2_160_000, 36036),
        (60000.0 / 1001, "10:00:00;00", 2_157_840, 35999.964),
        (60000.0 / 1001, "01:00:00:00", 216_000, 3603.6),
        (60000.0 / 1001, "01:00:00;00", 215_784, 3599.9964),
    ]
    for (fps, label, frames, seconds) in cases {
        let f = TimecodeFormat(fps: fps, label: label)
        #expect(f.frames(label) == frames, "\(label) @\(fps)")
        #expect(abs(f.seconds(frames) - seconds) < 1e-6, "\(label) @\(fps): \(f.seconds(frames))")
        #expect(f.string(frames) == label, "\(label) @\(fps)")
        #expect(f.frameCount(seconds) == frames, "\(label) @\(fps)")
        // The nice rate a probe reports counts the same.
        #expect(TimecodeFormat(fps: (fps * 1000).rounded() / 1000, label: label).frames(label) == frames)
    }
    // ";" reads drop frame even where the format counts non-drop; rates without drop frame ignore it.
    #expect(TimecodeFormat(fps: 29.97, dropFrame: false).frames(reading: "01:00:00;00") == 107_892)
    #expect(TimecodeFormat(fps: 25).frames(reading: "01:00:00;00") == 90000)
}

@Test func mediaTimecodeIsFrameExactAndKeepsItsLabel() throws {
    var m = MediaAsset(id: "a", path: "/x/a.mxf", name: "a", duration: 60, width: 1920, height: 1080, fps: 29.97, hasVideo: true, hasAudio: true)
    let ndf = TimecodeFormat(fps: 29.97, label: "10:00:00:00")
    m.setTimecode(frames: try #require(ndf.frames("10:00:00:00")), format: ndf)
    #expect(m.timecodeStart == 36036 && m.timecodeLabel == "10:00:00:00")
    #expect(m.timecodeFrames() == 1_080_000 && m.timecodeString() == "10:00:00:00")
    #expect(m.sourceFrames(at: 1) == 1_080_030)
    #expect(try abs(#require(m.sourceSeconds(timecode: "10:00:01:00")) - 1.001) < 1e-9)
    #expect(m.timecodeFormat().string(m.sourceFrames(at: 60.06)) == "10:01:00:00")

    // Legacy projects stored only seconds: the label follows the rate's default counting.
    var legacy = m
    legacy.timecodeLabel = nil
    #expect(legacy.timecodeFrames() == 1_080_000 && legacy.timecodeString() == "10:00:36;00")
    #expect(legacy.timecodeFormat(dropFrame: false).string(legacy.timecodeFrames()!) == "10:00:00:00")
    // A stale label loses to the start it no longer matches.
    legacy.timecodeLabel = "09:00:00:00"
    #expect(legacy.timecodeFrames() == 1_080_000)
}

@Test func sourceTimecodeAnchorsCountInTheMediasOwnTimecode() throws {
    var p = Project(name: "TC", canvas: Canvas(fps: 25))
    var m = MediaAsset(id: "cam", path: "/x/cam.mov", name: "cam", duration: 60, width: 1920, height: 1080, fps: 30000.0 / 1001, hasVideo: true, hasAudio: true)
    m.setTimecode(frames: 107_892, format: TimecodeFormat(fps: m.fps, label: "01:00:00;00"))
    p.media = [m]
    #expect(try abs(p.resolveSourceTime("cam@01:00:10;00", transcripts: [:]) - 300.0 * 1001 / 30000) < 1e-9)
    #expect(try abs(p.resolveSourceTime("cam@01:00:10;00+0.5", transcripts: [:]) - (300.0 * 1001 / 30000 + 0.5)) < 1e-9)
    // Past the first minute, drop frame skips ;00 and ;01.
    #expect(try abs(p.resolveSourceTime("cam@01:01:00;02", transcripts: [:]) - 1800.0 * 1001 / 30000) < 1e-9)
    #expect(throws: EditError.self) { try p.resolveSourceTime("cam@00:59:59;00", transcripts: [:]) }
    #expect(throws: EditError.self) { try p.resolveSourceTime("cam@01:00:00;45", transcripts: [:]) }
    #expect(throws: EditError.self) { try p.resolveSourceTime("nobody@01:00:00;00", transcripts: [:]) }
}

// MARK: Interchange round trips

private func cameraMedia() -> [MediaAsset] {
    // A 29.97 NDF XDCAM mezzanine of an MXF, a 25 fps file and a 29.97 DF ProRes.
    var a = MediaAsset(id: "xdcam", path: "/cache/mezzanine/xdcam-1234.mov", name: "Xdcam", duration: 120, width: 1920, height: 1080, fps: 30000.0 / 1001, hasVideo: true, hasAudio: true)
    a.originalPath = "/footage/XDCAM_0001.MXF"
    a.reel = "TAPE7"
    let ndf = TimecodeFormat(fps: a.fps, label: "10:00:00:00")
    a.setTimecode(frames: ndf.frames("10:00:00:00")!, format: ndf)
    var b = MediaAsset(id: "pal", path: "/footage/pal.mov", name: "Pal", duration: 120, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)
    b.setTimecode(frames: TimecodeFormat(fps: 25).frames("14:22:10:05")!, format: TimecodeFormat(fps: 25))
    b.reel = "A001"
    var c = MediaAsset(id: "prores", path: "/footage/A002C003.mov", name: "Prores", duration: 120, width: 1920, height: 1080, fps: 30000.0 / 1001, hasVideo: true, hasAudio: true)
    let df = TimecodeFormat(fps: c.fps, label: "01:00:00;00")
    c.setTimecode(frames: df.frames("01:00:00;00")!, format: df)
    return [a, b, c]
}

/// 29.97 drop frame. V1: xdcam, pal, prores cut together with an uneven dissolve between the first two.
private func timecodedProject() -> Project {
    var p = Project(name: "Conform", canvas: Canvas(fps: 30000.0 / 1001))
    p.media = cameraMedia()
    let g = 1001.0 / 30000
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "xdcam", start: 0, duration: 90 * g, sourceIn: 150 * g),
        // 40.04 s is a whole frame at both 29.97 and 25 fps.
        Clip(id: "c2", kind: .media, mediaId: "pal", start: 90 * g, duration: 60 * g, sourceIn: 1200 * g),
        Clip(id: "c3", kind: .media, mediaId: "prores", start: 150 * g, duration: 120 * g, sourceIn: 300 * g),
    ]
    var tr = Transition(id: "tr1", from: "c1", to: "c2", type: "dissolve", duration: 30 * g)
    tr.cutOffset = 10 * g
    p.transitions = [tr]
    return p
}

private func expectSameEdit(_ q: Project, _ p: Project, _ format: String, transitions: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
    let a = p.tracks[0].clips, b = q.tracks[0].clips
    #expect(b.count == a.count, "\(format) clips", sourceLocation: sourceLocation)
    for (x, y) in zip(a, b) {
        #expect(y.mediaId == x.mediaId, "\(format) \(x.id) media \(y.mediaId ?? "nil")", sourceLocation: sourceLocation)
        #expect(abs(y.sourceIn - x.sourceIn) < 1e-4, "\(format) \(x.id) source in \(y.sourceIn) vs \(x.sourceIn)", sourceLocation: sourceLocation)
        #expect(abs(y.start - x.start) < 1e-4 && abs(y.duration - x.duration) < 1e-4, "\(format) \(x.id) timing", sourceLocation: sourceLocation)
    }
    guard transitions else { return }
    #expect(q.transitions.count == 1, "\(format) transitions", sourceLocation: sourceLocation)
    if let t = q.transitions.first, let w = try? q.window(t), let v = try? p.window(p.transitions[0]) {
        #expect(abs(w.start - v.start) < 1e-4 && abs(w.end - v.end) < 1e-4 && abs(w.head - v.head) < 1e-4, "\(format) transition \(w.start)–\(w.end) head \(w.head)", sourceLocation: sourceLocation)
    }
}

@Test func edlSourceTimecodeIsInTheListsCountingAndRoundTrips() throws {
    var p = timecodedProject()
    p.transitions = []
    let edl = p.edl(title: "Conform")
    // In the drop-frame list: c1 (10:00:00:00 NDF + 150 frames) is the same frame relabeled drop frame; pal (25 fps,
    // 14:22:10:05 + 1001 frames) the same time of day at 29.97; each with its own timecode in a comment.
    #expect(edl.contains("001  TAPE7    AA/V  C        10:00:41;00 10:00:44;00 01:00:00;00 01:00:03;00"), "\(edl)")
    #expect(edl.contains("* SOURCE TC: 10:00:05:00 10:00:08:00 (29.97 fps NDF)"), "\(edl)")
    #expect(edl.contains("002  A001     AA/V  C        14:22:50;07 14:22:52;07 01:00:03;00 01:00:05;00"), "\(edl)")
    #expect(edl.contains("* SOURCE TC: 14:22:50:06 14:22:52:06 (25 fps)"), "\(edl)")
    #expect(edl.contains("003  A002C003 AA/V  C        01:00:10;00 01:00:14;00"), "\(edl)")
    #expect(edl.components(separatedBy: "SOURCE TC").count == 3, "the DF source matches the list")
    // A non-drop list never mixes in drop-frame or 25 fps source timecode.
    var n = p
    n.canvas.dropFrame = false
    let ndf = n.edl(title: "Conform")
    #expect(!ndf.split(separator: "\n").contains { $0.first?.isNumber == true && $0.contains(";") }, "\(ndf)")
    #expect(ndf.contains("* SOURCE TC: 01:00:10;00 01:00:14;00 (29.97 fps DF)") && ndf.contains("(25 fps)"), "\(ndf)")
    expectSameEdit(try Importer.edl(ndf, into: n).project, n, "NDF EDL", transitions: false)
    // Source and record durations agree on every event.
    for l in edl.split(separator: "\n") where l.first?.isNumber == true {
        let t = l.split(separator: " ").suffix(4).map(String.init)
        let f = TimecodeFormat(fps: 30000.0 / 1001)
        #expect(f.frames(t[1])! - f.frames(t[0])! == f.frames(t[3])! - f.frames(t[2])!, "\(l)")
    }
    #expect(edl.contains("* SOURCE FILE: /footage/XDCAM_0001.MXF"))
    #expect(edl.contains("* FROM CLIP NAME: Xdcam"))

    let back = try Importer.edl(edl, into: p).project
    #expect(back.media.count == 3, "\(back.media.map(\.id))")
    expectSameEdit(back, p, "EDL", transitions: false)

    // Without a reel, the reel is the file name cut to EDL rules.
    var q = p
    q.media[2].reel = nil
    #expect(q.edl(title: "Conform").contains("A002C003 AA/V  C"))
}

@Test func fcpxmlAssetsStartAtTheirTimecodeAndRoundTrip() throws {
    let p = timecodedProject()
    let xml = p.fcpxml()
    // 10:00:00:00 NDF is 1,080,000 frames of 1001/30000 s; FCP's asset start and clip start include it.
    #expect(xml.contains("name=\"Xdcam\" start=\"36036s\""), "\(xml)")
    #expect(xml.contains("name=\"Xdcam\" start=\"7208201/200s\""), "\(xml)")
    #expect(xml.contains("com.apple.proapps.studio.reel\" value=\"TAPE7\""))
    #expect(xml.contains("tcFormat=\"NDF\""))
    let r = try Importer.fcpxml(Data(xml.utf8), relativeTo: nil).project
    #expect(r.media.first { $0.name == "Xdcam" }?.timecodeString() == "10:00:00:00")
    #expect(r.media.first { $0.name == "Prores" }?.timecodeString() == "01:00:00;00")
    #expect(r.media.first { $0.name == "Pal" }?.timecodeString() == "14:22:10:05")
    #expect(r.media.first { $0.name == "Xdcam" }?.reel == "TAPE7")
    var adopted = p
    let counts = try adopted.adoptTimeline(r, name: "FCP")
    #expect(counts.matched == 3 && counts.added == 0)
    expectSameEdit(adopted, p, "FCPXML")
}

@Test func xmemlFilesCarryTheirTimecodeReelAndGradeAndRoundTrip() throws {
    var p = timecodedProject()
    let lut = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-tc-\(UUID().uuidString).cube")
    try "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n0.9 0.9 0.9\n".write(to: lut, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: lut) }
    p.tracks[0].clips[2].effects = [Effect(id: "show", type: "color.lut", params: ["file": .string(lut.path)])]
    let xml = p.xmeml()
    #expect(xml.contains("<string>10:00:00:00</string>") && xml.contains("<frame>1080000</frame>"), "\(xml)")
    #expect(xml.contains("<string>14:22:10:05</string>") && xml.contains("<timebase>25</timebase>"))
    #expect(xml.contains("<reel>") && xml.contains("<name>TAPE7</name>"))
    #expect(xml.contains("<cutPointTicks>"))
    #expect(xml.contains("; LUT \(lut.path)</mastercomment1>") || xml.contains(">LUT \(lut.path)</mastercomment1>"))
    let r = try Importer.xmeml(Data(xml.utf8), relativeTo: nil).project
    let x = try #require(r.media.first { $0.path == "/footage/XDCAM_0001.MXF" })
    #expect(abs((x.timecodeStart ?? 0) - 36036) < 1e-6 && x.timecodeLabel == "10:00:00:00" && x.reel == "TAPE7")
    var adopted = p
    let counts = try adopted.adoptTimeline(r, name: "XML")
    // The mezzanine matches by its camera original, not as a new "xdcam-2".
    #expect(counts.matched == 3 && counts.added == 0 && adopted.media.count == 3, "\(adopted.media.map(\.id))")
    expectSameEdit(adopted, p, "xmeml")
    // The LUT comes back as itself, not as the CDL fitted to it.
    #expect(adopted.tracks[0].clips[2].effects.map(\.type) == ["color.lut"] && adopted.tracks[0].clips[2].effects[0].enabled)
}

@Test func otioRangesAreInSourceTimecodeAndRoundTrip() throws {
    let p = timecodedProject()
    let root = try #require(try JSONSerialization.jsonObject(with: p.otio()) as? [String: Any])
    let v1 = try #require((((root["tracks"] as? [String: Any])?["children"] as? [[String: Any]])?.first)?["children"] as? [[String: Any]])
    let clip = v1[0]
    let ref = try #require((clip["media_references"] as? [String: Any])?["DEFAULT_MEDIA"] as? [String: Any])
    let avail = try #require((ref["available_range"] as? [String: Any])?["start_time"] as? [String: Any])
    #expect(avail["value"] as? Double == 1_080_000 && abs((avail["rate"] as? Double ?? 0) - 30000.0 / 1001) < 1e-9)
    let start = try #require((clip["source_range"] as? [String: Any])?["start_time"] as? [String: Any])
    #expect(start["value"] as? Double == 1_080_150)
    let r = try Importer.otio(p.otio(), relativeTo: nil).project
    #expect(r.media.first { $0.name == "Xdcam" }?.timecodeString() == "10:00:00:00")
    var adopted = p
    #expect(try adopted.adoptTimeline(r, name: "OTIO").matched == 3)
    expectSameEdit(adopted, p, "OTIO")
}

@Test func adoptingATimelineRebasesClipsOfMediaWhoseTimecodeDiffers() throws {
    var p = timecodedProject()
    var other = p
    // The other editor's copy of pal counts from 14:22:00:00, ten seconds earlier.
    other.media[1].setTimecode(frames: TimecodeFormat(fps: 25).frames("14:22:00:05")!, format: TimecodeFormat(fps: 25))
    other.tracks[0].clips[1].sourceIn += 10
    try p.adoptTimeline(other, name: "Other")
    #expect(abs(p.tracks[0].clips[1].sourceIn - 1200.0 * 1001 / 30000) < 1e-9)
}

@Test func premiereColorMattesAndBarsAreSolids() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <xmeml version="4"><sequence><name>S</name><rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate><media><video><track>
    <clipitem id="m1"><name>Red</name><duration>50</duration><rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate><start>0</start><end>50</end><in>0</in><out>50</out>
    <file id="f1"><name>Color Matte</name><duration>50</duration><media><video/></media></file>
    <filter><effect><name>Color Matte</name><effectid>colormatte</effectid><parameter><parameterid>color</parameterid><value><red>255</red><green>0</green><blue>0</blue></value></parameter></effect></filter></clipitem>
    <clipitem id="m2"><name>Bars</name><duration>50</duration><start>50</start><end>100</end><in>0</in><out>50</out>
    <file id="f2"><name>HD Bars and Tone</name><duration>50</duration><media><video/><audio/></media></file></clipitem>
    </track></video></media></sequence></xmeml>
    """
    let r = try Importer.xmeml(Data(xml.utf8), relativeTo: nil)
    #expect(r.project.tracks[0].clips.map(\.kind) == [.solid, .solid])
    #expect(r.project.tracks[0].clips[0].color == RGBA(r: 1, g: 0, b: 0))
    #expect(r.missingMedia.isEmpty && r.project.media.isEmpty)
}
