import CutlineCore
import Foundation
import Testing

/// 120 bpm from 0.87 s with downbeats from 1.87 s: a pickup bar of two beats, then bars of four.
private let beats = (0..<16).map { 0.87 + Double($0) * 0.4975 }
private let downbeats = [1.865, 3.855, 5.845, 7.835]

@Test func beatCutCountsFromTheBar() {
    let two = Project.beatMarks(beats, every: 2, downbeats: downbeats)
    #expect(two.phased)
    let twoTimes = two.indices.map { beats[$0] }
    #expect(twoTimes.contains { abs($0 - 1.87) < 0.01 } && twoTimes.contains { abs($0 - 3.86) < 0.01 })
    #expect(!twoTimes.contains { abs($0 - 1.37) < 0.01 } && !twoTimes.contains { abs($0 - 2.37) < 0.01 })
    #expect(twoTimes.contains { abs($0 - 2.86) < 0.01 }, "beat 3 of the bar: \(twoTimes)")

    let four = Project.beatMarks(beats, every: 4, downbeats: downbeats)
    let fourTimes = four.indices.map { beats[$0] }
    #expect(four.phased && fourTimes.filter { $0 > 1.8 }.allSatisfy { t in downbeats.contains { abs($0 - t) < 0.02 } }, "\(fourTimes)")

    // Without downbeats, or for every 1 or 3, every n-th beat from the first.
    #expect(Project.beatMarks(beats, every: 2, downbeats: []) == (Array(stride(from: 0, to: 16, by: 2)), false))
    #expect(Project.beatMarks(beats, every: 3, downbeats: downbeats).phased == false)
}

@Test func beatCutLandsOnDownbeats() throws {
    var p = Project(name: "Beat", canvas: Canvas(width: 640, height: 360, fps: 30))
    p.media = [MediaAsset(id: "m", path: "/x/m.mov", name: "m", duration: 60, width: 640, height: 360, fps: 30, hasVideo: true, hasAudio: false)]
    let note = try p.beatCut(footage: [BeatFootage(mediaId: "m", range: TimeRange(0, 60))], beats: beats, every: 4, trackId: "V1", downbeats: downbeats)
    #expect(note.contains("on the downbeats"), "\(note)")
    let starts = p.tracks[0].clips.map(\.start)
    for d in downbeats.dropLast() { #expect(starts.contains { abs($0 - d) < 0.04 }, "\(starts)") }
}
