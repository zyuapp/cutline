import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation
import Testing

/// Premultiplied RGBA bytes of an image.
private struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ img: CGImage) {
        width = img.width
        height = img.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        data = bytes
    }

    /// y from the top.
    func at(_ x: Int, _ y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return data[i..<i + 4].map(Int.init)
    }

    func alpha(_ x: Int, _ y: Int) -> Int { at(x, y)[3] }

    var opaqueCount: Int { stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + (data[$1] > 8 ? 1 : 0) } }

    /// Highest alpha in a square around a point.
    func maxAlpha(near x: Int, _ y: Int, radius r: Int) -> Int {
        var best = 0
        for yy in max(0, y - r)...min(height - 1, y + r) {
            for xx in max(0, x - r)...min(width - 1, x + r) { best = max(best, alpha(xx, yy)) }
        }
        return best
    }
}

private let canvas = CGSize(width: 320, height: 180)

private func render(_ type: String, _ params: [String: ParamValue] = [:], canvas: CGSize = canvas) -> Pixels? {
    GeneratorRenderer.render(type: type, params: params, canvas: canvas).map(Pixels.init)
}

@Test func everyGeneratorRendersSomething() throws {
    #expect(GeneratorCatalog.all.count == 11)
    for type in GeneratorCatalog.all {
        #expect(type.category == "generator")
        let px = try #require(render(type.id), "\(type.id) rendered nil")
        #expect(px.width == 320 && px.height == 180)
        #expect(px.opaqueCount > 20, "\(type.id) drew \(px.opaqueCount) pixels")
    }
    #expect(GeneratorCatalog.type("shape.rect")?.spec("radius") != nil)
    #expect(GeneratorRenderer.render(type: "nope", params: [:], canvas: canvas) == nil)
}

@Test func rectFillsItsCenter() throws {
    let px = try #require(render("shape.rect", ["x": .number(0.25), "y": .number(0.25), "fill": .string("#FF0000")]))
    let c = px.at(80, 45)
    #expect(c[0] > 245 && c[1] < 10 && c[2] < 10 && c[3] == 255, "\(c)")
    #expect(px.alpha(240, 135) == 0)
    // Default size is 0.4 × 0.25 of the height: 72 × 45 px.
    #expect(px.alpha(80 + 30, 45) == 255)
    #expect(px.alpha(80 + 40, 45) == 0)
}

@Test func ellipseLeavesCornersEmpty() throws {
    let px = try #require(render("shape.ellipse", ["width": .number(0.8), "height": .number(0.8)]))
    #expect(px.alpha(160, 90) == 255)
    #expect(px.alpha(160 - 70, 90 - 70) == 0)
}

@Test func arrowDrawsOnWithItsHead() throws {
    let base: [String: ParamValue] = ["x1": .number(0.1), "y1": .number(0.5), "x2": .number(0.9), "y2": .number(0.5), "width": .number(0.02)]
    var p = base
    p["progress"] = .number(0)
    let none = try #require(render("shape.arrow", p))
    #expect(none.opaqueCount == 0)
    p["progress"] = .number(1)
    let full = try #require(render("shape.arrow", p))
    // Head is wider than the shaft just behind the tip at x = 288.
    let headLen = Int(0.04 * 180)
    #expect(full.alpha(288 - 2, 90) > 200)
    #expect(full.maxAlpha(near: 288 - headLen + 1, 90 - 3, radius: 0) > 100)
    #expect(full.alpha(160, 90) > 200)
    #expect(full.alpha(160, 90 - 5) == 0)
    p["progress"] = .number(0.5)
    let half = try #require(render("shape.arrow", p))
    #expect(half.alpha(250, 90) == 0)
    #expect(half.alpha(140, 90) > 200)
}

@Test func lineProgressAndBentArrow() throws {
    let line = try #require(render("shape.line", ["x1": .number(0), "y1": .number(0.5), "x2": .number(1), "y2": .number(0.5), "width": .number(0.03), "progress": .number(0.25)]))
    #expect(line.alpha(40, 90) > 200)
    #expect(line.alpha(160, 90) == 0)
    let bent = try #require(render("shape.arrow", ["x1": .number(0.1), "y1": .number(0.5), "x2": .number(0.9), "y2": .number(0.5), "width": .number(0.03), "curve": .number(1)]))
    // Positive curve bows to the left of travel, which is up when pointing right.
    #expect(bent.maxAlpha(near: 160, 90 - 64, radius: 3) > 200)
    #expect(bent.alpha(160, 90) == 0)
}

