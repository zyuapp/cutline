import CoreGraphics
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A 320×180 blue-gray PNG with an orange 80×80 square in the left half.
private func squareStill(_ url: URL) throws {
    let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.45, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.55, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 40, y: 50, width: 80, height: 80))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func openStill() async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-polish-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try squareStill(dir.appendingPathComponent("square.png"))
    var project = Project(name: "Polish", canvas: Canvas(width: 640, height: 360, fps: 30))
    project.media = [try await MediaProbe.probe(dir.appendingPathComponent("square.png"), id: "square")]
    project.tracks[0].clips = [Clip(id: "a", kind: .media, mediaId: "square", start: 0, duration: 4)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: project)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

/// The first "N% of the frame white" in `text`.
private func whiteShare(_ text: String) -> Int? {
    guard let r = text.range(of: #"(\d+)% of the frame white"#, options: .regularExpression) else { return nil }
    return Int(text[r].prefix { $0.isNumber })
}

@Test func qualifyReportsTheMatteTheEffectRenders() async throws {
    let (box, dir) = try await openStill()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Unwindowed: the orange square is 80×80 of 320×180, about 11% of the frame.
    let q = await box.call("recipe", ["name": "qualify", "args": ["clip": "a", "x": 0.25, "y": 0.5, "at": 1]])
    #expect(!q.isError, "\(q.plainText)")
    let fx = try #require(try box.session.project().clip("a")?.effects.last?.id)
    let matte = await box.call("timeline_frames", ["view": "matte", "clip": "a", "effect": .string(fx), "times": [1]])
    let reported = try #require(whiteShare(q.plainText), "\(q.plainText)"), shown = try #require(whiteShare(matte.plainText), "\(matte.plainText)")
    #expect(abs(reported - shown) <= 1 && abs(reported - 11) <= 2, "report \(reported)% vs matte \(shown)%")

    // A window over the right half leaves the square out: the report says so, as the matte view does.
    _ = await box.call("effect_add", ["target": "a", "type": "color.wheels", "id": "win", "params": ["limit": "rect", "limit_x": 0.75, "limit_y": 0.5, "limit_width": 0.45, "limit_height": 0.9]])
    let windowed = await box.call("recipe", ["name": "qualify", "args": ["clip": "a", "effect": "win", "x": 0.25, "y": 0.5, "at": 1]])
    #expect(!windowed.isError && windowed.plainText.contains("limit rect+qualifier"), "\(windowed.plainText)")
    let winMatte = await box.call("timeline_frames", ["view": "matte", "clip": "a", "effect": "win", "times": [1]])
    let r2 = try #require(whiteShare(windowed.plainText), "\(windowed.plainText)"), s2 = try #require(whiteShare(winMatte.plainText))
    #expect(r2 == s2 && r2 <= 1, "windowed report \(r2)% vs matte \(s2)%")
}

@Test func textMeasureIncludesTitleGraphics() async throws {
    let (box, dir) = try await openStill()
    defer { try? FileManager.default.removeItem(at: dir) }
    for (gen, params, start) in [
        ("title.lower_third_modern", ["title": "Ada Lovelace", "subtitle": "Mathematician"] as JSON, 0.0),
        ("credits", ["text": "# THE END\nDirector | Ada"], 0.0),
        ("text.path", ["text": "AROUND AND AROUND • "], 0.0),
        ("title.card", ["title": "Chapter One"], 0.0),
    ] {
        let r = await box.call("clip_add", ["generator": .string(gen), "params": params, "start": .number(start), "duration": 4, "track": "new"])
        #expect(!r.isError, "\(gen): \(r.plainText)")
    }
    let measured = await box.call("timeline_measure", ["what": ["text"]])
    let text = measured.plainText
    for words in ["Ada Lovelace", "THE END", "AROUND AND AROUND", "Chapter One"] {
        #expect(text.contains(words) && text.components(separatedBy: "\n").contains { $0.contains(words) && $0.contains("contrast") }, "\(words) missing: \(text)")
    }
    #expect(text.contains("title-safe"), "\(text)")
}

@Test func titlePresetsTakeTheNamesAgentsGuess() async throws {
    let (box, dir) = try await openStill()
    defer { try? FileManager.default.removeItem(at: dir) }
    let added = await box.call("clip_add", ["generator": "title.lower_third_modern", "params": ["name": "Ada Lovelace", "role": "Mathematician"], "start": 0, "duration": 3, "track": "new"])
    #expect(!added.isError, "\(added.plainText)")
    let gen = try #require(try box.session.project().tracks.flatMap(\.clips).first { $0.kind == .generator }?.effects.first)
    #expect(gen.params["title"] == .string("Ada Lovelace") && gen.params["subtitle"] == .string("Mathematician"), "\(gen.params)")
    let quote = EffectCatalog.type("title.quote")!
    #expect(quote.paramName(for: "name") == "author" && quote.paramName(for: "text") == "quote")
    let card = EffectCatalog.type("title.card")!
    #expect(card.paramName(for: "heading") == "title" && card.paramName(for: "body") == "subtitle" && card.paramName(for: "eyebrow") == "kicker")

    // text_add presets: a title graphic, or a styled text clip.
    let lower = await box.call("text_add", ["text": "Grace Hopper\nRear Admiral", "preset": "lower_third_box", "start": 3, "duration": 3])
    #expect(!lower.isError && lower.plainText.contains("title.lower_third_box"), "\(lower.plainText)")
    let p = try box.session.project()
    let graphic = try #require(p.tracks.flatMap(\.clips).first { $0.effects.first?.type == "title.lower_third_box" })
    #expect(graphic.kind == .generator && graphic.start == 3)
    #expect(graphic.effects[0].params["title"] == .string("Grace Hopper") && graphic.effects[0].params["subtitle"] == .string("Rear Admiral"))
    let styled = await box.call("text_add", ["text": "Day one", "preset": "caption_box", "start": 0, "color": "#FFEE00"])
    #expect(!styled.isError, "\(styled.plainText)")
    let caption = try #require(try box.session.project().tracks.flatMap(\.clips).first { $0.text?.text == "Day one" }?.text)
    #expect(caption.background != nil && caption.y > 0.8 && caption.color == RGBA(hex: "#FFEE00"))
    let unknown = await box.call("text_add", ["text": "x", "preset": "fancy", "start": 0])
    #expect(unknown.isError && unknown.plainText.contains("lower_third_modern") && unknown.plainText.contains("caption_box"), "\(unknown.plainText)")
}

@Test func asNamesWhatAnyCallCreates() async throws {
    let (box, dir) = try await openStill()
    defer { try? FileManager.default.removeItem(at: dir) }
    let missing = await box.call("effect_add", ["target": "$intro", "type": "stylize.vignette"])
    #expect(missing.isError && missing.plainText.contains("as:\"intro\""), "\(missing.plainText)")
    let title = await box.call("text_add", ["text": "Intro", "start": 0, "as": "intro"])
    #expect(!title.isError && title.plainText.contains("$intro = "), "\(title.plainText)")
    let id = try #require(box.session.names["intro"])
    let moved = await box.call("clip_update", ["clip_id": "$intro", "start": 1])
    let movedStart = try box.session.project().clip(id)?.start
    #expect(!moved.isError && movedStart == 1, "\(moved.plainText)")
    // Free text keeps "$intro"; names carry into batch, and batch names carry out.
    let literal = await box.call("text_add", ["text": "$intro", "start": 2])
    let kept = try box.session.project().tracks.flatMap(\.clips).contains { $0.text?.text == "$intro" }
    #expect(!literal.isError && kept)
    let batch = await box.call("batch", ["operations": [
        ["tool": "effect_add", "args": ["target": "$intro", "type": "stylize.vignette", "as": "vig"]],
    ]])
    #expect(!batch.isError && box.session.names["vig"] != nil, "\(batch.plainText)")
    let nothing = await box.call("param_set", ["target": "$intro", "set": ["opacity": 0.5], "as": "x"])
    #expect(!nothing.isError && nothing.plainText.contains("as:\"x\" named nothing"), "\(nothing.plainText)")
}

@Test func mediaIdsStayReadable() {
    let url = URL(fileURLWithPath: "/x/DJI Inspire3 8K ProResRAW nature sample A005C0032.mov")
    let id = Toolbox.mediaId(for: url, existing: [])
    #expect(id == "dji-inspire3-8k-proresraw-nature-sample", "\(id)")
    #expect(Toolbox.mediaId(for: url, existing: [id]) == id + "-2")
    #expect(Toolbox.mediaId(for: URL(fileURLWithPath: "/x/interview.mov"), existing: []) == "interview")
    let long = Toolbox.mediaId(for: URL(fileURLWithPath: "/x/" + String(repeating: "a", count: 60) + ".mov"), existing: [])
    #expect(long.count == 40)
}
