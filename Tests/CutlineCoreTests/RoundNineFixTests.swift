import Foundation
import Testing
@testable import CutlineCore

private func media(_ id: String, width: Int = 1920, height: Int = 1080, channels: Int? = nil) -> MediaAsset {
    var m = MediaAsset(id: id, path: "/tmp/\(id).mov", name: id, duration: 120, width: width, height: height, fps: 30, hasVideo: true, hasAudio: true)
    if let channels { m.audioChannels = (1...channels).map { SourceChannel(track: $0, channel: 1) } }
    return m
}

@Test func reframeKeepsVerticalPicturesCoveringTheFrame() throws {
    var p = Project(name: "Reframe")
    p.media = [media("wide"), media("tall", width: 1080, height: 1920)]
    var tall = Clip(id: "tall1", kind: .media, mediaId: "tall", start: 2, duration: 2)
    tall.transform.fit = .fill
    tall.transform.y = 0.1307
    p.tracks[0].clips = [Clip(id: "wide1", kind: .media, mediaId: "wide", start: 0, duration: 2), tall]
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.contains("canvas not covered") }, "a fill picture with room to move covers the 16:9 frame")

    var stale = p
    stale.canvas.width = 1080
    stale.canvas.height = 1920
    let issue = stale.qualityIssues(transcripts: [:]).first { $0.hasPrefix("canvas not covered: tall1") }
    #expect(issue?.contains("top 13%") == true, "\(stale.qualityIssues(transcripts: [:]))")

    let note = try p.reframe(width: 1080, height: 1920) { _ in [] }
    #expect(p.clip("tall1")?.transform.y == 0, "\(String(describing: p.clip("tall1")?.transform))")
    #expect(note.contains("vertical offset refit"), "\(note)")
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.contains("canvas not covered") }, "\(p.qualityIssues(transcripts: [:]))")
}

@Test func reframeScalesAnimatedVerticalOffsetsIntoTheOverflow() throws {
    var p = Project(name: "Reframe")
    p.media = [media("wide")]
    var c = Clip(id: "c", kind: .media, mediaId: "wide", start: 0, duration: 2)
    c.transform.fit = .fill
    try c.animate("transform.y", keys: [CurveKey(t: 0, v: .number(-0.2)), CurveKey(t: 2, v: .number(0.2))])
    p.tracks[0].clips = [c]
    _ = try p.reframe(width: 1080, height: 1920) { _ in [] }
    let ys = p.clip("c")?.anim["transform.y"]?.keys.compactMap(\.v.number) ?? []
    #expect(ys == [0, 0], "a landscape picture filling 9:16 has no vertical room: \(ys)")
}

@Test func coverageIgnoresPicturesWithACoveringPictureBelow() throws {
    var p = Project(name: "PiP")
    p.media = [media("a"), media("b")]
    p.tracks[0].clips = [Clip(id: "bg", kind: .media, mediaId: "a", start: 0, duration: 4)]
    let v2 = p.addTrack(kind: .video, name: "PiP", index: 1)
    var pip = Clip(id: "pip", kind: .media, mediaId: "b", start: 0, duration: 4)
    pip.transform.scale = 0.3
    p.tracks[p.trackIndex(v2.id)!].clips = [pip]
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.contains("canvas not covered") })
    p.tracks[0].clips = []
    #expect(p.qualityIssues(transcripts: [:]).contains { $0.hasPrefix("canvas not covered: pip") })
}

