@testable import CutlineCore
import Foundation
import simd
import Testing

private func pq(_ nits: Float) -> SIMD3<Float> { SIMD3(repeating: Transfer.pqEncode(nits: nits)) }

@Test func hdrZoneWeightsCrossOverSmoothly() {
    let zones = HDRZones()
    for y in stride(from: -4.0, through: 14, by: 0.05) {
        let w = zones.weights(pow(2, y))
        #expect(abs(w.reduce(0, +) - 1) < 1e-9)
        #expect(w.allSatisfy { $0 >= -1e-12 && $0 <= 1 + 1e-12 })
    }
    for (i, n) in HDRZones.defaultNits.enumerated() { #expect(abs(zones.weights(n)[i] - 1) < 1e-9) }
    // Halfway (in stops) between light (80) and highlight (400) the two share equally.
    let mid = zones.weights((80.0 * 400).squareRoot())
    #expect(abs(mid[3] - 0.5) < 1e-9 && abs(mid[4] - 0.5) < 1e-9)
    // Tighter softness keeps each zone's full effect over more of its range.
    var tight = HDRZones()
    tight.softness = 0.3
    #expect(tight.weights(120)[3] == 1 && zones.weights(120)[3] < 1)
}

@Test func hdrZonesExposeAndSaturateByNits() {
    var zones = HDRZones()
    zones.exposure[5] = -1
    zones.saturation[3] = -1
    let f = zones.transform(.pq)
    // A 3000 cd/m² specular halves; diffuse light at 10 cd/m² is untouched.
    let spec = LightEncoding.pq.nits(f(pq(3000))).x
    #expect(abs(spec - 1500) / 1500 < 0.01, "\(spec)")
    let dark = LightEncoding.pq.nits(f(pq(10))).x
    #expect(abs(dark - 10) < 0.05, "\(dark)")
    // The light zone (80 cd/m²) loses its color but keeps its luminance.
    let w = LightEncoding.pq.lumaWeights
    let skin = SIMD3<Float>(120, 70, 50)
    let skinCode = LightEncoding.pq.encode(skin)
    let graded = LightEncoding.pq.nits(f(skinCode))
    #expect(graded.max() - graded.min() < 2, "\(graded)")
    #expect(abs((graded * w).sum() - (skin * w).sum()) < 1)
    #expect(HDRZones().isIdentity)
    // HLG and SDR read the same zones in their own light.
    let sdr = zones.transform(.sdr)(SIMD3(repeating: 1))
    #expect(abs(sdr.x - 1) < 1e-3)
}

@Test func sdrTrimPutsReferenceWhiteOnSDRWhiteAndFoldsHighlights() {
    for method in SDRTrim.Method.allCases {
        let f = SDRTrim(method: method).transform(from: .rec2020_pq)
        let grey = f(pq(0.18 * 203)).x, white = f(pq(203)).x, peak = f(pq(1000)).x, beyond = f(pq(4000)).x
        #expect(grey > 0.35 && grey < 0.55, "\(method) grey \(grey)")
        #expect(white > grey && peak >= white && beyond >= peak - 1e-4, "\(method) \(white) \(peak)")
        #expect(peak <= 1 && beyond <= 1)
        var last: Float = 0
        for n in stride(from: Float(0.01), through: 2000, by: 7) {
            let v = f(pq(n)).x
            #expect(v >= last - 1e-4)
            last = v
        }
    }
    let soft = SDRTrim(method: .bt2390).transform(from: .rec2020_pq), clip = SDRTrim(method: .clip).transform(from: .rec2020_pq)
    // The knee keeps highlights apart that a clip flattens.
    #expect(soft(pq(400)).x < soft(pq(800)).x && clip(pq(400)).x == clip(pq(800)).x)
    #expect(abs(soft(pq(1000)).x - 1) < 0.01)
    // A saturated BT.2020 green is gamut-compressed into Rec. 709 rather than clipped to a channel.
    let green = SDRTrim().transform(from: .rec2020_pq)(LightEncoding.pq.encode(SIMD3(0, 150, 0)))
    #expect(green.y > 0.5 && green.x >= 0 && green.z >= 0)
    let hlg = SDRTrim().transform(from: .rec2020_hlg)(LightEncoding.hlg.encode(SIMD3(repeating: 203)))
    #expect(abs(hlg.x - soft(pq(203)).x) < 0.02)
}

@Test func eetfAndRolloffKeepContentBelowTheKnee() {
    #expect(abs(SDRTrim.eetf(10, source: 1000, target: 100) - 10) < 0.01)
    #expect(abs(SDRTrim.eetf(1000, source: 1000, target: 100) - 100) < 0.5)
    #expect(SDRTrim.eetf(500, source: 1000, target: 100) < 100)
    let r = PeakRolloff(peakNits: 1000)
    #expect(r.curve(500) == 500 && r.curve(4000) < 1000 && r.curve(4000) > 985 && r.curve(900) < 900)
    let out = LightEncoding.pq.nits(r.transform(LightEncoding.pq.encode(SIMD3(4000, 2000, 400))))
    #expect(out.max() <= 1000.5)
    #expect(out.x > out.y && out.y > out.z && abs(out.z - 400) < 0.5, "order kept, light under the knee untouched: \(out)")
    var c = Canvas(colorSpace: .rec2020_pq)
    c.masterPeakNits = 1000
    #expect(c.peakRolloff?.peakNits == 1000)
    c.colorSpace = .rec709
    #expect(c.peakRolloff == nil)
    let data = try! JSONEncoder().encode(Canvas(colorSpace: .rec2020_pq))
    #expect(!String(decoding: data, as: UTF8.self).contains("masterPeakNits"))
}

@Test func hueCurvesWrapWithoutOvershoot() throws {
    let c = try HueCurves { $0 == .hue_sat ? "60,1 120,0.5 180,1" : nil }
    for h in stride(from: Float(0), to: 360, by: 1) {
        let v = c.value(.hue_sat, h)
        #expect(v >= 0.5 - 1e-4 && v <= 1 + 1e-4, "\(h): \(v)")
    }
    #expect(abs(c.value(.hue_sat, 120) - 0.5) < 1e-5 && abs(c.value(.hue_sat, 0) - 1) < 1e-5 && abs(c.value(.hue_sat, 270) - 1) < 1e-5)
    // Points across 0° join smoothly through 360.
    let wrap = try HueCurves { $0 == .hue_hue ? "350,10 10,10 180,0" : nil }
    #expect(abs(wrap.value(.hue_hue, 0) - 10) < 1e-4 && abs(wrap.value(.hue_hue, 359.5) - wrap.value(.hue_hue, 0.5)) < 0.05)
    // A single point is a bump.
    let bump = try HueCurves { $0 == .hue_lum ? "225,0.8" : nil }
    #expect(abs(bump.value(.hue_lum, 225) - 0.8) < 1e-5 && bump.value(.hue_lum, 100) == 1 && bump.value(.hue_lum, 200) < 1)
    #expect(throws: EditError.self) { _ = try HueCurves { $0 == .lum_sat ? "1.5,1" : nil } }
    #expect(throws: EditError.self) { _ = try HueCurves { $0 == .hue_sat ? "60,1 420,2" : nil } }
    #expect(throws: EditError.self) { try Effect.checkResource(type: "color.hue_curves", param: "hue_hue", value: .string("20,400")) }
}

@Test func hueCurvesDesaturateGreensAndShiftSkin() throws {
    let greens = try HueCurves { $0 == .hue_sat ? "60,1 120,0.5 180,1" : nil }.transform
    let green = SIMD3<Float>(0.2, 0.7, 0.2), red = SIMD3<Float>(0.8, 0.15, 0.1), gray = SIMD3<Float>(0.5, 0.5, 0.5)
    let g = greens(green)
    #expect(abs((g.y - g.x) - 0.25) < 0.02, "\(g)")
    #expect(abs(ColorMath.luma(g) - ColorMath.luma(green)) < 1e-3)
    #expect(simd_distance(greens(red), red) < 1e-4 && simd_distance(greens(gray), gray) < 1e-6)

    let skin = try HueCurves { $0 == .hue_hue ? "0,0 20,6 45,0" : nil }.transform
    let tone = SIMD3<Float>(0.85, 0.62, 0.5)
    let (h0, _, _) = ColorMath.rgbToHSL(tone)
    let (h1, _, _) = ColorMath.rgbToHSL(skin(tone))
    #expect(h1 - h0 > 3 && h1 - h0 < 6.5, "\(h0) → \(h1)")
    #expect(abs(ColorMath.luma(skin(tone)) - ColorMath.luma(tone)) < 2e-3)

    let shadows = try HueCurves { $0 == .lum_sat ? "0,0 0.4,1 1,1" : nil }.transform
    let dark = SIMD3<Float>(0.15, 0.05, 0.05), bright = SIMD3<Float>(0.9, 0.6, 0.6)
    #expect((shadows(dark).max() - shadows(dark).min()) < (dark.max() - dark.min()) * 0.8)
    #expect(simd_distance(shadows(bright), bright) < 1e-4)
    let catalog = try #require(EffectCatalog.type("color.hue_curves"))
    #expect(catalog.summary.contains("greens less saturated") && catalog.params.count >= 5 + EffectCatalog.limitSpecs.count)
    #expect(EffectCatalog.type("color.hdr_zones")?.params.contains { $0.name == "specular_exposure" } == true)
}

@Test func beatCutPlanPrefersQualityMatchesEnergyAndAvoidsRepeats() {
    let footage = [
        BeatFootage(mediaId: "a", range: TimeRange(0, 4), quality: 0.9, energy: 0.1),
        BeatFootage(mediaId: "a", range: TimeRange(4, 8), quality: 0.2, energy: 0.2),
        BeatFootage(mediaId: "b", range: TimeRange(0, 4), quality: 0.85, energy: 0.9),
        BeatFootage(mediaId: "b", range: TimeRange(4, 8), quality: 0.8, energy: 0.5),
    ]
    let quiet = BeatCutPlan.Segment(need: 1, energy: 0.1), loud = BeatCutPlan.Segment(need: 1, energy: 1)
    let plan = BeatCutPlan.choose(footage, segments: [quiet, loud, quiet, loud])
    let picked = plan.picks.compactMap { $0?.footage }
    #expect(picked.first == 0, "the best footage opens: \(picked)")
    #expect(picked[1] == 2, "the loud stretch gets the busy shot: \(picked)")
    #expect(!picked.contains(1) || picked.firstIndex(of: 1)! > 2)
    #expect(plan.repeats == 0 && plan.scored && plan.energyMatched)
    // Media alternate rather than one source hogging the cut.
    let media = picked.map { footage[$0].mediaId }
    #expect(zip(media, media.dropFirst()).filter { $0 == $1 }.count <= 1, "\(media)")

    // Footage runs out: every moment used before any repeats.
    let tiny = [BeatFootage(mediaId: "a", range: TimeRange(0, 3))]
    let tight = BeatCutPlan.choose(tiny, segments: Array(repeating: .init(need: 1, energy: nil), count: 4))
    let starts = tight.picks.compactMap { $0?.sourceIn }
    #expect(Set(starts.prefix(3).map { ($0 * 100).rounded() }).count == 3 && tight.repeats == 1, "\(starts)")
    #expect(BeatCutPlan.ranks([3, nil, 1, 2]) == [1, nil, 0, 0.5])
}

@Test func fillOffsetKeepsFacesInFrame() throws {
    // A 430×360 angle filling a 16:9 canvas is cropped top and bottom; a face high in the frame comes down into view.
    let face = NormRect(x: 0.42, y: 0.12, width: 0.16, height: 0.2)
    let f = try #require(Transform.fillOffset(sourceAspect: 430.0 / 360, canvasAspect: 16.0 / 9, subjects: [face], faces: true))
    let ph = (16.0 / 9) / (430.0 / 360)
    let faceTop = 0.5 + f.y + (face.y - 0.5) * ph, faceCenter = 0.5 + f.y + (face.midY - 0.5) * ph
    #expect(faceTop > 0.02 && abs(faceCenter - 0.4) < 0.08, "top \(faceTop), center \(faceCenter)")
    #expect(abs(f.x) < 1e-9 && f.y <= (ph - 1) / 2 + 1e-9)
    // A landscape shot on a vertical canvas pans to the face, never past the picture's edge.
    let side = try #require(Transform.fillOffset(sourceAspect: 16.0 / 9, canvasAspect: 9.0 / 16, subjects: [NormRect(x: 0.9, y: 0.3, width: 0.08, height: 0.15)], faces: true))
    let pw = (16.0 / 9) / (9.0 / 16)
    #expect(side.x < 0 && abs(side.x) <= (pw - 1) / 2 + 1e-9)
    #expect(Transform.fillOffset(sourceAspect: 16.0 / 9, canvasAspect: 16.0 / 9, subjects: [face], faces: true) == nil)
}

@Test func beatCutWithScoredFootageReportsItsPicks() throws {
    var p = Project(name: "Beats")
    p.canvas.fps = 25
    p.media = ["a", "b"].map { MediaAsset(id: $0, path: "/tmp/\($0).mov", name: $0, duration: 30, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false) }
    let footage = [BeatFootage(mediaId: "a", range: TimeRange(0, 10), quality: 1, energy: 0), BeatFootage(mediaId: "b", range: TimeRange(0, 10), quality: 0.5, energy: 1)]
    let beats = (0..<9).map { Double($0) * 0.5 }
    let note = try p.beatCut(footage: footage, beats: beats, every: 1, trackId: "V1", energy: { r in r.start >= 2 ? 1 : 0 }) { _ in (0, 0.1) }
    let clips = p.tracks[0].clips
    #expect(clips.count == 8 && clips.allSatisfy { $0.transform.y == 0.1 })
    #expect(clips.first?.mediaId == "a" && clips.last?.mediaId == "b", "\(clips.map { $0.mediaId ?? "" })")
    #expect(note.contains("motion following the music") && note.contains("a ×") && note.contains("framed"), "\(note)")
}
