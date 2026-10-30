import Foundation
import Testing
@testable import CutlineCore

// Speed, reverse, freezes, ramps and picture transforms through AAF, FCPXML and FCP7 XML, and Media Composer's own
// motion effects (the OpenTimelineIO AAF adapter's samples, expected values from its tests).

/// V1: 2×, reversed, reversed at half speed, a freeze, a ramp down and back, and a reversed ramp. V2: a 4:3 clip
/// filled, positioned, rotated, faded and cropped; a 4:3 clip stretched and scaled; a 4K clip fit, scaled and keyed.
func motionProject() throws -> Project {
    var p = Project(name: "Motion", canvas: Canvas(fps: 25))
    p.media = [
        MediaAsset(id: "a", path: "/tmp/motion/a.mov", name: "a", duration: 300, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "b", path: "/tmp/motion/b.mov", name: "b", duration: 300, width: 1440, height: 1080, fps: 25, hasVideo: true, hasAudio: false),
        MediaAsset(id: "k", path: "/tmp/motion/k.mov", name: "k", duration: 300, width: 3840, height: 2160, fps: 25, hasVideo: true, hasAudio: false),
    ]
    func keys(_ pairs: [(Seconds, Double, Easing)]) -> Curve { Curve(keys: pairs.map { CurveKey(t: $0.0, v: .number($0.1), ease: $0.2) }) }
    var fast = Clip(id: "fast", kind: .media, mediaId: "a", start: 0, duration: 2, sourceIn: 10, speed: 2)
    fast.volume = 0
    var back = Clip(id: "back", kind: .media, mediaId: "b", start: 2, duration: 2, sourceIn: 30)
    back.reverse = true
    var slowBack = Clip(id: "slowback", kind: .media, mediaId: "b", start: 4, duration: 2, sourceIn: 50, speed: 0.5)
    slowBack.reverse = true
    var hold = Clip(id: "hold", kind: .media, mediaId: "b", start: 6, duration: 1.6, sourceIn: 70)
    Importer.freeze(&hold)
    var ramp = Clip(id: "ramp", kind: .media, mediaId: "b", start: 7.6, duration: 4, sourceIn: 90)
    ramp.anim["time.speed"] = keys([(0.4, 1, .linear), (1.2, 0.25, .easeInOut), (2.4, 0.25, .linear), (3.2, 1, .easeInOut)])
    var rampBack = Clip(id: "rampback", kind: .media, mediaId: "b", start: 11.6, duration: 3, sourceIn: 120)
    rampBack.reverse = true
    rampBack.anim["time.speed"] = keys([(0, 2, .linear), (3, 0.5, .linear)])
    p.tracks[0].clips = [fast, back, slowBack, hold, ramp, rampBack]

    var filled = Clip(id: "filled", kind: .media, mediaId: "b", start: 0, duration: 3, sourceIn: 5)
    filled.transform = Transform(fit: .fill, scale: 1, x: 0.1, y: -0.05, rotation: 15, opacity: 0.6, crop: Crop(left: 0.1, top: 0, right: 0, bottom: 0.05))
    var stretched = Clip(id: "stretched", kind: .media, mediaId: "b", start: 3, duration: 3, sourceIn: 5)
    stretched.transform = Transform(fit: .stretch, scale: 0.8, x: -0.2, y: 0.1)
    var keyed = Clip(id: "keyed", kind: .media, mediaId: "k", start: 6, duration: 3, sourceIn: 5)
    keyed.transform = Transform(fit: .fit, scale: 1.3)
    keyed.anim["transform.scale"] = keys([(0, 1.3, .linear), (2, 0.5, .linear)])
    keyed.anim["transform.x"] = keys([(0, -0.25, .linear), (3, 0.25, .linear)])
    let v2 = p.addTrack(kind: .video, name: "Picture")
    p.tracks[p.trackIndex(v2.id)!].clips = [filled, stretched, keyed]
    try p.validate()
    return p
}

private func reimport(_ format: InterchangeFormat, _ p: Project) throws -> ImportResult {
    let made = try p.interchange(format)
    switch format {
    case .aaf: return try Importer.aaf(made.data, relativeTo: nil)
    case .fcpxml: return try Importer.fcpxml(made.data, relativeTo: nil)
    default: return try Importer.xmeml(made.data, relativeTo: nil)
    }
}

