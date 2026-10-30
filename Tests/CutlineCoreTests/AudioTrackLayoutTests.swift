import Foundation
import Testing
@testable import CutlineCore

@Test func audioTrackLayoutsParsePresetsListsAndLayouts() throws {
    let eight = try AudioTrackSpec.parse("broadcast_8ch")
    #expect(eight.map(\.token) == ["mix", "me", "dia", "mus", "fx", "amb"])
    #expect(eight.map(\.layout.channelCount) == [2, 2, 1, 1, 1, 1])
    #expect(AudioTrackSpec.channels(eight).map(\.name) == ["Mix L", "Mix R", "M&E L", "M&E R", "DIA", "MUS", "FX", "AMB"])
    #expect(AudioTrackSpec.describe(eight) == "ch1-2 Mix (stereo), ch3-4 M&E (stereo), ch5 DIA (mono), ch6 MUS (mono), ch7 FX (mono), ch8 AMB (mono)")

    let netflix = try AudioTrackSpec.parse("mix@5.1, mix, bus:DIA@stereo, role:Crowd, tone, silence")
    #expect(netflix.map(\.layout) == [.surround51, .stereo, .stereo, .mono, .mono, .mono])
    #expect(netflix.map(\.name) == ["Mix 5.1", "Mix", "DIA", "CROWD", "Tone", "Silence"])
    #expect(netflix[2].content == .bus("DIA") && netflix[3].content == .role("crowd"))
    #expect(netflix[0].token == "mix@5.1" && netflix[2].token == "bus:DIA@stereo")
    #expect(AudioTrackSpec.channels(netflix).count == 13)

    #expect(throws: EditError.self) { try AudioTrackSpec.parse("mix,voice") }
    #expect(throws: EditError.self) { try AudioTrackSpec.parse("mix@quad") }
    #expect(throws: EditError.self) { try AudioTrackSpec.parse(" ") }
}

@Test func stemSlotsSplitAmbienceFromEffects() {
    #expect(Project.stemSlot("effects.ambience", trackName: "SFX") == "ambience")
    #expect(Project.stemSlot("effects", trackName: "Atmos") == "ambience")
    #expect(Project.stemSlot("Ambience", trackName: "A4") == "ambience")
    #expect(Project.stemSlot("effects", trackName: "Hits") == "effects")
    #expect(Project.stemSlot("dialogue.room tone", trackName: "BG") == "dialogue")
    #expect(Project.stemSlot("music", trackName: "Background") == "music")
    #expect(Project.stemSlot("Crowd", trackName: "") == "crowd")
}

@Test func audioTrackSourcesKeepEachStemAndSumToTheMix() throws {
    var p = Project(name: "Layout")
    p.media = [MediaAsset(id: "m", path: "/m.wav", name: "m", duration: 10, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true)]
    p.master.loudnessTarget = -23
    p.master.effects = [Effect(id: "lim", type: "audio.limiter")]
    let roles: [(String, String, String?)] = [("A1", "Dialogue", "dialogue"), ("A2", "Score", "music"), ("A3", "SFX", "effects"), ("A4", "Atmos", nil), ("A5", "Crowd", "crowd")]
    p.tracks = roles.map { id, name, role in
        var t = Track(id: id, kind: .audio, name: name, clips: [Clip(id: "c\(id)", kind: .media, mediaId: "m", start: 0, duration: 2)])
        t.role = role
        return t
    }
    let inferred = ["A4": "effects"]
    let layout = try AudioTrackSpec.parse("broadcast_8ch")
    func audible(_ s: Project?) -> [String] { (s?.tracks ?? []).filter { !$0.muted && $0.clips.contains { $0.volume > 0 } }.map(\.id) }

    let mix = try p.audioTrackSource(.mix, roles: inferred, layout: layout)
    #expect(mix == p)
    let dia = try p.audioTrackSource(.role("dialogue"), roles: inferred, layout: layout)
    #expect(audible(dia) == ["A1"])
    #expect(dia?.master.loudnessTarget == nil && dia?.master.effects.isEmpty == true)
    #expect(audible(try p.audioTrackSource(.role("ambience"), roles: inferred, layout: layout)) == ["A4"])
    // FX also carries the custom role no other track has, so DIA + MUS + FX + AMB is everything.
    #expect(audible(try p.audioTrackSource(.role("effects"), roles: inferred, layout: layout)) == ["A3", "A5"])
    #expect(audible(try p.audioTrackSource(.musicAndEffects, roles: inferred, layout: layout)) == ["A2", "A3", "A4", "A5"])
    // Without an AMB track, ambience goes in FX.
    let three = try AudioTrackSpec.parse("mix,dia,mus,fx")
    #expect(audible(try p.audioTrackSource(.role("effects"), roles: inferred, layout: three)) == ["A3", "A4", "A5"])
    #expect(try p.audioTrackSource(.tone, roles: inferred, layout: layout) == nil)
    #expect(throws: EditError.self) { try p.audioTrackSource(.bus("NOPE"), roles: inferred, layout: layout) }
    #expect(p.dialogueClipSpans(inferred) == [TimeRange(0, 2)])
}

