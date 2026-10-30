import CutlineCore
import Foundation
import Testing

@Test func timecodeFormatMatchesEDLDropFrameChoice() {
    let df = TimecodeFormat(fps: 30000.0 / 1001)
    #expect(df.nominal == 30 && df.dropFrame)
    #expect(df.string(df.frames("01:00:00:00")! - 900) == "00:59:30;00")
    #expect(df.string(df.frames("00:00:59;29")! + 1) == "00:01:00;02")
    #expect(TimecodeFormat(fps: 59.94).dropFrame)
    #expect(!TimecodeFormat(fps: 23.976).dropFrame)
    #expect(!TimecodeFormat(fps: 25).dropFrame)
    let pal = TimecodeFormat(fps: 25)
    #expect(pal.string(-25) == "23:59:59:00")
    #expect(pal.frames("01:00:00:25") == nil)
    var p = Project(name: "DF", canvas: Canvas(fps: 30000.0 / 1001))
    p.tracks[0].clips = []
    #expect(p.edl(title: "DF").contains("FCM: DROP FRAME"))
}

@Test func canvasStartTimecodeRoundTripsAndDefaultsToTheHour() throws {
    #expect(Canvas().startTimecode == "01:00:00:00")
    let c = Canvas(fps: 25, timecodeStart: "10:00:00:00")
    let back = try JSONDecoder().decode(Canvas.self, from: JSONEncoder().encode(c))
    #expect(back.startTimecode == "10:00:00:00")
    #expect(!String(decoding: try JSONEncoder().encode(Canvas()), as: UTF8.self).contains("timecodeStart"))
}

@Test func broadcastChecksFrameRateSizeAndCodec() throws {
    var p = Project(name: "B", canvas: Canvas(width: 1920, height: 1080, fps: 24))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 5, color: .black)]
    let generic = try #require(Platform.named("broadcast"))
    #expect(generic.check(p).contains { $0.contains("fps") })
    let eu = try #require(Platform.named("broadcast_eu"))
    #expect(eu.check(p, preset: "h264").count == 2)
    p.canvas.fps = 25
    #expect(eu.check(p, preset: "prores_hq").isEmpty)
    #expect(generic.resolved(for: p).loudness == -23)
    p.canvas.fps = 30000.0 / 1001
    let us = generic.resolved(for: p)
    #expect(us.loudness == -24 && us.truePeak == -2 && us.check(p).isEmpty)
    p.canvas.width = 1280
    p.canvas.height = 720
    #expect(us.check(p).contains { $0.contains("1920×1080") })
    #expect(try #require(Platform.named("youtube")).check(p, preset: "h264").isEmpty)
}
