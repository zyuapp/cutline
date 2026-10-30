import Foundation
import Testing
@testable import CutlineCore

private func f25(_ t: Seconds) -> Int { Int((t * 25).rounded()) }

private func video(_ id: String, _ path: String, audio: Bool = true) -> MediaAsset {
    MediaAsset(id: id, path: path, name: id, duration: 120, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: audio)
}

// MARK: Nested sequences

/// 25 fps. V1: c1 (a) then c2 (b); V2: a title and a person-masked overlay over c2; A1: dialogue under c2.
/// c2, the title, the overlay and the dialogue are nested into "Scene".
private func nestedProject() throws -> (Project, Clip) {
    var p = Project(name: "Nest", canvas: Canvas(fps: 25))
    p.media = [video("a", "/tmp/cutline conform/a.mov"), video("b", "/tmp/cutline conform/b.mov"),
               MediaAsset(id: "dlg", path: "/tmp/cutline conform/dlg.wav", name: "dlg", duration: 60, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 2),
                         Clip(id: "c2", kind: .media, mediaId: "b", start: 4, duration: 4, sourceIn: 10)]
    p.tracks[1].clips = [Clip(id: "d1", kind: .media, mediaId: "dlg", start: 4.4, duration: 3, sourceIn: 1, volume: 0.5)]
    let v2 = p.addTrack(kind: .video, name: "Overlay")
    let ti = try #require(p.trackIndex(v2.id))
    p.tracks[ti].clips = [Clip(id: "t1", kind: .text, start: 4.4, duration: 1, text: TextSpec(text: "Scene one")),
                          Clip(id: "o1", kind: .media, mediaId: "a", start: 6, duration: 1.6, sourceIn: 30, effects: [Effect(id: "cut", type: "mask.person")])]
    let seq = try p.nest(["c2", "t1", "o1", "d1"], name: "Scene")
    try p.validate()
    return (p, seq)
}

/// What a sequence clip plays, flattened, as "kind media start+duration@source" in frames.
private func played(_ p: Project) -> [String] {
    p.flattenedSequences().tracks.flatMap { t in
        t.clips.map { c in "\(t.kind.rawValue) \(c.kind.rawValue) \(c.mediaId ?? c.text?.text ?? "") \(f25(c.start))+\(f25(c.duration))@\(f25(c.sourceIn))" }
    }.sorted()
}

@Test func fcpxmlWritesSequencesAsCompoundClips() throws {
    let (p, seq) = try nestedProject()
    let xml = p.fcpxml()
    let doc = try XMLDocument(xmlString: xml, options: [])
    let media = try #require(try doc.nodes(forXPath: "/fcpxml/resources/media").first as? XMLElement)
    #expect(media.attribute(forName: "name")?.stringValue == "Scene")
    #expect(try media.nodes(forXPath: "sequence/spine/asset-clip").count == 1)
    #expect(try media.nodes(forXPath: "sequence/spine/asset-clip/title").count == 1)
    #expect(try media.nodes(forXPath: "sequence/spine/asset-clip/asset-clip[@lane='-1']").count == 1)
    let ref = try #require(try doc.nodes(forXPath: "//project/sequence/spine/ref-clip").first as? XMLElement)
    #expect(ref.attribute(forName: "ref")?.stringValue == media.attribute(forName: "id")?.stringValue)
    #expect(ref.attribute(forName: "offset")?.stringValue == "3604s" && ref.attribute(forName: "duration")?.stringValue == "4s")
    #expect(!xml.contains("<gap name=\"Scene\""))

    let r = try Importer.fcpxml(Data(xml.utf8), relativeTo: nil)
    let q = r.project
    let clip = try #require(q.tracks[0].clips.first { $0.kind == .sequence })
    #expect(f25(clip.start) == f25(seq.start) && f25(clip.duration) == f25(seq.duration))
    #expect(q.sequences.count == 1 && q.sequences[0].name == "Scene")
    #expect(played(q) == played(p))
    try q.validate()
}

