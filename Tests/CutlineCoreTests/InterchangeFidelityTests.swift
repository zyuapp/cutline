import Foundation
import Testing
@testable import CutlineCore

// MARK: Fixture

/// Dialogue with J and L cuts on V1, music on A1 and room tone from `recipe room_tone` on A2: crossfaded pieces whose
/// sound overlaps its neighbours' and runs past the program's last frame.
func roomToneProject(fps: Double = 25, crossfade: Seconds = 0.24) throws -> Project {
    var p = Project(name: "Room tone", canvas: Canvas(fps: fps))
    let grid = FrameGrid(fps: fps)
    func t(_ frames: Int) -> Seconds { Double(frames * grid.num) / Double(grid.den) }
    let n = Int(grid.rate.rounded())
    p.media = [
        MediaAsset(id: "d1", path: "/tmp/fidelity/d1.mov", name: "d1", duration: 120, width: 1920, height: 1080, fps: fps, hasVideo: true, hasAudio: true),
        MediaAsset(id: "d2", path: "/tmp/fidelity/d2.mov", name: "d2", duration: 120, width: 1920, height: 1080, fps: fps, hasVideo: true, hasAudio: true),
        MediaAsset(id: "rt", path: "/tmp/fidelity/rt.wav", name: "rt", duration: 30, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
        MediaAsset(id: "m", path: "/tmp/fidelity/m.wav", name: "m", duration: 200, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    let total = 25 * n + 2 * n / 25
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "d1", start: 0, duration: t(6 * n), sourceIn: t(10 * n)),
        Clip(id: "c2", kind: .media, mediaId: "d2", start: t(6 * n), duration: t(7 * n), sourceIn: t(20 * n)),
        Clip(id: "c3", kind: .media, mediaId: "d1", start: t(13 * n), duration: t(6 * n), sourceIn: t(40 * n)),
        Clip(id: "c4", kind: .media, mediaId: "d2", start: t(19 * n), duration: t(total - 19 * n), sourceIn: t(60 * n)),
    ]
    try p.splitEdit(left: "c1", right: "c2", offset: t(10))
    try p.splitEdit(left: "c2", right: "c3", offset: -t(8))
    p.tracks[1].clips = [Clip(id: "m1", kind: .media, mediaId: "m", start: 0, duration: t(total), sourceIn: t(5 * n))]
    p.tracks[1].clips[0].audioFadeOut = 2
    let rt = p.addTrack(kind: .audio, name: "Room tone")
    try p.fillRoomTone(TimeRange(t(2 * n), t(total)), mediaId: "rt", source: TimeRange(1, 6), trackId: rt.id, crossfade: crossfade)
    // Interchange counts source time in frames.
    let a2 = p.tracks.count - 1
    for i in p.tracks[a2].clips.indices { p.tracks[a2].clips[i].sourceIn = p.canvas.snap(p.tracks[a2].clips[i].sourceIn) }
    try p.validate()
    return p
}

private func describe(_ p: Project) -> String {
    p.tracks.map { t in "\(t.id) \(t.kind): " + t.clips.map { c in String(format: "%@ %.3f+%.3f lead %.3f lag %.3f fades %.3f/%.3f", c.id, c.start, c.duration, c.audioLead, c.audioLag, c.audioFadeIn, c.audioFadeOut) }.joined(separator: ", ") }.joined(separator: "\n")
}

@Test(arguments: ["xml", "fcpxml", "otio", "edl"]) func roomToneRoundTripKeepsDurationAndTracks(format: String) throws {
    let p = try roomToneProject()
    let r: ImportResult
    switch format {
    case "xml": r = try Importer.xmeml(Data(p.xmeml().utf8), relativeTo: nil)
    case "fcpxml": r = try Importer.fcpxml(Data(p.fcpxml().utf8), relativeTo: nil)
    case "otio": r = try Importer.otio(p.otio(), relativeTo: nil)
    default: r = try Importer.edl(p.edl(title: p.name), into: p)
    }
    let q = r.project
    #expect(abs(q.duration - p.duration) < 1e-6, "\(format) duration \(q.duration), not \(p.duration)")
    #expect(q.tracks.filter { !$0.clips.isEmpty }.count == p.tracks.filter { !$0.clips.isEmpty }.count, "\(format):\n\(describe(q))\nwas\n\(describe(p))")
    #expect(r.warnings.isEmpty, "\(format) \(r.warnings)")
    expectExact(p, q, format)
}

private func read(_ format: InterchangeFormat, _ data: Data, into p: Project) throws -> ImportResult {
    switch format {
    case .xml: try Importer.xmeml(data, relativeTo: nil)
    case .fcpxml: try Importer.fcpxml(data, relativeTo: nil)
    case .otio: try Importer.otio(data, relativeTo: nil)
    case .edl: try Importer.edl(String(decoding: data, as: UTF8.self), into: p)
    case .aaf: try Importer.aaf(data, relativeTo: nil)
    }
}

/// Room tone as the recipe makes it, crossfades off the frame grid: the program length and track layout survive.
@Test(arguments: InterchangeFormat.allCases, [25.0, 30000.0 / 1001]) func roomToneOffTheFrameGridKeepsDurationAndTracks(format: InterchangeFormat, fps: Double) throws {
    let p = try roomToneProject(fps: fps, crossfade: 0.25)
    let made = try p.interchange(format)
    let r = try read(format, made.data, into: p)
    let q = r.project
    let grid = FrameGrid(fps: fps)
    #expect(grid.frames(q.duration) == grid.frames(p.duration), "\(format) \(fps) duration \(q.duration), not \(p.duration)")
    #expect(q.tracks.filter { !$0.clips.isEmpty }.map(\.clips.count) == p.tracks.filter { !$0.clips.isEmpty }.map(\.clips.count), "\(format) \(fps):\n\(describe(q))")
    #expect(r.warnings.isEmpty, "\(format) \(r.warnings)")
    // EDLs have no audio fades; Cutline reads the room tone's back from its comments.
    // FCP7 XML and AAF have no audio roles; room tone's subrole is the only thing they note, and AAF its short handles.
    #expect(made.notes.allSatisfy { (format == .edl && $0.hasSuffix("fades not carried")) || ([.xml, .aaf].contains(format) && $0.hasSuffix("audio role dialogue.room tone not carried"))
            || (format == .aaf && $0.hasPrefix("Handles: ")) }, "\(format) \(made.notes)")
    // Each room-tone piece's sound runs within a frame of where it did.
    let rt = p.tracks.last!.clips, back = q.tracks.last!.clips
    for (a, b) in zip(rt, back) {
        #expect(abs(grid.frames(a.audioRange.start) - grid.frames(b.audioRange.start)) <= 1 && abs(grid.frames(a.audioRange.end) - grid.frames(b.audioRange.end)) <= 1, "\(format) \(a.id)")
    }
}

