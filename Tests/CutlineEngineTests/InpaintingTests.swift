import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CutlineCore
@testable import CutlineEngine

/// Writes a picture as PNG when CUTLINE_SAVE_FRAMES names a directory, for looking at results.
func saveForReview(_ p: Plane, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["CUTLINE_SAVE_FRAMES"] else { return }
    var bytes = [UInt8](repeating: 255, count: p.width * p.height * 4)
    for i in 0..<(p.width * p.height) { for c in 0..<3 { bytes[i * 4 + c] = Plane.byte(p.data[i * 3 + c]) } }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let img = CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// Structured backgrounds for completion tests, with ground truth.
enum Pattern {
    /// A sky gradient behind a railing: two dark horizontal rails and thin balusters every 36 px.
    case railing
    /// Running-bond bricks with light mortar.
    case brick
    /// Diagonal stripes 10 px apart.
    case diagonal
    /// Two thin dark lines at slopes 0.3 and −0.15 over a smooth random texture.
    case slanted

    static func lineY(_ k: Int, _ x: Float) -> Float { k == 0 ? 20 + 0.3 * x : 150 - 0.15 * x }

    func picture(_ w: Int, _ h: Int) -> Plane {
        var p = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var c: SIMD3<Float>
                switch self {
                case .railing:
                    let t = Float(y) / Float(h)
                    c = SIMD3(0.45 + 0.2 * t, 0.6 + 0.15 * t, 0.85 - 0.1 * t)
                    let rail = (40..<46).contains(y) || (100..<104).contains(y)
                    let baluster = y >= 46 && y < 100 && x % 36 < 3
                    if rail || baluster { c = SIMD3(0.18, 0.16, 0.14) }
                case .brick:
                    let row = y / 16, off = row % 2 == 0 ? 0 : 16
                    let mortar = y % 16 < 2 || (x + off) % 32 < 2
                    let shade = Float(((x + off) / 32 * 7 + row * 3) % 5) * 0.03
                    c = mortar ? SIMD3(0.8, 0.78, 0.74) : SIMD3(0.55 + shade, 0.25 + shade * 0.5, 0.18)
                case .diagonal:
                    c = (x + y) % 20 < 6 ? SIMD3(0.2, 0.3, 0.6) : SIMD3(0.85, 0.8, 0.6)
                case .slanted:
                    let fx = Float(x), fy = Float(y)
                    let n = 0.5 + 0.12 * sin(fx * 0.21 + 1.3 * sin(fy * 0.11)) + 0.1 * sin(fy * 0.17 + 0.7 * cos(fx * 0.05)) + 0.06 * sin((fx + 2 * fy) * 0.37)
                    c = SIMD3(n, n * 0.95 + 0.05, n * 0.8 + 0.1)
                    for k in 0..<2 {
                        let d = abs(fy - Pattern.lineY(k, fx)) / (1 + (k == 0 ? 0.09 : 0.0225)).squareRoot()
                        let a = min(1, max(0, 2.5 - d))
                        c = c * (1 - a) + SIMD3(0.08, 0.08, 0.1) * a
                    }
                }
                let o = (y * w + x) * 3
                p.data[o] = c.x; p.data[o + 1] = c.y; p.data[o + 2] = c.z
            }
        }
        return p
    }
}

private func holeMask(_ w: Int, _ h: Int, _ r: (x: Int, y: Int, w: Int, h: Int)) -> [Bool] {
    (0..<(w * h)).map { i in let x = i % w, y = i / w; return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h }
}

private func mae(_ a: Plane, _ b: Plane, _ mask: [Bool]) -> Double {
    var s = 0.0, n = 0
    for i in mask.indices where mask[i] { for c in 0..<3 { s += Double(abs(a.data[i * 3 + c] - b.data[i * 3 + c])) }; n += 1 }
    return s / Double(max(1, 3 * n))
}

/// Share of the hole's columns in which each rail row band is dark and the sky just above and below it is light.
private func railContinuity(_ p: Plane, columns: Range<Int>) -> Double {
    func luma(_ x: Int, _ y: Int) -> Float { let o = (y * p.width + x) * 3; return 0.3 * p.data[o] + 0.59 * p.data[o + 1] + 0.11 * p.data[o + 2] }
    var good = 0, total = 0
    for x in columns {
        for (lo, hi) in [(40, 46), (100, 104)] {
            total += 1
            let rail = (lo..<hi).map { luma(x, $0) }.reduce(0, +) / Float(hi - lo)
            let above = luma(x, lo - 3), below = luma(x, hi + 2)
            if rail < 0.3, above > 0.5, below > 0.5 { good += 1 }
        }
    }
    return Double(good) / Double(max(1, total))
}

