import AVFoundation
import CoreImage
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing
import Vision

private let film = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

/// Person segmentation of one film frame as a binary grid, rows top to bottom.
private struct Grid {
    var w: Int, h: Int, v: [Bool]

    /// 4-connected component labels and their sizes.
    func components() -> (labels: [Int], sizes: [Int]) {
        var labels = [Int](repeating: -1, count: w * h), sizes: [Int] = []
        for start in v.indices where v[start] && labels[start] < 0 {
            let id = sizes.count
            var stack = [start], n = 0
            labels[start] = id
            while let i = stack.popLast() {
                n += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if v[j] && labels[j] < 0 { labels[j] = id; stack.append(j) }
                }
            }
            sizes.append(n)
        }
        return (labels, sizes)
    }

    /// The component overlapping `ref` most (the largest when `ref` is nil).
    func component(overlapping ref: Grid?) -> Grid {
        let (labels, sizes) = components()
        guard !sizes.isEmpty else { return self }
        var score = sizes.map(Double.init)
        if let ref {
            score = [Double](repeating: 0, count: sizes.count)
            for i in v.indices where labels[i] >= 0 && ref.v[i] { score[labels[i]] += 1 }
        }
        let best = score.indices.max { score[$0] < score[$1] }!
        return Grid(w: w, h: h, v: labels.map { $0 == best })
    }

    static func polygon(_ pts: [(Double, Double)], w: Int, h: Int) -> Grid {
        var v = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let py = (Double(y) + 0.5) / Double(h)
            var xs: [Double] = []
            for i in pts.indices {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                if (a.1 <= py) != (b.1 <= py) { xs.append(a.0 + (py - a.1) / (b.1 - a.1) * (b.0 - a.0)) }
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let x0 = max(0, Int((xs[k] * Double(w) - 0.5).rounded(.up))), x1 = min(w - 1, Int((xs[k + 1] * Double(w) - 0.5).rounded(.down)))
                if x0 <= x1 { for x in x0...x1 { v[y * w + x] = true } }
                k += 2
            }
        }
        return Grid(w: w, h: h, v: v)
    }

    func iou(_ o: Grid) -> Double {
        var i = 0, u = 0
        for k in v.indices { if v[k] && o.v[k] { i += 1 }; if v[k] || o.v[k] { u += 1 } }
        return u == 0 ? 1 : Double(i) / Double(u)
    }
}

