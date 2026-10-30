import Foundation
import Testing
@testable import CutlineCore

// Exports from Final Cut Pro, Premiere Pro, Avid, Resolve, Hiero and Nucoda, from the OpenTimelineIO adapters.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func edl(_ name: String, fps: Double = 24) throws -> ImportResult {
    try Importer.edl(String(decoding: try fixture(name), as: UTF8.self), fps: fps) { _ in nil }
}

private func otio(_ name: String) throws -> ImportResult { try Importer.otio(try fixture(name), relativeTo: nil) }
private func fcpxml(_ name: String) throws -> ImportResult { try Importer.fcpxml(try fixture(name), relativeTo: nil) }
private func xmeml(_ name: String) throws -> ImportResult { try Importer.xmeml(try fixture(name), relativeTo: nil) }

private func frames(_ t: Seconds, _ fps: Double) -> Int { Int((t * fps).rounded()) }

/// "start+duration@sourceIn" of each clip, in frames.
private func timing(_ t: Track, fps: Double = 24) -> [String] {
    t.clips.map { "\(frames($0.start, fps))+\(frames($0.duration, fps))@\(frames($0.sourceIn, fps))" }
}

private func markerFrames(_ p: Project, fps: Double = 24) -> [Int] { p.markers.map { frames($0.time, fps) } }

/// Every clip fits its media and every transition its clips, in the project and its nested sequences.
private func expectValid(_ p: Project) throws {
    try p.validate()
    for t in p.transitions { try p.checkTransition(t) }
    for s in p.sequences {
        let inner = p.inside(s)
        try inner.validate()
        for t in inner.transitions { try inner.checkTransition(t) }
    }
}

// MARK: EDL

