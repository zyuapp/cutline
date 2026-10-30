import Foundation
import Testing
@testable import CutlineCore

// MARK: Fixture

/// 29.97 fps. V1 (fader 0.8): c1 (a 0–4 from 2 s, ducking ramp, transform, crop, grade) J-cut into c2 (b 4–8 from 10 s,
/// −6 dB with fades, sound 0.5 s early), gap, c3 (a 9–11 from 20 s, sound 1 s past its end). A1: music with a fader ramp.
/// Master −2 dB.
private func richProject() -> Project {
    var p = Project(name: "Mix", canvas: Canvas(fps: 29.97))
    p.media = [
        MediaAsset(id: "a", path: "/tmp/a.mov", name: "a", duration: 60, width: 1920, height: 1080, fps: 29.97, hasVideo: true, hasAudio: true),
        MediaAsset(id: "b", path: "/tmp/b.mov", name: "b", duration: 60, width: 1920, height: 1080, fps: 29.97, hasVideo: true, hasAudio: true),
        MediaAsset(id: "music", path: "/tmp/music.m4a", name: "music", duration: 60, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    let f = 1001.0 / 30000
    var c1 = Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 120 * f, sourceIn: 60 * f)
    c1.anim["audio.volume"] = Curve(keys: [CurveKey(t: 0, v: .number(1), ease: .linear), CurveKey(t: 60 * f, v: .number(0.25), ease: .linear), CurveKey(t: 120 * f, v: .number(1), ease: .linear)])
    c1.transform = Transform(scale: 1.2, x: 0.1, y: -0.05, rotation: 10, crop: Crop(left: 0.1, top: 0.05))
    c1.effects = [
        Effect(id: "wheels", type: "color.grade", params: ["lift": .number(0.02), "gamma": .number(1.1), "gain": .number(1.05)]),
        Effect(id: "grade", type: "color.adjust", params: ["saturation": .number(-0.2)]),
    ]
    var c2 = Clip(id: "c2", kind: .media, mediaId: "b", start: 120 * f, duration: 120 * f, sourceIn: 300 * f, volume: 0.5, audioFadeIn: 15 * f, audioFadeOut: 30 * f)
    c2.effects = [Effect(id: "grade", type: "color.adjust", params: ["exposure": .number(0.5), "temperature": .number(30)])]
    let c3 = Clip(id: "c3", kind: .media, mediaId: "a", start: 270 * f, duration: 60 * f, sourceIn: 600 * f)
    p.tracks[0].clips = [c1, c2, c3]
    try! p.splitEdit(left: "c1", right: "c2", offset: 15 * f)
    p.tracks[0].clips[2].audioLag = 30 * f
    p.tracks[0].volume = 0.8
    p.tracks[1].clips = [Clip(id: "m1", kind: .media, mediaId: "music", start: 0, duration: 300 * f, volume: 0.7)]
    p.tracks[1].volumeCurve = Curve(keys: [CurveKey(t: 0, v: .number(1), ease: .linear), CurveKey(t: 150 * f, v: .number(0.5), ease: .linear)])
    p.master.gainDb = -2
    try! p.validate()
    return p
}

private let fps = 30000.0 / 1001

private func frames(_ t: Seconds) -> Int { Int((t * fps).rounded()) }

private func db(_ g: Double) -> Double { 20 * log10(max(g, 1e-6)) }

/// The heard level of `b` matches `a`'s within 0.1 dB over its sound, sampled every few frames.
private func expectSameLevels(_ p: Project, _ a: Clip, _ q: Project, _ b: Clip, sourceLocation: SourceLocation = #_sourceLocation) {
    let ta = p.tracks.first { $0.clips.contains { $0.id == a.id } }!, tb = q.tracks.first { $0.clips.contains { $0.id == b.id } }!
    let a0 = -a.audioLead, a1 = a.duration + a.audioLag
    for t in stride(from: a0 + 1 / fps, to: a1 - 1 / fps, by: 4 / fps) {
        let ga = p.heardGain(a, track: ta, at: t), gb = q.heardGain(b, track: tb, at: t + a.start - b.start)
        #expect(abs(db(ga) - db(gb)) < 0.1, "\(a.id) at \(t): \(db(ga)) dB became \(db(gb)) dB", sourceLocation: sourceLocation)
    }
}

/// Picture, split edit, fades, levels, transform and CDL of each V1 clip survive.
private func expectSameV1(_ p: Project, _ q: Project, levels: Bool = true, transforms: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
    let v = p.tracks[0].clips, w = try! #require(q.tracks.first { $0.kind == .video }).clips
    #expect(w.count == v.count, sourceLocation: sourceLocation)
    for (a, b) in zip(v, w) {
        #expect(frames(b.start) == frames(a.start) && frames(b.duration) == frames(a.duration) && frames(b.sourceIn) == frames(a.sourceIn), "\(a.id) timing", sourceLocation: sourceLocation)
        #expect(frames(b.audioLead) == frames(a.audioLead) && frames(b.audioLag) == frames(a.audioLag), "\(a.id) split \(b.audioLead) \(b.audioLag)", sourceLocation: sourceLocation)
        if let ca = a.cdl {
            let cb = try! #require(b.cdl, "\(a.id) lost its CDL", sourceLocation: sourceLocation)
            #expect(ca.distance(to: cb) < 1e-4, "\(a.id) CDL \(ca.text) became \(cb.text)", sourceLocation: sourceLocation)
        }
        if levels {
            #expect(frames(b.audioFadeIn) == frames(a.audioFadeIn) && frames(b.audioFadeOut) == frames(a.audioFadeOut), "\(a.id) fades", sourceLocation: sourceLocation)
            expectSameLevels(p, a, q, b, sourceLocation: sourceLocation)
        }
        if transforms {
            let s = a.transform, t = b.transform
            #expect(abs(s.scale - t.scale) < 1e-3 && abs(s.x - t.x) < 1e-3 && abs(s.y - t.y) < 1e-3 && abs(s.rotation - t.rotation) < 1e-3, "\(a.id) transform \(t)", sourceLocation: sourceLocation)
            #expect(abs(s.crop.left - t.crop.left) < 1e-3 && abs(s.crop.top - t.crop.top) < 1e-3 && t.crop.right == 0 && t.crop.bottom == 0, "\(a.id) crop", sourceLocation: sourceLocation)
        }
    }
}

// MARK: CDL

@Test func cdlFromGradeIsExactAndFitRecoversACDL() throws {
    let grade = Clip(id: "g", kind: .media, start: 0, duration: 1, effects: [Effect(id: "w", type: "color.grade", params: ["lift": .number(0.1), "gamma": .number(2), "gain": .number(1.2)])])
    let cdl = try #require(grade.cdl)
    #expect(cdl.distance(to: CDL(slope: SIMD3(repeating: 1.1), offset: SIMD3(repeating: 0.1), power: SIMD3(repeating: 0.5))) < 1e-9)

    let known = CDL(slope: SIMD3(1.1, 0.95, 0.9), offset: SIMD3(0.02, -0.01, 0.03), power: SIMD3(0.9, 1.1, 1.2), saturation: 0.8)
    #expect(CDL.fit(known.transform).distance(to: known) < 2e-3)
    // A color.cdl effect is the CDL it holds; a look is fitted.
    let roundTrip = Clip(id: "c", kind: .media, start: 0, duration: 1, effects: [known.effect(id: "cdl")])
    #expect(try #require(roundTrip.cdl).distance(to: known) < 1e-9)
    let look = Clip(id: "l", kind: .media, start: 0, duration: 1, effects: [Effect(id: "look", type: "color.look", params: ["look": .string("cool_night")])])
    let fitted = try #require(look.cdl)
    let grey = fitted.apply(SIMD3(repeating: 0.4))
    #expect(grey.z > grey.x && fitted.saturation < 1)

    let adjust = Clip(id: "a", kind: .media, start: 0, duration: 1, effects: [Effect(id: "g", type: "color.adjust", params: ["exposure": .number(1), "saturation": .number(-0.5), "gamma": .number(1.2)])])
    let a = try #require(adjust.cdl)
    #expect(a.slope == SIMD3(repeating: 2) && a.power == SIMD3(repeating: 1.2) && a.saturation == 0.5)
    // No color, disabled or windowed color: no CDL.
    #expect(Clip(id: "n", kind: .media, start: 0, duration: 1).cdl == nil)
    #expect(Clip(id: "d", kind: .media, start: 0, duration: 1, effects: [Effect(id: "g", type: "color.adjust", enabled: false, params: ["exposure": .number(1)])]).cdl == nil)
    #expect(Clip(id: "w", kind: .media, start: 0, duration: 1, effects: [Effect(id: "g", type: "color.adjust", params: ["exposure": .number(1), "limit": .string("ellipse")])]).cdl == nil)
}

@Test func cdlTextRoundTrips() throws {
    let c = CDL(slope: SIMD3(1.1, 1, 0.9), offset: SIMD3(0, -0.012, 0.05), power: SIMD3(1, 1.2, 0.95), saturation: 0.85)
    #expect(c.sop == "(1.1 1.0 0.9)(0.0 -0.012 0.05)(1.0 1.2 0.95)")
    #expect(c.text == "ASC_SOP (1.1 1.0 0.9)(0.0 -0.012 0.05)(1.0 1.2 0.95) ASC_SAT 0.85")
    #expect(CDL(text: "Graded. " + c.text) == c)
    #expect(CDL(sop: c.sop, sat: "0.85") == c)
    #expect(CDL(sop: "(1 1)(0 0 0)") == nil)
    #expect(EffectCatalog.type("color.cdl") != nil)
}

// MARK: Timecode

@Test func everyExporterAgreesOnDropFrame() throws {
    var p = richProject()
    #expect(p.canvas.isDropFrame)
    #expect(p.edl(title: "Mix").contains("FCM: DROP FRAME"))
    #expect(p.fcpxml().contains("tcFormat=\"DF\""))
    #expect(p.xmeml().contains("<ntsc>TRUE</ntsc>") && p.xmeml().contains("<displayformat>DF</displayformat>") && p.xmeml().contains("<string>00:00:00;00</string>"))
    #expect(try Importer.fcpxml(Data(p.fcpxml().utf8), relativeTo: nil).project.canvas.isDropFrame)

    p.canvas.dropFrame = false
    #expect(!p.canvas.isDropFrame)
    #expect(p.edl(title: "Mix").contains("FCM: NON-DROP FRAME"))
    #expect(p.fcpxml().contains("tcFormat=\"NDF\""))
    #expect(p.xmeml().contains("<displayformat>NDF</displayformat>") && !p.xmeml().contains("<displayformat>DF</displayformat>"))
    // Importers keep the choice.
    #expect(try Importer.fcpxml(Data(p.fcpxml().utf8), relativeTo: nil).project.canvas.dropFrame == false)
    #expect(try Importer.xmeml(Data(p.xmeml().utf8), relativeTo: nil).project.canvas.dropFrame == false)
    #expect(try Importer.edl(p.edl(title: "Mix"), fps: 29.97) { $0 }.project.canvas.dropFrame == false)
    #expect(try Importer.otio(p.otio(), relativeTo: nil).project.canvas.dropFrame == false)

    // Only NTSC 29.97 and 59.94 can count drop frame.
    for rate in [23.976, 24, 25, 30] { #expect(!Canvas(fps: rate).isDropFrame) }
    #expect(Canvas(fps: 59.94).isDropFrame)
    var ndf = Canvas(fps: 25)
    ndf.dropFrame = true
    #expect(!ndf.isDropFrame)
}

// MARK: Round trips

@Test func fcpxmlCarriesSplitEditsLevelsTransformsAndCDL() throws {
    let p = richProject()
    let xml = p.fcpxml()
    let doc = try XMLDocument(xmlString: xml, options: [])
    let clips = try doc.nodes(forXPath: "//spine/asset-clip").compactMap { $0 as? XMLElement }
    #expect(clips.count == 3)
    // c2's sound starts 15 frames before its picture: expanded audio, like Final Cut writes for split edits.
    #expect(clips[1].attribute(forName: "audioStart")?.stringValue == "19019/2000s" && clips[1].attribute(forName: "start")?.stringValue == "1001/100s")
    #expect(clips[1].attribute(forName: "audioDuration")?.stringValue == "9009/2000s")
    #expect(try clips[0].nodes(forXPath: "adjust-volume/param[@name='amount']/keyframeAnimation/keyframe").count >= 3)
    #expect(try clips[1].nodes(forXPath: "adjust-volume/param/fadeIn").count == 1)
    let transform = try #require(try clips[0].nodes(forXPath: "adjust-transform").first as? XMLElement)
    #expect(transform.attribute(forName: "scale")?.stringValue == "1.2 1.2" && transform.attribute(forName: "rotation")?.stringValue == "-10.0")
    #expect(transform.attribute(forName: "position")?.stringValue == "17.7778 5.0")
    #expect(try clips[0].nodes(forXPath: "note").first?.stringValue?.hasPrefix("ASC_SOP (") == true)

    let r = try Importer.fcpxml(Data(xml.utf8), relativeTo: nil)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    let q = r.project
    expectSameV1(p, q)
    let music = try #require(q.tracks.first { $0.kind == .audio }?.clips.first)
    expectSameLevels(p, p.tracks[1].clips[0], q, music)
    try q.validate()
}

@Test func xmemlCarriesLinkedSplitSoundLevelsMotionAndCDL() throws {
    let p = richProject()
    let xml = p.xmeml()
    #expect(xml.contains("<linkclipref>clipitem-c2-audio</linkclipref>"))
    #expect(xml.contains("<effectid>basic</effectid>") && xml.contains("<effectid>crop</effectid>"))
    #expect(xml.contains("<effectid>KGAudioTransCrossFade0dB</effectid>"))
    #expect(xml.contains("<mastercomment1>ASC_SOP ("))
    let doc = try XMLDocument(xmlString: xml, options: [])
    let sound = try #require(try doc.nodes(forXPath: "//clipitem[@id='clipitem-c2-audio']").first as? XMLElement)
    func n(_ e: XMLElement, _ k: String) -> String? { e.elements(forName: k).first?.stringValue }
    // The J cut: c2's sound starts 15 frames before its picture (frame 120), from 15 frames earlier in the source.
    #expect(n(sound, "start") == "105" && n(sound, "end") == "240" && n(sound, "in") == "285")
    #expect(try doc.nodes(forXPath: "//clipitem[@id='clipitem-c1-audio']//keyframe").count >= 3)

    let r = try Importer.xmeml(Data(xml.utf8), relativeTo: nil)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    let q = r.project
    #expect(q.tracks.map(\.kind) == [.video, .audio])
    expectSameV1(p, q)
    expectSameLevels(p, p.tracks[1].clips[0], q, q.tracks[1].clips[0])
    try q.validate()
}

@Test func otioCarriesOffsetSoundAudioLevelsAndCDL() throws {
    let p = richProject()
    let root = try #require(try JSONSerialization.jsonObject(with: p.otio()) as? [String: Any])
    let tracks = try #require((root["tracks"] as? [String: Any])?["children"] as? [[String: Any]])
    #expect(tracks.map { $0["kind"] as? String } == ["Video", "Audio", "Audio"])
    // The embedded sound of V1 spans each clip's audio range: c1 ends 15 frames early, c2 starts 15 early.
    let sound = (tracks[1]["children"] as? [[String: Any]] ?? []).filter { $0["OTIO_SCHEMA"] as? String == "Clip.2" }
    func range(_ item: [String: Any], _ k: String) -> Double? { ((item["source_range"] as? [String: Any])?[k] as? [String: Any])?["value"] as? Double }
    #expect(sound.map { range($0, "duration") } == [105, 135, 90])
    #expect(sound.map { range($0, "start_time") } == [60, 285, 600])
    let level = try #require((sound[1]["effects"] as? [[String: Any]])?.first { $0["effect_name"] as? String == "AudioLevel" })
    let gainDb = try #require(((level["metadata"] as? [String: Any])?["cutline"] as? [String: Any])?["gain_db"] as? Double)
    #expect(abs(gainDb - (db(0.5 * 0.8) - 2)) < 0.01)
    let picture = try #require((tracks[0]["children"] as? [[String: Any]])?.first)
    let cdl = try #require((picture["metadata"] as? [String: Any])?["cdl"] as? [String: Any])
    #expect((cdl["asc_sop"] as? [String: Any])?["slope"] is [Double] && cdl["asc_sat"] is Double)

    let r = try Importer.otio(p.otio(), relativeTo: nil)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    let q = r.project
    expectSameV1(p, q)
    #expect(q.tracks[0].volume == 0.8 && q.master.gainDb == -2 && q.tracks[1].volumeCurve == p.tracks[1].volumeCurve)
    #expect(q.tracks[0].clips[0].effects == p.tracks[0].clips[0].effects)
    expectSameLevels(p, p.tracks[1].clips[0], q, q.tracks[1].clips[0])
    try q.validate()

    // A reader without Cutline's metadata gets the level and CDL from AudioLevel and cdl.
    var foreign = root
    func strip(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            if var md = d["metadata"] as? [String: Any], d["OTIO_SCHEMA"] as? String != "Effect.1" { md["cutline"] = nil; d["metadata"] = md }
            for (k, x) in d { d[k] = strip(x) }
            return d
        }
        if let a = v as? [Any] { return a.map(strip) }
        return v
    }
    foreign = strip(foreign) as! [String: Any]
    let f = try Importer.otio(try JSONSerialization.data(withJSONObject: foreign), relativeTo: nil).project
    let music = try #require(f.tracks.last?.clips.first)
    expectSameLevels(p, p.tracks[1].clips[0], f, music)
    #expect(try #require(f.tracks[0].clips[0].cdl).distance(to: try #require(p.tracks[0].clips[0].cdl)) < 1e-4)
}

@Test func edlSendsProductionSoundSplitEditsAndCDL() throws {
    let p = richProject()
    let edl = p.edl(title: "Mix")
    #expect(edl.hasPrefix("TITLE: Mix\nFCM: DROP FRAME\n\n"))
    // c1 and c2 have split sound: picture-only V events, then AA events over the audio ranges.
    #expect(edl.contains("001  A        V     C        00:00:02;00 00:00:06;00 01:00:00;00 01:00:04;00"))
    #expect(edl.contains("AA    C        00:00:09;15 00:00:14;00 01:00:03;15 01:00:08;00"))
    #expect(edl.contains("*ASC_SOP (") && edl.contains("*ASC_SAT "))
    #expect(edl.contains("NONE  C        00:00:00;00 00:00:10;00 01:00:00;00 01:00:10;00\nAUD  3\n"))

    let r = try Importer.edl(edl, fps: 29.97) { ["a": "a", "b": "b", "music": "music"][$0] }
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    let q = r.project
    #expect(q.tracks.map(\.kind) == [.video, .audio] && q.tracks[1].clips.map(\.mediaId) == ["music"])
    expectSameV1(p, q, levels: false, transforms: false)
    #expect(q.tracks[0].clips.allSatisfy { $0.volume == 1 })

    // Sound in sync with its picture rides on the same event; a muted clip is picture only, and stays silent.
    var plain = p
    for i in plain.tracks[0].clips.indices { plain.tracks[0].clips[i].audioLead = 0; plain.tracks[0].clips[i].audioLag = 0 }
    plain.tracks[0].clips[2].volume = 0
    let e2 = plain.edl(title: "Plain")
    #expect(e2.components(separatedBy: "AA/V").count == 3 && !e2.contains(" AA    C"))
    let q2 = try Importer.edl(e2, fps: 29.97) { ["a": "a", "b": "b", "music": "music"][$0] }.project
    #expect(q2.tracks[0].clips.map(\.volume) == [1, 1, 0])
}

/// Real exports re-exported by Cutline import back with the same picture timing.
@Test func realSamplesSurviveReExport() throws {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }
    func timing(_ p: Project) -> [[String]] {
        p.tracks.filter { $0.kind == .video }.map { $0.clips.filter { $0.kind == .media }.map { "\(Int(($0.start * p.canvas.fps).rounded()))+\(Int(($0.duration * p.canvas.fps).rounded()))" } }.filter { !$0.isEmpty }
    }
    for name in ["premiere_example.xml", "sample_just_track.xml", "fcpx_example.fcpxml", "fcpx_project.fcpxml", "premiere_example.otio", "multitrack.otio", "simple_cut.otio"] {
        let source: Project
        switch (name as NSString).pathExtension {
        case "xml": source = try Importer.xmeml(try fixture(name), relativeTo: nil).project
        case "fcpxml": source = try Importer.fcpxml(try fixture(name), relativeTo: nil).project
        default: source = try Importer.otio(try fixture(name), relativeTo: nil).project
        }
        let viaXML = try Importer.xmeml(Data(source.xmeml().utf8), relativeTo: nil).project
        let viaOTIO = try Importer.otio(try source.otio(), relativeTo: nil).project
        #expect(timing(viaXML) == timing(source), "\(name) via xmeml")
        #expect(timing(viaOTIO) == timing(source), "\(name) via OTIO")
        func volumes(_ p: Project) -> [Double] { p.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { $0.kind == .media }.map(\.volume) }
        #expect(volumes(viaOTIO) == volumes(source), "\(name) volumes via OTIO")
        #expect(volumes(viaXML) == volumes(source), "\(name) volumes via xmeml")
        let viaFCP = try Importer.fcpxml(Data(source.fcpxml().utf8), relativeTo: nil).project
        #expect(timing(viaFCP).first == timing(source).first, "\(name) via FCPXML")
        let edl = source.edl(title: name)
        if edl.contains("001  ") {
            let viaEDL = try Importer.edl(edl, fps: source.canvas.fps) { _ in nil }.project
            #expect(timing(viaEDL).first == timing(source.flattenedSequences()).first, "\(name) via EDL")
        }
    }
}
