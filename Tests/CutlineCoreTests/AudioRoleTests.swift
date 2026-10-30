import Foundation
import Testing
@testable import CutlineCore

/// Five 3 s stretches of speech with 1 s pauses over 20 s.
private let spoken = (0..<5).map { TimeRange(Double($0) * 4, Double($0) * 4 + 3) }

private func words(_ mediaId: String, in spans: [TimeRange]) -> Transcript {
    var w: [Word] = []
    for s in spans {
        var t = s.start
        while t + 0.4 <= s.end { w.append(Word(text: "word", start: t, end: t + 0.4)); t += 0.5 }
    }
    return Transcript(mediaId: mediaId, locale: "en-US", words: w)
}

private func levels(_ duration: Seconds, rate: Double = 10, _ db: (Seconds) -> Float) -> [Float] {
    (0..<Int(duration * rate)).map { db(Double($0) / rate) }
}

private func speechShaped(_ t: Seconds) -> Float { spoken.contains { $0.start <= t && t < $0.end } ? -20 : -70 }

/// A 4-channel interview split to mono tracks (ch1+ch2 the lavs, ch3 a music bed, ch4 unused), silent b-roll and room tone.
private func interview() throws -> (Project, SoundEvidence) {
    var p = Project(name: "Roles")
    var talk = MediaAsset(id: "talk", path: "/tmp/talk.wav", name: "Interview", duration: 20, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)
    talk.audioChannels = (1...4).map { SourceChannel(track: $0, channel: 1) }
    let broll = MediaAsset(id: "broll", path: "/tmp/broll.mov", name: "B-roll", duration: 20, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)
    let room = MediaAsset(id: "room", path: "/tmp/room.wav", name: "Room", duration: 10, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)
    p.media = [talk, broll, room]
    p.tracks = [Track(id: "V1", kind: .video, name: "V1")]
    p.tracks.append(Track(id: "V2", kind: .video, name: "Cutaways", clips: [Clip(id: "b", kind: .media, mediaId: "broll", start: 2, duration: 4, sourceIn: 2)]))
    for n in 1...4 {
        var c = Clip(id: "ch\(n)", kind: .media, mediaId: "talk", start: 0, duration: 20)
        c.channels = ChannelRouting(rawValue: "ch\(n)")
        p.tracks.append(Track(id: "A\(n)", kind: .audio, name: "Interview ch\(n)", clips: [c]))
    }
    let tone = p.addTrack(kind: .audio, name: "Fill").id
    try p.fillRoomTone(TimeRange(20, 26), mediaId: "room", source: TimeRange(0, 4), trackId: tone)

    let ch3: (Seconds) -> Float = { _ in -25 }
    var e = SoundEvidence(transcripts: ["talk": words("talk", in: spoken)])
    e.channels["talk"] = ChannelLevels(mediaId: "talk", rate: 10, levels: [levels(20, speechShaped), levels(20, speechShaped), levels(20, ch3), levels(20) { _ in -80 }])
    e.beats["talk"] = BeatAnalysis(mediaId: "talk", tempo: 120, beats: stride(from: 0.0, to: 20, by: 0.5).map { $0 }, downbeats: [], onsets: [], energy: [])
    e.audio["broll"] = AudioAnalysis(mediaId: "broll", levelRate: 10, levels: levels(20) { _ in -80 }, silences: [TimeRange(0, 20)], silenceThresholdDb: -50, loudnessDb: -80)
    return (p, e)
}

@Test func rolesComeFromWhatEachChannelCarries() throws {
    let (p, e) = try interview()
    let r = p.inferRoles(e)
    #expect(r.tracks["A1"]?.mainRole == "dialogue" && r.tracks["A2"]?.mainRole == "dialogue", "\(r.lines(p))")
    #expect(r.tracks["A2"]?.why.hasPrefix("speech ") == true && (r.tracks["A2"]?.speechFraction ?? 0) > 0.6, "\(r.tracks["A2"]!)")
    #expect(r.tracks["A3"]?.mainRole == "music", "the bed sounds through the words, so they aren't its: \(r.tracks["A3"]!)")
    #expect(r.tracks["A4"]?.role == nil && r.tracks["A4"]?.basis == .silent, "\(r.tracks["A4"]!)")
    #expect(r.tracks["V2"]?.role == nil && r.tracks["V2"]?.basis == .silent, "silent b-roll has no role: \(r.tracks["V2"]!)")
    let fill = p.tracks.last!
    #expect(fill.clips.allSatisfy { $0.role == Project.roomToneRole })
    #expect(r.tracks[fill.id]?.mainRole == "dialogue", "room tone is dialogue: \(r.tracks[fill.id]!)")

    #expect(r.isSpeech("ch2", track: "A2") && !r.isSpeech("ch3", track: "A3") && !r.isSpeech("ch4", track: "A4"))
    let speech = r.speechRanges(p)
    #expect(!speech.isEmpty && speech.allSatisfy { s in spoken.contains { $0.start <= s.start + 0.01 && s.end <= $0.end + 0.01 } }, "\(speech)")

    let lines = r.lines(p) { Project.dmeBus($0) }
    #expect(lines.contains { $0.hasPrefix("A2 \"Interview ch2\" → DIA: speech ") }, "\(lines)")
    #expect(lines.contains { $0.hasPrefix("V2 \"Cutaways\": no role, silent") }, "\(lines)")
}

