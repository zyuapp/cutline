import Foundation
import Testing
@testable import CutlineCore

private func aaf(_ name: String) throws -> Project {
    let url = try #require(Bundle.module.url(forResource: name + ".aaf", withExtension: "lzfse", subdirectory: "Fixtures/aaf"))
    let data = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
    return try Importer.aaf(data, relativeTo: nil).project
}

private func offline(_ id: String, duration: Seconds, tc: Seconds? = nil) -> MediaAsset {
    var m = MediaAsset(id: id, path: "/offline/\(id).mov", name: "\(id).mov", duration: duration, width: 1920, height: 1080, fps: 24, hasVideo: true, hasAudio: true)
    if let tc { m.setTimecode(seconds: tc, format: TimecodeFormat(fps: 24)) }
    return m
}

// MARK: Media matching across imports

@Test(arguments: [("transitions", "multitrack"), ("trims", "simple"), ("trims", "preflattened"), ("simple", "trims")])
func aSecondAAFReadingTheSameOfflineMediaImports(first: String, second: String) throws {
    var p = Project(name: "Conform")
    for n in [first, second] {
        let imported = try aaf(n)
        let r = try p.adoptTimeline(imported, name: n)
        try p.validate()
        #expect(p.tracks.flatMap(\.clips).count == imported.tracks.flatMap(\.clips).count, "\(n): \(r.warnings)")
        // Every clip still reads the same source timecode.
        for (a, b) in zip(p.tracks.flatMap(\.clips), imported.tracks.flatMap(\.clips)) where a.kind == .media {
            let mine = try #require(a.mediaId.flatMap(p.mediaAsset)), theirs = try #require(b.mediaId.flatMap(imported.mediaAsset))
            #expect(abs(a.sourceIn + (mine.timecodeStart ?? 0) - b.sourceIn - (theirs.timecodeStart ?? 0)) < 1e-6)
        }
    }
    // KOLL-HD has another timecode in trims.aaf than elsewhere: two offline entries, one per timecode.
    let koll = p.media.filter { $0.name == "KOLL-HD.mp4" }
    #expect(koll.count == 2 && Set(koll.map { $0.timecodeStart ?? 0 }).count == 2, "\(koll.map(\.id))")
}

@Test func offlineMediaGrowsWhenAnotherTimelineReadsMoreOfIt() throws {
    var p = Project(name: "P")
    p.media = [offline("a", duration: 5, tc: 3600)]
    var other = Project(name: "O")
    other.media = [offline("a", duration: 12, tc: 3600)]
    other.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 8)]
    let r = try p.adoptTimeline(other, name: "Longer")
    try p.validate()
    #expect(r.matched == 1 && r.added == 0 && p.media.count == 1 && abs(p.media[0].duration - 12) < 1e-9)
}

@Test func onlineMediaTrimsClipsReadingPastItsEnd() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("conform-\(UUID().uuidString).mov")
    try Data([0]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var p = Project(name: "P")
    p.media = [MediaAsset(id: "a", path: file.path, name: "a", duration: 5, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)]
    var other = Project(name: "O")
    other.media = [MediaAsset(id: "a", path: file.path, name: "a", duration: 20, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)]
    other.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 3),
                             Clip(id: "c2", kind: .media, mediaId: "a", start: 4, duration: 2, sourceIn: 10)]
    let r = try p.adoptTimeline(other, name: "Cut")
    try p.validate()
    #expect(p.tracks[0].clips.map(\.id) == ["c1"] && abs(p.tracks[0].clips[0].duration - 2) < 1e-9)
    #expect(r.warnings.contains { $0.contains("trimmed") } && r.warnings.contains { $0.contains("left out") }, "\(r.warnings)")
}