@Test func otioWritesSequencesAsNestedStacks() throws {
    let (p, seq) = try nestedProject()
    let root = try #require(try JSONSerialization.jsonObject(with: p.otio()) as? [String: Any])
    let tracks = try #require((root["tracks"] as? [String: Any])?["children"] as? [[String: Any]])
    let stack = try #require((tracks[0]["children"] as? [[String: Any]])?.first { $0["OTIO_SCHEMA"] as? String == "Stack.1" })
    #expect(stack["name"] as? String == "Scene")
    let inner = try #require(stack["children"] as? [[String: Any]])
    #expect(inner.map { $0["kind"] as? String } == ["Video", "Video", "Audio", "Audio", "Audio"])

    let r = try Importer.otio(p.otio(), relativeTo: nil)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    let q = r.project
    let clip = try #require(q.clip(seq.id))
    #expect(clip.kind == .sequence && clip.mediaId == seq.mediaId && f25(clip.start) == f25(seq.start))
    #expect(q.sequences.map(\.id) == p.sequences.map(\.id) && q.sequences[0].name == "Scene")
    #expect(Set(q.sequences[0].tracks.flatMap(\.clips).map(\.id)) == ["c2", "t1", "o1", "d1"])
    #expect(q.sequences[0].tracks.flatMap(\.clips).first { $0.id == "o1" }?.effects.map(\.type) == ["mask.person"])
    #expect(played(q) == played(p))
    try q.validate()
}

@Test func edlListsWhatSequencesPlay() throws {
    let (p, _) = try nestedProject()
    let edl = p.edl(title: "Nest")
    // c2's picture with its sound, then the dialogue on channel 3.
    #expect(edl.contains("B        AA/V  C        00:00:10:00 00:00:14:00 01:00:04:00 01:00:08:00"))
    #expect(edl.contains("DLG      NONE  C        00:00:01:00 00:00:04:00 01:00:04:10 01:00:07:10\nAUD  3"))
    let q = try Importer.edl(edl, into: p).project
    let v = q.tracks[0].clips.map { "\($0.mediaId ?? "") \(f25($0.start))+\(f25($0.duration))@\(f25($0.sourceIn))" }
    #expect(v == ["a 0+100@50", "b 100+100@250"])
    let dialogue = try #require(q.tracks.first { $0.kind == .audio }?.clips.first)
    #expect(dialogue.mediaId == "dlg" && f25(dialogue.start) == 110 && f25(dialogue.duration) == 75)
    #expect(q.media.map(\.id) == p.media.map(\.id))
}

// MARK: Color

