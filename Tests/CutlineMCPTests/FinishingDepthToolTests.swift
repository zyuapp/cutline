import AppKit
import AVFoundation
import CoreImage
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import simd
import Testing

/// Corners (top-left origin pixels, 640×360) of a printed card drifting right and down while turning.
private func corners(_ i: Int) -> [SIMD2<Double>] {
    let t = Double(i)
    return [SIMD2(180 + 3 * t, 90 + 1.2 * t), SIMD2(420 + 3.4 * t, 100 + 1.0 * t), SIMD2(430 + 3.6 * t, 270 + 1.6 * t), SIMD2(170 + 3 * t, 260 + 1.4 * t)]
}

private func cardMovie(_ url: URL, frames: Int = 40) async throws {
    let w = 640, h = 360
    let ctx2 = CGContext(data: nil, width: 300, height: 220, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx2.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.85, alpha: 1))
    ctx2.fill(CGRect(x: 0, y: 0, width: 300, height: 220))
    let colors = [CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1)]
    for i in 0..<14 {
        ctx2.setFillColor(colors[i % 3])
        let x = Double((i * 73) % 260), y = Double((i * 47) % 190)
        if i % 2 == 0 { ctx2.fill(CGRect(x: x, y: y, width: 18 + Double(i % 4) * 6, height: 12 + Double(i % 3) * 7)) } else { ctx2.fillEllipse(in: CGRect(x: x, y: y, width: 20, height: 20)) }
    }
    let line = NSAttributedString(string: "TRACKED 2026", attributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black])
    for (k, y) in [20.0, 90.0, 160.0].enumerated() {
        ctx2.textPosition = CGPoint(x: 10 + Double(k) * 12, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(line), ctx2)
    }
    let texture = CIImage(cgImage: ctx2.makeImage()!)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let ctx = CIContext()
    let background = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    for i in 0..<frames {
        let c = corners(i).map { CIVector(x: $0.x, y: Double(h) - $0.y) }
        let card = texture.applyingFilter("CIPerspectiveTransform", parameters: ["inputTopLeft": c[0], "inputTopRight": c[1], "inputBottomRight": c[2], "inputBottomLeft": c[3]])
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        ctx.render(card.composited(over: background), to: pb!)
        #expect(adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 25)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

private func area(_ q: [SIMD2<Double>]) -> Double {
    var s = 0.0
    for i in q.indices { let a = q[i], b = q[(i + 1) % q.count]; s += a.x * b.y - b.x * a.y }
    return abs(s) / 2
}

@Test func trackMaskRecipeMakesARotoShapeFollowTheCard() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-trackmask-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("card.mov")
    try await cardMovie(movie)
    var project = Project(name: "Roto", canvas: Canvas(width: 640, height: 360, fps: 25))
    project.media = [try await MediaProbe.probe(movie, id: "card")]
    try project.addClip(Clip(id: "c1", kind: .media, mediaId: "card", start: 0, duration: 1.5), trackId: "V1", mode: .place)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: project)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])

    let start = corners(0).map { String(format: "%.5f,%.5f", $0.x / 640, $0.y / 360) }.joined(separator: " ")
    let added = await box.call("effect_add", ["target": "c1", "type": "mask.shape", "params": ["points": .string(start), "feather": 0]])
    #expect(!added.isError, "\(added.plainText)")
    let fx = try #require(try bundle.loadProject().clip("c1")?.effects.first { $0.type == "mask.shape" })

    let missing = await box.call("recipe", ["name": "track_mask", "args": ["clip": "c1", "effect": "nope"]])
    #expect(missing.isError && missing.plainText.contains("mask.shape"), "\(missing.plainText)")
    let r = await box.call("recipe", ["name": "track_mask", "args": ["clip": "c1", "mode": "planar"]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("fx.\(fx.id).points follows the footage") && r.plainText.contains("view: \"matte\""), "\(r.plainText)")
    let clip = try #require(try bundle.loadProject().clip("c1"))
    let curve = try #require(clip.anim["fx.\(fx.id).points"])
    #expect(curve.keys.count >= 2)
    // At frame 30 (1.2 s) the keyed corners are within 2 px of the card's.
    let pts = try #require(curve.value(at: 1.2)?.string.flatMap(Curve.points))
    let truth = corners(30)
    let worst = zip(pts, truth).map { hypot($0.0 * 640 - $1.x, $0.1 * 360 - $1.y) }.max()!
    print("track_mask: \(curve.keys.count) keys, worst corner error at 1.2 s \(String(format: "%.2f", worst)) px")
    #expect(worst < 2)

    // Magnetic refinement and point tracking run as previews without touching the keys.
    let snapped = await box.call("recipe", ["name": "track_mask", "args": ["clip": "c1", "mode": "points", "refine": "subject", "snap": 0.01], "dry_run": true])
    #expect(!snapped.isError && snapped.plainText.contains("(points + subject edges)") && snapped.plainText.contains("to the subject matte's edge"), "\(snapped.plainText)")
    #expect(try bundle.loadProject().clip("c1")?.anim["fx.\(fx.id).points"] == curve)

    // A correction holds exactly at its frame; tracking re-anchors there from both sides.
    let fixed = corners(30).map { String(format: "%.5f,%.5f", ($0.x + 4) / 640, $0.y / 360) }.joined(separator: " ")
    let corrected = await box.call("recipe", ["name": "track_mask", "args": ["clip": "c1", "mode": "planar", "correct": [["at": 1.2, "points": .string(fixed)]]]])
    #expect(!corrected.isError && corrected.plainText.contains("1 correction(s)"), "\(corrected.plainText)")
    let at12 = try #require(try bundle.loadProject().clip("c1")?.anim["fx.\(fx.id).points"]?.value(at: 1.2)?.string.flatMap(Curve.points))
    #expect(zip(at12, corners(30)).allSatisfy { abs($0.0 * 640 - $1.x - 4) < 0.5 && abs($0.1 * 360 - $1.y) < 0.5 }, "\(at12)")
    let miscounted = await box.call("recipe", ["name": "track_mask", "args": ["clip": "c1", "correct": [["at": 1, "points": "0.1,0.1 0.2,0.1 0.2,0.2"]]], "dry_run": true])
    #expect(miscounted.isError && miscounted.plainText.contains("same order"), "\(miscounted.plainText)")
    _ = await box.call("history", ["action": "undo"])

    // The matte view shows the tracked card: its share of the frame matches the card's area there.
    let matte = await box.call("timeline_frames", ["view": "matte", "clip": "c1", "effect": .string(fx.id), "times": [1.2]])
    #expect(!matte.isError, "\(matte.plainText)")
    let white = matte.plainText.components(separatedBy: "\n").filter { $0.contains("% of the frame white") }.compactMap { line in
        line.components(separatedBy: "  ").dropFirst().first.flatMap { Int($0.components(separatedBy: "%").first ?? "") }
    }
    let expected = area(truth) / (640 * 360) * 100
    #expect(white.count == 1 && abs(Double(white[0]) - expected) <= 2, "matte \(white) vs \(expected)%")
}