@Test func overlapsMoveToANewTrackAndCollidingSequencesGetNewIds() throws {
    var p = Project(name: "P")
    p.media = [offline("a", duration: 30)]
    p.sequences = [NestedSequence(id: "seq", name: "Old", tracks: [Track(id: "V1", kind: .video, name: "V", clips: [Clip(id: "x", kind: .media, mediaId: "a", start: 0, duration: 2)])])]
    var other = Project(name: "O")
    other.media = [offline("a", duration: 30)]
    other.sequences = [NestedSequence(id: "seq", name: "New", tracks: [Track(id: "V1", kind: .video, name: "V", clips: [Clip(id: "y", kind: .media, mediaId: "a", start: 0, duration: 3, sourceIn: 5)])])]
    other.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4),
                             Clip(id: "c2", kind: .media, mediaId: "a", start: 2, duration: 4),
                             Clip(id: "n", kind: .sequence, mediaId: "seq", start: 6, duration: 3)]
    let r = try p.adoptTimeline(other, name: "Cut")
    try p.validate()
    #expect(p.tracks.filter { $0.kind == .video }.count == 2 && r.warnings.contains { $0.contains("moved to V2") }, "\(r.warnings)")
    let nest = try #require(p.tracks.flatMap(\.clips).first { $0.id == "n" })
    #expect(nest.mediaId == "seq-2" && p.sequence("seq-2")?.name == "New" && p.sequence("seq")?.name == "Old")
}

// MARK: Split mono channels

private func splitChannels() -> Project {
    var p = Project(name: "Split")
    var m = MediaAsset(id: "rec", path: "/footage/rec.wav", name: "rec", duration: 20, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)
    m.audioChannels = (1...4).map { SourceChannel(track: $0, channel: 1) }
    p.media = [m]
    p.tracks = [Track(id: "V1", kind: .video, name: "Main")] + (1...4).map { n in
        var c = Clip(id: "a\(n)", kind: .media, name: "rec", mediaId: "rec", start: 1, duration: 5, sourceIn: 2)
        c.channels = ChannelRouting(rawValue: "ch\(n)")
        return Track(id: "A\(n)", kind: .audio, name: "Audio \(n)", clips: [c])
    }
    return p
}

private func routings(_ p: Project) -> [String] {
    p.tracks.filter { $0.kind == .audio }.flatMap(\.clips).map { $0.channels?.rawValue ?? "stereo" }.sorted()
}