private func personGrid(_ gen: AVAssetImageGenerator, _ t: Double) async throws -> Grid {
    let (img, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
    let req = VNGeneratePersonSegmentationRequest()
    req.qualityLevel = .accurate
    req.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    let pb = try #require(req.results?.first?.pixelBuffer)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var v = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w { v[y * w + x] = base[y * row + x] > 127 } }
    return Grid(w: w, h: h, v: v)
}

/// A dozen-point outline of a grid: the farthest mask pixel along rays from its center.
private func outline(_ g: Grid, count: Int = 14) -> [(Double, Double)] {
    var sx = 0.0, sy = 0.0, n = 0.0
    for i in g.v.indices where g.v[i] { sx += Double(i % g.w); sy += Double(i / g.w); n += 1 }
    let cx = sx / n, cy = sy / n
    return (0..<count).map { k in
        let a = Double(k) / Double(count) * 2 * .pi
        var r = 0.0, best = 0.0
        while true {
            let x = Int(cx + cos(a) * r), y = Int(cy + sin(a) * r)
            guard x >= 0, y >= 0, x < g.w, y < g.h else { break }
            if g.v[y * g.w + x] { best = r }
            r += 0.5
        }
        return ((cx + cos(a) * best + 0.5) / Double(g.w), (cy + sin(a) * best + 0.5) / Double(g.h))
    }
}

/// Tracked roto on a Tears of Steel medium shot (an actor rising and turning, 126.0–134.7 s): mean mask IoU of
/// each mode's shape against the actor's person segmentation, every 0.25 s.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_SLOW"] != nil && FileManager.default.fileExists(atPath: film)))
func trackedRotoFollowsAnActorInAFilmShot() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-roto-film-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = URL(fileURLWithPath: film)
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let source = 126.0, length = 8.7
    var truth: [Grid] = []
    var prev: Grid?
    let times = stride(from: 0.0, through: length - 0.05, by: 0.25).map { $0 }
    for t in times {
        let g = try await personGrid(gen, source + t).component(overlapping: prev)
        truth.append(g)
        prev = g
    }
    let start = outline(truth[0]).map { String(format: "%.4f,%.4f", $0.0, $0.1) }.joined(separator: " ")

    var project = Project(name: "Roto film", canvas: Canvas(width: 1280, height: 720, fps: 24))
    project.media = [try await MediaProbe.probe(url, id: "tos")]
    try project.addClip(Clip(id: "c1", kind: .media, mediaId: "tos", start: 0, duration: length, sourceIn: source), trackId: "V1", mode: .place)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: project)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    let added = await box.call("effect_add", ["target": "c1", "type": "mask.shape", "params": ["points": .string(start)]])
    #expect(!added.isError, "\(added.plainText)")
    let fx = try #require(try bundle.loadProject().clip("c1")?.effects.first { $0.type == "mask.shape" }).id

    func score(_ args: JSON?) async throws -> (mean: Double, worst: Double, series: [Double], shapes: [[(Double, Double)]], text: String) {
        var text = ""
        if let args {
            let r = await box.call("recipe", ["name": "track_mask", "args": args])
            guard !r.isError else { return (0, 0, [], [], r.plainText) }
            text = r.plainText
        }
        let clip = try #require(try bundle.loadProject().clip("c1"))
        let curve = clip.anim["fx.\(fx).points"]
        var ious: [Double] = [], shapes: [[(Double, Double)]] = []
        for (i, t) in times.enumerated() {
            let pts = try #require(Curve.points(curve?.value(at: t)?.string ?? start))
            shapes.append(pts)
            ious.append(Grid.polygon(pts, w: truth[i].w, h: truth[i].h).iou(truth[i]))
        }
        if args != nil { _ = await box.call("history", ["action": "undo"]) }
        return (ious.reduce(0, +) / Double(ious.count), ious.min()!, ious, shapes, text)
    }
    /// What an editor fixing a drifted frame does: each tracked point moved onto the actor's edge nearest it.
    func fix(_ pts: [(Double, Double)], frame i: Int) -> String {
        let g = truth[i], aspect = Double(g.w) / Double(g.h)
        var edge: [(Double, Double)] = []
        for y in 0..<g.h {
            for x in 0..<g.w where g.v[y * g.w + x] {
                let open = x == 0 || y == 0 || x == g.w - 1 || y == g.h - 1 || !g.v[y * g.w + x - 1] || !g.v[y * g.w + x + 1] || !g.v[(y - 1) * g.w + x] || !g.v[(y + 1) * g.w + x]
                if open { edge.append(((Double(x) + 0.5) / Double(g.w), (Double(y) + 0.5) / Double(g.h))) }
            }
        }
        return pts.map { p in
            let q = edge.min { hypot(($0.0 - p.0) * aspect, $0.1 - p.1) < hypot(($1.0 - p.0) * aspect, $1.1 - p.1) }!
            return String(format: "%.4f,%.4f", q.0, q.1)
        }.joined(separator: " ")
    }
    func report(_ name: String, _ r: (mean: Double, worst: Double, series: [Double], shapes: [[(Double, Double)]], text: String), _ seconds: Double) {
        print("roto film: \(name) mean IoU \(String(format: "%.3f", r.mean)), worst \(String(format: "%.3f", r.worst)), \(String(format: "%.0f", seconds))s — \(r.text.prefix(240))")
        print("  per 0.25 s: " + r.series.map { String(format: "%.2f", $0) }.joined(separator: " "))
    }
    let still = try await score(nil)
    print("roto film: static shape mean IoU \(String(format: "%.3f", still.mean))")
    let only = ProcessInfo.processInfo.environment["CUTLINE_ROTO_MODES"].map { Set($0.split(separator: ",").map(String.init)) }
    var results: [String: Double] = [:]
    for (name, args) in [
        ("points", ["clip": "c1", "mode": "points"] as JSON),
        ("points+person", ["clip": "c1", "mode": "points", "refine": "person"]),
        ("planar", ["clip": "c1", "mode": "planar"]),
        ("translate", ["clip": "c1", "mode": "translate"]),
        ("person", ["clip": "c1", "mode": "person"]),
    ] where only?.contains(name) ?? true {
        let clock = Date()
        let r = try await score(args)
        results[name] = r.mean
        report(name, r, Date().timeIntervalSince(clock))
        // Two corrections where this run drifted most, a second or more apart.
        guard name.hasPrefix("points") else { continue }
        let order = r.series.indices.sorted { r.series[$0] < r.series[$1] }
        var picked: [Int] = []
        for k in order where k > 0 && !picked.contains(where: { abs($0 - k) < 4 }) {
            picked.append(k)
            if picked.count == 2 { break }
        }
        var corrected = args.object!
        corrected["correct"] = .array(picked.sorted().map { ["at": .number(times[$0]), "points": .string(fix(r.shapes[$0], frame: $0))] })
        let clock2 = Date()
        let c = try await score(.object(corrected))
        results[name + "+2 corrections"] = c.mean
        report(name + " + corrections at " + picked.sorted().map { String(format: "%.2fs", times[$0]) }.joined(separator: ", "), c, Date().timeIntervalSince(clock2))
    }
    if only == nil {
        #expect(results["points"]! > still.mean + 0.1)
        #expect(results["points+person"]! > results["points"]!)
        #expect(results["points+2 corrections"]! > results["points"]! + 0.01)
        #expect(results["points+person+2 corrections"]! >= results["points+person"]! - 0.01)
        #expect(results["person"]! > 0.8)
    }
}
