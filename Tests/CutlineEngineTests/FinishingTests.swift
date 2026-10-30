import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing
import Vision
@testable import CutlineCore
@testable import CutlineEngine

private struct LCG {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u = max(1e-7, next()), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// Smooth random RGB texture, `w`×`h`, values roughly 0.15…0.85.
private func texture(_ w: Int, _ h: Int, seed: UInt64) -> Plane {
    var rng = LCG(state: seed)
    var p = Plane(width: w, height: h)
    for i in p.data.indices { p.data[i] = rng.next() }
    for _ in 0..<2 {
        let blurred = (0..<3).map { c in Denoiser.box3(stride(from: c, to: p.data.count, by: 3).map { p.data[$0] }, w, h) }
        for i in 0..<(w * h) { for c in 0..<3 { p.data[i * 3 + c] = blurred[c][i] } }
    }
    let lo = p.data.min()!, hi = p.data.max()!
    for i in p.data.indices { p.data[i] = 0.15 + 0.7 * (p.data[i] - lo) / (hi - lo) }
    return p
}

/// A `w`×`h` window of `p` from `x` (fractional, sampled bilinearly).
private func crop(_ p: Plane, x: Double, y: Int, w: Int, h: Int) -> Plane {
    var out = Plane(width: w, height: h)
    let x0 = Int(x.rounded(.down)), f = Float(x - Double(x0))
    for yy in 0..<h {
        for xx in 0..<w {
            for c in 0..<3 {
                let a = p.data[((y + yy) * p.width + x0 + xx) * 3 + c], b = p.data[((y + yy) * p.width + min(p.width - 1, x0 + xx + 1)) * 3 + c]
                out.data[(yy * w + xx) * 3 + c] = a + (b - a) * f
            }
        }
    }
    return out
}

private func buffer(_ p: Plane) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, p.width, p.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    p.write(to: pb!)
    return pb!
}

private func addNoise(_ p: Plane, sigma: Float, rng: inout LCG) -> Plane {
    var out = p
    for i in out.data.indices { out.data[i] = min(1, max(0, p.data[i] + sigma * rng.gaussian())) }
    return out
}

/// The 8-bit round trip a frame takes through a buffer.
private func quantized(_ p: Plane) -> Plane { Plane(buffer(p)) }

/// Runs stages over in-memory frames and returns the results, off the cooperative pool as the engine does.
private func process(_ frames: [Plane], times: [Seconds]? = nil, stages: [TemporalStage]) async throws -> [Plane] {
    try await runBlocking { cancelled in
        var k = 0
        let window = FrameWindow {
            guard k < frames.count else { return nil }
            defer { k += 1 }
            return (times?[k] ?? Double(k) / 30, buffer(frames[k]))
        }
        var out: [Plane] = []
        try PictureProcessor(stages: stages).run(window, cancelled: cancelled) { _, _, plane in out.append(plane) }
        return out
    }
}

private func mse(_ a: Plane, _ b: Plane, where keep: (Int, Int) -> Bool) -> (mse: Double, mae: Double, n: Int) {
    var s = 0.0, m = 0.0, n = 0
    for y in 0..<a.height {
        for x in 0..<a.width where keep(x, y) {
            for c in 0..<3 {
                let d = Double(a.data[(y * a.width + x) * 3 + c] - b.data[(y * a.width + x) * 3 + c])
                s += d * d
                m += abs(d)
            }
            n += 1
        }
    }
    return (s / Double(max(1, 3 * n)), m / Double(max(1, 3 * n)), n)
}

private func psnr(_ mse: Double) -> Double { 10 * log10(1 / max(mse, 1e-12)) }

private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

// MARK: Temporal noise reduction

/// A static textured background with a textured square moving 3 px a frame, under gaussian noise.
private struct MovingSquare {
    let w = 256, h = 144, side = 36, frames = 15
    let speed = 3
    var clean: [Plane] = []
    var noisy: [Plane] = []

    init(sigma: Float) {
        let bg = texture(w, h, seed: 7)
        let fg = texture(side, side, seed: 99)
        var rng = LCG(state: 42)
        for i in 0..<frames {
            var f = bg
            let x0 = squareX(i)
            for y in 0..<side {
                for x in 0..<side {
                    for c in 0..<3 { f.data[((y + 50) * w + x0 + x) * 3 + c] = min(1, fg.data[(y * side + x) * 3 + c] * 0.6 + (c == 0 ? 0.4 : 0)) }
                }
            }
            clean.append(quantized(f))
            noisy.append(quantized(addNoise(f, sigma: sigma, rng: &rng)))
        }
    }

    func squareX(_ i: Int) -> Int { 40 + speed * i }

