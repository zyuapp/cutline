import Foundation
import Testing
@testable import CutlineCore

private func words(_ spans: [(String, Seconds, Seconds)]) -> Transcript {
    Transcript(mediaId: "m", locale: "en-US", words: spans.map { Word(text: $0.0, start: $0.1, end: $0.2) })
}

@Test func assembleHandlesStopAtNeighbouringWordsAndNeverShaveTheLastWord() {
    let t = words([("one", 19.2, 19.6), ("two", 20.0, 20.4), ("w12", 23.9, 24.18), ("next", 24.25, 24.6)])
    // Cut exactly at the word edges, no handles: the frame rounding still keeps all of w12 (24.18 isn't on a 25 fps frame).
    let bare = SourceSegment(mediaId: "m", sourceIn: 20.0, sourceOut: 24.18).withHandles(t, before: 0, after: 0, fps: 25, duration: 60)
    #expect(bare.sourceIn == 20 && bare.sourceOut >= 24.18 - 1e-9 && bare.sourceOut <= 24.25 + 1e-9, "\(bare)")
    let frames = (bare.sourceOut - bare.sourceIn) * 25
    #expect(abs(frames - frames.rounded()) < 1e-6)

    // Default handles: 0.08 before, 0.12 after, clamped to the neighbours' edges.
    let padded = SourceSegment(mediaId: "m", sourceIn: 20.0, sourceOut: 24.18).withHandles(t, before: 0.08, after: 0.12, fps: 25, duration: 60)
    #expect(abs(padded.sourceIn - 19.92) < 1e-9, "\(padded)")
    #expect(padded.sourceOut >= 24.18 - 1e-9 && padded.sourceOut <= 24.25 + 1e-9, "stops at the next word: \(padded)")

    // A wider cut than the handles is kept; a segment without words is untouched.
    let wide = SourceSegment(mediaId: "m", sourceIn: 19.7, sourceOut: 20.4).withHandles(t, before: 0.08, after: 0.12, fps: 25, duration: 60)
    #expect(abs(wide.sourceIn - 19.7) < 1e-9 && wide.sourceOut >= 20.52 - 1e-9)
    let empty = SourceSegment(mediaId: "m", sourceIn: 30, sourceOut: 31)
    #expect(empty.withHandles(t, before: 0.08, after: 0.12, fps: 25, duration: 60) == empty)
}

@Test func speechPausesComeFromWordGapsAcrossFillers() {
    let t = words([("so", 0, 0.4), ("um", 0.7, 0.9), ("then", 1.2, 1.5), ("we", 3.0, 3.2)])
    #expect(t.pauses(atLeast: 0.5) == [TimeRange(1.5, 3.0)])
    #expect(t.pauses(atLeast: 0.5, skippingFillers: true) == [TimeRange(0.4, 1.2), TimeRange(1.5, 3.0)])
}

@Test func beatCutNeverRepeatsAMomentUntilEveryMomentIsUsed() {
    // One short clip and one long one: the short clip's only moment must not come back while the long one has fresh time.
    let footage = [
        BeatFootage(mediaId: "fractal", range: TimeRange(3.5, 4.5), quality: 1, energy: nil),
        BeatFootage(mediaId: "long", range: TimeRange(0, 11), quality: 0, energy: nil),
    ]
    // 12 one-second moments exist (1 + 11), so nothing repeats.
    let plan = BeatCutPlan.choose(footage, segments: Array(repeating: .init(need: 1, energy: nil), count: 12))
    var shown: [String: [TimeRange]] = [:]
    for (i, pick) in plan.picks.enumerated() {
        guard let p = pick else { Issue.record("shot \(i) has no footage"); continue }
        let r = TimeRange(p.sourceIn, p.sourceIn + 1), id = footage[p.footage].mediaId
        #expect(!(shown[id] ?? []).contains { $0.start < r.end - 1e-6 && r.start < $0.end - 1e-6 }, "shot \(i) repeats \(id) \(r)")
        shown[id, default: []].append(r)
    }
    #expect(plan.repeats == 0 && plan.reused.isEmpty)
    // A 13th shot reuses the moment shown longest ago: the first shot's.
    let more = BeatCutPlan.choose(footage, segments: Array(repeating: .init(need: 1, energy: nil), count: 13))
    #expect(more.repeats == 1 && more.reused.count == 1)
    if let first = more.picks[0], let again = more.reused.first {
        #expect(again.footage == first.footage && abs(again.sourceIn - first.sourceIn) < 1e-9 && again.segment == 12, "\(again)")
    }
}

