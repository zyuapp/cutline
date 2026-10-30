import CoreImage
import CoreVideo
import CutlineCore
import Foundation

/// Rolling shutter repair. A CMOS sensor reads row y `readout · (y/H − ½)` frame intervals after the middle row, so
/// while the camera moves each row shows the scene displaced by the motion during that delay. The stage measures the
/// motion of each horizontal band between neighbouring frames (optical flow, else translation registration of
/// strips), integrates it from the middle row outward and moves every row back to where it was at the middle row's
/// time.
final class RollingShutterCorrector: TemporalStage {
    struct Settings {
        var readout: Float
        var bottomUp: Bool
        var bands: Int
        var strength: Float
        var mix: Float
    }

    let settings: Settings
    let flow: OpticalFlow?
    let context: CIContext
    /// Per-band content motion (dx, dy pixels) from frame k to frame k + 1.
    private var steps: [Int: [SIMD2<Float>]] = [:]
    private var small: [Int: CVPixelBuffer] = [:]
    /// The displacement each row was corrected by on the last frame, for reporting and tests.
    private(set) var lastShift: [SIMD2<Float>] = []

    init(_ settings: Settings, flow: OpticalFlow?, context: CIContext) {
        var s = settings
        s.bands = min(48, max(1, s.bands))
        self.settings = s
        self.flow = flow
        self.context = context
    }

    func needs(_ j: Int, from i: Int) -> Bool { j >= i - 1 }

    /// Band motion from frame `k` to `k + 1`, nil when either is missing or they are in different shots.
    func step(_ k: Int, _ window: FrameWindow) throws -> [SIMD2<Float>]? {
        if let hit = steps[k] { return hit }
        guard k >= 0, let a = try window.frame(k), let b = try window.frame(k + 1), try window.sameShot(k, k + 1) else { return nil }
        let bands = settings.bands
        var out: [SIMD2<Float>]?
        if let flow, let pair = try? flow.flows(k, a, k + 1, b) {
            out = RollingShutterCorrector.bandMotion(pair.forward, height: CVPixelBufferGetHeight(a), bands: bands)
            flow.retain { $0 >= k }
        } else {
            out = registeredBands(k, a, b, bands: bands)
        }
        steps[k] = out
        steps = steps.filter { $0.key >= k - 2 }
        small = small.filter { $0.key >= k }
        return out
    }