@Test func lensAndTextToolsAreReachable() async throws {
    let box = Toolbox()
    for (q, id) in [("lens", "distort.lens"), ("rolling shutter", "video.rolling_shutter"), ("jello", "video.rolling_shutter"), ("vignette", "color.vignette_correct"), ("chromatic", "distort.chromatic_aberration")] {
        let found = await box.call("catalog", ["search": .string(q)])
        #expect(found.plainText.contains(id), "\(q): \(found.plainText.prefix(300))")
    }
    let lens = await box.call("catalog", ["type": "distort.lens"])
    #expect(lens.plainText.contains("gopro_wide") && lens.plainText.contains("k1"), "\(lens.plainText)")
    let path = await box.call("catalog", ["type": "text.path"])
    #expect(path.plainText.contains("offset") && path.plainText.contains("shape:"), "\(path.plainText)")
    let recipe = await box.call("catalog", ["recipe": "track_mask"])
    #expect(recipe.plainText.contains("planar") && recipe.plainText.contains("refine"), "\(recipe.plainText)")
    let manual = await box.call("catalog", ["tool": "template_save"])
    #expect(manual.plainText.contains("export (string") && manual.plainText.contains("import (string"), "\(manual.plainText)")
}

@Test func templatesTravelAsFiles() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-templates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    EditTemplate.directoryOverride = dir.appendingPathComponent("studio-a", isDirectory: true)
    defer { EditTemplate.directoryOverride = nil }

    var project = Project(name: "Graphics", canvas: Canvas(width: 640, height: 360, fps: 30))
    try project.addClip(Clip(id: "ring", kind: .generator, start: 1, duration: 3, effects: [Effect(id: "gen", type: "text.path", params: ["text": .string("{{name}} • ")])]), trackId: "V1", mode: .place)
    try project.addClip(Clip(id: "logo", kind: .generator, start: 1.5, duration: 2, effects: [Effect(id: "gen", type: "text.extruded", params: ["text": .string("STUDIO")])]), trackId: project.addTrack(kind: .video, name: "Logo").id, mode: .place)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: project)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])

    let pkg = dir.appendingPathComponent("package.cutline-template").path
    let saved = await box.call("template_save", ["name": "Studio ident", "clips": ["ring", "logo"], "summary": "Ident", "export": .string(pkg)])
    #expect(!saved.isError && saved.plainText.contains("Saved template") && saved.plainText.contains("Exported 1 template"), "\(saved.plainText)")
    #expect(FileManager.default.fileExists(atPath: pkg))
    let folder = dir.path + "/pack/"
    let all = await box.call("template_save", ["export": .string(folder)])
    #expect(!all.isError && all.plainText.contains("Exported 1 template"), "\(all.plainText)")

    // Another machine: an empty template library reads the package and inserts the ident.
    EditTemplate.directoryOverride = dir.appendingPathComponent("studio-b", isDirectory: true)
    #expect(EditTemplate.all().isEmpty)
    let imported = await box.call("template_save", ["import": .string(pkg)])
    #expect(!imported.isError && imported.plainText.contains("Imported 1 template") && imported.plainText.contains("fields name"), "\(imported.plainText)")
    let renamed = await box.call("template_save", ["import": .string(folder), "name": "Ident B"])
    #expect(!renamed.isError && renamed.plainText.contains("Ident B"), "\(renamed.plainText)")
    #expect(Set(EditTemplate.all().map(\.name)) == ["Studio ident", "Ident B"])
    let placed = await box.call("recipe", ["name": "template", "args": ["name": "Studio ident", "at": 5, "values": ["name": "ACME"]]])
    #expect(!placed.isError, "\(placed.plainText)")
    let p = try bundle.loadProject()
    let texts = p.tracks.flatMap(\.clips).filter { $0.start >= 5 }.compactMap { $0.effects.first?.params["text"]?.string }
    #expect(texts.contains("ACME • ") && texts.contains("STUDIO"), "\(texts)")

    let bad = dir.appendingPathComponent("junk.json")
    try Data("{\"hello\": 1}".utf8).write(to: bad)
    let refused = await box.call("template_save", ["import": .string(bad.path)])
    #expect(refused.isError && refused.plainText.contains("No Cutline templates"), "\(refused.plainText)")
}