@Test func dmeBusesFollowTheEvidenceAndLeaveSilenceAlone() throws {
    let (start, e) = try interview()
    var p = start
    let r = p.inferRoles(e)
    let lines = p.applyDMEBuses(roles: r.trackRoles, reasons: r.tracks.mapValues(\.why))
    let out = Dictionary(uniqueKeysWithValues: p.tracks.map { ($0.id, $0.output ?? "master") })
    #expect(out["A1"] == "DIA" && out["A2"] == "DIA" && out["A3"] == "MUS", "\(out)")
    #expect(out["A4"] == "master" && out["V2"] == "master", "silent tracks route nowhere: \(out)")
    #expect(out[p.tracks.last!.id] == "DIA", "room tone goes with dialogue")
    #expect(lines.contains { $0.hasPrefix("A2 \"Interview ch2\" → DIA: speech ") }, "\(lines)")

    p.tracks[p.trackIndex("A3")!].role = "dialogue"
    let set = p.inferRoles(e)
    #expect(set.tracks["A3"]?.basis == .explicit && set.isSpeech("ch3", track: "A3"), "a role set on the track wins")
}

@Test func roomToneStaysInTheDialogueStem() throws {
    let (p, e) = try interview()
    let roles = p.inferRoles(e).stemRoles
    let used = p.audioRoles(roles)
    let fill = p.tracks.last!.id
    #expect(used["dialogue"]?.contains(fill) == true && used["effects"] == nil && used["dialogue.room tone"] == nil, "\(used)")
    let dx = p.keepingRoles(roles) { $0 == "dialogue" }
    #expect(dx.tracks.last!.clips.allSatisfy { $0.volume == 1 } && !dx.tracks.last!.muted)
}

@Test func trackRoleIsTheMajorityOfItsClips() {
    var p = Project(name: "Mix")
    p.media = ["a", "b", "song"].map { MediaAsset(id: $0, path: "/tmp/\($0).wav", name: $0, duration: 20, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true) }
    p.tracks = [Track(id: "A1", kind: .audio, name: "A1", clips: [
        Clip(id: "x", kind: .media, mediaId: "a", start: 0, duration: 15),
        Clip(id: "y", kind: .media, mediaId: "b", start: 15, duration: 10),
        Clip(id: "z", kind: .media, mediaId: "song", start: 25, duration: 4),
    ])]
    var e = SoundEvidence(transcripts: ["a": words("a", in: spoken), "b": words("b", in: spoken), "song": words("song", in: [TimeRange(0, 12)])])
    for id in ["a", "b", "song"] { e.audio[id] = AudioAnalysis(mediaId: id, levelRate: 10, levels: levels(20) { _ in -20 }, silences: [], silenceThresholdDb: -50, loudnessDb: -20) }
    e.sounds["song"] = SoundEvents(mediaId: "song", events: [SoundEvent(label: "music", start: 0, end: 20, confidence: 0.9)])
    let r = p.inferRoles(e)
    #expect(r.clips["z"]?.mainRole == "music", "sung words over music are music: \(r.clips["z"]!)")
    #expect(r.tracks["A1"]?.mainRole == "dialogue" && r.tracks["A1"]?.why.contains("2 of 3 clips") == true, "\(r.tracks["A1"]!)")
}

@Test func unanalyzedTracksFallBackToTheirNameOrNothing() {
    var p = Project(name: "Mix")
    p.media = [MediaAsset(id: "m", path: "/tmp/m.wav", name: "m", duration: 10, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)]
    p.tracks = [
        Track(id: "A1", kind: .audio, name: "Score", clips: [Clip(id: "s", kind: .media, mediaId: "m", start: 0, duration: 4)]),
        Track(id: "A2", kind: .audio, name: "A2", clips: [Clip(id: "u", kind: .media, mediaId: "m", start: 0, duration: 4)]),
    ]
    let r = p.inferRoles(SoundEvidence())
    #expect(r.tracks["A1"]?.basis == .name && r.tracks["A1"]?.mainRole == "music")
    #expect(r.tracks["A2"]?.role == nil && r.tracks["A2"]?.basis == .unknown)
    #expect(r.stemRoles["A2"] == "effects", "unknown sound still lands in a stem")
    var q = p
    #expect(q.applyDMEBuses(roles: r.trackRoles).contains { $0.hasPrefix("A1 \"Score\" → MUS") })
    #expect(q.tracks[1].output == nil, "a track with no role isn't routed")
}
