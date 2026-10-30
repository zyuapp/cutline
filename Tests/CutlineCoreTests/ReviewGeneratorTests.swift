import Foundation
import Testing
@testable import CutlineCore

@Test func creditsParseTextAndJSON() {
    let lines = Credits.parse("# THE END\n\n## Cast\nCaptain | Ada Lovelace\nGrace Hopper\n")
    #expect(lines.map(\.kind) == [.title, .space, .heading, .row, .name, .space])
    #expect(lines[3].role == "Captain" && lines[3].text == "Ada Lovelace")
    let json = Credits.parse(#"[{"title": "Film"}, {"heading": "Crew", "rows": [["Editor", "Alan"], {"role": "Sound", "name": "Clara"}], "names": ["Extra One"]}]"#)
    #expect(json.map(\.kind) == [.title, .heading, .row, .row, .name])
    #expect(json[3].role == "Sound" && json[3].text == "Clara")
}

@Test func creditsLayoutAndRollMotion() {
    let lines = Credits.parse("## Cast\nA | B\nC | D\n## Crew\nE")
    let (laid, height) = Credits.layout(lines, size: 0.04, headingSize: 0.03, titleSize: 0.08, spacing: 1.5, sectionGap: 2)
    #expect(laid.count == 5)
    #expect(abs(laid[1].top - 0.045) < 1e-9)
    // The second heading follows a two-line gap.
    #expect(abs(laid[3].top - (0.045 + 0.06 + 0.06 + 0.12)) < 1e-9)
    #expect(abs(height - (laid[4].top + 0.06)) < 1e-9)
    #expect(Credits.rollTop(progress: 0, height: height, lastCenter: 0.3, hold: false) == 1)
    #expect(abs(Credits.rollTop(progress: 1, height: height, lastCenter: 0.3, hold: false) + height) < 1e-9, "rolls fully off the top")
    #expect(abs(Credits.rollTop(progress: 1, height: height, lastCenter: 0.3, hold: true) - 0.2) < 1e-9, "last line ends centered")
    #expect(Credits.progress(time: 4, duration: 10, endHold: 2) == 0.5)
    #expect(Credits.progress(time: 9, duration: 10, endHold: 2) == 1, "holds over the last seconds")
}

@Test func skyMatchMovesTheForegroundTowardTheNewHorizon() {
    let same = SkyMatch.gains(oldSky: SIMD3(0.5, 0.6, 0.8), newHorizon: SIMD3(0.5, 0.6, 0.8), blend: 1)
    #expect(same.values.allSatisfy { abs($0) < 1e-9 }, "\(same)")
    let warm = SkyMatch.gains(oldSky: SIMD3(0.5, 0.6, 0.8), newHorizon: SIMD3(0.95, 0.55, 0.3), blend: 0.5)
    #expect(warm["gain_r"]! > 0 && warm["gain_b"]! < 0 && warm.values.allSatisfy { abs($0) <= 0.2 })
    #expect(SkyMatch.gains(oldSky: SIMD3(0.5, 0.6, 0.8), newHorizon: SIMD3(0.95, 0.55, 0.3), blend: 0).values.allSatisfy { $0 == 0 })
}

@Test func burnInReadsRecordAndSourceTimecode() {
    var p = Project(name: "Burn", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    var m = MediaAsset(id: "m", path: "/x/A001.mov", name: "A001.mov", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false)
    m.setTimecode(frames: TimecodeFormat(fps: 25).frames("10:00:00:00")!, format: TimecodeFormat(fps: 25))
    m.reel = "A001"
    p.media = [m]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, name: "Interview", mediaId: "m", start: 0, duration: 10, sourceIn: 12)]
    let v2 = Track(id: "V2", kind: .video, name: "Burn", clips: [Clip(id: "g", kind: .generator, start: 0, duration: 10, effects: [Effect(id: "gen", type: "timecode_burn")])])
    p.tracks.append(v2)
    let text = BurnIn.text(p, clip: "g", at: 2, show: "record,source,clip,frame,reel", label: "DRAFT")
    #expect(text == "DRAFT   01:00:02:00   SRC 10:00:14:00   Interview   FR 000050   A001", "\(text)")
    #expect(BurnIn.text(p, clip: "g", at: 12, show: "source") == "--:--:--:--", "nothing below past the clip")
    p.tracks[0].hidden = true
    #expect(BurnIn.text(p, clip: "g", at: 2, show: "media") == "", "hidden tracks are skipped")
    #expect(BurnIn.text(p, clip: "g", at: 2, show: "media", sourceTrack: "V1") == "A001.mov")
}
