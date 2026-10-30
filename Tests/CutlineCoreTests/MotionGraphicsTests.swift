import Foundation
import Testing
@testable import CutlineCore

// MARK: Paths

@Test func svgPathsParseAndMeasure() throws {
    let tri = try ShapePath.svg("M0 0 L10 0 L10 10 Z")
    #expect(tri.contours.count == 1 && tri.contours[0].closed)
    #expect(abs(tri.length - (20 + 200.0.squareRoot())) < 1e-6)
    let rel = try ShapePath.svg("m 0 0 h 10 v 10 h -10 z")
    #expect(abs(rel.length - 40) < 1e-6)
    let arc = try ShapePath.svg("M 0 0 A 5 5 0 0 1 10 0")
    #expect(abs(arc.length - 5 * .pi) < 0.01, "\(arc.length)")
    let quad = try ShapePath.svg("M0,0 Q5,10 10,0 T20,0")
    #expect(quad.contours[0].segments.count == 2)
    #expect(throws: EditError.self) { try ShapePath.svg("L 1 2") }
    #expect(throws: EditError.self) { try ShapePath.svg("M 0 0 L 1") }
    #expect(abs(ShapePath.ellipse(width: 2, height: 2).length - 2 * .pi) < 0.002)
}

@Test func trimKeepsTheRequestedShareOfLength() throws {
    let circle = ShapePath.ellipse(width: 2, height: 2)
    let total = circle.length
    for (s, e, o) in [(0.0, 0.25, 0.0), (0.2, 0.7, 0.0), (0.0, 0.4, 0.8), (0.6, 0.1, 0.0)] {
        let part = circle.trimmed(start: s, end: e, offset: o)
        #expect(abs(part.length - abs(e - s) * total) < 0.002, "\(s)…\(e)+\(o): \(part.length)")
    }
    // Wrapping past the end of a closed contour stays one stroke.
    #expect(circle.trimmed(start: 0, end: 0.4, offset: 0.8).contours.count == 1)
    #expect(circle.trimmed(start: 0.3, end: 0.3).isEmpty)
    // The first quarter of a circle starting at 12 o'clock ends at 3 o'clock.
    let q = circle.trimmed(start: 0, end: 0.25)
    let end = q.contours[0].segments.last!.end
    #expect(abs(end.x - 1) < 1e-3 && abs(end.y) < 1e-3)
    let line = ShapePath.line(length: 4).trimmed(start: 0.25, end: 0.5)
    #expect(line.contours[0].start == PathPoint(-1, 0) && line.contours[0].segments.last!.end == PathPoint(0, 0))
}

@Test func morphBlendsMatchingPaths() throws {
    let a = try ShapePath.svg("M0 0 L10 0 L10 10 Z"), b = try ShapePath.svg("M0 0 L20 0 L20 20 Z")
    let mid = try #require(a.morph(to: b, 0.5))
    #expect(abs(mid.contours[0].segments[1].end.x - 15) < 1e-9)
    #expect(a.morph(to: try ShapePath.svg("M0 0 L1 1"), 0.5) == nil)
}

// MARK: Shape layers