    /// Median flow of each of `bands` horizontal bands of a `height`-row frame.
    static func bandMotion(_ f: FlowField, height: Int, bands: Int) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for b in 0..<bands {
            let y0 = Float(height) * Float(b) / Float(bands), y1 = Float(height) * Float(b + 1) / Float(bands)
            var xs: [Float] = [], ys: [Float] = []
            for gy in 0..<f.height {
                let cy = (Float(gy) + 0.5) * f.cellY - 0.5
                guard cy >= y0 - f.cellY / 2, cy < y1 + f.cellY / 2 else { continue }
                // Columns near the side edges see content entering and leaving the frame.
                let margin = f.width / 16
                for gx in margin..<max(margin + 1, f.width - margin) {
                    xs.append(f.data[(gy * f.width + gx) * 2])
                    ys.append(f.data[(gy * f.width + gx) * 2 + 1])
                }
            }
            out.append(xs.isEmpty ? .zero : SIMD2(median(xs), median(ys)))
        }
        return out
    }

    static func median(_ v: [Float]) -> Float {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Band motion by translation registration of overlapping strips of small copies.
    private func registeredBands(_ k: Int, _ a: CVPixelBuffer, _ b: CVPixelBuffer, bands: Int) -> [SIMD2<Float>]? {
        guard let sa = small[k] ?? Registration.small(a, context: context), let sb = small[k + 1] ?? Registration.small(b, context: context) else { return nil }
        small[k] = sa
        small[k + 1] = sb
        let fullW = CVPixelBufferGetWidth(a)
        let w = CVPixelBufferGetWidth(sa), h = CVPixelBufferGetHeight(sa)
        if bands == 1 {
            let t = Registration.translation(sa, sb, fullWidth: fullW)
            return [SIMD2(Float(t.x), Float(t.y))]
        }
        let ia = CIImage(cvPixelBuffer: sa), ib = CIImage(cvPixelBuffer: sb)
        var out: [SIMD2<Float>] = []
        for band in 0..<bands {
            let bh = Double(h) / Double(bands)
            let pad = max(bh, 24)
            let top = max(0, Double(band) * bh - pad / 2), bottom = min(Double(h), Double(band + 1) * bh + pad / 2)
            let rect = CGRect(x: 0, y: Double(h) - bottom, width: Double(w), height: bottom - top).integral
            guard let ca = strip(ia, rect), let cb = strip(ib, rect) else { out.append(.zero); continue }
            let step = Stabilizer.register(from: ca, to: cb, width: Double(rect.width), height: Double(rect.height))
            let s = Float(fullW) / Float(w)
            out.append(SIMD2(Float(step.0) * s, Float(step.1) * s))
        }
        return out
    }

    private func strip(_ img: CIImage, _ rect: CGRect) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(rect.width), Int(rect.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        context.render(img.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)), to: pb, bounds: CGRect(origin: .zero, size: rect.size), colorSpace: nil)
        return pb
    }

    /// Per-row shift (dx, dy) that takes each output row's pixels from where the row saw the scene, given each band's
    /// motion per frame interval.
    static func rowShifts(bandMotion v: [SIMD2<Float>], height h: Int, readout: Float, bottomUp: Bool, strength: Float) -> [SIMD2<Float>] {
        let bands = v.count
        guard bands > 0, h > 0 else { return [] }
        // Smooth neighbouring bands so one noisy band doesn't tear the picture.
        var sm = v
        if bands >= 3 {
            for b in 0..<bands {
                let lo = v[max(0, b - 1)], hi = v[min(bands - 1, b + 1)]
                sm[b] = (lo + 2 * v[b] + hi) / 4
            }
        }
        func velocity(_ y: Float) -> SIMD2<Float> {
            let f = (y + 0.5) / Float(h) * Float(bands) - 0.5
            let i = Int(f.rounded(.down))
            if i < 0 { return sm[0] }
            if i >= bands - 1 { return sm[bands - 1] }
            let t = f - Float(i)
            return sm[i] + (sm[i + 1] - sm[i]) * t
        }
        // Delay of each row after the next one, in frame intervals.
        let perRow = readout / Float(h) * (bottomUp ? -1 : 1) * strength
        var shift = [SIMD2<Float>](repeating: .zero, count: h)
        let mid = Float(h - 1) / 2
        let m = Int(mid.rounded(.down))
        // Integrate outward from the middle row with the trapezoid rule.
        var acc = velocity(mid) * (Float(m) - mid) * perRow
        shift[m] = acc
        var prev = velocity(Float(m))
        for y in stride(from: m + 1, to: h, by: 1) {
            let cur = velocity(Float(y))
            acc += (prev + cur) / 2 * perRow
            shift[y] = acc
            prev = cur
        }
        acc = shift[m]
        prev = velocity(Float(m))
        for y in stride(from: m - 1, through: 0, by: -1) {
            let cur = velocity(Float(y))
            acc -= (prev + cur) / 2 * perRow
            shift[y] = acc
            prev = cur
        }
        return shift
    }

    func apply(_ i: Int, _ current: inout Plane, _ window: FrameWindow) throws {
        guard settings.strength > 0.001, settings.mix > 0.001 else { return }
        let before = try step(i - 1, window), after = try step(i, window)
        let motion: [SIMD2<Float>]
        switch (before, after) {
        case let (b?, a?): motion = zip(b, a).map { ($0 + $1) / 2 }
        case let (b?, nil): motion = b
        case let (nil, a?): motion = a
        default: return
        }
        let w = current.width, h = current.height
        let shift = RollingShutterCorrector.rowShifts(bandMotion: motion, height: h, readout: settings.readout, bottomUp: settings.bottomUp, strength: settings.strength)
        lastShift = shift
        guard shift.contains(where: { abs($0.x) > 0.01 || abs($0.y) > 0.01 }) else { return }
        let src = current.data
        let mix = min(1, settings.mix)
        current.data.withUnsafeMutableBufferPointer { out in
            src.withUnsafeBufferPointer { inp in
                let s = inp.baseAddress!, d = out.baseAddress!
                parallelRows(h) { rows in
                    for y in rows {
                        let sy = min(max(Float(y) + shift[y].y, 0), Float(h - 1))
                        let y0 = Int(sy), y1 = min(y0 + 1, h - 1), fy = sy - Float(y0)
                        for x in 0..<w {
                            let sx = min(max(Float(x) + shift[y].x, 0), Float(w - 1))
                            let x0 = Int(sx), x1 = min(x0 + 1, w - 1), fx = sx - Float(x0)
                            let a = (y0 * w + x0) * 3, b = (y0 * w + x1) * 3, c = (y1 * w + x0) * 3, e = (y1 * w + x1) * 3
                            let o = (y * w + x) * 3
                            for k in 0..<3 {
                                let top = s[a + k] + (s[b + k] - s[a + k]) * fx
                                let bottom = s[c + k] + (s[e + k] - s[c + k]) * fx
                                let v = top + (bottom - top) * fy
                                d[o + k] = mix >= 1 ? v : s[o + k] + (v - s[o + k]) * mix
                            }
                        }
                    }
                }
            }
        }
    }
}
