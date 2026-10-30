import Foundation
import simd
import Testing
@testable import CutlineCore

/// The first frame's metadata of DJI's Inspire 3 ProRes RAW sample (camera → XYZ D65 matrix, 5400 K, gain 8.45).
private func proResRaw() -> RawMedia {
    var m = RawMedia(format: .prores_raw)
    m.colorMatrix = [0.6462026, 0.23321252, 0.070984885, 0.17767087, 1.0091001, -0.18677098, 0.12501451, -0.4386719, 1.4023573]
    m.whiteBalance = [2.671142578125, 1.74169921875]
    m.gain = 8.45118522644043
    m.temperature = 5400
    m.decodeScale = 1.11
    return m
}

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-3) -> Bool { simd_length(a - b) <= tol * max(1, simd_length(b)) }

@Test func blackbodyAndTintWhites() {
    let d65ish = CameraRaw.planckian(6504)
    #expect(abs(d65ish.x - 0.3135) < 0.002 && abs(d65ish.y - 0.3237) < 0.002, "\(d65ish)")
    let a = CameraRaw.planckian(2856)
    #expect(abs(a.x - 0.4476) < 0.003 && abs(a.y - 0.4074) < 0.003, "illuminant A \(a)")
    // Positive tint moves the light toward green (higher y at about the same x).
    let green = CameraRaw.whitePoint(kelvin: 5600, tint: 30), locus = CameraRaw.planckian(5600)
    #expect(green.y > locus.y + 0.005)
}

@Test func workingEncodingRoundTrips() {
    for v: Float in [0.001, 0.18, 1, 10, 100] {
        let c = SIMD3<Float>(v, v * 0.5, v * 0.25)
        #expect(close(CameraRaw.decode(CameraRaw.encode(c)), c, 2e-3), "\(c)")
    }
}

@Test func clipSettingsAdjustTheMedias() {
    let media = RawSettings(exposure: 1, temperature: 5600, tint: 4, highlights: 0.5)
    let clip = RawSettings(exposure: 0.5, tint: -2, noiseReduction: 0.3)
    let s = clip.over(media)
    #expect(s == RawSettings(exposure: 1.5, temperature: 5600, tint: 2, highlights: 0.5, noiseReduction: 0.3))
    #expect(RawSettings(temperature: 3200).over(media).temperature == 3200)
    #expect(s.baked == RawSettings(temperature: 5600, tint: 2, highlights: 0.5, noiseReduction: 0.3))
    #expect(RawSettings().summary == "as shot")
}

@Test func rawParametersLiveOnMediaClipsOfRawMedia() throws {
    var p = Project(name: "RAW")
    var m = MediaAsset(id: "a001", path: "/x/a001.mov", name: "A001", duration: 10, width: 4096, height: 2160, fps: 24, hasVideo: true, hasAudio: false)
    m.raw = proResRaw()
    var plain = MediaAsset(id: "b", path: "/x/b.mov", name: "B", duration: 10, width: 1920, height: 1080, fps: 24, hasVideo: true, hasAudio: false)
    plain.log = .slog3
    p.media = [m, plain]
    var c = Clip(id: "c1", kind: .media, mediaId: "a001", start: 0, duration: 2)
    #expect(!c.fixedSpecs.contains { $0.name == "raw.exposure" })
    try c.set("raw.exposure", .number(1.5))
    try c.set("raw.temperature", .number(3200))
    #expect(c.raw == RawSettings(exposure: 1.5, temperature: 3200))
    #expect(c.fixedSpecs.contains { $0.name == "raw.tint" })
    #expect(c.staticValue("raw.highlights") == .number(-1))
    #expect(throws: EditError.self) { try c.set("raw.tint", .number(500)) }
    try c.set("raw.temperature", .number(0))
    try c.set("raw.exposure", .number(0))
    #expect(c.raw == nil)
    try c.set("raw.highlights", .number(0.8))
    let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
    #expect(back.raw == RawSettings(highlights: 0.8))
    p.tracks[0].clips = [c]
    try p.validate()
    p.tracks[0].clips[0].mediaId = "b"
    #expect(throws: EditError.self) { try p.validate() }
    #expect(m.rawSettings(for: c) == RawSettings(highlights: 0.8))
    #expect(plain.rawSettings(for: c) == nil)
}