@Test func pointParametersTakeListsAndRejectOtherText() throws {
    var c = Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 2, effects: [Effect(id: "m1", type: "mask.shape")])
    try c.set("fx.m1.points", .string("[[0.1,0.1],[0.9,0.1],[0.5,0.9]]"))
    #expect(c.effects[0].params["points"] == .string("0.1,0.1 0.9,0.1 0.5,0.9"))
    try c.set("fx.m1.points", .string(#"[{"x":0.2,"y":0.2},{"x":0.8,"y":0.2},{"x":0.5,"y":0.7}]"#))
    #expect(c.effects[0].params["points"] == .string("0.2,0.2 0.8,0.2 0.5,0.7"))
    try c.set("fx.m1.points", .string("0.1, 0.1 0.9, 0.1 0.5, 0.9"))
    #expect(c.effects[0].params["points"] == .string("0.1,0.1 0.9,0.1 0.5,0.9"))
    #expect(throws: EditError.self) { try c.set("fx.m1.points", .string("triangle")) }
    #expect(throws: EditError.self) { try c.set("fx.m1.points", .string("0.1,0.1 0.9,0.1")) }
    #expect(throws: EditError.self) { try c.set("fx.m1.points", .number(3)) }
    do { try c.set("fx.m1.points", .string("triangle")) } catch { #expect("\(error)".contains("x,y x,y …"), "\(error)") }

    var curves = Clip(id: "k", kind: .media, mediaId: "m", start: 0, duration: 2, effects: [Effect(id: "cv", type: "color.curves")])
    try curves.set("fx.cv.master", .string("[[0,0],[0.5,0.6],[1,1]]"))
    #expect(curves.effects[0].params["master"] == .string("0,0 0.5,0.6 1,1"))
    try curves.set("fx.cv.master", .string(""))

    var lut = Clip(id: "l", kind: .media, mediaId: "m", start: 0, duration: 2, effects: [Effect(id: "matte", type: "mask.matte")])
    #expect(throws: EditError.self) { try lut.set("fx.matte.track", .string(#"{"id": "V2"}"#)) }
    try lut.set("fx.matte.track", .string("[2]"))
}

@Test func detachedSoundCarriesEverythingAndAttachesBack() throws {
    var p = Project(name: "Detach")
    p.media = [media("m")]
    var c = Clip(id: "pic", kind: .media, mediaId: "m", start: 4, duration: 6, sourceIn: 10)
    c.audioLead = 1
    c.audioLag = 0.5
    c.audioFadeIn = 0.3
    c.audioFadeOut = 0.4
    c.volume = 0.8
    c.channels = ChannelRouting(rawValue: "left")
    c.effects = [Effect(id: "eq1", type: "audio.eq"), Effect(id: "blur1", type: "blur.gaussian")]
    try c.animate("audio.volume", keys: [CurveKey(t: 0, v: .number(0.5)), CurveKey(t: 2, v: .number(1))])
    p.tracks[0].clips = [c]
    let original = p.clip("pic")!

    let (sound, track) = try p.detachAudio("pic")
    #expect(track != "V1" && p.tracks.first { $0.id == track }?.kind == .audio)
    #expect(abs(sound.start - 3) < 1e-6 && abs(sound.duration - 7.5) < 1e-6 && abs(sound.sourceIn - 9) < 1e-6, "\(sound)")
    #expect(sound.volume == 0.8 && sound.audioFadeIn == 0.3 && sound.audioFadeOut == 0.4 && sound.channels?.rawValue == "left")
    #expect(sound.effects.map(\.id) == ["eq1"] && sound.audioLead == 0 && sound.audioLag == 0)
    #expect(sound.anim["audio.volume"]?.keys.map(\.t) == [1, 3], "automation keeps its timeline times")
    let pic = try #require(p.clip("pic"))
    #expect(pic.volume == 0 && pic.audioLead == 0 && pic.audioLag == 0 && pic.anim["audio.volume"] == nil && pic.effects.map(\.id) == ["blur1"])
    #expect(pic.link != nil && pic.link == p.clip(sound.id)?.link)
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.contains("doubled sound") })
    #expect(throws: EditError.self) { _ = try p.detachAudio("pic") }

    try p.moveLinked("pic", start: 5)
    #expect(abs((p.clip(sound.id)?.start ?? 0) - 4) < 1e-6, "linked clips move together")
    try p.moveLinked("pic", start: 4)

    let back = try p.attachAudio(sound.id)
    #expect(back == ("pic", sound.id))
    let joined = try #require(p.clip("pic"))
    #expect(p.clip(sound.id) == nil && joined.link == nil)
    #expect(joined.audioLead == original.audioLead && joined.audioLag == original.audioLag && joined.volume == 0.8 && joined.channels == original.channels)
    #expect(joined.effects.map(\.id).sorted() == ["blur1", "eq1"] && joined.anim["audio.volume"] == original.anim["audio.volume"])
}