@Test func offlineMediaRelinksByReelAndTimecodeCoverage() throws {
    var p = Project(name: "Relink", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    var m = MediaAsset(id: "a001", path: "/gone/A001C003.mov", name: "A001C003", duration: 10, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)
    m.reel = "A001"
    m.timecodeStart = 36000
    p.media = [m]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "a001", start: 0, duration: 3, sourceIn: 2)]
    func file(_ path: String, reel: String, tc: Seconds, duration: Seconds) -> MediaAsset {
        var c = MediaAsset(id: "x", path: path, name: path, duration: duration, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)
        c.reel = reel
        c.timecodeStart = tc
        return c
    }
    let short = file("/new/short.mov", reel: "A001", tc: 36001, duration: 3)
    let whole = file("/new/whole.mov", reel: "A001", tc: 36000, duration: 60)
    let other = file("/new/other.mov", reel: "B002", tc: 36000, duration: 60)
    let tight = file("/new/tight.mov", reel: "a001", tc: 36001.5, duration: 4)
    // The clip plays 36002–36005 of A001's day: short misses its end, B002 is another reel, tight is the closest fit.
    #expect(p.reelTimecodeMatch(p.media[0], candidates: [short, whole, other, tight])?.path == "/new/tight.mov")
    #expect(p.reelTimecodeMatch(p.media[0], candidates: [short, other]) == nil)
    var linked = tight
    linked.id = "a001"
    p.replaceMediaKeepingTimecode(linked)
    #expect(abs(p.clip("c")!.sourceIn - 0.5) < 1e-9, "keeps its source timecode")

    let index = RelinkIndex(["/x/a/A001C003.MOV", "/x/b/A001C003.mxf", "/x/c/Other.mov"])
    #expect(index.match(m) == "/x/a/A001C003.MOV")
}

@Test func interlacedMastersNeedA25Or2997Canvas() {
    #expect(FieldOrder.interlacedRateProblem(fps: 25) == nil)
    #expect(FieldOrder.interlacedRateProblem(fps: 30000.0 / 1001) == nil)
    #expect(FieldOrder.interlacedRateProblem(fps: 24)?.contains("48 fields") == true)
    #expect(FieldOrder.interlacedRateProblem(fps: 50)?.contains("1080i50") == true)
    #expect(FieldOrder.interlacedRateProblem(fps: 60000.0 / 1001)?.contains("1080i59.94") == true)
}

@Test func edlAudioChannelsFollowTheRoutedSourceChannel() throws {
    var p = Project(name: "Channels", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    p.media = [
        MediaAsset(id: "pic", path: "/tmp/pic.mov", name: "Pic", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false),
        MediaAsset(id: "poly", path: "/tmp/poly.wav", name: "Poly", duration: 60, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    p.tracks[0].clips = [Clip(id: "v", kind: .media, mediaId: "pic", start: 0, duration: 4)]
    var boom = Clip(id: "boom", kind: .media, mediaId: "poly", start: 0, duration: 4)
    boom.channels = ChannelRouting(rawValue: "ch2")
    var lav = Clip(id: "lav", kind: .media, mediaId: "poly", start: 0, duration: 4, sourceIn: 10)
    lav.channels = ChannelRouting(rawValue: "ch1")
    var ch3 = Clip(id: "c3", kind: .media, mediaId: "poly", start: 4, duration: 2)
    ch3.channels = ChannelRouting(rawValue: "ch3")
    p.tracks[1].clips = [boom, ch3]
    p.tracks.append(Track(id: "A2", kind: .audio, name: "Lav", clips: [lav]))
    let events = p.edl(title: "Routed").split(separator: "\n").filter { $0.first?.isNumber == true }.map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
    // Unrouted, A1's clips would be on A and A2's on A2; routed, each goes on its source channel.
    #expect(events.contains { $0[2] == "A2" && $0[4] == "00:00:00:00" && $0[6] == "01:00:00:00" }, "\(events)")
    #expect(events.contains { $0[2] == "A" && $0[4] == "00:00:10:00" && $0[6] == "01:00:00:00" }, "\(events)")
    let edl = p.edl(title: "Routed")
    #expect(edl.contains("NONE  C        00:00:00:00 00:00:02:00 01:00:04:00 01:00:06:00\nAUD  3"), "\(edl)")
}
