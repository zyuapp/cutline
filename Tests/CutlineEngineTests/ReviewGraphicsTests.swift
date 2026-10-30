import CoreImage
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

/// Alpha of every pixel, rows from the top.
private func alphas(_ cg: CGImage) -> (w: Int, h: Int, a: [UInt8]) {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, stride(from: 3, to: px.count, by: 4).map { px[$0] })
}

/// Rows (from the top) that have drawn pixels.
private func inkedRows(_ cg: CGImage) -> [Int] {
    let (w, h, a) = alphas(cg)
    return (0..<h).filter { y in (0..<w).contains { a[y * w + $0] > 40 } }
}

private let size = CGSize(width: 320, height: 180)

@Test func creditsRollUpOverTheClip() throws {
    let text = "# FILM\n## Cast\nCaptain | Ada\nEngineer | Alan\n## Music\nClara"
    func frame(_ t: Double, _ extra: [String: ParamValue] = [:]) throws -> CGImage {
        try #require(GeneratorRenderer.render(type: "credits", params: ["text": .string(text)].merging(extra) { $1 }, canvas: size, time: t, duration: 10))
    }
    #expect(inkedRows(try frame(0)).isEmpty, "starts below the frame")
    let early = inkedRows(try frame(1)), later = inkedRows(try frame(2))
    #expect(!early.isEmpty && !later.isEmpty)
    #expect(later.first! < early.first!, "moves up")
    #expect(inkedRows(try frame(10)).isEmpty, "ends above the frame")
    let held = inkedRows(try frame(10, ["end_hold": .number(3)]))
    #expect(held.contains(90) || held.contains { abs($0 - 90) < 6 }, "end_hold leaves the last line centered: \(held)")
    #expect(inkedRows(try frame(8, ["end_hold": .number(3)])) == held, "and holds it")
    // Rows: the role is drawn left of the center, the name right of it.
    let mid = try frame(0, ["progress": .number(0.5)])
    let (w, _, a) = alphas(mid)
    let rows = inkedRows(mid)
    #expect(rows.contains { y in (0..<150).contains { a[y * w + $0] > 40 } && (170..<320).contains { a[y * w + $0] > 40 } })
    let crawl = inkedRows(try frame(5, ["mode": .string("crawl")]))
    #expect(!crawl.isEmpty && crawl.allSatisfy { $0 > 140 }, "crawl runs along the bottom: \(crawl)")
}

@Test func timecodeBurnShowsTheTimelineTimecode() throws {
    var p = Project(name: "Burn", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.tracks[0].clips = [Clip(id: "bg", kind: .solid, start: 0, duration: 10, color: RGBA(r: 0.2, g: 0.3, b: 0.4, a: 1))]
    p.tracks.append(Track(id: "V2", kind: .video, name: "Burn", clips: [
        Clip(id: "g", kind: .generator, start: 0, duration: 10, effects: [Effect(id: "gen", type: "timecode_burn", params: ["show": .string("record,frame"), "position": .string("top_left")])]),
    ]))
    let scene = RenderScene(project: p, captions: [], trackIDs: [:], orientations: [:], images: [:])
    func shot(_ t: Double) -> CGImage { ctx.createCGImage(scene.render(at: t) { _ in nil }, from: CGRect(x: 0, y: 0, width: 320, height: 180))! }
    let a = shot(2), b = shot(2.04)
    func top(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 320 * 40 * 4)
        px.withUnsafeMutableBytes { buf in
            let c = CGContext(data: buf.baseAddress, width: 320, height: 40, bitsPerComponent: 8, bytesPerRow: 320 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: -140, width: 320, height: 180))
        }
        return px
    }
    let ta = top(a)
    #expect(ta.enumerated().contains { $0.offset % 4 == 0 && $0.element > 200 }, "white digits in the top-left box")
    #expect(ta != top(b), "the next frame shows the next timecode")
    #expect(BurnIn.text(p, clip: "g", at: 2, show: "record,frame") == "01:00:02:00   FR 000050")
}

/// Frames of the credits and burn-in written to /tmp/cutline-review for a look.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_SLOW"] != nil))
func reviewGraphicsLook() throws {
    let out = URL(fileURLWithPath: "/tmp/cutline-review")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let canvas = CGSize(width: 960, height: 540)
    let frames: [(String, CGImage?)] = [
        ("credits-mid", GeneratorRenderer.render(type: "credits", params: ["background": .string("#000000")], canvas: canvas, time: 2.5, duration: 5)),
        ("credits-hold", GeneratorRenderer.render(type: "credits", params: ["background": .string("#000000"), "end_hold": .number(2)], canvas: canvas, time: 5, duration: 5)),
        ("burn", GeneratorRenderer.render(type: "timecode_burn", params: ["watermark": .string("CONFIDENTIAL"), "label": .string("DRAFT v3")], canvas: canvas)),
    ]
    for (name, cg) in frames {
        let img = try #require(cg)
        let data = try #require(Frames.png(img))
        try data.write(to: out.appendingPathComponent("\(name).png"))
    }
}