    /// Distance in pixels from (x, y) to the square in frame i (0 inside).
    func distance(_ x: Int, _ y: Int, frame i: Int) -> Int {
        let x0 = squareX(i), y0 = 50
        let dx = max(x0 - x, 0, x - (x0 + side - 1)), dy = max(y0 - y, 0, y - (y0 + side - 1))
        return max(dx, dy)
    }
}

@Test func temporalDenoiseCleansStaticAreasWithoutGhosting() async throws {
    let scene = MovingSquare(sigma: 0.06)
    let radius = 2
    let flow = try? OpticalFlow(width: scene.w, height: scene.h, context: ciContext)
    let denoiser = Denoiser(.init(radius: radius, strength: 1, threshold: 0.04, spatial: 0, mix: 1), flow: flow, context: ciContext)
    let out = try await process(scene.noisy, stages: [denoiser])
    #expect(out.count == scene.frames)
    var staticNoisy = 0.0, staticOut = 0.0, edgeNoisy = 0.0, edgeOut = 0.0, trailNoisy = 0.0, trailOut = 0.0
    let measured = radius..<(scene.frames - radius)
    for i in measured {
        // Static: far from the square in every frame the filter reads.
        let still = { (x: Int, y: Int) in (i - radius...i + radius).allSatisfy { scene.distance(x, y, frame: $0) > 6 } }
        staticNoisy += mse(scene.noisy[i], scene.clean[i], where: still).mse
        staticOut += mse(out[i], scene.clean[i], where: still).mse
        // The square's edges, inside and out.
        let edge = { (x: Int, y: Int) in scene.distance(x, y, frame: i) <= 3 && !(scene.distance(x, y, frame: i) == 0 && x > scene.squareX(i) + 3 && x < scene.squareX(i) + scene.side - 4 && y > 53 && y < 50 + scene.side - 4) }
        edgeNoisy += mse(scene.noisy[i], scene.clean[i], where: edge).mae
        edgeOut += mse(out[i], scene.clean[i], where: edge).mae
        // Background the square just uncovered, where a ghost would linger.
        let trail = { (x: Int, y: Int) in scene.distance(x, y, frame: i) > 2 && (1...radius).contains { scene.distance(x, y, frame: i - $0) == 0 } }
        trailNoisy += mse(scene.noisy[i], scene.clean[i], where: trail).mae
        trailOut += mse(out[i], scene.clean[i], where: trail).mae
    }
    let n = Double(measured.count)
    let gain = psnr(staticOut / n) - psnr(staticNoisy / n)
    print("denoise: flow \(flow != nil), static PSNR \(String(format: "%.2f → %.2f dB (+%.2f)", psnr(staticNoisy / n), psnr(staticOut / n), gain)), edge MAE \(String(format: "%.4f → %.4f", edgeNoisy / n, edgeOut / n)), uncovered MAE \(String(format: "%.4f → %.4f", trailNoisy / n, trailOut / n))")
    #expect(gain >= 4, "static PSNR gain \(gain) dB")
    #expect(edgeOut <= edgeNoisy, "edge error rose: \(edgeNoisy / n) → \(edgeOut / n)")
    #expect(trailOut <= trailNoisy, "uncovered background ghosted: \(trailNoisy / n) → \(trailOut / n)")
}

@Test func spatialPassRemovesNoiseLeftOnASingleFrame() throws {
    var rng = LCG(state: 5)
    let clean = quantized(texture(128, 72, seed: 3))
    let dirty = quantized(addNoise(clean, sigma: 0.05, rng: &rng))
    let smoothed = Denoiser.bilateral(dirty, sigma: 0.08, amount: 1)
    let before = mse(dirty, clean) { _, _ in true }.mse, after = mse(smoothed, clean) { _, _ in true }.mse
    print("bilateral: PSNR \(String(format: "%.2f → %.2f dB", psnr(before), psnr(after)))")
    #expect(psnr(after) > psnr(before) + 2)
}

@Test func motionThresholdTradesNoiseForGhosts() async throws {
    let scene = MovingSquare(sigma: 0.04)
    // Without alignment or rejection a moving square smears; with them the uncovered background stays clean.
    let loose = Denoiser(.init(radius: 2, strength: 1, threshold: 0.5, spatial: 0, mix: 1), flow: nil, context: ciContext)
    let tight = Denoiser(.init(radius: 2, strength: 1, threshold: 0.03, spatial: 0, mix: 1), flow: nil, context: ciContext)
    let a = try await process(scene.noisy, stages: [loose]), b = try await process(scene.noisy, stages: [tight])
    let i = 7
    let trail = { (x: Int, y: Int) in scene.distance(x, y, frame: i) > 2 && (1...2).contains { scene.distance(x, y, frame: i - $0) == 0 } }
    let ghost = mse(a[i], scene.clean[i], where: trail).mae, clean = mse(b[i], scene.clean[i], where: trail).mae
    print("threshold: uncovered MAE loose \(ghost) tight \(clean)")
    #expect(ghost > clean * 1.5)
}

