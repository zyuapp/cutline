import CoreGraphics
@testable import CutlineCore
import Foundation
import Testing

@Test func clipsListTheShotsTheyPlay() {
    #expect(Shot.ranges(cuts: [2, 5], duration: 8) == [TimeRange(0, 2), TimeRange(2, 5), TimeRange(5, 8)])
    let c = Clip(id: "a", kind: .media, mediaId: "m", start: 10, duration: 4, sourceIn: 1)
    #expect(c.shots(cuts: [2, 5, 7], mediaDuration: 8) == [TimeRange(1, 2), TimeRange(2, 5)])
    #expect(c.timelineSpan(ofSource: TimeRange(2, 5)) == TimeRange(11, 14))
    var r = c
    r.reverse = true
    #expect(r.shots(cuts: [2, 5, 7], mediaDuration: 8) == [TimeRange(2, 5), TimeRange(1, 2)], "reversed clips play their last shot first")
}

@Test func shotLimitedEffectsActOnlyInTheirShot() throws {
    var c = Clip(id: "a", kind: .media, mediaId: "m", start: 10, duration: 4, sourceIn: 1)
    c.effects = [Effect(id: "all", type: "color.wheels"), Effect(id: "s2", type: "color.wheels", sourceRange: TimeRange(2, 5))]
    #expect(c.effects(atTimeline: 10.5).map(\.enabled) == [true, false])
    #expect(c.effects(atTimeline: 12).map(\.enabled) == [true, true])
    let json = try JSONEncoder().encode(c.effects[1])
    #expect(try JSONDecoder().decode(Effect.self, from: json) == c.effects[1])
    let old = try JSONDecoder().decode(Effect.self, from: Data(#"{"id": "x", "type": "color.wheels"}"#.utf8))
    #expect(old.sourceRange == nil && old.acts(atSource: 100))
}

@Test func splittingAtShotsKeepsEachShotsOwnGrade() throws {
    var p = Project(name: "Shots", canvas: Canvas(width: 320, height: 180, fps: 25))
    var c = Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 6, sourceIn: 0)
    c.effects = [Effect(id: "base", type: "color.wheels"), Effect(id: "s1", type: "color.wheels", sourceRange: TimeRange(0, 2)), Effect(id: "s3", type: "color.wheels", sourceRange: TimeRange(4.01, 9))]
    c.anim["fx.s3.saturation"] = Curve(keys: [CurveKey(t: 4.5, v: .number(0.2))])
    p.tracks[0].clips = [c]
    let pieces = try p.splitAtShots("a", cuts: [2, 4.01, 7])
    #expect(pieces.count == 3 && pieces[0] == "a")
    let clips = pieces.compactMap { p.clip($0) }
    #expect(clips.map(\.start) == [0, 2, 4], "cuts snap to frames: \(clips.map(\.start))")
    #expect(clips[0].effects.map(\.id) == ["base", "s1"] && clips[0].effects[1].sourceRange == nil)
    #expect(clips[1].effects.map(\.id) == ["base"])
    #expect(clips[2].effects.map(\.id) == ["base", "s3"] && clips[2].anim["fx.s3.saturation"] != nil)
    #expect(clips[0].anim["fx.s3.saturation"] == nil)
    #expect(try p.splitAtShots(pieces[1], cuts: [2, 4.01]) == [pieces[1]], "a clip inside one shot stays whole")
}

@Test func captionsStayInsideVerticalPlatformUI() {
    let safe = Platform.verticalSafe
    for pl in Platform.vertical { #expect(pl.safe.contains(safe), "\(pl.id)") }
    var p = Project(name: "V", canvas: Canvas(width: 1080, height: 1920, fps: 30))
    p.captions.style = CaptionStyle(size: 0.075, weight: 900, strokeWidth: 0.1, uppercase: true, y: 0.82, maxWordsPerLine: 3, maxLines: 1, animation: .pop)
    let shown = p.captionStyle
    let x = shown.x ?? 0.5
    #expect(x - shown.maxWidth / 2 >= safe.minX && x + shown.maxWidth / 2 <= safe.maxX, "\(shown)")
    let h = shown.estimatedHeight(canvas: p.canvas)
    #expect(shown.y - h / 2 >= safe.minY - 1e-9 && shown.y + h / 2 <= safe.maxY + 1e-9, "\(shown.y) ± \(h / 2)")
    #expect(shown.y < 0.82 && shown.maxWidth < 0.86)

    p.captions.platform = "none"
    #expect(p.captionStyle == p.captions.style, "none places them exactly as set")
    p.captions.platform = "tiktok"
    #expect(p.captionStyle.y + h / 2 <= Platform.named("tiktok")!.safe.maxY + 1e-9)

    var wide = Project(name: "W", canvas: Canvas(width: 1920, height: 1080, fps: 30))
    #expect(wide.captionSafeArea == nil && wide.captionStyle == wide.captions.style, "16:9 without a platform is left alone")
    wide.captions.enabled = true
    let placed = wide.placingCaptions(for: Platform.named("youtube"))
    #expect(placed.captions.platform == "youtube" && placed.captionStyle == wide.captions.style, "the default style already clears YouTube's UI")
    var inside = CaptionStyle(y: 0.5, maxWidth: 0.5)
    inside = inside.fitted(in: safe, canvas: p.canvas)
    #expect(inside == CaptionStyle(y: 0.5, maxWidth: 0.5), "captions already inside don't move")
}

@Test func particlePresetsAreCompleteEmitters() throws {
    let type = try #require(GeneratorCatalog.type("particles"))
    for name in ParticleSystem.presetNames {
        let values = try #require(ParticleSystem.presets[name])
        for (k, v) in values {
            let spec = try #require(type.spec(k), "\(name).\(k) is not a particles parameter")
            #expect(throws: Never.self, "\(name).\(k)") { try spec.validate(v, path: k) }
        }
    }
    #expect(type.spec("preset")?.kind == .choice(["none"] + ParticleSystem.presetNames))
    var c = Clip(id: "g", kind: .generator, start: 0, duration: 5, effects: [Effect(id: "gen", type: "particles", params: ["preset": .string("snow"), "rate": .number(10)])])
    #expect(c.generatorValue("sprite", at: 1) == .string("snow"))
    #expect(c.generatorValue("rate", at: 1) == .number(10), "a parameter set by hand overrides the preset")
    #expect(c.staticValue("fx.gen.lifetime") == .number(9))
    c.effects[0].params["preset"] = .string("none")
    #expect(c.generatorValue("sprite", at: 1) == type.spec("sprite")?.defaultValue)
    let snow = ParticleSystem.particles(at: 2, width: 640, height: 360) { k, t in Clip(id: "g", kind: .generator, start: 0, duration: 5, effects: [Effect(id: "gen", type: "particles", params: ["preset": .string("snow")])]).generatorValue(k, at: t) ?? .number(0) }
    #expect(snow.count > 100, "prewarmed snow fills the frame: \(snow.count)")
}

@Test func effectParametersAcceptCommonNames() throws {
    let cases: [(String, String, String)] = [
        ("color.curves", "all", "master"), ("color.curves", "rgb", "master"), ("color.curves", "luma", "master"), ("color.curves", "r", "red"),
        ("audio.eq", "low_cut", "highpass_hz"), ("audio.eq", "hpf", "highpass_hz"), ("audio.eq", "high_cut", "lowpass_hz"), ("audio.eq", "lpf", "lowpass_hz"),
        ("audio.eq", "bass", "low_gain"), ("audio.eq", "treble", "high_gain"),
        ("audio.compressor", "attack", "attack_ms"), ("audio.compressor", "release", "release_ms"), ("audio.compressor", "thresh", "threshold"),
        ("color.wheels", "sat", "saturation"), ("color.wheels", "temp", "temperature"), ("color.adjust", "warmth", "temperature"),
        ("blur.gaussian", "amount", "radius"), ("blur.gaussian", "blur", "radius"), ("stylize.vignette", "opacity", "mix"),
        ("audio.pitch", "pitch", "semitones"), ("particles", "count", "rate"), ("particles", "life", "lifetime"),
    ]
    for (type, given, expected) in cases {
        let t = try #require(EffectCatalog.type(type), "\(type)")
        #expect(t.paramName(for: given) == expected, "\(type) \(given) → \(t.paramName(for: given) ?? "nil")")
    }
    var c = Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 2)
    c.effects = [Effect(id: "eq1", type: "audio.eq"), Effect(id: "curves1", type: "color.curves")]
    #expect(c.resolvedPath("fx.eq1.low_cut") == "fx.eq1.highpass_hz")
    #expect(c.resolvedPath("fx.curves1.all") == "fx.curves1.master")
    #expect(c.resolvedPath("fx.curves1.master") == "fx.curves1.master" && c.resolvedPath("opacity") == "transform.opacity")
}
