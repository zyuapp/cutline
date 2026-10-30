import Foundation
import Testing
@testable import CutlineCore

private func cuts(fps: Double) -> Project {
    var p = Project(name: "Grid", canvas: Canvas(fps: fps))
    p.media = [MediaAsset(id: "m", path: "/tmp/m.mov", name: "M", duration: 30, width: 1920, height: 1080, fps: fps, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 4, sourceIn: 2),
        Clip(id: "b", kind: .media, mediaId: "m", start: 4, duration: 4, sourceIn: 10),
    ]
    return p
}

@Test func splitEditsSnapToTheFrameGrid() throws {
    var p = cuts(fps: 24)
    let applied = try p.splitEdit(left: "a", right: "b", offset: 0.6)
    #expect(abs(applied - 14.0 / 24) < 1e-12, "0.6 s is 14.4 frames at 24 fps")
    #expect(abs(p.clip("b")!.audioLead - 14.0 / 24) < 1e-12)
    #expect(p.snapNote(0.6, applied).contains("14 frames"))

    var q = cuts(fps: 24)
    #expect(try q.splitEdit(left: "a", right: "b", offset: 0.6, subframe: true) == 0.6)
    #expect(q.clip("b")!.audioLead == 0.6)
}

@Test func audioTrimsLandOnFrames() throws {
    var p = cuts(fps: 24)
    p.tracks[0].clips[0].start = 0
    p.tracks[0].clips[1].start = 5
    let note = try p.trimAudio("b", edge: .start, delta: -0.3)
    #expect(abs(p.clip("b")!.audioLead - 7.0 / 24) < 1e-12, "\(note)")
    #expect(note.contains("7 frames"))
    // Rolling a sound cut between touching clips snaps the same way.
    var q = cuts(fps: 25)
    _ = try q.trimAudio("b", edge: .start, delta: -0.53)
    #expect(abs(q.clip("b")!.audioLead - 0.52) < 1e-12)
    #expect(abs(q.clip("a")!.audioLag + 0.52) < 1e-12)
    var r = cuts(fps: 25)
    _ = try r.trimAudio("b", edge: .start, delta: -0.53, subframe: true)
    #expect(abs(r.clip("b")!.audioLead - 0.53) < 1e-12)
}

@Test func roomToneOverlapsWholeFrames() {
    let x = Project.roomToneCrossfade(0.25, range: TimeRange(0, 10), fps: 30)
    #expect(abs(x / 2 * 30 - (x / 2 * 30).rounded()) < 1e-9 && abs(x - 8.0 / 30) < 1e-9)
    // Too short for a frame of overlap: the declick stays as it was.
    #expect(abs(Project.roomToneCrossfade(0.25, range: TimeRange(0, 0.08), fps: 25) - 0.04) < 1e-9)
}

@Test func standardRatesKeepNTSCExact() {
    #expect(Canvas.standardRate(23.976025) == 24_000.0 / 1001)
    #expect(Canvas.standardRate(29.97) == 30_000.0 / 1001)
    #expect(Canvas.standardRate(24.0002) == 24)
    #expect(Canvas.standardRate(59.94006) == 60_000.0 / 1001)
    #expect(Canvas.standardRate(12.5) == 12.5)
    let c = Canvas(fps: 30)
    #expect(c.playsSmoothly(60) && c.playsSmoothly(30) && !c.playsSmoothly(24) && !c.playsSmoothly(29.97) && !c.playsSmoothly(25))
}

@Test func firstFootageSetsAnUntouchedCanvas() throws {
    var p = Project(name: "Fit")
    let film = MediaAsset(id: "film", path: "/tmp/f.mov", name: "F", duration: 10, width: 3840, height: 1606, fps: 23.976025, hasVideo: true, hasAudio: true)
    let fitted = p.fitCanvas(toImported: film)
    let note = try #require(fitted)
    #expect(p.canvas.width == 3840 && p.canvas.height == 1606 && p.canvas.fps == 24_000.0 / 1001, "\(note)")
    #expect(note.contains("23.976") && p.canvasSet == true)
    // The canvas is now chosen: other footage only warns.
    let pal = MediaAsset(id: "pal", path: "/tmp/p.mov", name: "P", duration: 10, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)
    let warned = p.fitCanvas(toImported: pal)
    let warn = try #require(warned)
    #expect(warn.contains("judder") && warn.contains("canvas_set") && p.canvas.fps == 24_000.0 / 1001)

    // A deliberate canvas is kept even in an empty project.
    var q = Project(name: "Kept")
    q.canvasSet = true
    #expect(q.fitCanvas(toImported: film)?.contains("judder") == true)
    #expect(q.canvas.width == 1920 && q.canvas.fps == 30)

    // Once clips are on the timeline the canvas stays.
    var r = cuts(fps: 30)
    _ = r.fitCanvas(toImported: film)
    #expect(r.canvas.fps == 30)

    // Images and matching footage say nothing.
    var s = Project(name: "Still")
    #expect(s.fitCanvas(toImported: MediaAsset(id: "s", path: "/tmp/s.png", name: "S", duration: 0, width: 100, height: 100, fps: 0, hasVideo: true, hasAudio: false, isImage: true)) == nil)
    #expect(s.canvasSet == nil)
    #expect(s.fitCanvas(toImported: MediaAsset(id: "hd", path: "/tmp/h.mov", name: "H", duration: 5, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)) == nil)
    #expect(s.canvasSet == true)
    let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(s))
    #expect(saved.canvasSet == true)
}
