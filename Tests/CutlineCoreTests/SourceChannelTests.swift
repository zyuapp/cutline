import Foundation
import Testing
@testable import CutlineCore

private func multitrack(tracks: Int = 4, video: Bool = true) -> Project {
    var p = Project(name: "Multitrack")
    var m = MediaAsset(id: "cam", path: "/tmp/cam.mov", name: "Cam", duration: 30, width: 1920, height: 1080, fps: 25, hasVideo: video, hasAudio: true)
    m.audioChannels = (1...tracks).map { SourceChannel(track: $0, channel: 1, name: $0 == 3 ? "Lav 1" : nil) }
    p.media = [m]
    return p
}

@Test func channelRoutingParsesAnySourceChannel() throws {
    #expect(ChannelRouting(rawValue: "ch3")?.form == .single(3))
    #expect(ChannelRouting(rawValue: "3")?.rawValue == "ch3")
    #expect(ChannelRouting(rawValue: "CH3+ch4")?.form == .pair(3, 4))
    #expect(ChannelRouting(rawValue: "3+4")?.rawValue == "ch3+ch4")
    #expect(ChannelRouting(rawValue: "mix:1,3")?.form == .mix([1, 3]))
    #expect(ChannelRouting(rawValue: "mix:ch3")?.rawValue == "ch3")
    #expect(ChannelRouting(rawValue: "left")?.form == .single(1))
    #expect(ChannelRouting(rawValue: "left") == .left && ChannelRouting(rawValue: "ch1") != .left)
    for bad in ["center", "ch0", "ch3+", "mix:", "mix:1,x", "ch99"] { #expect(ChannelRouting(rawValue: bad) == nil, "\(bad)") }

    let pair = try #require(ChannelRouting(rawValue: "ch3+ch4")).matrix(count: 4)
    #expect(pair.left == [0, 0, 1, 0] && pair.right == [0, 0, 0, 1])
    let mix = try #require(ChannelRouting(rawValue: "mix:1,3")).matrix(count: 4)
    #expect(mix.left == [0.5, 0, 0.5, 0] && mix.right == mix.left)
    // Named routings on a mono file play its one channel; numbered channels beyond it are silent.
    #expect(ChannelRouting.right.matrix(count: 1).left == [1])
    #expect(ChannelRouting(rawValue: "ch2")!.matrix(count: 1).left == [0])
    #expect(ChannelRouting(rawValue: "ch5")!.problem(count: 4)?.contains("ch1–ch4") == true)
    #expect(ChannelRouting.right.problem(count: 1) == nil)
    #expect(ChannelRouting(rawValue: "ch3")!.isMono && !ChannelRouting(rawValue: "ch3+ch4")!.isMono)
}

@Test func audioChannelsAcceptsChannelsTheMediaHas() throws {
    var p = multitrack()
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "cam", start: 0, duration: 2)]
    try p.tracks[0].clips[0].set("audio.channels", .string("ch3+ch4"))
    #expect(p.tracks[0].clips[0].channels?.rawValue == "ch3+ch4")
    try p.validate()
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
    #expect(decoded.tracks[0].clips[0].channels == ChannelRouting(rawValue: "ch3+ch4"))
    #expect(decoded.media[0].audioChannels?.count == 4 && decoded.media[0].audioChannels?[2].name == "Lav 1")
    try p.tracks[0].clips[0].set("audio.channels", .string("ch5"))
    #expect(throws: EditError.self) { try p.validate() }
    #expect(throws: EditError.self) { try p.tracks[0].clips[0].set("audio.channels", .string("mix:")) }
    #expect(p.media[0].channelSummary == "4 source channels in 4 mono tracks: ch1, ch2, ch3 \"Lav 1\", ch4")
}

@Test func splittingAMultitrackRecordingLaysEachChannelOnItsOwnLinkedTrack() throws {
    var p = multitrack()
    let clip = Clip(id: "x", kind: .media, mediaId: "cam", start: 2, duration: 5, sourceIn: 1)
    let made = try p.addSplitChannels(clip, pictureTrack: "V1", mode: .place)
    #expect(made.channels.count == 4)
    let picture = try #require(made.picture.flatMap { p.clip($0) })
    #expect(picture.volume == 0 && picture.start == 2)
    for (i, ch) in made.channels.enumerated() {
        let c = try #require(p.clip(ch.clip))
        #expect(c.channels?.rawValue == "ch\(i + 1)")
        #expect(c.start == 2 && c.duration == 5 && c.sourceIn == 1 && c.link == picture.link)
        #expect(p.tracks.first { $0.id == ch.track }?.kind == .audio)
    }
    #expect(Set(made.channels.map(\.track)).count == 4)
    #expect(p.tracks.first { $0.id == made.channels[2].track }?.name.contains("Lav 1") == true)
    try p.validate()

    // Linked pieces move together.
    try p.moveLinked(picture.id, start: 10)
    #expect(made.channels.allSatisfy { p.clip($0.clip)?.start == 10 })

    // Onto existing tracks, after what's there.
    var audio = multitrack(tracks: 2, video: false)
    let a1 = audio.addTrack(kind: .audio).id, a2 = audio.addTrack(kind: .audio).id
    let split = try audio.addSplitChannels(Clip(id: "y", kind: .media, mediaId: "cam", start: 0, duration: 3), pictureTrack: nil, audioTracks: [a1, a2], mode: .append)
    #expect(split.picture == nil && split.channels.map(\.track) == [a1, a2])
    #expect(throws: EditError.self) { try audio.addSplitChannels(Clip(id: "z", kind: .media, mediaId: "cam", start: 0, duration: 3), pictureTrack: nil, audioTracks: [a1], mode: .append) }
}

@Test func masterLoudnessTargetRoundTripsAndReportsDrift() throws {
    var m = MasterAudio()
    #expect(m.drift(integrated: -30, truePeak: -8) == nil)
    m.loudnessTarget = -23
    let decoded = try JSONDecoder().decode(MasterAudio.self, from: JSONEncoder().encode(m))
    #expect(decoded.loudnessTarget == -23 && decoded.ceiling == -1.5)
    let legacy = try JSONDecoder().decode(MasterAudio.self, from: Data(#"{"gainDb": 2, "effects": []}"#.utf8))
    #expect(legacy.loudnessTarget == nil && legacy.gainDb == 2)
    let drift = try #require(m.drift(integrated: -30.6, truePeak: -9))
    #expect(drift.contains("7.6 LU below") && drift.contains("+7.6 dB"), "\(drift)")
    #expect(m.drift(integrated: -23.2, truePeak: -3)?.hasPrefix("on target") == true)
}
