import Foundation
import Testing
@testable import CutlineCore

private func words(_ text: String, from start: Double) -> [Word] {
    text.split(separator: " ").enumerated().map { i, w in Word(text: String(w), start: start + Double(i) * 0.3, end: start + Double(i) * 0.3 + 0.25) }
}

private func media(_ id: String) -> MediaAsset {
    MediaAsset(id: id, path: "/tmp/\(id).mov", name: id, duration: 60, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)
}

// MARK: Caption cues

@Test func captionCueStartsAtACutToAnotherSource() {
    var p = Project(name: "Cues")
    p.media = [media("a"), media("b")]
    // Clip a ends without punctuation and clip b follows without a pause: one cue by the timing rules alone.
    p.tracks[0].clips = [
        Clip(id: "ca", kind: .media, mediaId: "a", start: 0, duration: 1.5),
        Clip(id: "cb", kind: .media, mediaId: "b", start: 1.5, duration: 3, sourceIn: 10),
    ]
    let tr = ["a": Transcript(mediaId: "a", locale: "en", words: words("I want to be awesome", from: 0)),
              "b": Transcript(mediaId: "b", locale: "en", words: words("in Why not", from: 10.05))]
    let cues = p.captionCues(transcripts: tr)
    #expect(cues.map(\.text) == ["I want to be awesome", "in Why not"])

    // A merge edit still joins them.
    var merged = p
    #expect(throws: Never.self) { try merged.mergeCaptionCue(0, transcripts: tr) }
    #expect(merged.captionCues(transcripts: tr).count == 1)

    // The same source across a jump cut keeps flowing into one cue.
    var same = p
    same.tracks[0].clips[1].mediaId = "a"
    same.tracks[0].clips[1].sourceIn = 1.5
    let one = ["a": Transcript(mediaId: "a", locale: "en", words: words("I want to be awesome in Why not", from: 0))]
    #expect(same.captionCues(transcripts: one).count == 1)
}

@Test func captionCueStartsWhenTheSpeakerChanges() {
    var p = Project(name: "Speakers")
    p.media = [media("a")]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "a", start: 0, duration: 10)]
    var t = Transcript(mediaId: "a", locale: "en", words: words("so what do you think I love it", from: 0))
    #expect(p.captionCues(transcripts: ["a": t]).count == 1)
    t.speakers = ["S1", "S1", "S1", "S1", "S1", "S2", "S2", "S2"]
    #expect(p.captionCues(transcripts: ["a": t]).map(\.text) == ["so what do you think", "I love it"])
}

@Test func bundleTranscriptsCarryWordSpeakersWithoutSavingThem() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-speakers-\(UUID().uuidString).cutline")
    defer { try? FileManager.default.removeItem(at: dir) }
    var p = Project(name: "S")
    p.media = [media("a")]
    let b = try ProjectBundle.create(at: dir, project: p)
    try b.saveTranscript(Transcript(mediaId: "a", locale: "en", words: words("hi there", from: 0)))
    #expect(b.transcript("a")?.speakers == nil)
    try b.saveAnalysis(SpeakerAnalysis(mediaId: "a", speakers: ["S1", "S2"], segments: [], wordSpeakers: ["S1", "S2"], emphasis: [0, 0]), "a", "speakers")
    let t = try #require(b.transcript("a"))
    #expect(t.speakers == ["S1", "S2"])
    try b.saveTranscript(t)
    let raw = try String(contentsOf: dir.appendingPathComponent("analysis/a.transcript.json"), encoding: .utf8)
    #expect(!raw.contains("speakers"))
}

// MARK: Quality checks

@Test func midWordWarningsOnlyCheckDialogueTracks() {
    var p = Project(name: "Q")
    p.media = [media("talk")]
    let tr = ["talk": Transcript(mediaId: "talk", locale: "en", words: [Word(text: "hello", start: 0.9, end: 1.3), Word(text: "world", start: 1.4, end: 1.9)])]
    p.tracks[0].clips = [Clip(id: "v", kind: .media, mediaId: "talk", start: 0, duration: 1.1)]
    p.tracks[1].clips = [Clip(id: "dial", kind: .media, mediaId: "talk", start: 0, duration: 1.1)]
    p.tracks[1].role = "dialogue"
    p.tracks.append(Track(id: "A2", kind: .audio, name: "Room tone", clips: [Clip(id: "tone", kind: .media, mediaId: "talk", start: 0, duration: 1.1)]))
    let issues = p.qualityIssues(transcripts: tr).filter { $0.contains("middle of") }
    #expect(issues.count == 1 && issues[0].hasPrefix("dial "), "\(issues)")

    // A channel other than the one transcribed isn't checked.
    p.tracks[1].role = nil
    p.tracks[1].name = "Interview"
    p.tracks[2].clips = []
    #expect(p.qualityIssues(transcripts: tr).contains { $0.hasPrefix("dial ") && $0.contains("middle of") })
    p.media[0].analysisChannel = ChannelRouting(rawValue: "ch1")
    p.media[0].audioChannels = (1...4).map { SourceChannel(track: $0, channel: 1) }
    p.tracks[1].clips[0].channels = ChannelRouting(rawValue: "ch3")
    #expect(!p.qualityIssues(transcripts: tr).contains { $0.hasPrefix("dial ") && $0.contains("middle of") })
}

// MARK: Picture

@Test func graphicsGeneratorsAreNotThePicture() {
    var p = Project(name: "Layers")
    p.media = [media("cam")]
    p.tracks[0].clips = [Clip(id: "shot", kind: .media, mediaId: "cam", start: 0, duration: 10)]
    var lower = Clip(id: "lt", kind: .generator, start: 0, duration: 10)
    lower.effects = [Effect(id: "gen", type: "lower_third")]
    var wash = Clip(id: "grad", kind: .generator, start: 5, duration: 5)
    wash.effects = [Effect(id: "gen", type: "gradient")]
    p.tracks.append(Track(id: "V3", kind: .video, name: "Graphics", clips: [lower]))
    p.tracks.append(Track(id: "V4", kind: .video, name: "Wash", clips: [wash]))
    #expect(p.mainPicture(at: 2)?.id == "shot")
    #expect(p.pictureLayers(at: 2).map(\.clip.id) == ["shot"])
    #expect(p.mainPicture(at: 7)?.id == "grad")
}

// MARK: Source channels

@Test func channelSummaryDescribesTheOriginalLayout() {
    var m = media("mxf")
    m.audioChannels = [
        SourceChannel(track: 1, channel: 1, originalTrack: 1), SourceChannel(track: 1, channel: 2, originalTrack: 2),
        SourceChannel(track: 2, channel: 1, originalTrack: 3), SourceChannel(track: 3, channel: 1, originalTrack: 4),
    ]
    #expect(m.channelSummary == "4 source channels in 4 mono tracks: ch1–ch4 (the mezzanine carries ch1+ch2 as one stereo track; channel numbers are the same)")
    m.audioChannels = [SourceChannel(track: 1, channel: 1), SourceChannel(track: 1, channel: 2), SourceChannel(track: 2, channel: 1)]
    #expect(m.channelSummary == "3 source channels in 2 tracks (ch1+ch2, ch3): ch1–ch3")
    m.audioChannels = (1...6).map { SourceChannel(track: 1, channel: $0, name: $0 == 1 ? "Boom" : nil) }
    #expect(m.channelSummary == "6 source channels in 1 track: ch1 \"Boom\", ch2, ch3, ch4, ch5, ch6")
}