@Test func avidNucodaAndPremiereEDLsStartAtTheirFirstEventBeforeTheHour() throws {
    for (name, ids, paths) in [
        ("avid_example.edl", ["zz100-501-take-1-0001", "zz100-502a-take-2-0101"], [#"S:\path\to\ZZ100_501.take_1.0001.exr"#, #"S:\path\to\ZZ100_502A.take_2.0101.exr"#]),
        ("nucoda_example.edl", ["zz100-501-take-1-0001", "zz100-502a-take-2-0101"], [#"S:\path\to\ZZ100_501.take_1.0001.exr"#, #"S:\path\to\ZZ100_502A.take_2.0101.exr"#]),
        ("premiere_example.edl", ["zz100-501-take-1-0001", "zz100-502a-take-2-0101"], ["ZZ100_501.take_1.0001.exr", "ZZ100_502A.take_2.0101.exr"]),
    ] {
        let r = try edl(name)
        let p = r.project
        #expect(r.warnings.isEmpty, "\(name): \(r.warnings)")
        // Record 00:59:53:11 is pre-roll before the hour: the first event lands at zero, not an hour late.
        #expect(timing(p.tracks[0]) == ["0+31@101", "31+50@157"], "\(name)")
        #expect(p.media.map(\.id) == ids && p.media.map(\.path) == paths, "\(name)")
        #expect(p.media.allSatisfy { $0.timecodeStart == 3600 }, "\(name)")
        #expect(r.missingMedia == paths, "\(name)")
        try expectValid(p)
    }
}

@Test func screeningEDLsWithAndWithoutSpacesMatch() throws {
    let a = try edl("screening_example.edl"), b = try edl("no_spaces_test.edl")
    for r in [a, b] {
        let p = r.project
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(p.name == "Example_Screening.01")
        #expect(p.tracks.map(\.id) == ["V1"] && p.tracks[0].clips.count == 9)
        #expect(p.tracks[0].clips.first?.start == 0)
        // 00:59:53:11 to 01:00:37:04.
        #expect(frames(p.duration, 24) == 1049)
        #expect(timing(p.tracks[0]).first == "0+31@101" && timing(p.tracks[0]).last == "792+257@101")
        #expect(p.tracks[0].clips.map(\.name).first == "ZZ100_501 (LAY3)")
        #expect(p.media.first?.path == "ZZ100_501.LAY3.01" && p.media.count == 9 && r.missingMedia.count == 9)
        #expect(markerFrames(p) == [195, 219, 530])
        #expect(p.markers.map(\.label) == ["ANIM FIX NEEDED", "ANIM FIX NEEDED", "Marker"])
        try expectValid(p)
    }
    #expect(timing(a.project.tracks[0]) == timing(b.project.tracks[0]))
}

@Test func edlRecordingFromZeroWithSourceAtTheHour() throws {
    let r = try edl("25fps.edl", fps: 25)
    let p = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(p.canvas.fps == 25)
    #expect(timing(p.tracks[0], fps: 25) == ["0+161@0", "161+200@0", "361+86@0", "447+49@0"])
    #expect(p.tracks[0].clips.map(\.name) == ["sq001_s001", "sq001_s002", "sq001_s003", "sq001_s004"])
    #expect(p.media.allSatisfy { $0.timecodeStart == 3600 && $0.path.hasPrefix("sq001_s00") })
    try expectValid(p)
}

@Test func edlTimecodeMismatchKeepsRecordDurations() throws {
    let r = try edl("timecode_mismatch.edl", fps: 25)
    let p = r.project
    let clips = p.tracks[0].clips
    #expect(clips.count == 20)
    #expect(p.media.count == 19)
    #expect(clips.filter { $0.mediaId == "sq001-s0020" }.count == 2)
    #expect(clips.allSatisfy { $0.speed == 1 })
    // Event 004 reads 49 source frames over 47 record frames; event 005 starts 2 frames after it.
    #expect(timing(p.tracks[0], fps: 25)[3] == "447+47@0" && timing(p.tracks[0], fps: 25)[4] == "496+56@0")
    #expect(frames(clips.last!.end, 25) == 1789)
    #expect(r.warnings == ["Events 004, 005, 009, 010: source and record durations differ without an M2 speed; record durations kept at normal speed"])
    try expectValid(p)
}

@Test func edlSpeedEffectsAndFreezeFrames() throws {
    let r = try edl("speed_effects_small.edl")
    let p = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    let c = p.tracks[0].clips
    #expect(timing(p.tracks[0]) == ["0+126@45", "12240+17@261", "12257+1@260", "12258+18@260", "16600+36@144"])
    #expect(c[1].isRetimed && c[1].sourceOut == c[1].sourceIn && c[1].volume == 0)
    #expect(c[2].isRetimed && !c[3].isRetimed)
    // "Z682_157 (LAY2) FF" and "Z682_157 (LAY2)" are one source; "(47.56 FPS)" doesn't name a new one.
    #expect(p.media.map(\.id) == ["z677-4c-anim10", "z682-156-lay3", "z682-157-lay2", "z686-5a-lay2"])
    #expect(c[2].mediaId == c[3].mediaId)
    #expect(abs(c[4].speed - 47.6 / 24) < 1e-9 && c[4].name == "Z686_5A (LAY2) (47.56 FPS)")
    try expectValid(p)
}

@Test func edlDissolvesAndWipes() throws {
    let one = try edl("dissolve_test.edl").project
    #expect(timing(one.tracks[0]) == ["0+9@101", "9+10@200", "19+1@210"])
    #expect(one.transitions.map { "\($0.from ?? "-")>\($0.to ?? "-") \($0.type) \(frames($0.duration, 24)) \($0.align)" } == ["c1>c2 dissolve 10 start"])
    #expect(one.media.map(\.id) == ["clip-a", "clip-b"])
    try expectValid(one)

    let two = try edl("dissolve_test_2.edl").project
    #expect(timing(two.tracks[0]) == ["0+5@101", "5+10@196", "15+5@206"])
    #expect(two.transitions.count == 1 && frames(two.transitions[0].duration, 24) == 10)
    try expectValid(two)

    // The outgoing side names Clip_B, but the clip before the edit is Clip_A.
    let three = try edl("dissolve_test_3.edl").project
    #expect(timing(three.tracks[0]) == ["0+61@95", "61+30@814", "91+46@0"])
    #expect(three.media.map(\.id) == ["clip-a", "clip-c", "clip-d"])
    #expect(three.transitions.map { frames($0.duration, 24) } == [30] && three.transitions[0].from == "c1" && three.transitions[0].to == "c2")
    try expectValid(three)

    // Events jump from 005 to 060; records start at 01:04:11:17, kept after the hour.
    let four = try edl("dissolve_test_4.edl").project
    #expect(four.tracks[0].clips.count == 6)
    #expect(frames(four.tracks[0].clips[0].start, 24) == 6041)
    #expect(timing(four.tracks[0]).last == "6383+135@294")
    #expect(four.transitions.map { frames($0.duration, 24) } == [35, 64])
    #expect(four.transitions.map(\.from) == ["c2", "c3"] && four.transitions.allSatisfy { $0.align == .start })
    try expectValid(four)

    let duration = try edl("transition_duration.edl").project
    #expect(duration.tracks[0].clips.count == 4 && frames(duration.tracks[0].clips[0].start, 24) == 1172)
    #expect(duration.transitions.map { "\($0.from!)>\($0.to!) \(frames($0.duration, 24))" } == ["c2>c3 26"])
    try expectValid(duration)

    let wipe = try edl("wipe_test.edl")
    #expect(wipe.project.transitions.map(\.type) == ["wipe"])
    #expect(wipe.warnings == ["Event 002: wipe W001 imported as a left-to-right wipe"])
    try expectValid(wipe.project)
}

@Test func edlGapsBareCommentsAndAudioOnly() throws {
    let gap = try edl("gap_test.edl").project
    #expect(timing(gap.tracks[0]) == ["0+24@14400", "40+24@0", "102+24@0"])
    #expect(gap.tracks[0].clips.map(\.name) == ["shot1", "shot2", "shot3"])
    #expect(gap.media.map(\.timecodeStart) == [nil, 82800, 36000])
    try expectValid(gap)

    let audio = try edl("multi_audio.edl").project
    #expect(audio.tracks.map(\.id) == ["V1", "A1"] && audio.tracks[0].clips.isEmpty)
    #expect(timing(audio.tracks[1]) == ["0+81982@0"])
    #expect(audio.media.map { "\($0.id) v\($0.hasVideo) a\($0.hasAudio)" } == ["ax vfalse atrue"])
    try expectValid(audio)
}

// MARK: OpenTimelineIO

@Test func otioCutsAndUnevenTransitions() throws {
    let cut = try otio("simple_cut.otio")
    #expect(cut.warnings.isEmpty, "\(cut.warnings)")
    #expect(timing(cut.project.tracks[0]) == ["0+3@3", "3+6@2", "9+4@0", "13+6@0"])
    // Clip-004 has no source range: it plays its whole available range, from frame 100.
    #expect(cut.project.media[3].timecodeStart.map { frames($0, 24) } == 100 && frames(cut.project.media[3].duration, 24) == 6)
    #expect(cut.missingMedia == ["/folder/titles.mov", "/folder/wind-up.mov", "/folder/punchline.mov", "/folder/credits.mov"])
    try expectValid(cut.project)

    // 2 frames before the cut and 3 after: kept as they are, the cut 2 frames in, offline media growing to fit.
    let tr = try otio("transition.otio")
    let t = try #require(tr.project.transitions.first)
    #expect(tr.project.transitions.count == 1 && t.from == "c2" && t.to == "c3")
    #expect(t.align == .center && frames(t.duration, 24) == 5 && t.cutOffset.map { frames($0, 24) } == 2)
    #expect(tr.warnings.isEmpty, "\(tr.warnings)")
    let w = try tr.project.window(t)
    #expect(frames(w.head, 24) == 2 && frames(w.tail, 24) == 3)
    #expect(timing(tr.project.tracks[0]) == ["0+3@3", "3+6@2", "9+4@2", "13+6@0"])
    try expectValid(tr.project)

    let clip = try otio("clip_example.otio")
    #expect(timing(clip.project.tracks[0]) == ["8+3@3"])
    #expect(clip.project.media.map(\.path) == ["Clip-001"] && clip.missingMedia == ["Clip-001"])
    #expect(clip.project.transitions.map { "\($0.from ?? "-")>\($0.to ?? "-") \(frames($0.duration, 24))" } == ["c1>- 3"])
    try expectValid(clip.project)
}

@Test func otioMissingReferencesStayOffline() throws {
    let r = try otio("multitrack.otio")
    let p = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(p.tracks.map(\.name) == ["Sequence", "Sequence 2", "Sequence 3"])
    #expect(timing(p.tracks[0]) == ["0+720@0", "803+722@0", "1957+720@0"])
    #expect(timing(p.tracks[1]) == ["482+480@0"] && timing(p.tracks[2]) == ["1198+640@0"])
    #expect(r.missingMedia == ["tech.fux (loop)-HD.mp4", "out-b (loop)-HD.mp4", "brokchrd (loop)-HD.mp4", "t-hawk (loop)-HD.mp4", "KOLL-HD.mp4"])
    #expect(p.media.map(\.id) == ["tech-fux-loop-hd", "out-b-loop-hd", "brokchrd-loop-hd", "t-hawk-loop-hd", "koll-hd"])
    try expectValid(p)
}

@Test func otioClipsAndTracksDirectlyInsideStacksAndTracks() throws {
    let r = try otio("nested_example.otio")
    let p = r.project
    #expect(p.tracks.count == 1)
    #expect(p.tracks[0].clips.map(\.kind) == [.media, .sequence, .media, .sequence, .media, .sequence, .media])
    #expect(p.sequences.map(\.name) == ["Nested Stack 1", "Nested Stack 2 (with effects)", "Nested Track"])
    #expect(p.sequences.map { $0.tracks.flatMap(\.clips).compactMap(\.name) } == [["Clip Inside A Stack 1"], ["Clip Inside A Stack 2"], ["Clip Inside A Track"]])
    #expect(timing(p.sequences[0].tracks[0]) == ["0+37@373"])
    // Clips keep their slots; nested uses longer than their content are trimmed to it.
    #expect(timing(p.tracks[0]) == ["0+238@135", "238+31@0", "269+33@101", "302+24@0", "331+63@179", "394+1@0", "398+238@135"])
    #expect(r.missingMedia.count == 7)
    #expect(r.warnings.contains("Effects on 2 clips not kept: Nested Stack 2 (with effects), Nested Track"))
    #expect(r.warnings.filter { $0.contains("trimmed to its content") }.count == 2)
    try expectValid(p)
}

@Test func otioFromPremiereWithEmptyNestsAndGenerators() throws {
    let r = try otio("premiere_example.otio")
    let p = r.project
    #expect(p.canvas.width == 1280 && p.canvas.height == 720 && p.canvas.fps == 30)
    #expect(p.tracks.map(\.id) == ["V1", "V2", "V3", "V4", "A1", "A2", "A3"])
    #expect(p.tracks.flatMap(\.clips).count == 13)
    #expect(timing(p.tracks[1], fps: 30) == ["13+100@0", "165+157@0", "322+235@0", "636+320@0"])
    #expect(timing(p.tracks[2], fps: 30) == ["15+941@108000"])
    #expect(p.media.first { $0.id == "sc01-master-layera-sh030-temp" }?.timecodeStart.map { frames($0, 30) } == 99)
    #expect(p.media.first?.path == "D:/media/sc01_sh010_anim.mov")
    #expect(markerFrames(p, fps: 30) == [113, 298, 395, 492])
    #expect(p.transitions.map { "\($0.from ?? "-")>\($0.to ?? "-") \(frames($0.duration, 30)) \($0.align)" } == ["c4>- 19 center", "c7>c8 25 center"])
    #expect(p.transitions[1].cutOffset.map { frames($0, 30) } == 12)
    #expect(r.warnings.contains("Nested sc01_sh010_anim has nothing in it; kept as offline media (×2)"))
    #expect(r.warnings.contains("Generator test_title (Slug) kept as offline media"))
    try expectValid(p)
}

@Test func otioFromResolveWithStillsAndEffects() throws {
    let r = try otio("effects.otio")
    let p = r.project
    // 8 video and 11 audio tracks, plus one for the disabled clips of 5 of them.
    #expect(p.tracks.count == 24)
    #expect(p.tracks.filter { $0.name.hasSuffix("(disabled)") }.count == 5)
    #expect(p.tracks.flatMap(\.clips).count == 37)
    #expect(frames(p.duration, 24) == 1125)
    #expect(p.media.filter(\.isImage).count == 14)
    #expect(p.transitions.map { "\($0.from!)>\($0.to!) \(frames($0.duration, 24)) \($0.align)" } == ["c1>c2 60 center"])
    #expect(r.warnings.count == 3)
    #expect(r.warnings.contains { $0.hasPrefix("Resolve Transform on 5 clips not kept") })
    #expect(p.tracks.flatMap(\.clips).contains { abs($0.volume - pow(10, -11.0 / 20)) < 1e-9 })
    #expect(r.missingMedia.count == 28)
    try expectValid(p)
}

// MARK: Final Cut Pro X

@Test func fcpxmlEventClipsWithoutAProject() throws {
    let r = try fcpxml("fcpx_clips.fcpxml")
    let p = r.project
    #expect(r.warnings.first == "The file has no project; its 3 event clips are strung out on V1 in order")
    #expect(p.tracks.map(\.id) == ["V1"])
    #expect(p.tracks[0].clips.map(\.name) == ["compound_clip_1", "IMG_0857", "IMG_0858"])
    #expect(p.tracks[0].clips.map(\.kind) == [.sequence, .media, .media])
    // The compound ends in a 10 s gap, which is left empty.
    #expect(timing(p.tracks[0], fps: 30) == ["0+2100@0", "2400+2044@0", "4444+634@0"])
    let tags = try #require(p.media.first { $0.id == "img-0857" }?.tags)
    #expect(tags.map(\.label) == ["snow", "truck"])
    #expect(frames(tags[1].start, 30) == 430 && frames(tags[1].end, 30) == 1124)
    try expectValid(p)
}

@Test func fcpxmlLibrariesEventsAndProjects() throws {
    for name in ["fcpx_example.fcpxml", "fcpx_event.fcpxml", "fcpx_project.fcpxml"] {
        let r = try fcpxml(name)
        let p = r.project
        #expect(p.name == "OpenTimeline_Project", "\(name)")
        #expect(p.tracks.map { $0.clips.count } == [6, 3, 1, 4], "\(name)")
        #expect(p.transitions.count == 3 && p.markers.count == 8, "\(name)")
        let v1 = p.tracks[0].clips
        // Detached audio exactly under its picture folds back in; offset audio stays on A1 and the picture goes silent.
        #expect(v1.map(\.name) == ["IMG_0715", "compound_clip_1", "IMG_0233", "IMG_0687", "IMG_0268", "compound_clip_1"], "\(name)")
        #expect(v1.map(\.volume) == [1, 1, 0, 1, 1, 0], "\(name)")
        #expect(timing(p.tracks[3], fps: 30) == ["629+300@0", "1200+300@107", "3450+150@173", "4200+300@0"], "\(name)")
        #expect(p.tracks[3].clips.last?.kind == .sequence)
        try expectValid(p)
    }
    // Keywords on the browser clip become tags of its media.
    let tags = try fcpxml("fcpx_example.fcpxml").project.media.first { $0.id == "img-0513" }?.tags
    #expect(tags?.map(\.label) == ["snow", "truck", "tree"])
}

// MARK: Final Cut Pro 7 XML

@Test func xmemlFromPremiere() throws {
    let r = try xmeml("premiere_example.xml")
    let p = r.project
    #expect(p.name == "sc01_sh010_layerA" && p.canvas.width == 1280 && p.canvas.height == 720 && p.canvas.fps == 30)
    #expect(p.tracks.map(\.id) == ["V1", "V2", "V3", "V4", "A1", "A2"])
    // 15 fps media at 50 frames fills 100 sequence frames.
    #expect(timing(p.tracks[0], fps: 30) == ["536+100@0"])
    #expect(timing(p.tracks[1], fps: 30) == ["13+100@0", "165+157@0", "322+235@0", "636+320@0"])
    #expect(p.tracks[1].clips[3].kind == .sequence)
    // Clip edges of -1 sit at the cross dissolve's cut (cutPointTicks), the media spanning the transition.
    #expect(timing(p.tracks[3], fps: 30) == ["956+208@34", "1164+82@18"])
    #expect(p.transitions.map { "\($0.from ?? "-")>\($0.to ?? "-") \(frames($0.duration, 30)) \($0.align)" } == ["c4>- 19 center", "c11>c12 25 center"])
    #expect(markerFrames(p, fps: 30) == [113, 298, 395, 492])
    #expect(p.markers.map(\.label) == ["My MArker 1", "Marker", "Marker", "dsf"])
    // Linked stereo audio folds into its picture; picture whose audio isn't in the edit is silent.
    // The nested sequence's sound plays from A1, which uses less of it.
    #expect(p.tracks[1].clips.map(\.volume) == [1, 0, 0, 0] && p.tracks[3].clips.map(\.volume) == [1, 1])
    #expect(timing(p.tracks[4], fps: 30) == ["335+170@0", "636+294@0"] && p.tracks[4].clips[1].kind == .sequence)
    #expect(p.sequences.map(\.name) == ["sc01_sh010_anim"] && timing(p.sequences[0].tracks[0], fps: 30) == ["0+100@0", "100+220@0"])
    let master = try #require(p.media.first { $0.id == "sc01-master-layera-sh030-temp" })
    #expect(master.path == "D:/media/sc01_master_layerA_sh030_temp.mov" && master.timecodeStart.map { frames($0, 30) } == 99)
    #expect(r.missingMedia.count == 7)
    try expectValid(p)

    // Written back out and read again, the edit is the same.
    let again = try Importer.xmeml(Data(p.xmeml().utf8), relativeTo: nil).project
    #expect(again.tracks.map { timing($0, fps: 30) } == p.tracks.map { timing($0, fps: 30) })
    #expect(again.tracks.map { $0.clips.map(\.volume) } == p.tracks.map { $0.clips.map(\.volume) })
    #expect(again.transitions.map(\.duration) == p.transitions.map(\.duration))
    #expect(markerFrames(again, fps: 30) == markerFrames(p, fps: 30) && again.markers.map(\.label) == p.markers.map(\.label))
}

@Test func xmemlFromHieroWithTimeRemap() throws {
    let r = try xmeml("hiero_xml_export.xml")
    let p = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(p.canvas.fps == 24 && p.canvas.width == 1920)
    #expect(timing(p.tracks[0]) == ["14+1055@0", "1085+239@326400"])
    #expect(p.tracks[0].clips.map(\.speed) == [1, 0.25])
    let a = p.media[0]
    #expect(a.path == "/A160R0MN/A160R0MN/A160C005_171213_R0MN.mxf" && a.width == 3424 && a.height == 2202)
    #expect(a.timecodeStart.map { frames($0, 24) } == 1_101_071)
    #expect(r.missingMedia == ["/A160R0MN/A160R0MN/A160C005_171213_R0MN.mxf", "/"])
    try expectValid(p)
}

@Test func xmemlGeneratorsBecomeSolidsTitlesAndOfflineMedia() throws {
    let r = try xmeml("premiere_generators.xml")
    let p = r.project
    let fps = 24000.0 / 1001
    #expect(p.canvas.fps == 23.976)
    let v1 = p.tracks[0].clips
    // Premiere's counting leader and bars are synthetic too: solids, not offline media.
    #expect(v1.map(\.kind) == [.solid, .solid, .solid, .solid, .adjustment, .text])
    #expect(v1.map { frames($0.start, fps) } == [0, 264, 383, 502, 621, 737])
    #expect(v1[0].color == .black && v1[1].color == .black && v1[2].color == RGBA(r: 0, g: 0, b: 1) && v1[3].color == RGBA(r: 0.75, g: 0.75, b: 0.75))
    #expect(v1[5].text?.text.hasPrefix("A center align Title Card\nwith Menlo Font and\n") == true)
    #expect(r.missingMedia.isEmpty && p.media.isEmpty)
    #expect(p.tracks.filter { $0.kind == .audio }.allSatisfy { $0.clips.isEmpty })
    #expect(r.warnings.contains { $0.hasPrefix("Tone of HD Bars and Tone") })
    #expect(r.warnings.contains("Graphic Graphic: its text is kept, its styling isn't"))
    try expectValid(p)
}

@Test func xmemlSequenceWithoutTracks() throws {
    let r = try xmeml("sample_just_track.xml")
    #expect(r.project.name == "sc01_sh010_layerA" && r.project.canvas.fps == 30)
    #expect(r.project.tracks.flatMap(\.clips).isEmpty)
    #expect(throws: EditError.self) { try Importer.xmeml(Data("<fcpxml version=\"1.11\"/>".utf8), relativeTo: nil) }
    #expect(throws: EditError.self) { try Importer.xmeml(Data("<xmeml version=\"5\"/>".utf8), relativeTo: nil) }
}