/// The clip of `q` on the `n`th video track starting where `c` does.
private func counterpart(_ c: Clip, track n: Int, in q: Project) -> Clip? {
    let tracks = q.tracks.filter { $0.kind == .video && !$0.hidden }
    guard n < tracks.count else { return nil }
    return tracks[n].clips.first { abs($0.start - c.start) < 0.02 }
}

/// Source time shown every frame within half a frame, and the same direction.
private func expectSamePlayback(_ a: Clip, _ b: Clip, _ label: String) {
    #expect(a.reverse == b.reverse, "\(label) reverse")
    #expect(abs(a.duration - b.duration) < 0.02, "\(label) duration \(b.duration)")
    var worst = 0.0
    for f in 0..<Int((a.duration * 25).rounded()) {
        let t = a.start + Double(f) / 25
        worst = max(worst, abs(a.sourceTime(atTimeline: t) - b.sourceTime(atTimeline: t)))
    }
    #expect(worst < 0.5 / 25, "\(label) source off by \(worst)s")
}

@Test(arguments: [InterchangeFormat.aaf, .fcpxml, .xml]) func speedReverseFreezeAndRampsRoundTrip(format: InterchangeFormat) throws {
    let p = try motionProject()
    let r = try reimport(format, p)
    let q = r.project
    #expect(r.warnings.isEmpty, "\(format) \(r.warnings)")
    for c in p.tracks[0].clips {
        guard let d = counterpart(c, track: 0, in: q) else { Issue.record("\(format) \(c.id) missing"); continue }
        expectSamePlayback(c, d, "\(format) \(c.id)")
    }
    let hold = try #require(counterpart(p.tracks[0].clips[3], track: 0, in: q))
    #expect(hold.isRetimed && hold.speed(atLocal: 0.5) == 0 && abs(hold.sourceIn - 70) < 0.02, "\(format) freeze")
    let fast = try #require(counterpart(p.tracks[0].clips[0], track: 0, in: q))
    #expect(fast.speed == 2 && !fast.isRetimed && abs(fast.sourceIn - 10) < 0.02, "\(format) 2×")
    let ramp = try #require(counterpart(p.tracks[0].clips[4], track: 0, in: q))
    #expect(ramp.isRetimed && abs(ramp.speed(atLocal: 1.8) - 0.25) < 0.01 && abs(ramp.speed(atLocal: 3.6) - 1) < 0.01, "\(format) ramp")
    let notes = try p.interchange(format).notes
    #expect(!notes.contains { $0.contains("time.speed") || $0.contains("reverse") || $0.contains("speed ramp") }, "\(format) \(notes)")
}

