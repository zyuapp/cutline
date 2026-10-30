import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let lensContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

/// A float RGBA picture, rows from the top.
private struct Picture {
    let width: Int
    let height: Int
    var data: [Float]

    init(width: Int, height: Int, _ f: (Double, Double) -> (Float, Float, Float)) {
        self.width = width
        self.height = height
        data = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = f(Double(x) + 0.5, Double(y) + 0.5), o = (y * width + x) * 4
                data[o] = c.0; data[o + 1] = c.1; data[o + 2] = c.2
            }
        }
    }

    init(_ img: CIImage, width: Int, height: Int) {
        self.width = width
        self.height = height
        data = [Float](repeating: 0, count: width * height * 4)
        lensContext.render(img, toBitmap: &data, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
    }

    var image: CIImage {
        let d = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: d, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }

    func at(_ x: Int, _ y: Int, _ c: Int) -> Float { data[(y * width + x) * 4 + c] }
}

private func run(_ type: String, _ params: [String: ParamValue], _ p: Picture) -> Picture {
    let ctx = EffectRenderer.Context(unit: CGFloat(p.height), time: 0, opaque: true)
    let out = EffectRenderer.apply([Effect(id: "e", type: type, params: params)], to: p.image, context: ctx) { _, _ in nil }
    return Picture(out, width: p.width, height: p.height)
}

/// Undistorted radius for distorted radius `rd` by bisection, independent of `RadialLens.undistort`.
private func undistort(_ rd: Double, k1: Double, k2: Double) -> Double {
    var lo = 0.0, hi = 2.0
    for _ in 0..<60 {
        let m = (lo + hi) / 2
        let d = m * (1 + k1 * m * m + k2 * m * m * m * m)
        if d < rd { lo = m } else { hi = m }
    }
    return (lo + hi) / 2
}

/// Dark rows of a grid line through each column: the line's center (intensity-weighted) in rows near `guess`.
private func lineCenter(_ p: Picture, column x: Int, near guess: Double, reach: Int = 14) -> Double {
    var s = 0.0, w = 0.0
    for y in max(0, Int(guess) - reach)...min(p.height - 1, Int(guess) + reach) {
        let dark = Double(max(0, 1 - p.at(x, y, 1)))
        s += dark * (Double(y) + 0.5)
        w += dark
    }
    return w > 0 ? s / w : .nan
}