@Test func highlightWipesFromTheLeft() throws {
    let px = try #require(render("shape.highlight", ["progress": .number(0.4), "skew": .number(0), "color": .string("#FFD60A")]))
    // 90 px wide from x 115; 40% wiped on reaches x 151.
    #expect(px.alpha(120, 90) > 200)
    #expect(px.alpha(190, 90) == 0)
}

@Test func lowerThirdBuildsOn() throws {
    let full = try #require(render("lower_third", ["style": .string("box")]))
    let none = try #require(render("lower_third", ["progress": .number(0)]))
    #expect(none.opaqueCount == 0)
    // Box starts at the left edge (x 0.06) around y 0.8.
    #expect(full.alpha(Int(0.06 * 320) + 3, Int(0.8 * 180)) > 150)
    for style in ["clean", "bar", "underline"] {
        let px = try #require(render("lower_third", ["style": .string(style)]))
        #expect(px.opaqueCount > 100, "\(style)")
    }
}

@Test func progressBarAndGradientAndCounter() throws {
    let bar = try #require(render("progress_bar", ["progress": .number(0.25), "y": .number(0.5), "height": .number(0.1), "color": .string("#00FF00"), "background": .string("#00000000")]))
    #expect(bar.at(40, 90)[1] > 245)
    #expect(bar.alpha(200, 90) == 0)
    let g = try #require(render("gradient", ["color1": .string("#FF0000"), "color2": .string("#0000FF"), "angle": .number(90)]))
    #expect(g.at(1, 90)[0] > 240 && g.at(318, 90)[2] > 240)
    let down = try #require(render("gradient", ["color1": .string("#FF0000"), "color2": .string("#0000FF"), "angle": .number(160)]))
    #expect(down.at(160, 1)[0] > 200 && down.at(160, 178)[2] > 200)
    #expect(down.at(5, 90)[0] > down.at(315, 90)[0], "160° also runs slightly rightward")
    let up = try #require(render("gradient", ["color1": .string("#FF000080"), "color2": .string("#0000FF"), "angle": .number(0)]))
    #expect(up.at(160, 178)[3] < 140 && up.at(160, 1)[2] > 240)
    let zero = try #require(render("counter", ["progress": .number(0)]))
    let hundred = try #require(render("counter", ["progress": .number(1)]))
    #expect(zero.opaqueCount < hundred.opaqueCount)
    #expect(hundred.maxAlpha(near: 160, 90, radius: 12) > 200)
}

@Test func counterFormatting() {
    #expect(GeneratorRenderer.format(1234567.891, decimals: 2, separator: true) == "1,234,567.89")
    #expect(GeneratorRenderer.format(-1000, decimals: 0, separator: true) == "-1,000")
    #expect(GeneratorRenderer.format(999, decimals: 0, separator: true) == "999")
    #expect(GeneratorRenderer.format(1500, decimals: 1, separator: false) == "1500.0")
}

@Test func calloutAndGrid() throws {
    let c = try #require(render("callout"))
    #expect(c.alpha(Int(0.6 * 320), Int(0.45 * 180)) > 200, "dot on target")
    #expect(c.alpha(Int(0.3 * 320), Int(0.25 * 180)) > 200, "label pill")
    let grid = try #require(render("grid_overlay"))
    #expect(grid.alpha(Int(320 / 3), 20) > 100)
    #expect(grid.alpha(20, 20) == 0)
}