@Test func mediaRawSettingsAreSetByName() throws {
    var s = RawSettings()
    try s.set("exposure", 2)
    try s.set("noise_reduction", 0.4)
    try s.set("highlights", -1)
    #expect(s == RawSettings(exposure: 2, noiseReduction: 0.4))
    #expect(throws: EditError.self) { try s.set("contrast", 1) }
}

@Test func proResRawLiveControls() throws {
    let m = proResRaw()
    #expect(CameraRaw.liveAdjustment(m, RawSettings()) == nil)
    // As-shot white balance is the identity.
    let k = CameraRaw.whiteBalanceGains(m, kelvin: 5400, tint: 0)
    #expect(simd_length(k - SIMD3(repeating: 1)) < 1e-3, "\(k)")
    let gray = SIMD3<Float>(0.18, 0.18, 0.18)
    let up = try #require(CameraRaw.liveAdjustment(m, RawSettings(exposure: 1)))
    #expect(close(up(gray), gray * 2))
    let iso = try #require(CameraRaw.liveAdjustment({ var r = m; r.iso = 800; return r }(), RawSettings(iso: 3200)))
    #expect(close(iso(gray), gray * 4))
    // Neutralizing tungsten light pushes neutrals blue; a 9000 K light pushes them warm; + tint goes magenta.
    let coolAdjust = try #require(CameraRaw.liveAdjustment(m, RawSettings(temperature: 3200)))
    let warmAdjust = try #require(CameraRaw.liveAdjustment(m, RawSettings(temperature: 9000)))
    let tintAdjust = try #require(CameraRaw.liveAdjustment(m, RawSettings(tint: 40)))
    let cool = coolAdjust(gray), warm = warmAdjust(gray), magenta = tintAdjust(gray)
    #expect(cool.z > cool.x * 1.3, "\(cool)")
    #expect(warm.x > warm.z * 1.1, "\(warm)")
    #expect(magenta.x > magenta.y && magenta.z > magenta.y, "\(magenta)")
    // The developed copy enters the same input pipeline as camera log.
    let pipeline = ColorPipeline.inputTransform(log: CameraRaw.workingLog, target: .rec709, tone: .aces, exposure: 0, recordedIn: .full)
    let plain = CameraRaw.inputTransform(m, RawSettings(), target: .rec709, tone: .aces, exposure: 0)
    let code = CameraRaw.encode(gray)
    #expect(close(plain(code), pipeline(code)))
}

@Test func highlightRecoveryNeutralizesClippedChannels() {
    let clip = SIMD3<Double>(2, 1, 2)
    // Green clipped, red and blue still recording: the clipped chroma goes neutral at the unclipped mean.
    let u = SIMD3<Double>(1.6, 1, 1.3)
    let r = CameraRaw.recoverHighlights(u, clip: clip, amount: 1)
    #expect(abs(r.x - r.y) < 1e-9 && abs(r.y - r.z) < 1e-9, "\(r)")
    #expect(abs(r.sum() - u.sum()) < 1e-9)
    #expect(CameraRaw.recoverHighlights(SIMD3(0.5, 0.4, 0.3), clip: clip, amount: 1) == SIMD3(0.5, 0.4, 0.3))
    #expect(CameraRaw.recoverHighlights(u, clip: clip, amount: 0) == u)
}

@Test func rawMediaDecodesFromOlderProjects() throws {
    let json = #"{"id":"a","path":"/a.mov","name":"A","duration":1,"width":10,"height":10,"fps":24,"hasVideo":true,"hasAudio":false,"isImage":false}"#
    let m = try JSONDecoder().decode(MediaAsset.self, from: Data(json.utf8))
    #expect(m.raw == nil)
    var r = m
    r.raw = proResRaw()
    r.raw?.settings = RawSettings(exposure: 1)
    let back = try JSONDecoder().decode(MediaAsset.self, from: JSONEncoder().encode(r))
    #expect(back.raw == r.raw)
    #expect(String(decoding: try JSONEncoder().encode(RawSettings(noiseReduction: 0.2)), as: UTF8.self).contains("noise_reduction"))
}