@Test func lensCorrectionStraightensABarrelGrid() {
    let w = 480, h = 270, k1 = -0.28, k2 = 0.06
    let unit = hypot(Double(w), Double(h)) / 2
    let cx = Double(w) / 2, cy = Double(h) / 2
    // A grid of soft lines (Gaussian profile, σ 1.2 px) every 40 px, photographed through a barrel lens.
    func grid(_ x: Double, _ y: Double) -> Float {
        let d = min(abs(x.truncatingRemainder(dividingBy: 40) - 20), abs(y.truncatingRemainder(dividingBy: 40) - 20))
        return Float(1 - exp(-d * d / (2 * 1.2 * 1.2)))
    }
    let distorted = Picture(width: w, height: h) { x, y in
        let ux = (x - cx) / unit, uy = (y - cy) / unit, rd = hypot(ux, uy)
        let k = rd < 1e-9 ? 1 : undistort(rd, k1: k1, k2: k2) / rd
        let v = grid(cx + ux * k * unit, cy + uy * k * unit)
        return (v, v, v)
    }
    let fixed = run("distort.lens", ["k1": .number(k1), "k2": .number(k2), "scale": .string("none")], distorted)
    // The grid row at y = 20 (115 px above the center) bows toward the middle through the lens.
    func distortedRow(_ x: Double) -> Double {
        (0..<120).map { Double($0) * 0.5 }.min { a, b in
            func uy(_ y: Double) -> Double {
                let ux = (x - cx) / unit, vy = (y - cy) / unit, rd = hypot(ux, vy)
                return cy + vy * undistort(rd, k1: k1, k2: k2) / rd * unit
            }
            return abs(uy(a) - 20) < abs(uy(b) - 20)
        }!
    }
    func bow(_ p: Picture, distorted: Bool) -> Double {
        // Columns between the vertical lines (of the corrected grid).
        let ys = stride(from: 30, to: w - 30, by: 10).filter { abs($0 % 40 - 20) >= 8 }.map { x in lineCenter(p, column: x, near: distorted ? distortedRow(Double(x) + 0.5) : 20, reach: 10) }
        return ys.max()! - ys.min()!
    }
    let before = bow(distorted, distorted: true), after = bow(fixed, distorted: false)
    print("lens grid bow: \(String(format: "%.2f px → %.2f px", before, after))")
    #expect(before > 6)
    #expect(after < 0.25)
    // Straight and in place: the line sits at y = 20 across the frame.
    for x in [40, 230, 440] { #expect(abs(lineCenter(fixed, column: x, near: 20) - 20) < 0.25) }
}

@Test func lensFillLeavesNoEmptyBorderAndApplyInverts() {
    let w = 320, h = 180
    let flat = Picture(width: w, height: h) { x, y in (Float(x) / Float(w), Float(y) / Float(h), 0.5) }
    // Correcting pincushion pulls the edges in; fill zooms until none is left empty.
    let pin = run("distort.lens", ["k1": .number(0.2)], flat)
    let none = run("distort.lens", ["k1": .number(0.2), "scale": .string("none")], flat)
    #expect(none.at(1, 1, 3) < 0.01, "pincushion corner without fill is empty: \(none.at(1, 1, 3))")
    for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, 0)] { #expect(pin.at(x, y, 3) > 0.99) }
    // Applying then correcting the same lens gives the picture back.
    let lens: [String: ParamValue] = ["preset": .string("gopro_wide"), "scale": .string("none")]
    var applied = lens
    applied["mode"] = .string("apply")
    let back = run("distort.lens", lens, run("distort.lens", applied, flat))
    var err: Float = 0
    for y in 40..<140 { for x in 60..<260 { err = max(err, abs(back.at(x, y, 0) - flat.at(x, y, 0))) } }
    #expect(err < 0.01, "round trip error \(err)")
    let m = RadialRemap(width: 1920, height: 1080, lens: RadialLens.presets["gopro_wide"]!)
    print("gopro_wide fill zoom \(m.fillZoom())")
    #expect(m.fillZoom() < 1)
}

/// Sub-pixel x where channel `c` of row `y` first crosses 0.5 going right from `from`.
private func edge(_ p: Picture, row y: Int, channel c: Int, from: Int) -> Double {
    for x in from..<(p.width - 1) {
        let a = p.at(x, y, c), b = p.at(x + 1, y, c)
        if (a - 0.5) * (b - 0.5) <= 0, a != b { return Double(x) + 0.5 + Double((0.5 - a) / (b - a)) }
    }
    return .nan
}

@Test func chromaticAberrationCorrectionAlignsChannelEdges() {
    let w = 480, h = 270
    let cx = Double(w) / 2, cy = Double(h) / 2
    // A white bar on black near the right edge; the lens images red 0.4% larger and blue 0.3% smaller than green.
    func bar(_ x: Double, _ y: Double) -> Float {
        let v = min(max(x - 400, 0), 1) - min(max(x - 440, 0), 1)
        return Float(v)
    }
    let sr = 1.004, sb = 0.997
    let fringed = Picture(width: w, height: h) { x, y in
        (bar(cx + (x - cx) / sr, cy + (y - cy) / sr), bar(x, y), bar(cx + (x - cx) / sb, cy + (y - cy) / sb))
    }
    let fixed = run("distort.chromatic_aberration", ["red": .number(0.4), "blue": .number(-0.3)], fringed)
    func spread(_ p: Picture) -> Double {
        let g = edge(p, row: 135, channel: 1, from: 380), r = edge(p, row: 135, channel: 0, from: 380), b = edge(p, row: 135, channel: 2, from: 380)
        return max(abs(r - g), abs(b - g))
    }
    let before = spread(fringed), after = spread(fixed)
    print("CA edge misalignment: \(String(format: "%.3f px → %.3f px", before, after))")
    #expect(before > 0.5)
    #expect(after < 0.1)
}

