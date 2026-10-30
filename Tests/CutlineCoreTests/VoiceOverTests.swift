import Foundation
import Testing
@testable import CutlineCore

private func take(_ n: Int = 1, start: Seconds = 10.01, duration: Seconds = 3, sourceIn: Seconds = 2.004, warnings: [String] = []) -> VoiceOverTake {
    VoiceOverTake(take: n, file: "/tmp/vo1-take\(n).wav", start: start, duration: duration, sourceIn: sourceIn, fileDuration: sourceIn + duration + 0.5,
                  sampleRate: 48_000, device: "Test", inputLatency: 0.01, levels: RecordingLevels(peakDB: -6, rmsDB: -24, clippedSamples: 0, warnings: warnings))
}

private func project() -> Project {
    var p = Project(name: "VO")
    p.media = [1, 2].map { MediaAsset(id: "vo1-take\($0)", path: "/tmp/vo1-take\($0).wav", name: "vo1 take \($0)", duration: 5.6, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true) }
    return p
}

@Test func inputLatencyIsTakenOutOfTheTimelineTime() {
    // A sample stamped 1.25 s after the program rolled from 8 s, by an input 30 ms late, was heard at 9.22.
    let t = VoiceOver.timelineTime(host: 101.25, inputLatency: 0.03, anchorHost: 100, anchorTimeline: 8)
    #expect(abs(t - 9.22) < 1e-9)
}

@Test func takeSpanKeepsHandlesAndFindsTheLine() throws {
    let r = VoiceOverRequest(id: "vo1", start: 10, end: 13, preroll: 2, postroll: 0.5)
    #expect(r.rollFrom == 8)
    // Capture began during the countdown, a second before the roll.
    let full = try #require(VoiceOver.takeSpan(firstSample: 7, captured: 7, request: r))
    #expect(abs(full.keepFrom - 1) < 1e-9 && abs(full.keepTo - 6.5) < 1e-9)
    #expect(full.start == 10 && abs(full.duration - 3) < 1e-9)
    // Stopped a second into the line.
    let short = try #require(VoiceOver.takeSpan(firstSample: 7, captured: 7, request: r, stoppedAt: 11))
    #expect(abs(short.duration - 1) < 1e-9 && abs(short.keepTo - 4) < 1e-9)
    // Capture that only began inside the line starts the take there.
    let late = try #require(VoiceOver.takeSpan(firstSample: 10.5, captured: 4, request: r))
    #expect(late.start == 10.5 && late.keepFrom == 0 && abs(late.duration - 2.5) < 1e-9)
    // Stopped before the line: nothing to keep.
    #expect(VoiceOver.takeSpan(firstSample: 7, captured: 7, request: r, stoppedAt: 9.5) == nil)
    // Preroll before the timeline's start is cut to it.
    #expect(VoiceOverRequest(id: "vo2", start: 1, end: 2, preroll: 3).rollFrom == 0)
}

@Test func levelsWarnAboutClippingQuietAndMissingSignal() {
    let healthy = (0..<48_000).map { Float(0.3 * sin(Double($0) * 0.05)) }
    let ok = RecordingLevels.measure(healthy[...])
    #expect(ok.warnings.isEmpty && abs(ok.peakDB - 20 * log10(0.3)) < 0.1 && !ok.clipped)
    #expect(abs(ok.rmsDB - 20 * log10(0.3 / 2.0.squareRoot())) < 0.2)

    var hot = healthy.map { $0 * 3.5 }
    hot = hot.map { min(1, max(-1, $0)) }
    let clipped = RecordingLevels.measure(hot[...])
    #expect(clipped.clipped && clipped.warnings.first?.hasPrefix("clipping") == true)

    let quiet = RecordingLevels.measure(healthy.map { $0 * 0.02 }[...])
    #expect(quiet.warnings.contains { $0.hasPrefix("too quiet") }, "\(quiet)")

    let silent = RecordingLevels.measure([Float](repeating: 0, count: 1000)[...])
    #expect(silent.peakDB == -120 && silent.warnings.contains { $0.hasPrefix("no signal") })
}