@Test func generatorRenderIsFastAndCached() throws {
    let hd = CGSize(width: 1920, height: 1080)
    var worst = 0.0
    var worstType = ""
    for type in GeneratorCatalog.all {
        // Nudging a number each frame defeats the cache, as an animated graphic does.
        let name = type.params.first { $0.kind == .number && $0.name != "decimals" }!.name
        let base = type.spec(name)!.defaultValue.number!
        _ = GeneratorRenderer.render(type: type.id, params: [name: .number(base + 0.0005)], canvas: hd)
        let start = Date()
        for i in 1...10 {
            _ = GeneratorRenderer.render(type: type.id, params: [name: .number(base - Double(i) * 0.001)], canvas: hd)
        }
        let ms = Date().timeIntervalSince(start) * 1000 / 10
        if ms > worst { worst = ms; worstType = type.id }
        print("generator \(type.id): \(String(format: "%.2f", ms)) ms")
    }
    #expect(worst < 40, "\(worstType) took \(worst) ms")
    let a = GeneratorRenderer.render(type: "shape.rect", params: ["x": .number(0.3)], canvas: hd)
    let b = GeneratorRenderer.render(type: "shape.rect", params: ["x": .number(0.300001)], canvas: hd)
    #expect(a != nil && a === b)
}

// MARK: Text animators

@Test func typewriterHidesLaterChars() {
    let a = TextAnimator(unit: .char, preset: .typewriter, stagger: 0.05)
    let t = 0.12
    #expect(TextAnimator.state(a, unitIndex: 0, unitStart: a.start(ofUnit: 0), local: t, clipDuration: 3).opacity == 1)
    #expect(TextAnimator.state(a, unitIndex: 2, unitStart: a.start(ofUnit: 2), local: t, clipDuration: 3).opacity == 1)
    #expect(TextAnimator.state(a, unitIndex: 3, unitStart: a.start(ofUnit: 3), local: t, clipDuration: 3).opacity == 0)
    #expect(TextAnimator.state(a, unitIndex: 9, unitStart: a.start(ofUnit: 9), local: t, clipDuration: 3).opacity == 0)
}

@Test func popOvershootsThenSettles() {
    let a = TextAnimator(preset: .pop, duration: 0.4)
    let scales = stride(from: 0.0, through: 0.4, by: 0.01).map { TextAnimator.state(a, unitIndex: 0, unitStart: 0, local: $0, clipDuration: 5).scale }
    #expect(scales.first! < 0.5)
    #expect(scales.max()! > 1.03)
    #expect(abs(TextAnimator.state(a, unitIndex: 0, unitStart: 0, local: 1, clipDuration: 5).scale - 1) < 1e-9)
}

@Test func syncUsesUnitStart() {
    let a = TextAnimator(preset: .fade, stagger: 0.05, duration: 0.2, sync: true)
    #expect(a.start(ofUnit: 4, spoken: 2.0) == 2.0)
    #expect(TextAnimator(sync: false).start(ofUnit: 4, spoken: 2.0) == 0.24)
    #expect(TextAnimator.state(a, unitIndex: 4, unitStart: 2.0, local: 1.9, clipDuration: 5).opacity == 0)
    #expect(TextAnimator.state(a, unitIndex: 4, unitStart: 2.0, local: 2.1, clipDuration: 5).opacity > 0.1)
    #expect(TextAnimator.state(a, unitIndex: 4, unitStart: 2.0, local: 2.3, clipDuration: 5).opacity == 1)
}

@Test func presetsShapes() {
    func s(_ p: TextAnimator.Preset, _ t: Double, out: TextAnimator.Preset? = nil) -> TextAnimator.UnitState {
        TextAnimator.state(TextAnimator(preset: p, duration: 0.3, color: RGBA(r: 1, g: 0, b: 0), out: out), unitIndex: 1, unitStart: 0.5, local: t, clipDuration: 3)
    }
    #expect(s(.slideUp, 0.55).dy > 0)
    #expect(s(.slideDown, 0.55).dy < 0)
    #expect(s(.blurIn, 0.55).blur > 0 && s(.blurIn, 1).blur == 0)
    #expect(s(.scaleIn, 0.55).scale > 1)
    #expect(s(.bounce, 0.52).dy < 0)
    #expect(s(.highlight, 0.2) == .rest)
    #expect(s(.highlight, 0.6).color == RGBA(r: 1, g: 0, b: 0))
    #expect(s(.highlight, 1.0).color == nil)
    #expect(s(.wave, 1.3).dy != 0)
    // Exit: everything leaves together over the last `duration`.
    #expect(s(.fade, 2.5, out: .fade).opacity == 1)
    #expect(s(.fade, 2.85, out: .fade).opacity < 1)
    #expect(s(.fade, 3, out: .slideUp).opacity == 0)
    #expect(s(.fade, 2.9, out: .slideUp).dy < 0)
}