@Test func vignetteCorrectionFlattensFalloff() {
    let w = 320, h = 180
    let unit = hypot(Double(w), Double(h)) / 2
    let shaded = Picture(width: w, height: h) { x, y in
        let r = hypot(x - Double(w) / 2, y - Double(h) / 2) / unit
        let v = Float(0.6 * (1 - 0.35 * r * r))
        return (v, v, v)
    }
    let fixed = run("color.vignette_correct", ["amount": .number(0.35), "falloff": .number(2)], shaded)
    let corner = fixed.at(1, 1, 1), center = fixed.at(w / 2, h / 2, 1)
    print("vignette corner/center: \(shaded.at(1, 1, 1) / shaded.at(w / 2, h / 2, 1)) → \(corner / center)")
    #expect(abs(corner / center - 1) < 0.01)
    #expect(EffectCatalog.type("color.vignette_correct")?.spec("limit") != nil)
    #expect(EffectCatalog.type("distort.lens")?.spec("limit") == nil)
}

@Test func lensToolsAreFoundBySearch() {
    func search(_ q: String) -> [String] {
        EffectCatalog.listed.filter { t in
            t.id.contains(q) || t.summary.lowercased().contains(q) || t.params.contains { $0.name.contains(q) || $0.summary.lowercased().contains(q) }
        }.map(\.id)
    }
    for (q, id) in [("lens", "distort.lens"), ("distortion", "distort.lens"), ("fisheye", "distort.lens"), ("gopro", "distort.lens"), ("vignette", "color.vignette_correct"), ("chromatic", "distort.chromatic_aberration"), ("fringe", "distort.chromatic_aberration"), ("rolling shutter", "video.rolling_shutter"), ("jello", "video.rolling_shutter")] {
        #expect(search(q).contains(id), "\(q) → \(search(q))")
    }
}

// MARK: Rolling shutter

private struct Rand {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}

/// A smooth random texture `w`×`h` (gray-ish RGB), sampled bilinearly with `at`.
private struct Texture {
    let w: Int
    let h: Int
    var v: [Float]

    init(_ w: Int, _ h: Int, seed: UInt64) {
        self.w = w
        self.h = h
        var r = Rand(state: seed)
        var v = (0..<(w * h)).map { _ in r.next() }
        for _ in 0..<3 {
            var o = v
            for y in 0..<h {
                for x in 0..<w {
                    var s: Float = 0
                    for dy in -1...1 { for dx in -1...1 { s += v[min(h - 1, max(0, y + dy)) * w + min(w - 1, max(0, x + dx))] } }
                    o[y * w + x] = s / 9
                }
            }
            v = o
        }
        let lo = v.min()!, hi = v.max()!
        self.v = v.map { 0.1 + 0.8 * ($0 - lo) / (hi - lo) }
    }

    func at(_ x: Float, _ y: Float) -> Float {
        let cx = min(max(x, 0), Float(w - 1)), cy = min(max(y, 0), Float(h - 1))
        let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let top = v[y0 * w + x0] + (v[y0 * w + x1] - v[y0 * w + x0]) * fx
        let bottom = v[y1 * w + x0] + (v[y1 * w + x1] - v[y1 * w + x0]) * fx
        return top + (bottom - top) * fy
    }
}

/// Frame `k` of a pan at `speed` px/frame, each row read `readout · (y − mid)/h` frames late (0 is a global shutter).
private func panFrame(_ t: Texture, k: Int, w: Int, h: Int, speed: Float, readout: Float) -> Plane {
    var p = Plane(width: w, height: h)
    let mid = Float(h - 1) / 2
    for y in 0..<h {
        let time = Float(k) + readout * (Float(y) - mid) / Float(h)
        for x in 0..<w {
            let g = t.at(Float(x) + 60 - speed * time, Float(y) + 10)
            let o = (y * w + x) * 3
            p.data[o] = g; p.data[o + 1] = g * 0.9 + 0.05; p.data[o + 2] = 1 - g
        }
    }
    return p
}