// MARK: Object removal

/// A textured background seen through a moving window (the camera pans `pan` px a frame) with a magenta square
/// moving `speed` px a frame across the frame.
private struct ObjectScene {
    let w = 320, h = 180, side = 28, frames: Int
    let pan: Double, speed: Int
    var clean: [Plane] = []
    var shot: [Plane] = []
    var boxes: [TrackSample] = []

    init(pan: Double, speed: Int, frames: Int = 40) {
        self.pan = pan
        self.speed = speed
        self.frames = frames
        let bg = texture(w + Int(pan * Double(frames)) + 4, h, seed: 11)
        for i in 0..<frames {
            let plate = crop(bg, x: pan * Double(i), y: 0, w: w, h: h)
            var f = plate
            let x0 = 60 + speed * i, y0 = 70
            for y in 0..<side {
                for x in 0..<side {
                    let o = ((y0 + y) * w + x0 + x) * 3
                    f.data[o] = 0.95
                    f.data[o + 1] = 0.1 + 0.05 * Float((x / 4 + y / 4) % 2)
                    f.data[o + 2] = 0.9
                }
            }
            clean.append(quantized(plate))
            shot.append(quantized(f))
            boxes.append(TrackSample(t: Double(i) / 30, box: NormRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h), width: Double(side) / Double(w), height: Double(side) / Double(h)), confidence: 1))
        }
    }

    func hole(_ i: Int, pad: Int) -> (Int, Int) -> Bool {
        let x0 = 60 + speed * i - pad, y0 = 70 - pad, x1 = 60 + speed * i + side + pad, y1 = 70 + side + pad
        return { x, y in x >= x0 && x < x1 && y >= y0 && y < y1 }
    }
}

private func removal(_ scene: ObjectScene, window: Seconds = 1) async throws -> [Plane] {
    let s = ObjectRemover.Settings(samples: scene.boxes, padding: 4 / Float(scene.h), window: window, feather: 1 / Float(scene.h), mix: 1)
    return try await process(scene.shot, stages: [ObjectRemover(s, fps: 30, context: ciContext)])
}

@Test func objectRemovalFillsFromFramesWhereTheBackgroundShows() async throws {
    for (pan, speed) in [(1.4, 2), (0, 3)] {
        let scene = ObjectScene(pan: pan, speed: speed)
        let out = try await removal(scene)
        var before = 0.0, after = 0.0
        let frames = 12..<28
        for i in frames {
            let inHole = scene.hole(i, pad: 2)
            before += mse(scene.shot[i], scene.clean[i], where: inHole).mae
            after += mse(out[i], scene.clean[i], where: inHole).mae
        }
        let n = Double(frames.count)
        // Away from the object the picture is untouched.
        let outside = mse(out[20], scene.shot[20]) { x, y in !scene.hole(20, pad: 6)(x, y) }.mae
        print("remove object pan \(pan) speed \(speed): hole MAE vs clean plate \(String(format: "%.4f → %.4f", before / n, after / n)), outside change \(String(format: "%.5f", outside))")
        #expect(after / n < 0.02, "pan \(pan): filled region error \(after / n)")
        #expect(after < before * 0.1)
        #expect(outside < 0.001)
    }
}

@Test func objectRemovalDiffusesWhereNoFrameShowsTheBackground() async throws {
    // A still camera and a still object: no frame shows what's behind it.
    let scene = ObjectScene(pan: 0, speed: 0, frames: 10)
    let out = try await removal(scene)
    let inHole = scene.hole(5, pad: 0)
    let filled = mse(out[5], scene.clean[5], where: inHole).mae, original = mse(scene.shot[5], scene.clean[5], where: inHole).mae
    print("remove object, nothing visible: hole MAE \(String(format: "%.4f → %.4f", original, filled))")
    // Diffusion can't recover texture, but the magenta is gone: green is back near the background's level.
    #expect(filled < original * 0.4)
    var green: Float = 0
    for y in 75..<92 { for x in 65..<82 { green += out[5].data[(y * scene.w + x) * 3 + 1] } }
    #expect(green / Float(17 * 17) > 0.3)
}

// MARK: Tracked object masks