/// The room tone's crossfades stay on one track as crossfades in each file: xmeml and OTIO transitions, EDL dissolves.
@Test func roomToneCrossfadesAreWrittenAsCrossfades() throws {
    let p = try roomToneProject()
    let pieces = p.tracks.last!.clips.count
    let xml = try XMLDocument(xmlString: p.xmeml(), options: [])
    let tracks = try xml.nodes(forXPath: "/xmeml/sequence/media/audio/track").compactMap { $0 as? XMLElement }
    let roomTone = tracks.first { t in t.elements(forName: "clipitem").contains { ($0.elements(forName: "name").first?.stringValue ?? "") == "Room tone" } }!
    #expect(roomTone.elements(forName: "clipitem").count == pieces)
    #expect(roomTone.elements(forName: "transitionitem").filter { ($0.elements(forName: "alignment").first?.stringValue ?? "") == "center" }.count == pieces - 1)
    // No two clipitems on the track overlap, and nothing plays past the program.
    let end = FrameGrid(fps: 25).frames(p.duration)
    var last = -1
    for item in roomTone.elements(forName: "clipitem") {
        let s = Int(item.elements(forName: "start").first!.stringValue!)!, e = Int(item.elements(forName: "end").first!.stringValue!)!
        #expect(s == -1 || s >= last)
        if e >= 0 { last = e; #expect(e <= end) }
    }
    let edl = p.edl(title: "Room tone")
    expectNoOverlaps(edl)
    #expect(edl.components(separatedBy: "\n").filter { $0.contains(" D    006 ") }.count == pieces - 1)
}

// MARK: Graphics

/// V1 footage; V2 a styled title, a solid, a title card, a lower third, a shape and particles; a nested sequence on V1.
func graphicsProject() throws -> Project {
    var p = Project(name: "Graphics", canvas: Canvas(fps: 25))
    p.media = [MediaAsset(id: "a", path: "/tmp/fidelity/a.mov", name: "a", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)]
    var title = TextSpec(text: "Chapter One", font: "serif", size: 0.08, color: RGBA(r: 1, g: 0.8, b: 0.2), x: 0.3, y: 0.7)
    title.align = .left
    func generator(_ id: String, _ type: String, start: Seconds, params: [String: ParamValue] = [:]) -> Clip {
        Clip(id: id, kind: .generator, start: start, duration: 2, effects: [Effect(id: "gen", type: type, params: params)])
    }
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 10),
        Clip(id: "c2", kind: .media, mediaId: "a", start: 4, duration: 4, sourceIn: 20),
        Clip(id: "c3", kind: .media, mediaId: "a", start: 8, duration: 4, sourceIn: 30),
    ]
    let v2 = p.addTrack(kind: .video, name: "Graphics")
    let i = p.trackIndex(v2.id)!
    p.tracks[i].clips = [
        Clip(id: "t1", kind: .text, start: 0, duration: 2, text: title),
        Clip(id: "s1", kind: .solid, name: "Wash", start: 2, duration: 1, color: RGBA(r: 0.1, g: 0.2, b: 0.6)),
        generator("g1", "title.card", start: 3, params: ["title": .string("The Engine"), "kicker": .string("PART TWO")]),
        generator("g2", "title.lower_third_modern", start: 5, params: ["title": .string("Ada Lovelace"), "subtitle": .string("Mathematician")]),
        generator("g3", "shape.arrow", start: 7),
        generator("g4", "particles", start: 9),
    ]
    _ = try p.nest(["c2", "c3"], name: "Middle")
    try p.validate()
    return p
}