@Test func theSameSoundTwiceInSyncIsReported() throws {
    var p = Project(name: "Twice")
    p.media = [media("m")]
    p.tracks[0].clips = [Clip(id: "pic", kind: .media, mediaId: "m", start: 0, duration: 5, sourceIn: 2)]
    p.tracks[1].clips = [Clip(id: "snd", kind: .media, mediaId: "m", start: 1, duration: 5, sourceIn: 3)]
    let issue = p.qualityIssues(transcripts: [:]).first { $0.hasPrefix("doubled sound") }
    #expect(issue?.contains("pic on V1 and snd on A1") == true && issue?.contains("detach_audio") == true, "\(p.qualityIssues(transcripts: [:]))")
    p.tracks[1].clips[0].sourceIn = 4
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.hasPrefix("doubled sound") }, "out of sync is a different moment")
    p.tracks[1].clips[0].sourceIn = 3
    p.tracks[0].clips[0].channels = ChannelRouting(rawValue: "left")
    p.tracks[1].clips[0].channels = ChannelRouting(rawValue: "right")
    #expect(!p.qualityIssues(transcripts: [:]).contains { $0.hasPrefix("doubled sound") }, "different source channels")
}

@Test func anLCutThatSilencesWholeWordsIsReported() throws {
    var p = Project(name: "Split")
    p.media = [media("a"), media("b")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 0), Clip(id: "c2", kind: .media, mediaId: "b", start: 4, duration: 4, sourceIn: 10)]
    let tr = ["b": Transcript(mediaId: "b", locale: "en-US", words: [
        Word(text: "that's", start: 10.05, end: 10.25), Word(text: "perfect", start: 10.3, end: 10.5), Word(text: "now", start: 11, end: 11.3),
    ])]
    _ = try p.splitEdit(left: "c1", right: "c2", offset: -0.58)
    let issue = p.qualityIssues(transcripts: tr).first { $0.hasPrefix("c2's sound starts") }
    #expect(issue?.contains("“that's perfect”") == true, "\(p.qualityIssues(transcripts: tr))")
}

@Test func speechGapsUnderMusicOrActionAreNotPauses() {
    let words = [Word(text: "one", start: 0, end: 1), Word(text: "two", start: 3, end: 4), Word(text: "three", start: 6, end: 7), Word(text: "four", start: 9, end: 10), Word(text: "five", start: 12, end: 13)]
    let gaps = [TimeRange(1, 3), TimeRange(4, 6), TimeRange(7, 9), TimeRange(10, 12)]
    var levels = [Float](repeating: -50, count: 140)
    for w in words { for i in Int(w.start * 10)..<Int(w.end * 10) { levels[i] = -12 } }
    for i in 70..<90 { levels[i] = -14 }
    let audio = AudioAnalysis(mediaId: "m", levelRate: 10, levels: levels, silences: [], silenceThresholdDb: -45, loudnessDb: -20)
    let sounds = [SoundEvent(label: "music", start: 3.5, end: 6.5, confidence: 0.9), SoundEvent(label: "car", start: 10, end: 12, confidence: 0.8)]
    let sorted = SpeechPauses(gaps: gaps, words: words, sounds: sounds, levels: audio, includeMusic: false)
    #expect(sorted.cut == [TimeRange(1, 3)], "\(sorted.cut)")
    #expect(sorted.kept.map(\.reason) == [.music, .loud, .sound])
    #expect(sorted.keptSummary?.contains("1 under music, 1 with other sound (car), 1 not quiet") == true, "\(sorted.keptSummary ?? "")")
    #expect(SpeechPauses(gaps: gaps, words: words, sounds: sounds, levels: audio, includeMusic: true).cut == gaps)
}

