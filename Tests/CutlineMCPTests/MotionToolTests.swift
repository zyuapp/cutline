import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

private func newProject(_ box: Toolbox) async throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-motion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180])
    #expect(!r.isError, "\(r.plainText)")
    return dir
}

@Test func shapeLayersAnimateByShapeId() async throws {
    let box = Toolbox()
    let dir = try await newProject(box)
    defer { try? FileManager.default.removeItem(at: dir) }
    let shapes: JSON = [["id": "ring", "type": "ellipse", "width": 0.3, "height": 0.3, "stroke": "#FFFFFF", "stroke_width": 0.01, "trim_end": 0]]
    let added = await box.call("clip_add", ["generator": "shape", "duration": 3, "params": ["shapes": shapes, "ring.stroke_opacity": 0.8]])
    #expect(!added.isError, "\(added.plainText)")
    let clip = try #require(try box.session.project().tracks.flatMap(\.clips).first { $0.kind == .generator })
    let anim = await box.call("param_set", ["target": .string(clip.id), "relative": true, "animate": ["fx.gen.ring.trim_end": [[0, 0], [1, 1, "easeOut"]]]])
    #expect(!anim.isError, "\(anim.plainText)")
    #expect(try box.session.project().clip(clip.id)?.generatorValue("ring.trim_end", at: 1)?.number == 1)
    let typo = await box.call("param_set", ["target": .string(clip.id), "set": ["fx.gen.ring.trimend": 0.5]])
    #expect(typo.isError && typo.plainText.contains("trim_end"), "\(typo.plainText)")
    let bad = await box.call("clip_add", ["generator": "shape", "params": ["shapes": [["type": "hexagon"]]]])
    #expect(bad.isError && bad.plainText.contains("polygon"), "\(bad.plainText)")
    let docs = await box.call("catalog", ["type": "shape"])
    #expect(docs.plainText.contains("trim_end") && docs.plainText.contains("clip_add"), "\(docs.plainText)")
}

@Test func bindAddsWiggleRateLoopAndLinks() async throws {
    let box = Toolbox()
    let dir = try await newProject(box)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!(await box.call("clip_add", ["color": "#202020", "duration": 6, "name": "lead"])).isError)
    #expect(!(await box.call("clip_add", ["color": "#808080", "duration": 6, "track": "new", "start": 0, "name": "follow"])).isError)
    let clips = try box.session.project().tracks.flatMap(\.clips)
    let lead = try #require(clips.first { $0.name == "lead" }).id, follow = try #require(clips.first { $0.name == "follow" }).id
    let shake = await box.call("param_set", ["target": .string(lead), "bind": ["transform.x": ["source": "wiggle", "freq": 4, "amp": 0.02], "transform.rotation": ["source": "time", "rate": 45]]])
    #expect(!shake.isError && shake.plainText.contains("wiggle"), "\(shake.plainText)")
    var p = try box.session.project()
    #expect(p.clip(lead)?.number("transform.rotation", at: 2) == 90)
    let link = await box.call("param_set", ["target": .string(follow), "bind": ["transform.rotation": ["source": .string("link:\(lead).transform.rotation"), "scale": -1, "delay": 0.5]]])
    #expect(!link.isError && link.plainText.contains("kept in sync"), "\(link.plainText)")
    p = try box.session.project()
    #expect(abs(p.clip(follow)!.number("transform.rotation", at: 2) + 67.5) < 1e-6)
    // Changing the lead re-derives the follower.
    #expect(!(await box.call("param_set", ["target": .string(lead), "animate": ["transform.rotation": [[0, 0], [6, 60, "linear"]]]])).isError)
    p = try box.session.project()
    #expect(abs(p.clip(follow)!.number("transform.rotation", at: 2) + 15) < 1e-6)
    let loop = await box.call("param_set", ["target": .string(lead), "bind": ["transform.rotation": ["source": "loop", "mode": "pingpong"]]])
    #expect(!loop.isError && loop.plainText.contains("loop pingpong"), "\(loop.plainText)")
    let bad = await box.call("param_set", ["target": .string(lead), "bind": ["transform.x": ["source": "wiggle"]]])
    #expect(bad.isError && bad.plainText.contains("amp"), "\(bad.plainText)")
}

@Test func threeDAndCameraAreReachable() async throws {
    let box = Toolbox()
    let dir = try await newProject(box)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!(await box.call("clip_add", ["generator": "title.card", "duration": 4])).isError)
    #expect(!(await box.call("clip_add", ["generator": "camera", "duration": 4, "start": 0])).isError)
    let clips = try box.session.project().tracks.flatMap(\.clips)
    let card = try #require(clips.first { $0.effects.first?.type == "title.card" }).id
    let cam = try #require(clips.first { $0.effects.first?.type == "camera" }).id
    #expect(!(await box.call("param_set", ["target": .string(card), "set": ["transform.3d": true, "transform.z": 0.5]])).isError)
    let orbit = await box.call("param_set", ["target": .string(cam), "relative": true, "animate": ["fx.gen.orbit": [[0, -20], [4, 20]]]])
    #expect(!orbit.isError, "\(orbit.plainText)")
    let p = try box.session.project()
    #expect(p.clip(card)?.transform.threeD == true && p.clip(card)?.transform.z == 0.5)
    #expect(p.clip(cam)?.generatorValue("orbit", at: 2)?.number == 0)
    #expect(p.frameCoverage(p.clip(cam)!, at: 1) == 0)
}