@Test(arguments: [InterchangeFormat.fcpxml, .xml, .otio]) func graphicsComeBackAsTheirClips(format: InterchangeFormat) throws {
    let p = try graphicsProject()
    let made = try p.interchange(format)
    let q = try read(format, made.data, into: p).project
    let mine = p.tracks.flatMap(\.clips).filter { $0.kind != .media }, theirs = q.tracks.flatMap(\.clips).filter { $0.kind != .media }
    #expect(theirs.map(\.kind) == mine.map(\.kind), "\(format) \(theirs.map(\.kind))")
    for (a, b) in zip(mine, theirs) {
        #expect(b.text == a.text && b.color?.hex == a.color?.hex && b.effects == a.effects, "\(format) \(a.id)")
        #expect(abs(b.start - a.start) < 1e-6 && abs(b.duration - a.duration) < 1e-6, "\(format) \(a.id) at \(b.start)")
    }
    #expect(q.sequences.count == 1 && q.sequences[0].tracks.flatMap(\.clips).count == 2, "\(format) sequences")
    #expect(q.media.count == p.media.count, "\(format) media \(q.media.map(\.id))")
}

@Test func graphicsReportWhatEachFormatMakesOfThem() throws {
    let p = try graphicsProject()
    let fcp = try p.interchange(.fcpxml), xml = try p.interchange(.xml), edl = try p.interchange(.edl), otio = try p.interchange(.otio)
    func has(_ notes: [String], _ parts: String...) -> Bool { notes.contains { n in parts.allSatisfy(n.contains) } }
    #expect(has(fcp.notes, "g1", "title.card", "Basic Title", "The Engine"), "\(fcp.notes)")
    #expect(has(xml.notes, "g1", "title.card", "Text generator"), "\(xml.notes)")
    #expect(has(fcp.notes, "g4", "particles", "offline placeholder"))
    #expect(has(xml.notes, "g3", "shape.arrow", "offline placeholder"))
    #expect(has(edl.notes, "Track V2", "not in the EDL"), "\(edl.notes)")
    #expect(has(otio.notes, "g4", "particles", "Cutline metadata"))
    // Titles and solids are what the formats have.
    let doc = String(decoding: fcp.data, as: UTF8.self)
    #expect(doc.contains("Chapter One") && doc.contains("The Engine") && doc.contains("Ada Lovelace — Mathematician"))
    #expect(doc.contains("Solids.localized/Custom") && doc.contains("name=\"Position\""))
    let x = String(decoding: xml.data, as: UTF8.self)
    #expect(x.contains("<parameterid>str</parameterid>") && x.contains("<value>The Engine") == false && x.contains("PART TWO — The Engine"))
    #expect(x.contains("<effectid>Color</effectid>"))
}

