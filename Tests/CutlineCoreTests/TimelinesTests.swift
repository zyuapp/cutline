import Foundation
import Testing
@testable import CutlineCore

@Test func timelinesKeepTheirOwnEditsAndFrame() throws {
    var p = Project(name: "Show")
    p.tracks[0].clips = [Clip(id: "a", kind: .solid, start: 0, duration: 4, color: .white)]
    try p.newTimeline("Vertical", duplicate: true)
    #expect(p.currentTimelineName == "Vertical" && p.tracks[0].clips.map(\.id) == ["a"])
    p.canvas.width = 1080
    p.canvas.height = 1920
    p.tracks[0].clips[0].duration = 2

    try p.newTimeline("Trailer", duplicate: false)
    #expect(p.tracks.allSatisfy(\.clips.isEmpty) && p.canvas.width == 1080)
    #expect(p.timelineNames == ["Trailer", "Main", "Vertical"])

    try p.switchTimeline(to: "Main")
    #expect(p.canvas.width == 1920 && p.tracks[0].clips[0].duration == 4)
    try p.switchTimeline(to: "Vertical")
    #expect(p.canvas.height == 1920 && p.tracks[0].clips[0].duration == 2)

    try p.renameTimeline("Main", to: "Master 16x9")
    try p.deleteTimeline("Trailer")
    #expect(Set(p.timelineNames) == ["Vertical", "Master 16x9"])
    #expect(throws: EditError.self) { try p.deleteTimeline("Vertical") }
    #expect(throws: EditError.self) { try p.newTimeline("Vertical", duplicate: false) }

    let data = try JSONEncoder().encode(p)
    #expect(try JSONDecoder().decode(Project.self, from: data) == p)
}