@Test func bestInstanceMatchesTheTrackedBox() {
    // Instance 1 fills the left box, instance 2 sits on the right, instance 3 is huge background-ish clutter.
    let w = 100, h = 50
    var labels = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            if x >= 10, x < 30, y >= 10, y < 40 { labels[y * w + x] = 1 }
            else if x >= 60, x < 80, y >= 15, y < 35 { labels[y * w + x] = 2 }
            else if y >= 45 { labels[y * w + x] = 3 }
        }
    }
    let map = MaskLabels(width: w, height: h, labels: labels)
    let all = IndexSet([1, 2, 3])
    #expect(map.bestInstance(NormRect(x: 0.08, y: 0.18, width: 0.24, height: 0.66), among: all) == 1)
    #expect(map.bestInstance(NormRect(x: 0.58, y: 0.28, width: 0.24, height: 0.44), among: all) == 2)
    #expect(map.bestInstance(NormRect(x: 0.4, y: 0.1, width: 0.1, height: 0.2), among: all) == nil)
    let m = MaskBuffer.box(NormRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), width: 4, height: 4)
    #expect(m.values == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1])
}

@Test func objectMaskFollowsTheBoxAndShowsAsAMatte() async throws {
    // A plain picture Vision finds nothing in: the mask falls back to the tracked box, which moves with time.
    let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
    let img = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7)).cropped(to: frame)
    let boxes = ObjectTrack.encodeBoxes([
        TrackSample(t: 0, box: NormRect(x: 0.1, y: 0.2, width: 0.2, height: 0.4), confidence: 1),
        TrackSample(t: 1, box: NormRect(x: 0.6, y: 0.2, width: 0.2, height: 0.4), confidence: 1),
    ])
    let fx = Effect(id: "obj", type: "mask.object", params: ["boxes": .string(boxes), "threshold": .number(0), "smoothing": .number(0), "feather": .number(0)])
    func alpha(_ t: Seconds, _ x: CGFloat, _ y: CGFloat) -> Float {
        var ctx = EffectRenderer.Context(unit: 100, time: t, opaque: true)
        ctx.source = MaskCache.Key(mediaId: "m\(t)", time: t)
        let out = EffectRenderer.apply([fx], to: img, context: ctx) { _, _ in nil }
        var px = [Float](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: frame.height - y - 1, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return px[3]
    }
    let (values, matte) = try await runBlocking { _ -> ([Float], CIImage?) in
        var ctx = EffectRenderer.Context(unit: 100, time: 0, opaque: true)
        ctx.source = MaskCache.Key(mediaId: "matte", time: 0)
        return ([alpha(0, 40, 40), alpha(0, 140, 40), alpha(1, 140, 40), alpha(1, 40, 40), alpha(0.5, 90, 40)],
                EffectRenderer.matte([fx], id: "obj", to: img, context: ctx) { _, _ in nil })
    }
    #expect(values[0] > 0.9 && values[1] < 0.1, "\(values)")
    #expect(values[2] > 0.9 && values[3] < 0.1, "\(values)")
    // Halfway, the box is between.
    #expect(values[4] > 0.9)
    #expect(matte != nil)
}

private let film = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

@Test(.enabled(if: FileManager.default.fileExists(atPath: film)))
func objectMaskIsolatesOnePersonOnRealFootage() async throws {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: film)))
    gen.maximumSize = CGSize(width: 960, height: 960)
    gen.appliesPreferredTrackTransform = true
    var checked = 0
    for t in stride(from: 30.0, to: 600, by: 15) where checked < 3 {
        guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
        // Vision waits on its own queues, so it runs off the cooperative pool.
        let found = try await runBlocking { _ -> (NormRect, [Float], Int, Int)? in
            let req = VNDetectHumanRectanglesRequest()
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            guard let person = (req.results ?? []).filter({ $0.confidence > 0.8 && $0.boundingBox.height > 0.3 }).max(by: { $0.boundingBox.height < $1.boundingBox.height }) else { return nil }
            let b = person.boundingBox
            let box = NormRect(x: Double(b.minX), y: Double(1 - b.maxY), width: Double(b.width), height: Double(b.height))
            let img = CIImage(cgImage: cg)
            guard let mask = Segmentation.mask(.object(box, padding: 0.02, fallback: false, id: "p"), img) else { return nil }
            let e = img.extent
            let w = Int(e.width), h = Int(e.height)
            var values = [Float](repeating: 0, count: w * h)
            ciContext.render(mask, toBitmap: &values, rowBytes: w * 4, bounds: e, format: .Rf, colorSpace: nil)
            return (box, values, w, h)
        }
        guard let (box, values, w, h) = found else { continue }
        var inside = 0.0, outside = 0.0
        let pad = 0.025
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
                let v = Double(values[y * w + x])
                if fx >= box.x - pad, fx <= box.x + box.width + pad, fy >= box.y - pad, fy <= box.y + box.height + pad { inside += v } else { outside += v }
            }
        }
        let coverage = inside / (box.width * box.height * Double(w * h))
        print("object mask at \(t)s: \(String(format: "%.0f%%", coverage * 100)) of the person's box, \(String(format: "%.2f%%", outside / max(1, inside + outside) * 100)) outside")
        guard inside > 0 else { continue }
        #expect(outside / (inside + outside) < 0.01)
        #expect(coverage > 0.15 && coverage < 1.05)
        checked += 1
    }
    #expect(checked > 0)
}