@Test func shapeListsParseWithHelpfulErrors() throws {
    let items = try ShapeLayers.parse(##"[{"type": "ellipse", "stroke": "#FF0000"}, {"id": "bar", "type": "rect", "fill": "none", "dash": [0.02, 0.01]}]"##)
    #expect(items.map(\.id) == ["s1", "bar"])
    #expect(items[0].value("fill").color?.a == 0, "a stroked shape has no fill by default")
    #expect(items[0].value("stroke_width").number == 0.006)
    #expect(items[1].dash == [0.02, 0.01])
    let unknown = #expect(throws: EditError.self) { try ShapeLayers.parse(##"[{"type": "rect", "trimend": 0.5}]"##) }
    #expect(unknown?.message.contains("trim_end") == true)
    #expect(throws: EditError.self) { try ShapeLayers.parse(##"[{"id": "a"}, {"id": "a"}]"##) }
    #expect(throws: EditError.self) { try ShapeLayers.parse(##"[{"type": "path"}]"##) }
    #expect(throws: EditError.self) { try ShapeLayers.parse(##"[{"d": "M0 0 L1 0", "d_to": "M0 0 L1 0 L1 1"}]"##) }
    #expect(throws: EditError.self) { try ShapeLayers.parse(##"[{"type": "rect", "opacity": 3}]"##) }
}

@Test func shapePropertiesAreClipPaths() throws {
    let shapes = ##"[{"id": "ring", "type": "ellipse", "stroke": "#FFFFFF", "trim_end": 0.3}]"##
    var c = Clip(id: "g", kind: .generator, start: 0, duration: 4, effects: [Effect(id: "gen", type: "shape", params: ["shapes": .string(shapes)])])
    #expect(c.staticValue("fx.gen.ring.trim_end") == .number(0.3))
    #expect(try c.spec("fx.gen.ring.trim_end").animatable)
    try c.animate("fx.gen.ring.trim_end", keys: [CurveKey(t: 0, v: .number(0)), CurveKey(t: 2, v: .number(1), ease: .linear)])
    #expect(c.generatorValue("ring.trim_end", at: 1)?.number == 0.5)
    try c.set("fx.gen.ring.stroke", .string("#FF0000"))
    #expect(c.generatorValue("ring.stroke", at: 0)?.string == "#FF0000FF" || c.generatorValue("ring.stroke", at: 0)?.string == "#FF0000")
    #expect(c.parameterTree().contains { $0.path == "fx.gen.ring.trim_end" && $0.animated == 2 })
    let missing = #expect(throws: EditError.self) { try c.spec("fx.gen.ring.trim") }
    #expect(missing?.message.contains("ring") == true)
    #expect(throws: EditError.self) { try c.set("fx.gen.shapes", .string("[{\"type\": \"blob\"}]")) }
}

// MARK: Camera

@Test func defaultCameraSeesTheCanvasAsIs() {
    let cam = SceneCamera(width: 1920, height: 1080)
    let p = cam.project(Vec3(300, 200, 0))!
    #expect(abs(p.x - 300) < 1e-9 && abs(p.y - 200) < 1e-9)
    // One frame height back, offsets from the center shrink by f / (f + H).
    let f = 540 / tan(20 * Double.pi / 180)
    let q = cam.project(Vec3(960 + 100, 540, 1080))!
    #expect(abs((q.x - 960) - 100 * f / (f + 1080)) < 1e-6)
    #expect(cam.project(Vec3(960, 540, -f - 1)) == nil, "behind the lens")
}

@Test func cameraOrbitsTiltsAndRolls() {
    let right = SceneCamera(width: 1000, height: 1000) { $0 == "orbit" ? 90 : nil }
    // From the right, a point farther away on the z axis appears to the right of center.
    #expect(right.project(Vec3(500, 500, 300))!.x > 500)
    #expect(right.position.x > 500)
    let above = SceneCamera(width: 1000, height: 1000) { $0 == "tilt" ? 30 : nil }
    #expect(above.position.y < 500)
    #expect(above.project(Vec3(500, 500, 300))!.y < 500, "looking down, farther points rise")
    let rolled = SceneCamera(width: 1000, height: 1000) { $0 == "roll" ? 90 : nil }
    let r = rolled.project(Vec3(600, 500, 0))!
    #expect(abs(r.x - 500) < 1e-6 && abs(r.y - 600) < 1e-6, "rolling 90° turns the picture clockwise")
}

@Test func layerRotationsFollowTheirConventions() {
    let tilt = LayerPlacement3D(anchor: Vec3(0, 0, 0), scale: 1, rotateX: 30, rotateY: 0, rotateZ: 0)
    #expect(tilt.world(0, -10).z > 0, "rotate_x tips the top away")
    let turn = LayerPlacement3D(anchor: Vec3(0, 0, 0), scale: 1, rotateX: 0, rotateY: 30, rotateZ: 0)
    #expect(turn.world(10, 0).z > 0, "rotate_y turns the right side away")
    let roll = LayerPlacement3D(anchor: Vec3(0, 0, 0), scale: 2, rotateX: 0, rotateY: 0, rotateZ: 90)
    let p = roll.world(10, 0)
    #expect(abs(p.x) < 1e-9 && abs(p.y - 20) < 1e-9, "clockwise in a y-down frame")
}

@Test func threeDTransformRoundTrips() throws {
    var c = Clip(id: "t", kind: .text, start: 0, duration: 2, text: TextSpec(text: "Hi"))
    try c.set("transform.3d", .bool(true))
    try c.set("z", .number(1.5))
    try c.set("transform.rotate_z", .number(20))
    #expect(c.transform.threeD && c.transform.z == 1.5 && c.transform.rotation == 20)
    try c.animate("transform.z", keys: [CurveKey(t: 0, v: .number(0)), CurveKey(t: 2, v: .number(4), ease: .linear)])
    #expect(c.resolvedTransform(at: 1).z == 2)
    let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
    #expect(back.transform == c.transform)
    let plain = try JSONDecoder().decode(Transform.self, from: JSONEncoder().encode(Transform()))
    #expect(!plain.threeD && plain.z == 0)
}

// MARK: Particles

@Test func particlesComeFromTheSeedAlone() {
    let defaults = GeneratorCatalog.type("particles")!
    func run(_ t: Double, _ overrides: [String: ParamValue]) -> [Particle] {
        ParticleSystem.particles(at: t, width: 640, height: 360) { k, _ in overrides[k] ?? defaults.spec(k)!.defaultValue }
    }
    let a = run(2, [:]), b = run(2, [:])
    #expect(a == b && !a.isEmpty)
    #expect(run(2, ["seed": .number(9)]) != a)
    #expect(run(0, [:]).isEmpty)
    #expect(run(0.5, ["burst": .number(30), "rate": .number(0)]).count == 30)
    // Gravity pulls the fountain down over time: the mean height of old particles sinks.
    let late = run(4, ["rate": .number(200), "spread": .number(0), "speed_random": .number(0)])
    let young = late.filter { $0.age < 0.2 }, old = late.filter { $0.age > 0.6 }
    let oldFall: Double = old.map(\.vy).reduce(0, +) / Double(old.count)
    let youngFall: Double = young.map(\.vy).reduce(0, +) / Double(young.count)
    #expect(oldFall > youngFall)
    // Sizes shrink over life with size_end 0.
    let shrinking = run(2, ["size_end": .number(0), "size_random": .number(0)])
    let oldest = shrinking.max { $0.age < $1.age }!, newest = shrinking.min { $0.age < $1.age }!
    #expect(oldest.size < newest.size)
}

@Test func emitterPositionIsReadWhenEachParticleIsBorn() {
    let defaults = GeneratorCatalog.type("particles")!
    // The emitter jumps from the left to the right at 1 s; particles born before stay on the left.
    let ps = ParticleSystem.particles(at: 1.2, width: 1000, height: 1000) { k, t in
        switch k {
        case "x": return .number(t < 1 ? 0.2 : 0.8)
        case "speed", "gravity", "speed_random": return .number(0)
        default: return defaults.spec(k)!.defaultValue
        }
    }
    #expect(ps.contains { abs($0.x - 200) < 1 } && ps.contains { abs($0.x - 800) < 1 })
}

// MARK: Expressions

@Test func wiggleIsSmoothBoundedAndRepeatable() throws {
    var c = Clip(id: "c", kind: .solid, start: 0, duration: 10)
    try c.wiggle("transform.x", freq: 3, amp: 0.05)
    let values = stride(from: 0.0, through: 10, by: 1.0 / 60).map { c.number("transform.x", at: $0) }
    #expect(values.allSatisfy { abs($0) <= 0.05 + 1e-9 })
    #expect(values.contains { abs($0) > 0.02 }, "it moves")
    #expect(zip(values, values.dropFirst()).allSatisfy { abs($0 - $1) < 0.01 }, "smooth at 60 fps")
    var d = Clip(id: "c", kind: .solid, start: 0, duration: 10)
    try d.wiggle("transform.x", freq: 3, amp: 0.05)
    #expect(d.number("transform.x", at: 3.3) == c.number("transform.x", at: 3.3))
    try d.wiggle("transform.y", freq: 3, amp: 0.05)
    #expect(d.number("transform.y", at: 3.3) != d.number("transform.x", at: 3.3), "each path wiggles its own way")
    // Clamped to the parameter's range.
    try d.wiggle("transform.opacity", freq: 2, amp: 2)
    #expect(stride(from: 0.0, through: 5, by: 0.1).allSatisfy { (0...1).contains(d.number("transform.opacity", at: $0)) })
    #expect(throws: EditError.self) { try d.wiggle("time.speed", freq: 1, amp: 0.1) }
    #expect(throws: EditError.self) { try d.wiggle("fade.in", freq: 1, amp: 0.1) }
}

@Test func rateAndLoopRunOnTheClipClock() throws {
    var c = Clip(id: "c", kind: .solid, start: 5, duration: 10)
    try c.addRate("transform.rotation", rate: 90)
    #expect(c.number("transform.rotation", at: 2) == 180)
    try c.animate("transform.scale", keys: [CurveKey(t: 0, v: .number(1), ease: .linear), CurveKey(t: 1, v: .number(2), ease: .linear)])
    try c.loop("transform.scale", .cycle)
    #expect(abs(c.number("transform.scale", at: 2.25) - 1.25) < 1e-9)
    try c.loop("transform.scale", .pingpong)
    #expect(abs(c.number("transform.scale", at: 1.25) - 1.75) < 1e-9)
    #expect(abs(c.number("transform.scale", at: 2.25) - 1.25) < 1e-9)
    // Trimming the head keeps the expression on the same timeline moments.
    let before = c.number("transform.rotation", at: 4)
    let shifted = c.anim["transform.rotation"]!.shifted(by: -1)
    #expect(shifted.value(at: 3)?.number == before)
    // Survives saving.
    let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
    #expect(back.anim == c.anim)
    var flat = Clip(id: "d", kind: .solid, start: 0, duration: 3)
    #expect(throws: EditError.self) { try flat.loop("transform.scale", .cycle) }
}

@Test func linkedParametersFollowTheirSource() throws {
    var p = Project(name: "Link", canvas: Canvas(width: 1920, height: 1080, fps: 30))
    var lead = Clip(id: "lead", kind: .solid, start: 0, duration: 10)
    try lead.animate("transform.rotation", keys: [CurveKey(t: 0, v: .number(0), ease: .linear), CurveKey(t: 4, v: .number(40), ease: .linear)])
    try p.addClip(lead, trackId: "V1", mode: .place)
    let v2 = p.addTrack(kind: .video, name: "V2").id
    try p.addClip(Clip(id: "follow", kind: .solid, start: 2, duration: 8), trackId: v2, mode: .place)
    var follower = p.clip("follow")!
    try p.link(&follower, path: "transform.rotation", to: CurveLink(clip: "lead", path: "rotation", scale: 0.5, offset: 10, delay: 1))
    let loc = p.locateClip("follow")!
    p.tracks[loc.track].clips[loc.clip] = follower
    // Timeline 4 s is follower local 2 s; the lead was at 4 − 1 = 3 s: 30° × 0.5 + 10.
    #expect(abs(p.clip("follow")!.number("transform.rotation", at: 2) - 25) < 1e-9)
    // Editing the source updates the follower on refresh.
    let li = p.locateClip("lead")!
    try p.tracks[li.track].clips[li.clip].animate("transform.rotation", keys: [CurveKey(t: 0, v: .number(0), ease: .linear), CurveKey(t: 4, v: .number(80), ease: .linear)])
    p.refreshLinks()
    #expect(abs(p.clip("follow")!.number("transform.rotation", at: 2) - 40) < 1e-9)
    // A wiggling source is sampled per frame.
    try p.tracks[li.track].clips[li.clip].wiggle("transform.rotation", freq: 1, amp: 5)
    p.refreshLinks()
    let srcValue = p.clip("lead")!.number("transform.rotation", at: 3)
    #expect(abs(p.clip("follow")!.number("transform.rotation", at: 2) - (srcValue * 0.5 + 10)) < 1e-6)
    #expect(throws: EditError.self) { try p.link(&follower, path: "transform.rotation", to: CurveLink(clip: "follow", path: "transform.x")) }
    #expect(throws: EditError.self) { try p.link(&follower, path: "transform.rotation", to: CurveLink(clip: "nope", path: "transform.x")) }
    // Copies of linked clips (templates) follow the copied source.
    var copyLead = p.clip("lead")!, copyFollow = p.clip("follow")!
    copyLead.id = "lead2"
    copyLead.anim["transform.rotation"] = Curve(keys: [CurveKey(t: 0, v: .number(100))])
    copyFollow.id = "follow2"
    let v3 = p.addTrack(kind: .video, name: "V3").id, v4 = p.addTrack(kind: .video, name: "V4").id
    try p.addClip(copyLead, trackId: v3, mode: .place)
    try p.addClip(copyFollow, trackId: v4, mode: .place)
    p.relink(["lead": "lead2", "follow": "follow2"])
    #expect(p.clip("follow2")!.anim["transform.rotation"]?.link?.clip == "lead2")
    #expect(abs(p.clip("follow2")!.number("transform.rotation", at: 2) - 60) < 1e-9)
}