/// Without Cutline's metadata, as another app writes them, titles still come back with their text, font, size and place.
@Test(arguments: [InterchangeFormat.fcpxml, .xml]) func titlesReadBackFromTheFormatAlone(format: InterchangeFormat) throws {
    let p = try graphicsProject()
    var doc = String(decoding: try p.interchange(format).data, as: UTF8.self)
    for pattern in [#"(?s)<metadata>.*?</metadata>"#, #"<mastercomment3>.*?</mastercomment3>"#] {
        doc = doc.replacingOccurrences(of: pattern, with: "", options: [.regularExpression])
    }
    #expect(!doc.contains("Cutline clip"))
    let q = try read(format, Data(doc.utf8), into: p).project
    let t = try #require(q.tracks.flatMap(\.clips).first { $0.text?.text == "Chapter One" }?.text)
    #expect(abs(t.size - 0.08) < 0.002 && abs(t.x - 0.3) < 0.002 && abs(t.y - 0.7) < 0.002, "\(format) \(t.size) \(t.x) \(t.y)")
    #expect(abs(t.color.g - 0.8) < 0.01)
    let solid = try #require(q.tracks.flatMap(\.clips).first { $0.kind == .solid })
    #expect(abs((solid.color?.b ?? 0) - 0.6) < 0.01)
    #expect(q.tracks.flatMap(\.clips).contains { $0.text?.text.contains("Ada Lovelace") == true }, "\(q.tracks.flatMap(\.clips).map { "\($0.id) \($0.kind) \($0.text?.text ?? "")" })")
}

/// Baked graphics are media in the file and the generator again in Cutline.
@Test(arguments: [InterchangeFormat.fcpxml, .xml, .otio, .edl]) func bakedGraphicsAreMediaThatReadBackAsGenerators(format: InterchangeFormat) throws {
    let p = try graphicsProject()
    let files = Dictionary(uniqueKeysWithValues: p.generatorClips.map { ($0.clip.id, "/tmp/fidelity/Graphics_graphics/\($0.clip.id).mov") })
    let made = try p.interchange(format, options: InterchangeOptions(graphics: files))
    let text = String(decoding: made.data, as: UTF8.self)
    // An EDL carries the main video track only.
    #expect(text.contains("g4.mov") != (format == .edl), "\(format)")
    #expect(made.notes.contains { $0.contains("g4") && $0.contains("rendered to g4.mov") } != (format == .edl))
    let q = try read(format, made.data, into: p).project
    if format == .edl {
        #expect(q.tracks.flatMap(\.clips).allSatisfy { $0.kind == .media })
    } else {
        #expect(q.tracks.flatMap(\.clips).filter { $0.kind == .generator }.map(\.id).count == 4, "\(format)")
        #expect(!q.media.contains { $0.path.hasSuffix(".mov") && $0.path.contains("_graphics") })
    }
}

// MARK: Grades

