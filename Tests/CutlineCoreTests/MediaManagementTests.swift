import Foundation
import Testing
@testable import CutlineCore

private func near(_ a: [TimeRange]?, _ b: [TimeRange]) -> Bool {
    guard let a, a.count == b.count else { return false }
    return zip(a, b).allSatisfy { abs($0.start - $1.start) < 1e-6 && abs($0.end - $1.end) < 1e-6 }
}

private func usageProject() -> Project {
    var p = Project(name: "Usage")
    p.media = [
        MediaAsset(id: "a", path: "/media/a.mov", name: "A", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true),
        MediaAsset(id: "b", path: "/media/b.mov", name: "B", duration: 20, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: false),
        MediaAsset(id: "img", path: "/media/logo.png", name: "Logo", duration: 0, width: 512, height: 512, fps: 0, hasVideo: true, hasAudio: false, isImage: true),
        MediaAsset(id: "unused", path: "/media/u.mov", name: "U", duration: 5, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true),
    ]
    var c3 = Clip(id: "c3", kind: .media, mediaId: "a", start: 4, duration: 1, sourceIn: 8)
    c3.audioLag = 0.5
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 2, sourceIn: 1),
        Clip(id: "c2", kind: .media, mediaId: "a", start: 2, duration: 2, sourceIn: 3.5),
        c3,
        Clip(id: "fast", kind: .media, mediaId: "b", start: 5, duration: 1, sourceIn: 2, speed: 2),
        Clip(id: "seqclip", kind: .sequence, mediaId: "seq", start: 6, duration: 2, sourceIn: 1),
    ]
    p.tracks.append(Track(id: "V2", kind: .video, name: "Over", clips: [Clip(id: "logo", kind: .media, mediaId: "img", start: 0, duration: 3)]))
    p.transitions = [Transition(id: "tr1", from: "c1", to: "c2", type: "dissolve", duration: 1, part: .video)]
    p.sequences = [NestedSequence(id: "seq", name: "Nest", tracks: [
        Track(id: "V1", kind: .video, name: "Main", clips: [Clip(id: "inner", kind: .media, mediaId: "b", start: 0, duration: 4, sourceIn: 10)]),
    ])]
    return p
}

@Test func usedSourceRangesMergeAndIncludeHandles() {
    let p = usageProject()
    let used = p.usedSourceRanges(handles: 0)
    // c1 1–3 + 0.5 s tail, c2 3.5–5.5 − 0.5 s head merge; c3 runs 8–9 with 0.5 s of audio lag.
    #expect(near(used["a"], [TimeRange(1, 5.5), TimeRange(8, 9.5)]), "\(used["a"] ?? [])")
    // Double speed reads 2–4; the sequence clip shows inner 1–3 of a clip starting at source 10.
    #expect(near(used["b"], [TimeRange(2, 4), TimeRange(11, 13)]), "\(used["b"] ?? [])")
    #expect(used["img"] == nil && used["unused"] == nil)

    let padded = p.usedSourceRanges(handles: 1.5)
    #expect(near(padded["a"], [TimeRange(0, 10)]), "\(padded["a"] ?? [])")
    #expect(near(padded["b"], [TimeRange(0.5, 5.5), TimeRange(9.5, 14.5)]), "\(padded["b"] ?? [])")
}

@Test func usedSourceRangesFollowAudioTransitions() {
    var p = usageProject()
    p.transitions = [Transition(id: "tr1", from: "c1", to: "c2", type: "dissolve", duration: 1, part: .audio)]
    #expect(near(p.usedSourceRanges(handles: 0)["a"], [TimeRange(1, 5.5), TimeRange(8, 9.5)]))
    p.transitions = []
    #expect(near(p.usedSourceRanges(handles: 0)["a"], [TimeRange(1, 3), TimeRange(3.5, 5.5), TimeRange(8, 9.5)]))
}

@Test func relinkAllFindsMovedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let shoot = root.appendingPathComponent("Shoot/Day1"), other = root.appendingPathComponent("Other/Day1")
    for dir in [shoot, other, root.appendingPathComponent("Renders")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    for f in [shoot.appendingPathComponent("a.mov"), other.appendingPathComponent("a.mov"), root.appendingPathComponent("Renders/b.mp4"), root.appendingPathComponent("Renders/logo.mov")] {
        try Data([0]).write(to: f)
    }
    var p = usageProject()
    p.media[0].path = "/Volumes/Gone/Shoot/Day1/a.mov"
    p.media[3].path = root.appendingPathComponent("Renders/b.mp4").path
    let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
    #expect(p.missingMedia(exists: exists).map(\.id) == ["a", "b", "img"])

    let relinked = p.relinkAll(searchRoots: [root], fileExists: exists)
    let byId = Dictionary(uniqueKeysWithValues: relinked)
    #expect(byId["a"]?.hasSuffix("Shoot/Day1/a.mov") == true, "\(byId)")
    #expect(byId["b"]?.hasSuffix("Renders/b.mp4") == true)
    // A movie never stands in for a still with the same name.
    #expect(byId["img"] == nil)
    #expect(p.mediaAsset("a")?.path == byId["a"])
    #expect(p.missingMedia(exists: exists).map(\.id) == ["img"])
    #expect(p.relink(mediaId: "img", to: "/x/logo.png") && !p.relink(mediaId: "nope", to: "/x"))
}

@Test func consolidatePlanTrimsAndRemapsClips() throws {
    let p = usageProject()
    let plan = ConsolidatePlan(p, trim: true, handles: 0.5)
    #expect(plan.items.map(\.newId) == ["a_t1", "a_t2", "b_t1", "b_t2", "img"])
    #expect(plan.items.first { $0.newId == "img" }?.range == nil)
    // The whole nested clip (source 10–14) is kept so the sequence stays valid.
    #expect(plan.items.first { $0.newId == "b_t2" }?.range == TimeRange(9.5, 14.5))
    #expect(Set(plan.items.map(\.fileName)).count == plan.items.count)

    let out = plan.apply(to: p, directory: URL(fileURLWithPath: "/out"))
    #expect(out.mediaAsset("unused") == nil && out.mediaAsset("a") == nil)
    #expect(out.mediaAsset("a_t1")?.path == "/out/a_t1.mov" && out.mediaAsset("a_t1")?.duration == 5.5)
    let c2 = try #require(out.clip("c2")), c3 = try #require(out.clip("c3"))
    #expect(c2.mediaId == "a_t1" && abs(c2.sourceIn - 3.0) < 1e-9)
    #expect(c3.mediaId == "a_t2" && abs(c3.sourceIn - 0.5) < 1e-9)
    #expect(out.sequences[0].tracks[0].clips[0].mediaId == "b_t2" && abs(out.sequences[0].tracks[0].clips[0].sourceIn - 0.5) < 1e-9)
    #expect(out.clip("logo")?.mediaId == "img")
    try out.validate()
    #expect(plan.locate(mediaId: "a", time: 8.25).map { "\($0.mediaId)@\($0.time)" } == "a_t2@0.75")

    let whole = ConsolidatePlan(p, trim: false, handles: 0)
    #expect(whole.items.count == 4 && whole.items.allSatisfy { $0.range == nil && $0.newId == $0.mediaId })
    #expect(whole.apply(to: p, directory: URL(fileURLWithPath: "/out")).clip("c2")?.sourceIn == 3.5)
}