// MARK: Real footage

@Test(.enabled(if: FileManager.default.fileExists(atPath: film)))
func temporalDenoiseReducesGrainOnRealFootage() async throws {
    let url = URL(fileURLWithPath: film)
    // The grainiest dim moment among a few candidates.
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.maximumSize = CGSize(width: 640, height: 640)
    var best: (t: Seconds, grain: Double)?
    for t in stride(from: 60.0, to: 600, by: 60) {
        guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
        let p = Plane(cgImage: cg)
        let mean = Double(p.data.reduce(0, +)) / Double(p.data.count)
        let grain = flatNoise(p, p).0
        if mean > 0.05, mean < 0.4, best == nil || grain > best!.grain { best = (t, grain) }
    }
    let start = try #require(best).t
    let frames = try await SourceFrames.open(url: url, maxSize: CGSize(width: 640, height: 640), from: start)
    let (input, times) = try await runBlocking { _ -> ([Plane], [Seconds]) in
        var input: [Plane] = [], times: [Seconds] = []
        while input.count < 16, let f = try frames.next() {
            guard f.time >= start else { continue }
            input.append(Plane(f.buffer))
            times.append(f.time)
        }
        return (input, times)
    }
    let flow = try? OpticalFlow(width: input[0].width, height: input[0].height, context: ciContext)
    let denoiser = Denoiser(.init(radius: 2, strength: 1, threshold: 0.04, spatial: 0, mix: 1), flow: flow, context: ciContext)
    let out = try await process(input, times: times, stages: [denoiser])
    var before = 0.0, after = 0.0
    for i in 4..<12 {
        let (a, b) = flatNoise(input[i], out[i])
        before += a
        after += b
    }
    print("real footage at \(start)s: grain std in flat regions \(String(format: "%.4f → %.4f (%.0f%% less)", before / 8, after / 8, (1 - after / before) * 100))")
    #expect(after < before * 0.8)
}

/// Luma high-pass std in the flattest 8×8 blocks of `a`, measured in `a` and `b`.
private func flatNoise(_ a: Plane, _ b: Plane) -> (Double, Double) {
    func luma(_ p: Plane, _ x: Int, _ y: Int) -> Double {
        let o = (y * p.width + x) * 3
        return Double(0.2126 * p.data[o] + 0.7152 * p.data[o + 1] + 0.0722 * p.data[o + 2])
    }
    func residual(_ p: Plane, _ x: Int, _ y: Int) -> Double {
        var s = 0.0
        for dy in -1...1 { for dx in -1...1 { s += luma(p, x + dx, y + dy) } }
        return luma(p, x, y) - s / 9
    }
    var blocks: [(score: Double, a: Double, b: Double)] = []
    for by in stride(from: 8, to: a.height - 16, by: 8) {
        for bx in stride(from: 8, to: a.width - 16, by: 8) {
            var lumas: [Double] = [], ra = 0.0, rb = 0.0
            for y in by..<by + 8 {
                for x in bx..<bx + 8 {
                    lumas.append(luma(a, x, y))
                    ra += pow(residual(a, x, y), 2)
                    rb += pow(residual(b, x, y), 2)
                }
            }
            let mean = lumas.reduce(0, +) / 64
            // Flat but not crushed to black, where 8-bit clipping hides the grain.
            guard mean > 0.04 else { continue }
            let range = lumas.max()! - lumas.min()!
            blocks.append((range, (ra / 64).squareRoot(), (rb / 64).squareRoot()))
        }
    }
    let flat = blocks.sorted { $0.score < $1.score }.prefix(max(1, blocks.count / 5))
    return (flat.map(\.a).reduce(0, +) / Double(flat.count), flat.map(\.b).reduce(0, +) / Double(flat.count))
}

extension Plane {
    init(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.init(width: w, height: h)
        for i in 0..<(w * h) { for c in 0..<3 { data[i * 3 + c] = Float(bytes[i * 4 + c]) / 255 } }
    }
}

// MARK: Processed copies on the timeline

private func writeMovie(_ frames: [Plane]) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("finishing-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: frames[0].width, AVVideoHeightKey: frames[0].height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for (i, f) in frames.enumerated() {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(adaptor.append(buffer(f), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
}