@Test func splitMonoChannelsRoundTripThroughEveryFormat() throws {
    let p = splitChannels()
    let want = ["ch1", "ch2", "ch3", "ch4"]
    let xml = String(decoding: try p.interchange(.xml).data, as: UTF8.self)
    for n in 1...4 { #expect(xml.contains("<trackindex>\(n)</trackindex>")) }
    #expect(xml.components(separatedBy: "<channelcount>1</channelcount>").count == 5, "one audio element per mono track")
    #expect(routings(try Importer.xmeml(Data(xml.utf8), relativeTo: nil).project) == want)
    // Other apps' XML has only the sourcetrack.
    let bare = xml.replacingOccurrences(of: #"<mastercomment2>[^<]*</mastercomment2>"#, with: "", options: .regularExpression)
    #expect(routings(try Importer.xmeml(Data(bare.utf8), relativeTo: nil).project) == want)

    let fcp = String(decoding: try p.interchange(.fcpxml).data, as: UTF8.self)
    #expect(fcp.contains("audioSources=\"4\" audioChannels=\"4\"") && fcp.contains("<audio-channel-source srcCh=\"3\"/>"), "\(fcp)")
    #expect(routings(try Importer.fcpxml(Data(fcp.utf8), relativeTo: nil).project) == want)
    let fcpBare = fcp.replacingOccurrences(of: #"<md key="com.cutline.channels"[^>]*/>"#, with: "", options: .regularExpression)
    #expect(routings(try Importer.fcpxml(Data(fcpBare.utf8), relativeTo: nil).project) == want)

    #expect(routings(try Importer.otio(try p.interchange(.otio).data, relativeTo: nil).project) == want)
    #expect(routings(try Importer.aaf(try p.interchange(.aaf).data, relativeTo: nil).project) == want)
}

// MARK: Scope

@Test func interchangeCarriesOnlyTheCurrentTimeline() throws {
    var p = splitChannels()
    p.media.append(MediaAsset(id: "other", path: "/footage/other.mov", name: "other", duration: 9, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true))
    p.sequences = [NestedSequence(id: "unused", name: "Unused nest", tracks: [Track(id: "V1", kind: .video, name: "V", clips: [
        Clip(id: "hidden-clip", kind: .media, mediaId: "other", start: 0, duration: 2, effects: [Effect(id: "b", type: "blur.gaussian")])])])]
    try p.newTimeline("Other", duplicate: false)
    p.tracks[0].clips = [Clip(id: "elsewhere", kind: .media, mediaId: "other", start: 0, duration: 2, effects: [Effect(id: "b", type: "blur.gaussian")])]
    try p.switchTimeline(to: "Main")
    for format in InterchangeFormat.allCases {
        let made = try p.interchange(format)
        let text = String(decoding: made.data, as: UTF8.self)
        #expect(!text.contains("other.mov") && !text.contains("Unused nest"), "\(format)")
        let notes = made.notes.joined(separator: "\n")
        #expect(!notes.contains("elsewhere") && !notes.contains("hidden-clip") && !notes.contains("Unused nest") && !notes.contains("nested"), "\(format): \(notes)")
    }
    let fcp = String(decoding: try p.interchange(.fcpxml).data, as: UTF8.self)
    #expect(fcp.components(separatedBy: "<asset ").count == 2)
}

// MARK: Multicam

/// Two cameras and a recorder synced at a shared moment, switched A → B → A with the recorder heard, then camera B's sound.
private func multicamEdit() throws -> Project {
    var p = Project(name: "Multicam")
    p.canvas.fps = 25
    p.media = [
        MediaAsset(id: "camA", path: "/tmp/a.mov", name: "Cam A", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "camB", path: "/tmp/b.mov", name: "Cam B", duration: 50, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "rec", path: "/tmp/r.wav", name: "Recorder", duration: 70, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    let seq = try p.createMulticam(name: "Interview", angles: [("A", "camA", 10), ("B", "camB", 7.5), ("rec", "rec", 12)], audio: ["rec"], sync: "marker")
    var c = Clip(id: "mc", kind: .sequence, mediaId: seq.id, start: 2, duration: 30, sourceIn: 6)
    c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: "A")])
    p.tracks[0].clips = [c]
    try p.switchMulticam("mc", from: 10, angle: "B")
    try p.switchMulticam("mc", from: 20, to: 25, angle: "A", audio: ["B"])
    return p
}

private func angleSummary(_ p: Project) throws -> (ranges: [String], offsets: [Seconds], angles: [String]) {
    let clips = p.tracks.filter { $0.kind == .video }.flatMap(\.clips)
    #expect(clips.count == 1, "\(clips.map(\.id))")
    let c = try #require(clips.first)
    let setup = try #require(p.multicamSetup(c), "not a multicam clip")
    let ranges = p.visibleAngleRanges(c).map { "\(Int(($0.range.start * 25).rounded()))-\(Int(($0.range.end * 25).rounded())) \($0.angle) \($0.audio.joined(separator: "+"))" }
    return (ranges, setup.angles.map(\.offset), setup.angles.map(\.name))
}

@Test(arguments: [InterchangeFormat.fcpxml, .xml, .otio])
func multicamClipsRoundTripAsMulticam(format: InterchangeFormat) throws {
    let p = try multicamEdit()
    let want = try angleSummary(p)
    #expect(want.ranges == ["50-250 A rec", "250-500 B rec", "500-625 A B", "625-800 B rec"])
    let made = try p.interchange(format)
    let text = String(decoding: made.data, as: UTF8.self)
    let back: Project
    switch format {
    case .fcpxml:
        #expect(text.contains("<multicam ") && text.components(separatedBy: "<mc-angle ").count == 4 && text.components(separatedBy: "<mc-clip ").count == 5, "\(text)")
        #expect(text.contains("srcEnable=\"audio\"") && text.contains("<mc-source angleID=\"") && !text.contains("active angles"))
        back = try Importer.fcpxml(made.data, relativeTo: nil).project
    case .xml:
        #expect(text.contains("<multiclip id=") && text.contains("<collapsed>FALSE</collapsed>") && text.contains("<activevideoangle>TRUE</activevideoangle>"), "\(text)")
        back = try Importer.xmeml(made.data, relativeTo: nil).project
    default:
        #expect(text.contains("Interview (active angles)"))
        back = try Importer.otio(made.data, relativeTo: nil).project
    }
    let got = try angleSummary(back)
    #expect(got.ranges == want.ranges)
    #expect(got.angles == want.angles)
    for (a, b) in zip(got.offsets, want.offsets) { #expect(abs(a - b) < 0.021) }
    var host = Project(name: "Host")
    host.media = p.media
    _ = try host.adoptTimeline(back, name: "Back")
    try host.validate()
}