private func cubeFile(_ f: ColorMath.Transform, size: Int = 33) throws -> URL {
    let data = ColorMath.cubeData(size: size, f)
    var text = "TITLE \"test\"\nLUT_3D_SIZE \(size)\n"
    for i in stride(from: 0, to: data.count, by: 4) { text += String(format: "%.6f %.6f %.6f\n", data[i], data[i + 1], data[i + 2]) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-conform-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("match.cube")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func wheelsHaveAnExactCDL() throws {
    let params: [String: ParamValue] = ["lift": .number(0.03), "lift_b": .number(0.02), "gain": .number(0.1), "gain_r": .number(0.05),
                                        "gamma": .number(0.2), "gamma_g": .number(-0.1), "offset": .number(-0.01), "saturation": .number(-0.2)]
    let e = Effect(id: "w", type: "color.wheels", params: params)
    let clip = Clip(id: "c", kind: .media, start: 0, duration: 1, effects: [e])
    let cdl = try #require(clip.cdl)
    let wheels = ColorMath.wheels(ColorMath.Wheels { params[$0]?.number ?? (($0 == "pivot") ? 0.5 : 0) })
    for c in [SIMD3<Double>(0.1, 0.2, 0.3), SIMD3(0.5, 0.5, 0.5), SIMD3(0.7, 0.4, 0.2), SIMD3(0.85, 0.8, 0.75)] {
        let w = wheels(SIMD3(Float(c.x), Float(c.y), Float(c.z)))
        let d = cdl.apply(c) - SIMD3(Double(w.x), Double(w.y), Double(w.z))
        #expect(max(abs(d.x), abs(d.y), abs(d.z)) < 1e-5, "\(c)")
    }
    #expect(abs(cdl.slope.x - 0.97 * 1.15) < 1e-6 && abs(cdl.power.y - pow(2, -0.1)) < 1e-6 && abs(cdl.saturation - 0.8) < 1e-6)
    // Contrast at neutral gamma folds into slope and offset; white balance is fitted.
    let contrast = Clip(id: "k", kind: .media, start: 0, duration: 1, effects: [Effect(id: "w", type: "color.wheels", params: ["contrast": .number(0.2), "pivot": .number(0.4)])])
    #expect(try #require(contrast.cdl).distance(to: CDL(slope: SIMD3(repeating: 1.2), offset: SIMD3(repeating: -0.08))) < 1e-6)
    let warm = Clip(id: "t", kind: .media, start: 0, duration: 1, effects: [Effect(id: "w", type: "color.wheels", params: ["temperature": .number(40)])])
    let fitted = try #require(warm.cdl)
    #expect(fitted.slope.x > fitted.slope.z)
}

@Test func lutsAreSampledThroughTheirCubeAndNamedInEveryFormat() throws {
    let known = CDL(slope: SIMD3(1.1, 0.95, 0.9), offset: SIMD3(0.02, -0.01, 0.03), power: SIMD3(0.9, 1.1, 1.2), saturation: 0.8)
    let url = try cubeFile(known.transform)
    let lut = Effect(id: "match", type: "color.lut", params: ["file": .string(url.path)])
    #expect(try #require(Clip(id: "l", kind: .media, start: 0, duration: 1, effects: [lut]).cdl).distance(to: known) < 0.01)
    let missing = Effect(id: "m", type: "color.lut", params: ["file": .string("/nowhere/missing.cube")])
    #expect(Clip(id: "m", kind: .media, start: 0, duration: 1, effects: [missing]).cdl == nil)

    var p = Project(name: "LUT", canvas: Canvas(fps: 25))
    p.media = [video("a", "/tmp/cutline conform/a.mov")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, effects: [lut])]
    let sent = try #require(p.tracks[0].clips[0].cdl)

    func expectCarried(_ q: Project, _ format: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let c = q.tracks[0].clips[0]
        #expect(c.cdl.map { $0.distance(to: sent) < 1e-4 } == true, "\(format) CDL", sourceLocation: sourceLocation)
        #expect(c.effects.contains { $0.type == "color.lut" && $0.params["file"]?.string == url.path }, "\(format) LUT", sourceLocation: sourceLocation)
    }
    let xml = p.fcpxml()
    #expect(xml.contains("ASC_SAT \(sent.sat); LUT \(url.path)</note>"))
    let viaFCP = try Importer.fcpxml(Data(xml.utf8), relativeTo: nil).project
    expectCarried(viaFCP, "FCPXML")
    // The CDL already carries the LUT's look, so the LUT comes back switched off.
    #expect(viaFCP.tracks[0].clips[0].effects.first { $0.type == "color.lut" }?.enabled == false)

    let edl = p.edl(title: "LUT")
    #expect(edl.contains("*ASC_SAT \(sent.sat)\n*LUT: \(url.path)\n"))
    expectCarried(try Importer.edl(edl, fps: 25) { $0 == "a" ? "a" : nil }.project, "EDL")

    let root = try #require(try JSONSerialization.jsonObject(with: p.otio()) as? [String: Any])
    let item = try #require(((root["tracks"] as? [String: Any])?["children"] as? [[String: Any]])?.first?["children"] as? [[String: Any]])[0]
    #expect((item["metadata"] as? [String: Any]).flatMap { $0["lut"] as? [String: Any] }?["file"] as? String == url.path)
    #expect(try Importer.otio(p.otio(), relativeTo: nil).project.tracks[0].clips[0].effects == [lut])
}

// MARK: Timecode and sample rate

@Test func everyExporterStartsAtTheProjectTimecode() throws {
    var p = Project(name: "TC", canvas: Canvas(fps: 25))
    p.media = [video("a", "/tmp/cutline conform/a.mov")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 2)]
    for (start, frames) in [(nil as String?, 90_000), ("10:00:00:00", 900_000), ("00:00:00:00", 0)] {
        p.canvas.timecodeStart = start
        let label = p.canvas.startTimecode
        let xml = p.fcpxml()
        #expect(xml.contains("tcStart=\"\(frames / 25)s\""), "\(label)")
        #expect(xml.contains("offset=\"\(frames / 25)s\" name=\"a\""), "\(label)")
        let xmeml = p.xmeml()
        #expect(xmeml.contains("<string>\(label)</string>") && xmeml.contains("<frame>\(frames)</frame>"), "\(label)")
        let root = try #require(try JSONSerialization.jsonObject(with: p.otio()) as? [String: Any])
        #expect((root["global_start_time"] as? [String: Any])?["value"] as? Double == Double(frames), "\(label)")
        let edl = p.edl(title: "TC")
        #expect(edl.contains("00:00:02:00 00:00:06:00 \(label) "), "\(label)")

        #expect(try Importer.fcpxml(Data(xml.utf8), relativeTo: nil).project.canvas.timecodeStart == start, "\(label) FCPXML")
        #expect(try Importer.xmeml(Data(xmeml.utf8), relativeTo: nil).project.canvas.timecodeStart == start, "\(label) xmeml")
        #expect(try Importer.otio(p.otio(), relativeTo: nil).project.canvas.timecodeStart == start, "\(label) OTIO")
        let viaEDL = try Importer.edl(edl, fps: 25) { $0 == "a" ? "a" : nil }.project
        #expect(viaEDL.canvas.timecodeStart == start && viaEDL.tracks[0].clips[0].start == 0, "\(label) EDL")
    }
    // Drop frame at 29.97: one hour is 107,892 frames.
    var ntsc = Project(name: "NTSC", canvas: Canvas(fps: 29.97))
    ntsc.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 1)]
    #expect(ntsc.fcpxml().contains("tcStart=\"8999991/2500s\""))
    #expect(try Importer.fcpxml(Data(ntsc.fcpxml().utf8), relativeTo: nil).project.canvas.timecodeStart == nil)
}