/// Where the slanted lines run through the hole's columns: mean distance of the darkest row near each line from where
/// the line really is, and the share of columns where that row is clearly dark.
private func lineTrace(_ p: Plane, columns: Range<Int>) -> (Double, Double) {
    func luma(_ x: Int, _ y: Int) -> Float { let o = (y * p.width + x) * 3; return 0.3 * p.data[o] + 0.59 * p.data[o + 1] + 0.11 * p.data[o + 2] }
    var dev = 0.0, dark = 0, n = 0
    for x in columns {
        for k in 0..<2 {
            let y0 = Pattern.lineY(k, Float(x))
            let ys = max(0, Int(y0) - 8)...min(p.height - 1, Int(y0) + 8)
            let best = ys.min { luma(x, $0) < luma(x, $1) }!
            dev += Double(abs(Float(best) - y0))
            if luma(x, best) < 0.25 { dark += 1 }
            n += 1
        }
    }
    return (dev / Double(n), Double(dark) / Double(n))
}

@Test func patchInpaintingContinuesStructureAcrossAStaticHole() throws {
    let w = 320, h = 180
    for (pattern, rect) in [(Pattern.railing, (x: 150, y: 20, w: 30, h: 120)), (.brick, (x: 140, y: 60, w: 44, h: 44)), (.diagonal, (x: 130, y: 60, w: 50, h: 50)), (.slanted, (x: 130, y: 40, w: 44, h: 110))] {
        var truth = pattern.picture(w, h)
        var seed: UInt64 = 99
        for i in truth.data.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            truth.data[i] = min(1, max(0, truth.data[i] + 0.04 * (Float(seed >> 40) / Float(1 << 24) - 0.5)))
        }
        let mask = holeMask(w, h, rect)
        var damaged = truth
        for i in mask.indices where mask[i] { damaged.data[i * 3] = 0.95; damaged.data[i * 3 + 1] = 0.1; damaged.data[i * 3 + 2] = 0.9 }
        var smooth = damaged.data
        var known = mask.map { !$0 }
        let rw = w, rh = h
        ObjectRemover.diffuse(&smooth, &known, rw, rh) { _, _ in .zero }
        var filled = damaged.data
        let began = Date()
        let result = Inpainter.fill(&filled, width: w, height: h, hole: mask)
        let took = Date().timeIntervalSince(began)
        let out = Plane(width: w, height: h, data: filled)
        let diffused = Plane(width: w, height: h, data: smooth)
        let errPatch = mae(out, truth, mask), errSmooth = mae(diffused, truth, mask)
        var line = ""
        if pattern == .railing {
            let cols = rect.x..<(rect.x + rect.w)
            line = String(format: ", rail continuity %.0f%% (diffusion %.0f%%)", railContinuity(out, columns: cols) * 100, railContinuity(diffused, columns: cols) * 100)
            #expect(railContinuity(out, columns: cols) > 0.9)
        }
        if pattern == .slanted {
            let cols = rect.x..<(rect.x + rect.w)
            let (dev, dark) = lineTrace(out, columns: cols), (devS, darkS) = lineTrace(diffused, columns: cols)
            line = String(format: ", line offset %.2f px, %.0f%% dark (diffusion %.2f px, %.0f%%)", dev, dark * 100, devS, darkS * 100)
            #expect(dev < 1.5 && dark > 0.9)
        }
        print("inpaint \(pattern): hole MAE \(String(format: "%.4f", errPatch)) vs diffusion \(String(format: "%.4f", errSmooth))\(line), \(result.levels) levels, \(String(format: "%.0f", took * 1000)) ms")
        saveForReview(out, "inpaint-\(pattern)")
        saveForReview(diffused, "diffuse-\(pattern)")
        // A smooth aperiodic texture can only be continued, not recovered pixel for pixel; its lines are checked above.
        #expect(errPatch < errSmooth * (pattern == .slanted ? 0.85 : 0.3))
    }
}

@Test func seamBlendingRemovesAToneStepButKeepsDetail() {
    let w = 60, h = 40
    var rgb = [Float](repeating: 0.5, count: w * h * 3)
    let mask = holeMask(w, h, (x: 20, y: 10, w: 20, h: 20))
    // The fill is 0.04 too bright and carries a stripe.
    for i in mask.indices where mask[i] { for c in 0..<3 { rgb[i * 3 + c] = 0.54 + (i % w == 30 ? 0.2 : 0) } }
    Inpainter.blendSeams(&rgb, width: w, height: h, hole: mask)
    let corner = rgb[(12 * w + 22) * 3], middle = rgb[(20 * w + 25) * 3], stripe = rgb[(20 * w + 30) * 3]
    print("seam blend: corner \(corner), middle \(middle), stripe \(stripe)")
    #expect(abs(corner - 0.5) < 0.02 && abs(middle - 0.5) < 0.03)
    #expect(stripe - middle > 0.15)
}