@Test func edlChannelsFollowTheSource() {
    var p = Project(name: "EDL")
    p.media = [media("mono", channels: 1), media("stereo", channels: 2)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "mono", start: 0, duration: 2), Clip(id: "c2", kind: .media, mediaId: "stereo", start: 2, duration: 2)]
    let edl = p.edl(title: "T")
    let events = edl.components(separatedBy: "\n").filter { $0.hasPrefix("00") }
    #expect(events.count == 2 && events[0].contains(" A/V ") && events[1].contains(" AA/V "), "\(edl)")
}

@Test func importedSoundFarFromItsPictureStaysAClipOfItsOwn() throws {
    var p = Project(name: "Doc", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    p.media = [media("cam")]
    var near = Clip(id: "near", kind: .media, mediaId: "cam", start: 2, duration: 4, sourceIn: 10)
    near.audioLead = 1
    var far = Clip(id: "far", kind: .media, mediaId: "cam", start: 20, duration: 4, sourceIn: 60)
    far.audioLead = 7.24
    far.audioLag = -1
    p.tracks[0].clips = [near, far]
    // As another editor writes it: without Cutline's own clip notes.
    let foreign = p.xmeml().replacingOccurrences(of: #"<mastercomment[34]>[^<]*</mastercomment[34]>"#, with: "", options: .regularExpression)
    let q = try Importer.xmeml(Data(foreign.utf8), relativeTo: nil).project
    let pictures = q.tracks.filter { $0.kind == .video }.flatMap(\.clips)
    let sounds = q.tracks.filter { $0.kind == .audio }.flatMap(\.clips)
    let n = try #require(pictures.first { abs($0.start - 2) < 1e-3 })
    #expect(abs(n.audioLead - 1) < 1e-3, "a short split edit still folds into its picture")
    let f = try #require(pictures.first { abs($0.start - 20) < 1e-3 })
    #expect(f.audioLead == 0 && f.audioLag == 0 && f.volume == 0, "\(f) \(q.tracks.map { t in t.id + ": " + t.clips.map { "\($0.start)+\($0.duration) lead \($0.audioLead) lag \($0.audioLag) vol \($0.volume)" }.joined(separator: ", ") })")
    let s = try #require(sounds.first { abs($0.start - 12.76) < 0.05 }, "\(sounds)")
    #expect(abs(s.duration - 10.24) < 0.05 && s.link != nil && s.link == f.link, "\(s)")
    #expect(!q.qualityIssues(transcripts: [:]).contains { $0.hasPrefix("doubled sound") })
}

@Test func trimmedArchivesSayWhatTheyLeaveOut() throws {
    var p = Project(name: "Archive")
    p.media = [media("used"), media("spare"), media("other")]
    p.media[0].path = "/bin/ls"
    p.media[2].path = "/bin/cat"
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "used", start: 0, duration: 2)]
    try p.newTimeline("Cutdown", duplicate: false)
    p.tracks[0].clips = [Clip(id: "o", kind: .media, mediaId: "other", start: 0, duration: 2, sourceIn: 5)]
    try p.switchTimeline(to: "Main")

    let plan = ConsolidatePlan(p, trim: true, handles: 0)
    #expect(plan.items.map(\.mediaId) == ["used"])
    let skipped = Dictionary(uniqueKeysWithValues: plan.skipped(p).map { ($0.mediaId, $0.reason) })
    #expect(skipped == ["spare": "offline", "other": "only on other timelines"], "\(skipped)")
    #expect(plan.apply(to: p, directory: URL(fileURLWithPath: "/tmp")).timelines.isEmpty)

    let all = ConsolidatePlan(p, trim: true, handles: 0, allTimelines: true)
    #expect(Set(all.items.map(\.mediaId)) == ["used", "other"])
    let out = all.apply(to: p, directory: URL(fileURLWithPath: "/tmp"))
    let o = try #require(out.timelines.first?.tracks.flatMap(\.clips).first { $0.id == "o" })
    #expect(o.sourceIn == 0 && out.mediaAsset("other")?.duration == 2, "the other timeline reads its trimmed copy")
}