@Test func voiceOverIsPlacedOnTheFrameWithTheSourceMovedToMatch() throws {
    var p = project()
    let t = take()
    let (clip, track) = try p.placeVoiceOver(t, mediaId: "vo1-take1", track: nil, sessionId: "vo1")
    // 10.01 s is not on the 30 fps grid; the nearest frame is 10.0, so the source starts 10 ms earlier too.
    #expect(clip.start == 10 && abs(clip.sourceIn - 1.994) < 1e-9 && abs(clip.duration - 3) < 1e-9)
    let made = try #require(p.tracks.first { $0.id == track })
    #expect(made.kind == .audio && made.name == VoiceOver.trackName && made.role == "dialogue")
    // The timeline time of any source instant is unchanged by the snap.
    #expect(abs((clip.start - clip.sourceIn) - (t.start - t.sourceIn)) < 1e-9)

    // A later line reuses the Voice-over track; an overlapping one gets a new track; "new" always does.
    let later = try p.placeVoiceOver(take(2, start: 20), mediaId: "vo1-take2", track: nil, sessionId: "vo1")
    #expect(later.track == track)
    let overlapping = try p.placeVoiceOver(take(1, start: 11), mediaId: "vo1-take1", track: nil, sessionId: "vo1")
    #expect(overlapping.track != track)
    let fresh = try p.placeVoiceOver(take(1, start: 40), mediaId: "vo1-take1", track: "new", sessionId: "vo1")
    #expect(fresh.track != track && fresh.track != overlapping.track)
    // An explicit busy track refuses rather than overwriting.
    #expect(throws: EditError.self) { try p.placeVoiceOver(take(1, start: 10.5), mediaId: "vo1-take1", track: track, sessionId: "vo1") }
    try p.validate()
}

@Test func takesAreTaggedAsPlacedOrAlternate() throws {
    var p = project()
    p.tagVoiceOver(take(1), mediaId: "vo1-take1", sessionId: "vo1", placed: false)
    p.tagVoiceOver(take(2, warnings: ["too quiet"]), mediaId: "vo1-take2", sessionId: "vo1", placed: true)
    let a = try #require(p.mediaAsset("vo1-take1")), b = try #require(p.mediaAsset("vo1-take2"))
    #expect(a.metadata?["take"] == "1" && a.metadata?["scene"] == "vo1" && a.metadata?["source_in"] == "2.0040")
    #expect(a.tags?.map(\.label) == ["vo1 take 1 (alternate)"] && b.tags?.map(\.label) == ["vo1 take 2 (placed)"])
    #expect(abs((a.tags?.first?.start ?? 0) - 2.004) < 1e-9 && b.metadata?["levels"] == "too quiet" && a.bin == "Voice-over")
    // Tagging again replaces the session's tag.
    p.tagVoiceOver(take(1), mediaId: "vo1-take1", sessionId: "vo1", placed: true)
    #expect(p.mediaAsset("vo1-take1")?.tags?.map(\.label) == ["vo1 take 1 (placed)"])
}

@Test func preferredTakeIsTheLastCleanOne() {
    let takes = [take(1), take(2), take(3, warnings: ["clipping"])]
    #expect(VoiceOver.preferredTake(takes)?.take == 2)
    #expect(VoiceOver.preferredTake([take(1, warnings: ["x"]), take(2, warnings: ["y"])])?.take == 2)
    #expect(VoiceOver.preferredTake([]) == nil)
}

@Test func requestAndResultRoundTripAndIdsCount() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vo-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(VoiceOver.nextId(in: dir) == "vo1")
    let r = VoiceOverRequest(id: "vo1", start: 1, end: 2, script: "Hello", testInput: "/tmp/x.wav")
    try VoiceOver.write(r, to: VoiceOver.requestURL(dir.appendingPathComponent("vo1")))
    #expect(VoiceOver.read(VoiceOverRequest.self, from: VoiceOver.requestURL(dir.appendingPathComponent("vo1"))) == r)
    #expect(VoiceOver.nextId(in: dir) == "vo2")
    let result = VoiceOverResult(id: "vo1", status: .done, takes: [take()], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    try VoiceOver.write(result, to: VoiceOver.resultURL(dir))
    #expect(VoiceOver.read(VoiceOverResult.self, from: VoiceOver.resultURL(dir)) == result)
    #expect(VoiceOver.takeURL(dir, id: "vo1", take: 2).lastPathComponent == "vo1-take2.wav")
}