/// Horizontal shift (sub-pixel) that best aligns row band `rows` of `a` onto `b`.
private func rowShift(_ a: Plane, _ b: Plane, rows: Range<Int>) -> Double {
    var best = (shift: 0, err: Double.infinity)
    var errs: [Int: Double] = [:]
    for s in -12...12 {
        var e = 0.0, n = 0
        for y in rows {
            for x in 20..<(a.width - 20) {
                let d = Double(a.data[(y * a.width + x) * 3] - b.data[(y * b.width + x + s) * 3])
                e += d * d
                n += 1
            }
        }
        errs[s] = e / Double(n)
        if errs[s]! < best.err { best = (s, errs[s]!) }
    }
    guard let l = errs[best.shift - 1], let r = errs[best.shift + 1] else { return Double(best.shift) }
    let denom = l - 2 * best.err + r
    return Double(best.shift) + (denom > 0 ? 0.5 * (l - r) / denom : 0)
}

private func correct(_ frames: [Plane], flow: Bool, readout: Float, bands: Int = 12) async throws -> [Plane] {
    try await runBlocking { cancelled in
        var k = 0
        let window = FrameWindow {
            guard k < frames.count else { return nil }
            defer { k += 1 }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, frames[k].width, frames[k].height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            frames[k].write(to: pb!)
            return (Double(k) / 30, pb!)
        }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let of = flow ? try? OpticalFlow(width: frames[0].width, height: frames[0].height, context: context) : nil
        let stage = RollingShutterCorrector(.init(readout: readout, bottomUp: false, bands: bands, strength: 1, mix: 1), flow: of, context: context)
        var out: [Plane] = []
        try PictureProcessor(stages: [stage]).run(window, cancelled: cancelled) { _, _, plane in out.append(plane) }
        return out
    }
}

@Test func rollingShutterCorrectionRemovesPanSkew() async throws {
    let w = 320, h = 180, speed: Float = 10, readout: Float = 0.9
    let tex = Texture(w + 200, h + 20, seed: 7)
    let skewed = (0..<8).map { panFrame(tex, k: $0, w: w, h: h, speed: speed, readout: readout) }
    let global = (0..<8).map { panFrame(tex, k: $0, w: w, h: h, speed: speed, readout: 0) }
    for flow in [false, true] {
        let fixed = try await correct(skewed, flow: flow, readout: readout)
        #expect(fixed.count == 8)
        var worstBefore = 0.0, worstAfter = 0.0
        for k in [2, 4, 5] {
            for rows in [4..<20, 80..<100, 160..<176] {
                worstBefore = max(worstBefore, abs(rowShift(skewed[k], global[k], rows: rows)))
                worstAfter = max(worstAfter, abs(rowShift(fixed[k], global[k], rows: rows)))
            }
        }
        print("rolling shutter (\(flow ? "optical flow" : "registration")): worst row-band skew \(String(format: "%.2f px → %.2f px", worstBefore, worstAfter))")
        #expect(worstBefore > 3.5)
        #expect(worstAfter < 0.6)
    }
}

@Test func rowShiftsIntegrateBandMotionFromTheMiddleRow() {
    let s = RollingShutterCorrector.rowShifts(bandMotion: [SIMD2(10, 0)], height: 101, readout: 1, bottomUp: false, strength: 1)
    #expect(abs(s[50].x) < 1e-4)
    #expect(abs(s[100].x - 10 * 50 / 101) < 1e-3)
    #expect(abs(s[0].x + 10 * 50 / 101) < 1e-3)
    let up = RollingShutterCorrector.rowShifts(bandMotion: [SIMD2(10, 0)], height: 101, readout: 1, bottomUp: true, strength: 1)
    #expect(abs(up[100].x + 10 * 50 / 101) < 1e-3)
}
