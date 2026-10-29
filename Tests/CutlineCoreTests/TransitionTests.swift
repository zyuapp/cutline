import Foundation
import Testing
@testable import CutlineCore

private func cutProject() -> Project {
    var p = Project(name: "T")
    p.media = [MediaAsset(id: "m", path: "/tmp/t.mov", name: "M", duration: 20, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 4, sourceIn: 2),
        Clip(id: "b", kind: .media, mediaId: "m", start: 4, duration: 4, sourceIn: 10),
    ]
    return p
}

@Test func transitionWindowsFollowAlignment() throws {
    let p = cutProject()
    let center = try p.window(Transition(id: "t", from: "a", to: "b", type: "dissolve", duration: 1))
    #expect(center.start == 3.5 && center.end == 4.5 && center.tail == 0.5 && center.head == 0.5)
    let start = try p.window(Transition(id: "t", from: "a", to: "b", type: "dissolve", duration: 1, align: .start))
    #expect(start.start == 4 && start.tail == 1 && start.head == 0)
    let edge = try p.window(Transition(id: "t", from: nil, to: "b", type: "wipe", duration: 0.5))
    #expect(edge.start == 4 && edge.end == 4.5 && edge.head == 0)
    #expect(abs(center.progress(at: 4) - 0.5) < 1e-9)
}

@Test func transitionNeedsHandlesAndAdjacency() throws {
    var p = cutProject()
    try p.checkTransition(Transition(id: "t", from: "a", to: "b", type: "dissolve", duration: 1))
    p.tracks[0].clips[1].sourceIn = 0.2
    #expect(throws: EditError.self) { try p.checkTransition(Transition(id: "t", from: "a", to: "b", type: "dissolve", duration: 1)) }
    try p.checkTransition(Transition(id: "t", from: "a", to: "b", type: "dissolve", duration: 1, align: .start, part: .video))
    #expect(throws: EditError.self) { try p.checkTransition(Transition(id: "t", from: "a", to: "b", type: "nope", duration: 1)) }
    p.tracks[0].clips[1].start = 5
    #expect(throws: EditError.self) { try p.window(Transition(id: "t", from: "a", to: "b", type: "dissolve", duration: 1)) }
}

@Test func transitionsFollowSplitsAndDropWithClips() throws {
    var p = cutProject()
    p.transitions = [Transition(id: "tr1", from: "a", to: "b", type: "dissolve", duration: 0.5)]
    let (_, right) = try p.splitClip("a", at: 2)
    #expect(p.transitions[0].from == right)
    p.pruneTransitions()
    #expect(p.transitions.count == 1)
    try p.deleteClips([p.transitions[0].to!], ripple: false)
    p.pruneTransitions()
    #expect(p.transitions.isEmpty)
}

@Test func audioTransitionsBecomeCrossfades() throws {
    var p = cutProject()
    p.transitions = [Transition(id: "tr1", from: "a", to: "b", type: "dissolve", duration: 1)]
    let r = p.resolvingAudioTransitions()
    #expect(r.clip("a")?.audioLag == 0.5 && r.clip("a")?.audioFadeOut == 1)
    #expect(r.clip("b")?.audioLead == 0.5 && r.clip("b")?.audioFadeIn == 1)
    #expect(r.transitions.first?.part == .video)
    #expect(r.resolvingAudioTransitions() == r)
    try r.validate()
    let changes = p.changes(from: cutProject())
    #expect(changes.contains { $0.hasPrefix("+ transition tr1 dissolve") })
}

@Test func trimModes() throws {
    var p = cutProject()
    p.tracks[0].clips.append(Clip(id: "c", kind: .media, mediaId: "m", start: 8, duration: 2, sourceIn: 15))
    var q = p
    try q.trim("a", mode: .ripple, edge: .end, delta: -1)
    #expect(q.clip("a")?.end == 3 && q.clip("b")?.start == 3 && q.clip("c")?.start == 7)
    q = p
    try q.trim("a", mode: .roll, edge: .end, delta: 0.5)
    #expect(q.clip("a")?.end == 4.5 && q.clip("b")?.start == 4.5 && q.clip("b")?.sourceIn == 10.5 && q.clip("b")?.end == 8)
    q = p
    try q.trim("b", mode: .slip, edge: .end, delta: 1)
    #expect(q.clip("b")?.sourceIn == 11 && q.clip("b")?.start == 4)
    q = p
    try q.trim("b", mode: .slide, edge: .end, delta: 0.5)
    #expect(q.clip("a")?.end == 4.5 && q.clip("b")?.start == 4.5 && q.clip("c")?.start == 8.5 && q.clip("c")?.sourceIn == 15.5)
    try q.validate()
    q = p
    try q.trim("b", mode: .ripple, edge: .start, delta: 1)
    #expect(q.clip("b")?.start == 4 && q.clip("b")?.duration == 3 && q.clip("b")?.sourceIn == 11 && q.clip("c")?.start == 7)
    #expect(throws: EditError.self) { try p.trim("a", mode: .roll, edge: .start, delta: 1) }
}

@Test func speedCurvesMapSourceTime() throws {
    var c = Clip(id: "r", kind: .media, mediaId: "m", start: 10, duration: 4, sourceIn: 2)
    c.anim["time.speed"] = Curve(keys: [CurveKey(t: 0, v: .number(2), ease: .linear), CurveKey(t: 4, v: .number(0), ease: .linear)])
    #expect(abs(c.sourceOut - 6) < 1e-3)
    #expect(abs(c.timelineTime(atSource: c.sourceTime(atTimeline: 11.3)) - 11.3) < 1e-3)
    c.reverse = true
    #expect(abs(c.sourceTime(atTimeline: 10) - 6) < 1e-3)
    #expect(abs(c.sourceTime(atTimeline: 14) - 2) < 1e-3)
}