private func expectSameFraming(_ a: Clip, _ b: Clip, _ label: String, position: Bool = true) {
    let s = a.transform, t = b.transform
    #expect(s.fit == t.fit && abs(s.scale - t.scale) < 2e-3, "\(label) fit \(t.fit) scale \(t.scale)")
    #expect(abs(s.rotation - t.rotation) < 1e-3 && abs(s.opacity - t.opacity) < 1e-3, "\(label) rotation \(t.rotation) opacity \(t.opacity)")
    #expect(abs(s.crop.left - t.crop.left) < 1e-3 && abs(s.crop.bottom - t.crop.bottom) < 1e-3 && abs(s.crop.top - t.crop.top) < 1e-3, "\(label) crop \(t.crop)")
    if position { #expect(abs(s.x - t.x) < 1e-3 && abs(s.y - t.y) < 1e-3, "\(label) position \(t.x) \(t.y)") }
}

@Test(arguments: [InterchangeFormat.aaf, .fcpxml, .xml]) func fitFillStretchAndTransformsRoundTrip(format: InterchangeFormat) throws {
    let p = try motionProject()
    let q = try reimport(format, p).project
    let v2 = p.tracks.first { $0.name == "Picture" }!
    for c in v2.clips {
        guard let d = counterpart(c, track: 1, in: q) else { Issue.record("\(format) \(c.id) missing"); continue }
        if format == .xml, c.id == "stretched" {
            // Basic Motion scales evenly: the 4:3 picture comes back fit, at the size of its height.
            #expect(d.transform.fit == .fit && abs(d.transform.scale - 0.8) < 1e-3, "xml stretch \(d.transform)")
            continue
        }
        if c.id == "keyed" {
            #expect(d.transform.fit == .fit && abs(d.transform.scale - 1.3) < 2e-3, "\(format) keyed \(d.transform)")
            guard format == .aaf else { continue }
            for t in stride(from: 0.0, through: 3, by: 0.25) {
                #expect(abs(c.resolvedTransform(at: t).scale - d.resolvedTransform(at: t).scale) < 2e-3, "aaf scale at \(t)")
                #expect(abs(c.resolvedTransform(at: t).x - d.resolvedTransform(at: t).x) < 2e-3, "aaf x at \(t)")
            }
            continue
        }
        expectSameFraming(c, d, "\(format) \(c.id)")
    }
    let notes = try p.interchange(format).notes
    #expect(!notes.contains { $0.contains("fill conform") || $0.contains("position, scale") }, "\(format) \(notes)")
    #expect(notes.contains { $0.hasPrefix("stretched") && $0.contains("stretch") } == (format == .xml), "\(format) \(notes)")
    #expect(notes.contains { $0.hasPrefix("keyed") && $0.contains("transform.scale") } == (format != .aaf), "\(format) \(notes)")
}

@Test func basicMotionScaleIsInTheMediaPixels() throws {
    let p = try motionProject()
    let xml = p.xmeml()
    // The 4K clip fit at 1.3: 50% of its pixels times 1.3; the 4:3 clip filled after its crop: 1920/1296.
    #expect(xml.contains("<value>65</value>"))
    #expect(xml.contains("<value>148.148148</value>"))
}

@Test func aafMotionControlIsWrittenAsMediaComposerWritesIt() throws {
    let p = try motionProject()
    let doc = p.aafDocument()
    var groups: [AAFObject] = []
    doc.header!.walk { o in if o.classID == AAFClass.operationGroup, o.weak(0x0b01).map({ AUID(bytes: $0.key) }) == AAFDef.videoSpeedControl { groups.append(o) } }
    func param(_ g: AAFObject, _ id: AUID) -> AAFObject? { g.objects(0x0b03).first { $0.auid(0x4c01) == id } }
    func ratio(_ g: AAFObject) -> (num: Int, den: Int)? {
        guard let b = param(g, AAFDef.speedRatio)?.bytes(0x4d01), b.count >= 25 else { return nil }
        return AAFCodec.rational(Array(b[17...]))
    }
    // 2× over 50 frames reads 99 input frames, SpeedRatio 50/99; the reversed clip's offsets run from its last frame.
    let fast = try #require(groups.first { $0.int(0x0202) == 50 && ratio($0).map { $0.num == 50 && $0.den == 99 } == true })
    #expect(fast.objects(0x0b02).first?.int(0x0202) == 99)
    let back = try #require(groups.first { ratio($0).map { $0.num == -50 && $0.den == 50 } == true })
    let offsets = try #require(param(back, AAFDef.avidSpeedOffsetMap)?.objects(0x4e02).compactMap { $0.bytes(0x1a02).flatMap(AAFCodec.indirectNumber) })
    #expect(offsets == [49, -1])
    // The freeze reads one frame; SpeedRatio is its length over one.
    #expect(groups.contains { $0.int(0x0202) == 40 && ratio($0).map { $0.num == 40 && $0.den == 1 } == true && $0.objects(0x0b02).first?.int(0x0202) == 1 })

    // Every object has its required properties and a declared class, and every weak reference resolves.
    let declared = Set(doc.metaDictionary!.objects(0x0003).compactMap { $0.auid(0x0005) })
    var missing: [String] = [], undeclared = Set<String>(), dangling = 0
    doc.header!.walk { o in
        missing += AAFMetaModel.shared.missingRequired(o)
        if !declared.contains(o.classID) { undeclared.insert(o.classID.description) }
        for prop in o.properties {
            switch prop.value {
            case .weak(let w): if doc.resolve(w) == nil { dangling += 1 }
            case .weakSet(let ws), .weakVector(let ws): dangling += ws.filter { doc.resolve($0) == nil }.count
            default: break
            }
        }
    }
    #expect(missing.isEmpty && undeclared.isEmpty && dangling == 0, "\(missing) \(undeclared) \(dangling)")
    let ops = Set(doc.header!.strong(0x3b04)!.objects(0x2603).compactMap { $0.auid(0x1b01) })
    #expect(ops.isSuperset(of: [AAFDef.videoSpeedControl, AAFDef.videoCrop, AAFDef.videoScale, AAFDef.videoRotate, AAFDef.videoPosition, AAFDef.videoOpacity]))
}

// MARK: Media Composer samples

private func avid(_ name: String) throws -> ImportResult {
    let url = try #require(Bundle.module.url(forResource: name + ".aaf", withExtension: "lzfse", subdirectory: "Fixtures/aaf"))
    return try Importer.aaf((Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data, relativeTo: nil)
}

/// Signed speed rounded to hundredths: negative reversed, 0 frozen, nil at 1× forward.
private func speedLabel(_ c: Clip) -> Double? {
    if c.isRetimed { return c.speed(atLocal: c.duration / 2) == 0 ? 0 : -999 }
    if c.speed == 1, !c.reverse { return nil }
    return ((c.reverse ? -c.speed : c.speed) * 100).rounded() / 100
}

@Test func mediaComposerSpeedEffectsRead() throws {
    let q = try avid("misc_speed_effects").project
    let v = try #require(q.tracks.first { $0.kind == .video })
    #expect(v.clips.count == 10)
    #expect(v.clips.prefix(9).map(speedLabel) == [nil, 0, 2, 0.5, 3, 0.38, 14.38, 0.38, -1])
    #expect(v.clips.allSatisfy { abs($0.duration * 24 - ($0 == v.clips.last! ? 16 : 8)) < 0.01 })
    // The reversed clip shows input frames 31 back to 24: its source out is a frame past 31.
    let back = v.clips[8]
    #expect(abs(back.sourceOut - back.sourceIn - 8.0 / 24) < 1e-6)
    // The speed bump: fast, slow in the middle, fast again, over 15 input frames.
    let bump = v.clips[9]
    #expect(bump.isRetimed && bump.speed(atLocal: 0.05) > bump.speed(atLocal: 0.33) && bump.speed(atLocal: 0.62) > bump.speed(atLocal: 0.33))
    #expect(abs(bump.sourceOffset(atLocal: bump.duration) - 16.0 / 24) < 1.5 / 24)
}

@Test func mediaComposerTimeWarpSuiteReads() throws {
    let q = try avid("time_warp_test").project
    let v = try #require(q.tracks.first { $0.kind == .video })
    // As the adapter's test: whole clip, segments, freezes, speeds, fit-to-fill, trim-to-fill and reverse.
    let expected: [Double?] = [nil, nil, nil, nil, 0, 0, 0, nil, 0.99, 0.9, 0.5, 0.1, 1.01, 1.1, 2, 10,
                               0.99, 0.9, 0.5, 0.33, 0.05, 1.01, 2, 3.03, 10, 11.11, 0.99, 0.9, 0.5, 0.33, 0.05, 1.01, 2, 3.03, 10, 11.11,
                               -1, -0.5, -2, -0.3, -1.2]
    #expect(Array(v.clips.prefix(41).map(speedLabel)) == expected)
}

@Test func mediaComposerRampAnd3DWarpRead() throws {
    let r = try avid("keyframed_properties")
    let clips = r.project.tracks.filter { $0.kind == .video }.flatMap(\.clips)
    // A ramp from a standstill to 1× over 276 frames reads 138 input frames.
    let ramp = try #require(clips.first { $0.isRetimed })
    #expect(abs(ramp.duration * 24 - 276) < 0.01)
    #expect(ramp.speed(atLocal: 0.2) < 0.1 && ramp.speed(atLocal: ramp.duration - 0.2) > 0.9)
    #expect(abs(ramp.sourceOffset(atLocal: ramp.duration) * 24 - 138) < 1.5)
    #expect(clips.contains { $0.speed == 1.5 } && clips.contains { $0.speed == 0.8 } && clips.contains { $0.speed == 0.3 })
    // 3D Warp scale keyed from 22% to 100%.
    let grown = try #require(clips.first { $0.anim["transform.scale"] != nil })
    #expect(abs(grown.resolvedTransform(at: 0).scale - 0.22) < 1e-3 && abs(grown.resolvedTransform(at: grown.duration).scale - 1) < 1e-3)
    #expect(r.warnings.contains { $0.hasPrefix("3D Warp") })
}