@Test func gradesBeyondACDLAreReportedAndBakedLUTsReadBack() throws {
    var p = try graphicsProject()
    p.tracks[0].clips[0].effects = [
        Effect(id: "w", type: "color.wheels", params: ["lift_b": .number(0.03)]),
        Effect(id: "h", type: "color.hsl", params: ["range": .string("blues"), "saturation": .number(0.5)]),
    ]
    let notes = p.interchangeLosses(.xml)
    #expect(notes.contains { $0.contains("c1") && $0.contains("color.hsl") && $0.contains("not representable; CDL approximation") }, "\(notes)")
    // A baked LUT holds the whole stack.
    let c = p.tracks[0].clips[0]
    let cube = try #require(p.bakedLUT(c))
    let lut = try ColorMath.parseCube(cube)
    #expect(lut.size == 33)
    let f = try #require(p.colorStackTransform(c))
    let probe = SIMD3<Float>(0.5, 0.25, 0.75)
    let o = ((24 * 33 + 8) * 33 + 16) * 4, want = f(probe)
    #expect(abs(lut.rgba[o] - want.x) < 1e-4 && abs(lut.rgba[o + 2] - want.z) < 1e-4)
    let path = "/tmp/fidelity/Graphics_luts/c1.cube"
    for format in InterchangeFormat.allCases where format != .otio {
        let made = try p.interchange(format, options: InterchangeOptions(luts: ["c1": path]))
        #expect(String(decoding: made.data, as: UTF8.self).contains("GRADE LUT") || format == .aaf, "\(format)")
        let back = try read(format, made.data, into: p).project
        let first = try #require(back.tracks.first { $0.kind == .video }?.clips.first)
        #expect(first.effects.filter { $0.type.hasPrefix("color.") }.map(\.type) == ["color.lut"] && first.effects.first?.params["file"]?.string == path, "\(format) \(first.effects.map(\.type))")
    }
}

@Test func aCDLGradeBakesToItsOwnCube() throws {
    let cdl = CDL(slope: SIMD3(1.1, 1, 0.9), offset: SIMD3(0.02, 0, -0.01), power: SIMD3(1, 1.1, 1), saturation: 0.9)
    let c = Clip(id: "x", kind: .media, start: 0, duration: 1, effects: [cdl.effect(id: "cdl")])
    let p = Project(name: "x")
    let lut = try ColorMath.parseCube(try #require(p.bakedLUT(c)))
    for (r, g, b) in [(0, 0, 0), (16, 8, 30), (32, 32, 32)] {
        let o = ((b * 33 + g) * 33 + r) * 4
        let want = cdl.apply(SIMD3(Double(r) / 32, Double(g) / 32, Double(b) / 32))
        #expect(abs(Double(lut.rgba[o]) - want.x) < 1e-4 && abs(Double(lut.rgba[o + 1]) - want.y) < 1e-4)
    }
}

// MARK: Nesting

/// A nested sequence round trips with its clips' frames, through each format that nests.
@Test(arguments: [InterchangeFormat.fcpxml, .xml, .otio]) func nestedSequencesRoundTripExactly(format: InterchangeFormat) throws {
    var p = try roomToneProject()
    _ = try p.nest(["c2", "c3"], name: "Middle")
    try p.validate()
    let r = try read(format, try p.interchange(format).data, into: p)
    let q = r.project
    #expect(abs(q.duration - p.duration) < 1e-6)
    let seq = try #require(q.sequences.first)
    let mine = p.sequences[0].tracks.filter { !$0.clips.isEmpty }, theirs = seq.tracks.filter { !$0.clips.isEmpty }
    #expect(mine.map(\.clips.count) == theirs.map(\.clips.count), "\(format) \(theirs.map(\.clips.count))")
    for (a, b) in zip(mine.flatMap(\.clips), theirs.flatMap(\.clips)) {
        #expect(abs(a.start - b.start) < 1e-6 && abs(a.duration - b.duration) < 1e-6 && abs(a.sourceIn - b.sourceIn) < 1e-6, "\(format) \(a.id)")
    }
    let host = try #require(q.tracks[0].clips.first { $0.kind == .sequence })
    let orig = p.tracks[0].clips.first { $0.kind == .sequence }!
    #expect(abs(host.start - orig.start) < 1e-6 && abs(host.duration - orig.duration) < 1e-6)
}