@Test func assetsDeclareTheirOwnSampleRate() throws {
    var p = Project(name: "Rates", canvas: Canvas(fps: 25))
    var a = video("a", "/tmp/cutline conform/a.mov")
    a.sampleRate = 44_100
    p.media = [a, video("b", "/tmp/cutline conform/b.mov")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 2), Clip(id: "c2", kind: .media, mediaId: "b", start: 2, duration: 2)]
    let doc = try XMLDocument(xmlString: p.fcpxml(), options: [])
    let rates = try doc.nodes(forXPath: "/fcpxml/resources/asset").compactMap { ($0 as? XMLElement)?.attribute(forName: "audioRate")?.stringValue }
    #expect(rates == ["44100", "48000"])
    #expect(try Importer.fcpxml(Data(p.fcpxml().utf8), relativeTo: nil).project.media.map(\.sampleRate) == [44_100, 48_000])
    #expect(p.xmeml().contains("<samplerate>44100</samplerate>"))
    #expect(try Importer.xmeml(Data(p.xmeml().utf8), relativeTo: nil).project.media.first { $0.id == "a" }?.sampleRate == 44_100)
}

// MARK: EDL round trip

/// Clip by clip: same media, timeline and source range, split-edit lead and lag, and whether it is heard.
private func expectSameClips(_ p: Project, _ q: Project, sourceLocation: SourceLocation = #_sourceLocation) {
    func rows(_ p: Project) -> [String] {
        p.tracks.flatMap { t in
            t.clips.filter { $0.kind == .media }.map { c in
                let heard = c.volume > 1e-6 && !(t.kind == .audio && t.muted)
                return "\(t.kind.rawValue) \(c.mediaId ?? "") \(f25(c.start))+\(f25(c.duration))@\(f25(c.sourceIn)) lead \(f25(c.audioLead)) lag \(f25(c.audioLag)) \(heard ? "heard" : "silent")"
            }
        }.sorted()
    }
    #expect(rows(q) == rows(p), sourceLocation: sourceLocation)
    #expect(q.media.map(\.id) == p.media.map(\.id), "media \(q.media.map(\.id))", sourceLocation: sourceLocation)
}