/// The timeline frame at `t` of a one-clip project playing `url`.
private func timelineFrame(_ url: URL, effects: [Effect], at t: Seconds, size: (Int, Int), render: Bool) async throws -> (frame: Plane, missing: [String], request: ProcessedPicture.Request?) {
    var p = Project(name: "NR", canvas: Canvas(width: size.0, height: size.1, fps: 30))
    p.media = [try await MediaProbe.probe(url, id: "m")]
    var clip = Clip(id: "c1", kind: .media, mediaId: "m", start: 0, duration: 0.4, sourceIn: 0.05)
    clip.effects = effects
    try p.addClip(clip, trackId: "V1", mode: .place)
    let req = ProcessedPicture.requests(p).first
    if render, let req { _ = try await ProcessedPicture.render(req) }
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
    let frames = try await Frames.timeline(built, times: [t], maxSize: CGSize(width: size.0, height: size.1))
    return (Plane(cgImage: try #require(frames.first).image), built.missingPictures, req)
}

@Test func timelinePlaysTheProcessedCopyOnceRendered() async throws {
    let scene = MovingSquare(sigma: 0.05)
    let noisyURL = try await writeMovie(scene.noisy), cleanURL = try await writeMovie(scene.clean)
    defer { [noisyURL, cleanURL].forEach { try? FileManager.default.removeItem(at: $0) } }
    let nr = [Effect(id: "nr", type: "video.denoise", params: ["strength": .number(1)])]
    let size = (scene.w, scene.h)
    // Timeline 0.2 s is source 0.25 s, frame 7.
    let reference = try await timelineFrame(cleanURL, effects: [], at: 0.2, size: size, render: false).frame
    let unprocessed = try await timelineFrame(noisyURL, effects: nr, at: 0.2, size: size, render: false)
    #expect(unprocessed.missing == ["c1"])
    let req = try #require(unprocessed.request)
    defer { try? FileManager.default.removeItem(at: req.url) }
    let processed = try await timelineFrame(noisyURL, effects: nr, at: 0.2, size: size, render: true)
    #expect(processed.missing.isEmpty)
    #expect(ProcessedPicture.cached(req) != nil)
    let still = { (x: Int, y: Int) in (5...9).allSatisfy { scene.distance(x, y, frame: $0) > 6 } }
    let before = mse(unprocessed.frame, reference, where: still).mse, after = mse(processed.frame, reference, where: still).mse
    // The square sits where frame 7 has it, so the copy is in step with the source.
    let square = { (x: Int, y: Int) in scene.distance(x, y, frame: 7) == 0 && scene.distance(x, y, frame: 6) > 0 }
    let squareErr = mse(processed.frame, reference, where: square).mae
    print("timeline: static PSNR \(String(format: "%.2f → %.2f dB", psnr(before), psnr(after))), leading edge MAE \(String(format: "%.4f", squareErr))")
    #expect(psnr(after) > psnr(before) + 3)
    #expect(squareErr < 0.05)
}

// MARK: Inpainting what no frame shows

/// A still camera on a railing, a static post in front of it, and fresh sensor noise every frame.
private struct StaticPost {
    let w = 320, h = 180, frames = 14
    let post = (x: 152, y: 24, w: 24, h: 116)
    var clean: Plane
    var shot: [Plane] = []
    var boxes: [TrackSample]

    init(noise: Float = 0.012) {
        clean = quantized(Pattern.railing.picture(w, h))
        var rng = LCG(state: 17)
        for _ in 0..<frames {
            var f = addNoise(clean, sigma: noise, rng: &rng)
            for y in post.y..<(post.y + post.h) {
                for x in post.x..<(post.x + post.w) {
                    let o = (y * w + x) * 3
                    f.data[o] = 0.35; f.data[o + 1] = 0.3; f.data[o + 2] = 0.25
                }
            }
            shot.append(quantized(f))
        }
        let box = NormRect(x: Double(post.x) / Double(w), y: Double(post.y) / Double(h), width: Double(post.w) / Double(w), height: Double(post.h) / Double(h))
        boxes = [TrackSample(t: 0, box: box, confidence: 1), TrackSample(t: 1, box: box, confidence: 1)]
    }

    /// The padded hole.
    func hole(pad: Int) -> (Int, Int) -> Bool {
        { x, y in x >= post.x - pad && x < post.x + post.w + pad && y >= post.y - pad && y < post.y + post.h + pad }
    }

    func settings(_ patch: Bool = true) -> ObjectRemover.Settings {
        var s = ObjectRemover.Settings(samples: boxes, padding: 3 / Float(h), window: 0.3, feather: 1 / Float(h), mix: 1)
        s.patchFill = patch
        return s
    }
}

/// Mean absolute change between consecutive frames inside `keep`.
private func flicker(_ frames: [Plane], where keep: (Int, Int) -> Bool) -> Double {
    (1..<frames.count).map { mse(frames[$0], frames[$0 - 1], where: keep).mae }.reduce(0, +) / Double(frames.count - 1)
}

/// Share of the hole's columns where both rails stay dark between light sky.
private func railsContinue(_ p: Plane, columns: Range<Int>) -> Double {
    func luma(_ x: Int, _ y: Int) -> Float { let o = (y * p.width + x) * 3; return 0.3 * p.data[o] + 0.59 * p.data[o + 1] + 0.11 * p.data[o + 2] }
    var good = 0, total = 0
    for x in columns {
        for (lo, hi) in [(40, 46), (100, 104)] {
            total += 1
            let rail = (lo..<hi).map { luma(x, $0) }.reduce(0, +) / Float(hi - lo)
            if rail < 0.3, luma(x, lo - 3) > 0.5, luma(x, hi + 2) > 0.5 { good += 1 }
        }
    }
    return Double(good) / Double(max(1, total))
}

@Test func objectRemovalInpaintsAStaticObjectAndHoldsItStill() async throws {
    let scene = StaticPost()
    let began = Date()
    let patched = try await process(scene.shot, stages: [ObjectRemover(scene.settings(), fps: 30, context: ciContext)])
    let took = Date().timeIntervalSince(began) / Double(scene.frames)
    let smooth = try await process(scene.shot, stages: [ObjectRemover(scene.settings(false), fps: 30, context: ciContext)])
    // The same fill made frame by frame with no guide from the frame before.
    let independent = scene.shot.map { f -> Plane in
        var rgb = f.data
        let hole = (0..<(scene.w * scene.h)).map { scene.hole(pad: 3)($0 % scene.w, $0 / scene.w) }
        Inpainter.fill(&rgb, width: scene.w, height: scene.h, hole: hole)
        return Plane(width: scene.w, height: scene.h, data: rgb)
    }
    let inHole = scene.hole(pad: 2)
    let cols = scene.post.x..<(scene.post.x + scene.post.w)
    let err = patched.map { mse($0, scene.clean, where: inHole).mae }.reduce(0, +) / Double(scene.frames)
    let errSmooth = smooth.map { mse($0, scene.clean, where: inHole).mae }.reduce(0, +) / Double(scene.frames)
    let rails = patched.map { railsContinue($0, columns: cols) }.min()!, railsSmooth = railsContinue(smooth[5], columns: cols)
    let noiseFlicker = flicker(scene.shot, where: { x, y in !scene.hole(pad: 6)(x, y) })
    let held = flicker(patched, where: inHole), loose = flicker(independent, where: inHole)
    print("static post: hole MAE \(String(format: "%.4f", err)) (smooth \(String(format: "%.4f", errSmooth))), rails continue in \(String(format: "%.0f%%", rails * 100)) of columns (smooth \(String(format: "%.0f%%", railsSmooth * 100))), frame-to-frame change in the fill \(String(format: "%.4f", held)) guided vs \(String(format: "%.4f", loose)) frame by frame (sensor noise \(String(format: "%.4f", noiseFlicker))), \(String(format: "%.0f", took * 1000)) ms a frame")
    saveForReview(patched[6], "post-patch")
    saveForReview(smooth[6], "post-smooth")
    #expect(err < errSmooth * 0.3)
    #expect(rails > 0.9 && railsSmooth < 0.2)
    #expect(held < loose)
    #expect(held < noiseFlicker * 1.5)
    // Away from the post the picture is untouched.
    #expect(mse(patched[6], scene.shot[6]) { x, y in !scene.hole(pad: 6)(x, y) }.mae < 0.001)
}

@Test func objectRemovalTakesTheBackgroundFromACleanPlate() async throws {
    let scene = StaticPost()
    // A plate shot a little brighter and offset by the camera settling 3 px right and 2 px down.
    var plate = Plane(width: scene.w, height: scene.h)
    for y in 0..<scene.h {
        for x in 0..<scene.w {
            let sx = min(scene.w - 1, max(0, x - 3)), sy = min(scene.h - 1, max(0, y - 2))
            for c in 0..<3 { plate.data[(y * scene.w + x) * 3 + c] = min(1, scene.clean.data[(sy * scene.w + sx) * 3 + c] + 0.05) }
        }
    }
    var s = scene.settings()
    s.plate = buffer(quantized(plate))
    let out = try await process(Array(scene.shot.prefix(4)), stages: [ObjectRemover(s, fps: 30, context: ciContext)])
    let err = mse(out[2], scene.clean, where: scene.hole(pad: 2)).mae
    print("clean plate: hole MAE \(String(format: "%.4f", err))")
    #expect(err < 0.015)
}

@Test func cleanPlateFrameComesFromTheClipsMedia() async throws {
    // The post walks in after 0.1 s; frame 0 shows the railing clear.
    let scene = StaticPost()
    let frames = scene.shot.enumerated().map { $0.offset < 3 ? quantized(scene.clean) : $0.element } + Array(scene.shot.suffix(6))
    let url = try await writeMovie(frames), cleanURL = try await writeMovie([Plane](repeating: quantized(scene.clean), count: frames.count))
    defer { [url, cleanURL].forEach { try? FileManager.default.removeItem(at: $0) } }
    let fx = Effect(id: "rm", type: "video.remove_object", params: ["boxes": .string(ObjectTrack.encodeBoxes(scene.boxes)), "padding": .number(3.0 / 180), "clean_plate_at": .number(0)])
    let result = try await timelineFrame(url, effects: [fx], at: 0.2, size: (scene.w, scene.h), render: true)
    defer { result.request.map { try? FileManager.default.removeItem(at: $0.url) } }
    let reference = try await timelineFrame(cleanURL, effects: [], at: 0.2, size: (scene.w, scene.h), render: false).frame
    let err = mse(result.frame, reference, where: scene.hole(pad: 2)).mae
    print("clean plate frame: hole MAE \(String(format: "%.4f", err))")
    #expect(result.missing.isEmpty)
    #expect(err < 0.02)
}

/// Removes a railing post from a still of a bridge shot in Tears of Steel, held for a dozen frames with fresh grain so
/// no frame shows what's behind it; at the film's size and at 1080p. CUTLINE_REAL=1 runs it, CUTLINE_SAVE_FRAMES
/// keeps the frames.
@Test(.enabled(if: FileManager.default.fileExists(atPath: film) && ProcessInfo.processInfo.environment["CUTLINE_REAL"] != nil))
func objectRemovalOnRealFootage() async throws {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: film)))
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let still = Plane(cgImage: try await gen.image(at: CMTime(seconds: 280, preferredTimescale: 600)).image)
    // The post right of the walker, rails crossing it, down to the frame's bottom edge.
    let box = NormRect(x: 449.0 / 862, y: 162.0 / 360, width: 52.0 / 862, height: 198.0 / 360)
    let samples = [TrackSample(t: 0, box: box, confidence: 1), TrackSample(t: 10, box: box, confidence: 1)]
    for scale in [1, 2] {
        let base = scale == 1 ? still : upscaled(still, by: scale)
        let w = base.width, h = base.height
        var rng = LCG(state: 3)
        let input = (0..<12).map { _ in quantized(addNoise(base, sigma: 0.01, rng: &rng)) }
        for patch in scale == 1 ? [true, false] : [true] {
            var s = ObjectRemover.Settings(samples: samples, padding: 0.01, window: 0.4, feather: 0.004, mix: 1)
            s.patchFill = patch
            let began = Date()
            let out = try await process(input, stages: [ObjectRemover(s, fps: 24, context: ciContext)])
            let perFrame = Date().timeIntervalSince(began) / Double(input.count)
            let pad = 0.01 * Double(h)
            let x0 = Int(box.x * Double(w) - pad), x1 = Int((box.x + box.width) * Double(w) + pad), y0 = Int(box.y * Double(h) - pad)
            let inHole = { (x: Int, y: Int) in x >= x0 && x <= x1 && y >= y0 }
            let held = flicker(out, where: inHole), grain = flicker(input, where: { x, y in !inHole(x, y) })
            print("real footage \(w)×\(h), \(patch ? "patch" : "smooth") fill: hole \(x1 - x0 + 1)×\(h - y0) px (\(String(format: "%.1f%%", Double((x1 - x0 + 1) * (h - y0)) / Double(w * h) * 100)) of the frame), \(String(format: "%.0f", perFrame * 1000)) ms a frame, frame-to-frame change in the fill \(String(format: "%.4f", held)) (grain elsewhere \(String(format: "%.4f", grain)))")
            saveForReview(out[6], "tos-\(w)-\(patch ? "patch" : "smooth")")
            #expect(held < grain * 1.5)
        }
        saveForReview(input[6], "tos-\(w)-input")
    }
}

private func upscaled(_ p: Plane, by k: Int) -> Plane {
    var out = Plane(width: p.width * k, height: p.height * k)
    for y in 0..<out.height {
        for x in 0..<out.width {
            let sx = min(Float(p.width - 1), max(0, (Float(x) + 0.5) / Float(k) - 0.5)), sy = min(Float(p.height - 1), max(0, (Float(y) + 0.5) / Float(k) - 0.5))
            let ax = Int(sx), ay = Int(sy), bx = min(p.width - 1, ax + 1), by = min(p.height - 1, ay + 1)
            let fx = sx - Float(ax), fy = sy - Float(ay)
            for c in 0..<3 {
                let v = { (xx: Int, yy: Int) in p.data[(yy * p.width + xx) * 3 + c] }
                out.data[(y * out.width + x) * 3 + c] = (v(ax, ay) * (1 - fx) + v(bx, ay) * fx) * (1 - fy) + (v(ax, by) * (1 - fx) + v(bx, by) * fx) * fy
            }
        }
    }
    return out
}
