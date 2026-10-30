import CoreGraphics
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A 320×180 PNG: `background` everywhere, with an orange square in the left half.
private func still(_ url: URL, background: (CGFloat, CGFloat, CGFloat), orange: Bool) throws {
    let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<320 {
        // A gentle gradient so the picture has a spread of tones.
        let t = CGFloat(x) / 320 * 0.2
        ctx.setFillColor(CGColor(srgbRed: background.0 + t, green: background.1 + t, blue: background.2 + t, alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: 180))
    }
    if orange {
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.55, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 50, width: 80, height: 80))
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

@Test func gradingToolsQualifyMatchAndCompare() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-grading-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try still(dir.appendingPathComponent("bright.png"), background: (0.35, 0.45, 0.6), orange: true)
    try still(dir.appendingPathComponent("dark.png"), background: (0.02, 0.02, 0.03), orange: false)

    var project = Project(name: "Grade", canvas: Canvas(width: 640, height: 360, fps: 30))
    project.media = [
        try await MediaProbe.probe(dir.appendingPathComponent("bright.png"), id: "bright"),
        try await MediaProbe.probe(dir.appendingPathComponent("dark.png"), id: "dark"),
    ]
    project.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "bright", start: 0, duration: 2),
        Clip(id: "b", kind: .media, mediaId: "dark", start: 2, duration: 2),
    ]
    let bundleURL = dir.appendingPathComponent("p.cutline")
    _ = try ProjectBundle.create(at: bundleURL, project: project)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundleURL.path)])

    // The eyedropper on the orange square keys orange and not the blue background.
    let q = await box.call("recipe", ["name": "qualify", "args": ["clip": "a", "x": 0.25, "y": 0.5, "at": 1]])
    #expect(!q.isError && q.plainText.contains("Qualifier on a"), "\(q.plainText)")
    let fx = try #require(try box.session.project().clip("a")?.effects.last)
    #expect(fx.params["limit"] == .string("qualifier"))
    let hue = try #require(fx.params["q_hue"]?.number)
    #expect(abs(hue - 28) < 8, "hue \(hue)")
    let key = Qualifier(params: fx.params)
    #expect(key.weight(SIMD3(0.9, 0.55, 0.2)) == 1 && key.weight(SIMD3(0.4, 0.5, 0.65)) == 0)

    // Matching a near-black shot to a bright one is held back and flagged.
    let m = await box.call("recipe", ["name": "match_color", "args": ["clips": ["b"], "reference": "a", "reference_at": 1]])
    #expect(!m.isError, "\(m.plainText)")
    #expect(m.plainText.contains("Warning: b may not be comparable with a") && m.plainText.contains("much darker"), "\(m.plainText)")
    #expect(try box.session.project().clip("b")?.effects.first?.id == "match")

    let c = await box.call("timeline_measure", ["what": ["compare"], "reference": "a"])
    #expect(c.plainText.contains("a: L") && c.plainText.contains("(reference)") && c.plainText.contains("ΔE"), "\(c.plainText)")
    let byTime = await box.call("timeline_measure", ["what": ["compare"], "reference": 3])
    #expect(byTime.plainText.contains("against b"), "\(byTime.plainText)")
    let bad = await box.call("timeline_measure", ["what": ["compare"], "reference": "nope"])
    #expect(bad.isError && bad.plainText.contains("no clip nope"), "\(bad.plainText)")

    // Nodes show in project_status.
    _ = await box.call("effect_add", ["target": "a", "type": "color.wheels", "id": "bg", "params": ["node_mode": "outside", "saturation": -1]])
    let status = await box.call("project_status", ["target": "a"])
    #expect(status.plainText.contains("Node graph") && status.plainText.contains("bg outside (outside"), "\(status.plainText)")
    #expect(status.plainText.contains("fx.bg.node_mode") && !status.plainText.contains("fx.bg.q_hue"), "qualifier parameters stay hidden until used")
}
