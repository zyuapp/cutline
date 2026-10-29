import Foundation
import Testing
@testable import CutlineCore

private func makeProject() -> Project {
    var p = Project(name: "Test")
    p.media = [
        MediaAsset(id: "m1", path: "/tmp/a.mov", name: "a", duration: 20, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true),
        MediaAsset(id: "m2", path: "/tmp/b.mov", name: "b", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: false),
    ]
    return p
}

private func mediaClip(_ media: String, start: Seconds, sourceIn: Seconds, duration: Seconds) -> Clip {
    Clip(id: Project.newClipId(), kind: .media, mediaId: media, start: start, duration: duration, sourceIn: sourceIn)
}

@Test func appendPlacesClipsEndToEnd() throws {
    var p = makeProject()
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 5), trackId: "V1", mode: .append)
    let b = try p.addClip(mediaClip("m1", start: 0, sourceIn: 10, duration: 3), trackId: "V1", mode: .append)
    #expect(b.start == 5)
    #expect(p.duration == 8)
}

@Test func overlapIsRejected() throws {
    var p = makeProject()
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 5), trackId: "V1", mode: .append)
    var moved = p.tracks[0].clips[0]
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 5), trackId: "V1", mode: .append)
    moved.duration = 7
    #expect(throws: EditError.self) { try p.replaceClip(moved) }
}

@Test func overwriteSplitsUnderlyingClip() throws {
    var p = makeProject()
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 10), trackId: "V1", mode: .append)
    try p.addClip(mediaClip("m2", start: 4, sourceIn: 0, duration: 2), trackId: "V1", mode: .overwrite)
    let clips = p.tracks[0].clips
    #expect(clips.count == 3)
    #expect(clips[0].end == 4)
    #expect(clips[2].start == 6)
    #expect(clips[2].sourceIn == 6)
}

@Test func insertRipplesAllTracks() throws {
    var p = makeProject()
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 10), trackId: "V1", mode: .append)
    try p.addClip(mediaClip("m1", start: 6, sourceIn: 0, duration: 2), trackId: "A1", mode: .overwrite)
    try p.addClip(mediaClip("m2", start: 5, sourceIn: 0, duration: 3), trackId: "V1", mode: .insert)
    #expect(p.tracks[0].clips.map(\.start) == [0, 5, 8])
    #expect(p.tracks[1].clips[0].start == 9)
    #expect(p.duration == 13)
}

@Test func deleteRangeRipplesAndSplits() throws {
    var p = makeProject()
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 10), trackId: "V1", mode: .append)
    p.deleteRange(TimeRange(2, 3), ripple: true)
    let clips = p.tracks[0].clips
    #expect(clips.count == 2)
    #expect(clips[0].duration == 2)
    #expect(clips[1].start == 2)
    #expect(clips[1].sourceIn == 3)
    #expect(p.duration == 9)
}

@Test func cutSourceRangesFollowsEarlierEdits() throws {
    var p = makeProject()
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 4), trackId: "V1", mode: .append)
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 8, duration: 6), trackId: "V1", mode: .append)
    let removed = p.cutSourceRanges(mediaId: "m1", ranges: [TimeRange(1, 2), TimeRange(9, 10)])
    #expect(removed == [TimeRange(1, 2), TimeRange(5, 6)])
    #expect(p.duration == 8)
    #expect(p.tracks[0].clips.map(\.sourceIn) == [0, 2, 8, 10])
}

@Test func speedChangeWithRipple() throws {
    var p = makeProject()
    var a = try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 4), trackId: "V1", mode: .append)
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 10, duration: 2), trackId: "V1", mode: .append)
    a.speed = 2
    a.duration = 2
    #expect(throws: Never.self) { try p.replaceClip(a, ripple: true) }
    #expect(p.tracks[0].clips[1].start == 2)
    #expect(p.tracks[0].clips[0].sourceOut == 4)
}

@Test func sourceBoundsAreValidated() {
    var p = makeProject()
    #expect(throws: EditError.self) {
        try p.addClip(mediaClip("m2", start: 0, sourceIn: 8, duration: 5), trackId: "V1", mode: .append)
    }
}

@Test func captionsFollowCuts() throws {
    var p = makeProject()
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 10), trackId: "V1", mode: .append)
    let words = ["Hello", "um", "world.", "This", "is", "Cutline."].enumerated().map { i, w in
        Word(text: w, start: Double(i), end: Double(i) + 0.8)
    }
    let transcripts = ["m1": Transcript(mediaId: "m1", locale: "en", words: words)]
    p.cutSourceRanges(mediaId: "m1", ranges: [TimeRange(1, 2)])
    let tw = p.timelineWords(transcripts: transcripts)
    #expect(tw.map(\.text) == ["Hello", "world.", "This", "is", "Cutline."])
    #expect(tw[1].start == 1)
    p.captions.replacements = ["cutline": "CUTLINE"]
    let segs = p.captionSegments(transcripts: transcripts)
    #expect(segs.count == 2)
    #expect(segs[1].words.last?.text == "CUTLINE.")
}

@Test func keyframesInterpolate() {
    var c = Clip(id: "c", kind: .solid, start: 0, duration: 4, fadeIn: 1)
    c.keyframes = [Keyframe(time: 0, scale: 1, easing: .linear), Keyframe(time: 2, scale: 2, easing: .linear)]
    let mid = c.resolvedTransform(at: 1)
    #expect(abs(mid.scale - 1.5) < 1e-9)
    #expect(abs(mid.opacity - 1) < 1e-9)
    #expect(abs(c.resolvedTransform(at: 0.5).opacity - 0.5) < 1e-9)
    #expect(c.resolvedTransform(at: 3).scale == 2)
}

@Test func bundleHistoryUndoRedo() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).cutline")
    defer { try? FileManager.default.removeItem(at: url) }
    var p = makeProject()
    let bundle = try ProjectBundle.create(at: url, project: p)
    try p.addClip(mediaClip("m1", start: 0, sourceIn: 0, duration: 4), trackId: "V1", mode: .append)
    try bundle.commit(p, label: "Add clip")
    #expect(try bundle.loadProject().duration == 4)
    let (undone, entry) = try bundle.undo()
    #expect(entry.label == "Add clip")
    #expect(undone.duration == 0)
    #expect(try bundle.redo().0.duration == 4)
    try bundle.updateComments { $0.comments.append(Comment(time: 1, text: "Tighten", author: .human)) }
    #expect(bundle.loadComments().comments.count == 1)
}

@Test func colorHexRoundTrip() throws {
    let c = RGBA(hex: "#FF8800CC")!
    #expect(c.hex == "#FF8800CC")
    let data = try JSONEncoder().encode(c)
    #expect(try JSONDecoder().decode(RGBA.self, from: data) == c)
}

@Test func silenceDetection() {
    let levels: [Float] = Array(repeating: -20, count: 50) + Array(repeating: -70, count: 60) + Array(repeating: -20, count: 10)
    let s = AudioAnalysis.detectSilences(levels: levels, rate: 100, thresholdDb: -45, minDuration: 0.4)
    #expect(s == [TimeRange(0.5, 1.1)])
}
