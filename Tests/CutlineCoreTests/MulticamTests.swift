import Foundation
import Testing
@testable import CutlineCore

/// Lines alternating between angles "A" and "B": words 0.25 s long, 0.05 s apart, `gap` between lines.
private func dialogue(_ lines: [Int], gap: Seconds = 0.2, start: Seconds = 0.5) -> [MulticamWord] {
    var t = start
    var out: [MulticamWord] = []
    for (i, count) in lines.enumerated() {
        for _ in 0..<count {
            out.append(MulticamWord(start: t, end: t + 0.25, text: "word", angle: i % 2 == 0 ? "A" : "B"))
            t += 0.3
        }
        t += gap
    }
    return out
}

private func expectCutsBetweenWords(_ shots: [MulticamShot], _ words: [MulticamWord], sourceLocation: SourceLocation = #_sourceLocation) {
    for s in shots.dropFirst() {
        #expect(!words.contains { $0.start < s.start - 1e-9 && s.start < $0.end - 1e-9 }, "cut at \(s.start) is inside a word", sourceLocation: sourceLocation)
    }
}

@Test func rapidDialogueCutsOnEveryTurn() {
    // 30 s of quick back and forth: lines of 5–9 words (1.5–2.7 s).
    let lines = [6, 5, 8, 6, 7, 5, 9, 6, 5, 7, 6, 8, 5, 6, 7]
    let words = dialogue(lines)
    let range = TimeRange(0, words.last!.end + 0.5)
    let shots = MulticamPlan.shots(words: words, range: range, first: "A")
    #expect(shots.count == lines.count)
    #expect(shots.map(\.angle) == lines.indices.map { $0 % 2 == 0 ? "A" : "B" })
    #expect(shots.allSatisfy { $0.duration >= 1.0 })
    #expect(shots.first?.start == 0 && shots.last?.end == range.end)
    for (a, b) in zip(shots, shots.dropFirst()) { #expect(a.end == b.start) }
    expectCutsBetweenWords(shots, words)
    // Each cut lands in the pause before the new speaker's first word.
    var firstWord = 0
    for (i, n) in lines.enumerated() where i > 0 {
        firstWord += lines[i - 1]
        let w = words[firstWord], prev = words[firstWord - 1]
        _ = n
        #expect(shots[i].start >= prev.end - 1e-9 && shots[i].start <= w.start + 1e-9)
    }
}

@Test func quickInterjectionsStayOnTheCurrentSpeaker() {
    // A speaks, B says one word, A goes on.
    let words = dialogue([8, 1, 8, 6], gap: 0.1)
    let shots = MulticamPlan.shots(words: words, range: TimeRange(0, 12), first: "A")
    #expect(shots.map(\.angle) == ["A", "B"])
    #expect(shots.allSatisfy { $0.duration >= 1.0 })
    expectCutsBetweenWords(shots, words)

    var o = MulticamOptions()
    o.minShot = 0.2
    #expect(MulticamPlan.shots(words: words, range: TimeRange(0, 12), first: "A", options: o).map(\.angle) == ["A", "B", "A", "B"])
}

@Test func longTurnsGetReactionsOrAWideShot() {
    let words = dialogue([4, 30, 4], gap: 0.3)
    let range = TimeRange(0, words.last!.end + 0.3)
    var o = MulticamOptions()
    o.reactionAfter = 5
    let shots = MulticamPlan.shots(words: words, range: range, first: "A", options: o)
    let reaction = try! #require(shots.first { $0.kind == "reaction" })
    #expect(reaction.angle == "A")
    #expect(reaction.duration >= 1.5)
    #expect(shots.allSatisfy { $0.duration >= 1.0 })
    expectCutsBetweenWords(shots, words)

    var w = MulticamOptions()
    w.wide = "W"
    w.wideAfter = 6
    #expect(MulticamPlan.shots(words: words, range: range, first: "A", options: w).contains { $0.angle == "W" && $0.kind == "wide" })
}

@Test func loudestMicPicksTheSpeaker() {
    // A's mic is 6 dB hotter overall; each person is ~10 dB louder on their own mic.
    let truth = ["A", "A", "B", "B", "A", "B", "B", "A"]
    let a: [[Double]] = truth.map { $0 == "A" ? [-14, -15] : [-24, -25] }
    let b: [[Double]] = truth.map { $0 == "B" ? [-20, -21] : [-30, -31] }
    let (angles, margin) = MulticamPlan.loudestAngles(["A": a, "B": b])
    #expect(angles == truth)
    #expect(margin >= 9)
    // Every camera hearing the same room sound: no margin.
    let same: [[Double]] = truth.map { $0 == "A" ? [-20] : [-21] }
    #expect(MulticamPlan.loudestAngles(["A": same, "B": same]).margin < 1)
    // A loosely timed word: the previous speaker's quiet tail and a pause, then the new speaker loud on B.
    let tailA: [[Double]] = [[-14, -14], [-30, -60, -60, -45, -45, -45]]
    let tailB: [[Double]] = [[-30, -30], [-45, -60, -60, -16, -16, -16]]
    #expect(MulticamPlan.loudestAngles(["A": tailA + a, "B": tailB + b]).angles.prefix(2) == ["A", "B"])
}

@Test func manualAngleCutsSwitchMediaInSync() throws {
    var p = Project(name: "Multicam")
    p.canvas.fps = 25
    p.media = [
        MediaAsset(id: "camA", path: "/tmp/a.mov", name: "Cam A", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "camB", path: "/tmp/b.mov", name: "Cam B", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
    ]
    p.addSyncGroup(["camA": 0, "camB": 2.5])
    p.tracks[0].clips = [Clip(id: "v", kind: .media, mediaId: "camA", start: 0, duration: 30, sourceIn: 10)]
    let lines = try p.switchAngles([(at: 4, angle: "camB"), (at: 9, angle: "camA")], trackId: "V1")
    #expect(lines.count == 2)
    let clips = p.tracks[0].clips
    #expect(clips.map(\.mediaId) == ["camA", "camB", "camA"])
    #expect(clips.map(\.start) == [0, 4, 9])
    // camB at timeline 4 shows the moment camA would: source 14 on A is 16.5 on B.
    #expect(abs(clips[1].sourceIn - 16.5) < 1e-9)
    #expect(abs(clips[2].sourceIn - 19) < 1e-9)
    try p.validate()
    #expect(throws: EditError.self) { try p.switchAngles([(at: 50, angle: "camB")], trackId: "V1") }
}