/// Two cameras cut together on V1 with a J cut and a picture-only shot; camR's microphone on its own under that shot.
private func multicam() throws -> Project {
    var p = Project(name: "Multicam", canvas: Canvas(fps: 25))
    p.media = [video("camL", "/tmp/cutline conform/camL.mov"), video("camR", "/tmp/cutline conform/camR.mov")]
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "camL", start: 0, duration: 4, sourceIn: 10),
        Clip(id: "c2", kind: .media, mediaId: "camR", start: 4, duration: 4, sourceIn: 14),
        Clip(id: "c3", kind: .media, mediaId: "camL", start: 8, duration: 4, sourceIn: 18, volume: 0),
        Clip(id: "c4", kind: .media, mediaId: "camR", start: 12, duration: 4, sourceIn: 22),
    ]
    try p.splitEdit(left: "c1", right: "c2", offset: 0.48)
    p.addTrack(kind: .audio, name: "Boom")
    p.tracks[2].clips = [Clip(id: "d1", kind: .media, mediaId: "camR", start: 8, duration: 4, sourceIn: 18)]
    try p.validate()
    return p
}

@Test func edlRoundTripKeepsAMulticamCut() throws {
    let p = try multicam()
    let edl = p.edl(title: "Multicam")
    #expect(edl.contains("NONE  C        00:00:18:00 00:00:22:00 01:00:08:00 01:00:12:00\nAUD  4"))
    let r = try Importer.edl(edl, into: p)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(r.missingMedia.isEmpty || r.missingMedia.allSatisfy { $0.hasPrefix("/tmp/cutline conform/") })
    expectSameClips(p, r.project)
    try r.project.validate()

    // Picture-only cameras with each microphone on its own track, as A and A2: nothing folds into the picture.
    var q = p
    for i in q.tracks[0].clips.indices {
        q.tracks[0].clips[i].volume = 0
        q.tracks[0].clips[i].audioLead = 0
        q.tracks[0].clips[i].audioLag = 0
    }
    q.tracks[1].clips = [Clip(id: "l", kind: .media, mediaId: "camL", start: 0, duration: 16, sourceIn: 10)]
    q.tracks[2].clips = [Clip(id: "r", kind: .media, mediaId: "camR", start: 0, duration: 16, sourceIn: 10)]
    let e2 = q.edl(title: "Mics")
    #expect(e2.contains(" A     C        00:00:10:00 00:00:26:00 01:00:00:00 01:00:16:00") && e2.contains(" A2    C "))
    let r2 = try Importer.edl(e2, into: q)
    expectSameClips(q, r2.project)
}

@Test func edlImportReusesProjectMediaByPathReelAndName() throws {
    let p = try multicam()
    var renamed = p
    renamed.media[0].path = "/elsewhere/camL.mov"
    renamed.media[1].reel = "CAMR"
    renamed.media[1].path = "/elsewhere/B001.mov"
    // camR by its reel, camL by the reel its name gives.
    let q = try Importer.edl(p.edl(title: "M"), into: renamed).project
    #expect(q.media == renamed.media)
    #expect(Set(q.tracks.flatMap(\.clips).compactMap(\.mediaId)) == ["camL", "camR"])
}
