import Foundation
import Testing
@testable import CutlineCore

private func project() -> Project {
    var p = Project(name: "Mix")
    p.media = [MediaAsset(id: "talk", path: "/tmp/talk.mov", name: "talk", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    p.tracks = [
        Track(id: "V1", kind: .video, name: "Interview", clips: [Clip(id: "a", kind: .media, mediaId: "talk", start: 0, duration: 4)]),
        Track(id: "A1", kind: .audio, name: "Score", clips: [Clip(id: "m", kind: .media, mediaId: "talk", start: 0, duration: 4)]),
        Track(id: "A2", kind: .audio, name: "SFX", clips: [Clip(id: "s", kind: .media, mediaId: "talk", start: 0, duration: 2)]),
    ]
    return p
}

@Test func busOutputsCannotLoop() throws {
    var p = project()
    p.buses = [AudioBus(id: "A", output: "B"), AudioBus(id: "B", output: "C"), AudioBus(id: "C")]
    try p.validate()
    #expect(p.mixRouting().order.map(\.id) == ["A", "B", "C"], "feeders first")
    p.buses[2].output = "A"
    #expect(throws: EditError.self) { try p.validate() }
    p.buses[2].output = "C"
    #expect(throws: EditError.self, "a bus feeding itself") { try p.validate() }
    p.buses[2].output = "nowhere"
    #expect(throws: EditError.self) { try p.validate() }
}

@Test func routingRejectsUnknownBusesAndBadIds() throws {
    var p = project()
    p.tracks[1].output = "MUS"
    #expect(throws: EditError.self) { try p.validate() }
    p.buses = [AudioBus(id: "MUS")]
    try p.validate()
    p.tracks[1].sends = [AudioSend(bus: "VERB")]
    #expect(throws: EditError.self) { try p.validate() }
    p.buses.append(AudioBus(id: "VERB"))
    p.tracks[1].sends.append(AudioSend(bus: "VERB", levelDb: -6))
    #expect(throws: EditError.self, "two sends to one bus") { try p.validate() }
    p.tracks[1].sends = [AudioSend(bus: "VERB", levelDb: -6, preFader: true)]
    try p.validate()
    for bad in ["master", "1st", "A1", "MUS"] {
        var q = p
        q.buses.append(AudioBus(id: bad))
        #expect(throws: EditError.self, "\(bad)") { try q.validate() }
    }
}

@Test func busesRoundTripAndRemovingOneReroutes() throws {
    var p = project()
    p.buses = [AudioBus(id: "MUS", effects: [Effect(id: "eq1", type: "audio.eq")], volume: 0.8, volumeCurve: Curve(keys: [CurveKey(t: 0, v: .number(1))]), output: "PRE"), AudioBus(id: "PRE", name: "Premix", layout: .stereo)]
    p.tracks[1].output = "MUS"
    p.tracks[2].sends = [AudioSend(bus: "MUS", levelDb: -3, preFader: true)]
    p.tracks[2].clips[0].role = "ambience"
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Project.self, from: data)
    #expect(back == p)
    let plain = try JSONEncoder().encode(project().tracks[0])
    #expect(!String(decoding: plain, as: UTF8.self).contains("sends"), "tracks without sends don't write them")

    try p.removeBus("MUS")
    #expect(p.tracks[1].output == "PRE" && p.tracks[2].sends.isEmpty && p.buses.map(\.id) == ["PRE"])
    try p.validate()
    #expect(p.changes(from: back).contains { $0.hasPrefix("- bus MUS") })
}

@Test func soloHearsTheSoloedPathOnly() {
    var p = project()
    p.buses = [AudioBus(id: "SUB", output: "DIA"), AudioBus(id: "DIA", solo: true, output: "PRE"), AudioBus(id: "PRE"), AudioBus(id: "MUS")]
    let r = p.mixRouting()
    #expect(r.busHeard("SUB") && r.busHeard("DIA") && r.busHeard("PRE") && !r.busHeard("MUS"))
    #expect(r.destinationHeard("DIA") && r.destinationHeard("SUB"))
    #expect(!r.destinationHeard("PRE"), "the path to the master only carries the soloed bus")
    #expect(!r.destinationHeard(nil), "tracks straight to the master are silent under solo")
    p.buses[1].solo = false
    p.buses[2].muted = true
    let m = p.mixRouting()
    #expect(!m.busHeard("SUB") && !m.busHeard("DIA") && m.busHeard("MUS") && m.destinationHeard(nil))
}

@Test func clipRolesSplitStemsAndIsolationKeepsSends() {
    var p = project()
    p.tracks[0].role = "dialogue"
    p.tracks[0].clips.append(Clip(id: "rt", kind: .media, mediaId: "talk", start: 4, duration: 2))
    try? p.tracks[0].clips[1].set("audio.role", .string("ambience"))
    #expect(p.tracks[0].clips[1].role == "ambience")
    let roles = p.roles(transcripts: [:])
    #expect(p.audioRoles(roles) == ["dialogue": ["V1"], "ambience": ["V1"], "music": ["A1"], "effects": ["A2"]])
    let me = p.keepingRoles(roles) { $0 != "dialogue" }
    #expect(me.tracks[0].clips[0].volume == 0 && me.tracks[0].clips[1].volume == 1 && !me.tracks[0].muted)
    let dx = p.keepingRoles(roles) { $0 == "dialogue" }
    #expect(dx.tracks[1].muted && dx.tracks[2].muted && dx.tracks[0].clips[1].volume == 0)

    p.buses = [AudioBus(id: "MUS"), AudioBus(id: "VERB")]
    p.tracks[1].output = "MUS"
    p.tracks[0].sends = [AudioSend(bus: "VERB")]
    let verb = p.isolatingBus("VERB")
    #expect(verb.bus("MUS")?.muted == true && verb.bus("VERB")?.muted == false)
    #expect(verb.tracks[0].output == "stem_off" && !verb.tracks[0].muted, "direct tracks still feed their sends")
    #expect(verb.mixRouting().destinationHeard("VERB") && !verb.mixRouting().destinationHeard("stem_off"))
    let direct = p.isolatingBus(nil)
    #expect(direct.buses.allSatisfy(\.muted) && direct.tracks[0].output == nil)
}

@Test func dmeBusesRouteByRoleThenName() {
    var p = project()
    p.tracks.append(Track(id: "A3", kind: .audio, name: "Room tone", clips: [Clip(id: "r", kind: .media, mediaId: "talk", start: 0, duration: 1)]))
    p.tracks.append(Track(id: "A4", kind: .audio, name: "Narration VO", clips: [Clip(id: "n", kind: .media, mediaId: "talk", start: 0, duration: 1)]))
    let lines = p.applyDMEBuses(roles: p.roles(transcripts: [:]))
    #expect(p.buses.map(\.id) == ["DIA", "MUS", "FX"])
    #expect(p.tracks.map { $0.output ?? "master" } == ["DIA", "MUS", "FX", "DIA", "DIA"], "room tone is dialogue")
    #expect(p.bus("DIA")!.effects.map(\.type) == ["audio.compressor"])
    #expect(p.master.effects.map(\.type) == ["audio.limiter"])
    #expect(!lines.isEmpty)
    let again = p
    #expect(p.applyDMEBuses(roles: p.roles(transcripts: [:])).isEmpty)
    #expect(p == again, "running it twice changes nothing")
}