@Test func animatorDecodesWithDefaults() throws {
    let a = try JSONDecoder().decode(TextAnimator.self, from: Data(#"{"preset":"slide_up","unit":"char"}"#.utf8))
    #expect(a.preset == .slideUp && a.unit == .char && a.stagger == TextAnimator().stagger && a.out == nil)
    let round = try JSONDecoder().decode(TextAnimator.self, from: JSONEncoder().encode(TextAnimator(preset: .highlight, color: .white, sync: true, out: .fade)))
    #expect(round == TextAnimator(preset: .highlight, color: .white, sync: true, out: .fade))
}

// MARK: Animated text layout

@Test func layoutPlacesWordsOnOneLine() throws {
    let spec = TextSpec(text: "one two three", size: 0.08, shadow: false, maxWidth: 0.9)
    let layout = try #require(AnimatedText.layout(spec, canvasHeight: 1080, canvasWidth: 1920, unit: .word))
    #expect(layout.units.map(\.text) == ["one", "two", "three"])
    #expect(layout.units.allSatisfy { $0.line == 0 })
    let xs = layout.units.map(\.rect.minX)
    #expect(xs == xs.sorted() && Set(xs).count == 3)
    #expect(layout.units[0].rect.maxX < layout.units[1].rect.minX)
    #expect(abs(layout.units[0].rect.midY - layout.units[2].rect.midY) < 0.5)
    let chars = try #require(AnimatedText.layout(spec, canvasHeight: 1080, canvasWidth: 1920, unit: .char))
    #expect(chars.units.count == 11)
    let lines = try #require(AnimatedText.layout(spec, canvasHeight: 1080, canvasWidth: 1920, unit: .line))
    #expect(lines.units.map(\.text) == ["one two three"])
    #expect(AnimatedText.layout(spec, canvasHeight: 1080, canvasWidth: 1920, unit: .word) === layout)
}

@Test func layoutWrapsWhenNarrow() throws {
    let spec = TextSpec(text: "wrapping words onto lines", size: 0.08, maxWidth: 0.2)
    let layout = try #require(AnimatedText.layout(spec, canvasHeight: 1080, canvasWidth: 1920, unit: .word))
    #expect(layout.units.count == 4)
    #expect(layout.units.last!.line > 0)
    #expect(layout.units.last!.rect.minY > layout.units[0].rect.maxY - 1)
    let lines = try #require(AnimatedText.layout(spec, canvasHeight: 1080, canvasWidth: 1920, unit: .line))
    #expect(lines.units.count >= 2)
}

@Test func unitImagesMatchTheFullRender() throws {
    let spec = TextSpec(text: "Hi there", size: 0.2, color: RGBA(r: 1, g: 0, b: 0), shadow: false)
    let layout = try #require(AnimatedText.layout(spec, canvasHeight: 180, canvasWidth: 320, unit: .word))
    let word = Pixels(layout.units[0].image)
    #expect(word.opaqueCount > 50)
    let full = Pixels(try #require(AnimatedText.render(layout, states: [], spec: spec)))
    #expect(full.width == Int(layout.size.width.rounded(.up)))
    // Some pixel inside the first word's glyph box is solid red in the full render.
    let r = layout.units[0].rect
    var found = false
    for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where full.at(x, y) == [255, 0, 0, 255] { found = true } }
    #expect(found)
    // Hidden units draw nothing; recolored units use the state color.
    let hidden = Pixels(try #require(AnimatedText.render(layout, states: [.hidden, .hidden], spec: spec)))
    #expect(hidden.opaqueCount == 0)
    let blue = RGBA(r: 0, g: 0, b: 1)
    let tinted = Pixels(try #require(AnimatedText.render(layout, states: [TextAnimator.UnitState(color: blue), .rest], spec: spec)))
    var blueFound = false
    for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where tinted.at(x, y) == [0, 0, 255, 255] { blueFound = true } }
    #expect(blueFound)
    let blurred = Pixels(try #require(AnimatedText.render(layout, states: [TextAnimator.UnitState(blur: 0.2), .rest], spec: spec)))
    #expect(blurred.opaqueCount > 50)
}

@Test func animatedTextKeepsSpanColorsHighlightsAndUnderlines() throws {
    let orange = RGBA(hex: "#FF5533")!
    var spec = TextSpec(text: "TEARS OF STEEL", size: 0.2, color: .white, shadow: false)
    spec.spans = [TextSpan(match: "STEEL", color: orange), TextSpan(match: "OF", underline: true), TextSpan(match: "TEARS", highlight: RGBA(r: 0, g: 0, b: 1))]
    for unit in [TextAnimator.Unit.word, .char] {
        let layout = try #require(AnimatedText.layout(spec, canvasHeight: 180, canvasWidth: 640, unit: unit))
        let full = Pixels(try #require(AnimatedText.render(layout, states: [], spec: spec)))
        func count(in r: CGRect, _ match: ([Int]) -> Bool) -> Int {
            var n = 0
            for y in max(0, Int(r.minY))..<min(full.height, Int(r.maxY)) { for x in max(0, Int(r.minX))..<min(full.width, Int(r.maxX)) where match(full.at(x, y)) { n += 1 } }
            return n
        }
        func box(_ word: String) -> CGRect {
            let range = (spec.text as NSString).range(of: word)
            return layout.units.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        }
        let steel = box("STEEL"), tears = box("TEARS"), of = box("OF")
        // STEEL is orange (255, 85, 51) and never white; the rest of the text stays white.
        #expect(count(in: steel) { abs($0[0] - 255) < 3 && abs($0[1] - 85) < 3 && abs($0[2] - 51) < 3 && $0[3] == 255 } > 50, "\(unit)")
        #expect(count(in: steel) { $0 == [255, 255, 255, 255] } == 0, "\(unit)")
        #expect(count(in: tears) { $0 == [255, 255, 255, 255] } > 50, "\(unit)")
        // A blue box behind TEARS, a white rule under OF.
        #expect(count(in: tears.insetBy(dx: -4, dy: -4)) { $0 == [0, 0, 255, 255] } > 100, "\(unit)")
        let under = CGRect(x: of.minX, y: of.maxY - of.height * 0.35, width: of.width, height: of.height * 0.35)
        let rows = (Int(under.minY)..<Int(under.maxY)).filter { y in (Int(of.minX + 2)..<Int(of.maxX - 2)).allSatisfy { full.at($0, y)[3] > 200 } }
        #expect(!rows.isEmpty, "\(unit): no underline under OF")
        // A tinting animator recolors the plain text but not the span color.
        let green = RGBA(r: 0, g: 1, b: 0)
        let tinted = Pixels(try #require(AnimatedText.render(layout, states: layout.units.map { _ in TextAnimator.UnitState(color: green) }, spec: spec)))
        var orangeLeft = 0, greenTears = 0
        for y in Int(steel.minY)..<Int(steel.maxY) { for x in Int(steel.minX)..<Int(steel.maxX) where tinted.at(x, y) == full.at(x, y) && full.at(x, y)[3] == 255 { orangeLeft += 1 } }
        for y in Int(tears.minY)..<Int(tears.maxY) { for x in Int(tears.minX)..<Int(tears.maxX) where tinted.at(x, y) == [0, 255, 0, 255] { greenTears += 1 } }
        #expect(orangeLeft > 50 && greenTears > 50, "\(unit)")
    }
}

@Test func textChecksIncludeLowerThirds() async throws {
    var p = Project(name: "Titles")
    var lower = Clip(id: "lt", kind: .generator, start: 0, duration: 4)
    lower.effects = [Effect(id: "gen", type: "lower_third", params: ["title": .string("Celia"), "subtitle": .string("Robotics"), "x": .number(0.02), "y": .number(0.9)])]
    p.tracks[0].clips = [lower]
    let gray = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    gray.setFillColor(CGColor(gray: 0.5, alpha: 1))
    gray.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    let bg = gray.makeImage()!
    let checks = try await PictureMeter.checkText(p, captions: []) { _ in bg }
    let check = try #require(checks.first { $0.label.hasPrefix("lt \"Celia") })
    #expect(check.box.minX < 0.05 && check.box.maxY > 0.9)
    #expect(check.safeOverflow > 0)
    #expect(check.contrast > 1 && check.contrast < 21)
}