@Test func masteringPlatformsCheckLayoutTimedTextAndTimecode() throws {
    var p = Project(name: "Master", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    let netflix = try #require(Platform.named("netflix_master"))
    #expect(netflix.dialogueGated && netflix.loudness == -27 && netflix.loudnessTolerance == 2 && netflix.truePeak == -2)
    #expect(netflix.check(p, preset: "prores_hq").isEmpty)
    #expect(netflix.check(p, preset: "hevc").contains { $0.contains("prores_hq") })
    p.canvas.width = 1280
    p.canvas.height = 720
    #expect(netflix.check(p).contains { $0.contains("1920×1080 or 3840×2160") })
    p.canvas = Canvas(width: 3840, height: 2160, fps: 24000.0 / 1001)
    #expect(netflix.check(p).isEmpty)

    let eight = try AudioTrackSpec.parse("broadcast_8ch")
    #expect(netflix.deliveryCheck(p, audioTracks: eight, subtitleFormats: ["imsc"], timecodeStart: nil).isEmpty)
    #expect(netflix.deliveryCheck(p, audioTracks: eight, subtitleFormats: ["srt"], timecodeStart: nil).contains { $0.contains("IMSC 1.1") })
    #expect(netflix.deliveryCheck(p, audioTracks: try AudioTrackSpec.parse("dia,mus"), subtitleFormats: ["imsc"], timecodeStart: nil).contains { $0.contains("stereo mix") })
    p.master.layout = .surround51
    let surround = netflix.resolved(for: p)
    #expect(surround.audioTracks == "netflix_51_20")
    #expect(surround.deliveryCheck(p, audioTracks: eight, subtitleFormats: ["imsc"], timecodeStart: nil).contains { $0.contains("5.1 printmaster") })
    #expect(surround.deliveryCheck(p, audioTracks: try AudioTrackSpec.parse("netflix_51_20"), subtitleFormats: ["imsc"], timecodeStart: nil).isEmpty)

    let dpp = try #require(Platform.named("broadcast_uk_dpp"))
    var q = Project(name: "DPP", canvas: Canvas(width: 1920, height: 1080, fps: 25, timecodeStart: "10:00:00:00"))
    #expect(dpp.loudness == -23 && dpp.loudnessTolerance == 0.5 && dpp.preset == "avc_intra_class100")
    #expect(dpp.check(q, preset: "avc_intra_class100").isEmpty)
    #expect(dpp.check(q, preset: "prores_hq").contains { $0.contains("avc_intra_class100") })
    #expect(dpp.deliveryCheck(q, audioTracks: eight, subtitleFormats: [], timecodeStart: nil).isEmpty)
    #expect(dpp.deliveryCheck(q, audioTracks: try AudioTrackSpec.parse("mix,me"), subtitleFormats: [], timecodeStart: nil).contains { $0.contains("8 audio channels") })
    q.canvas.timecodeStart = "01:00:00:00"
    #expect(dpp.deliveryCheck(q, audioTracks: eight, subtitleFormats: [], timecodeStart: nil).contains { $0.contains("10:00:00:00") })
    #expect(dpp.deliveryCheck(q, audioTracks: eight, subtitleFormats: [], timecodeStart: "10:00:00:00").isEmpty)
    q.canvas.fps = 30000.0 / 1001
    #expect(dpp.check(q).contains { $0.contains("25 fps") })
}
