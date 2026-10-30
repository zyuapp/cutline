import CoreImage
import CoreText
import CutlineCore
import Foundation

/// Broadcast-style scopes and the numbers behind them, measured on encoded code values of a working space.
///
/// The picture is downscaled on the GPU (at most 640×360) and read back once; accumulation runs on the CPU.
public enum Scopes {
    public enum Kind: String, CaseIterable, Sendable {
        case waveform, parade, vectorscope, histogram
    }

    /// One channel's distribution in code values 0…1. `low` and `high` are the 1st and 99th percentiles.
    public struct ChannelStats: Sendable {
        public var min: Double
        public var low: Double
        public var median: Double
        public var high: Double
        public var max: Double
        public var mean: Double
    }

    public struct ParadeStats: Sendable {
        public var red: ChannelStats
        public var green: ChannelStats
        public var blue: ChannelStats
        public var luma: ChannelStats
    }

    /// Chroma in the vectorscope plane: `cb`/`cr` span ±0.5. `hue` is the vectorscope angle in degrees,
    /// counterclockwise from +Cb (the skin tone line is at 123°, 75% red near 103°). `saturation` is the centroid's
    /// distance from the center and `meanSaturation` the average pixel's, both with 1 at the graticule circle (chroma 0.5).
    public struct VectorscopeStats: Sendable {
        public var cb: Double
        public var cr: Double
        public var hue: Double
        public var saturation: Double
        public var meanSaturation: Double
        /// Signed angle in degrees from the centroid to the skin tone line; nil when the centroid is near neutral.
        public var skinToneOffset: Double?
    }

    public struct Stats: Sendable {
        public var parade: ParadeStats
        public var vectorscope: VectorscopeStats
        /// Fractions of samples with luma at or above 0.98, or at or below 0.02.
        public var clipped: Double
        public var crushed: Double
        public var samples: Int
        /// Share of the frame measured as picture; the rest was letterbox, pillarbox or background bars.
        public var picture: Double = 1
    }

    public static let skinToneAngle = 123.0

    // MARK: Rendering

    /// Draws a scope of `image` (read back in `space`) into a `size` image with its graticule.
    public static func render(_ image: CIImage, kind: Kind, size: CGSize, context: CIContext, space: WorkingSpace = .rec709) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w >= 64, h >= 48, let px = readback(image, context: context, space: space) else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let canvas = Canvas(data: data, width: w, height: h)
        let weights = lumaWeights(space)
        switch kind {
        case .waveform:
            let plot = plotRect(kind, size: size)
            waveform(px, into: canvas, plot: plot, channels: [(weights, SIMD3(0.55, 1, 0.6))])
            drawLevels(ctx, plot: plot, size: size)
        case .parade:
            let plot = plotRect(kind, size: size)
            let third = plot.width / 3
            let channels: [(SIMD3<Float>, SIMD3<Float>)] = [(SIMD3(1, 0, 0), SIMD3(1, 0.3, 0.3)), (SIMD3(0, 1, 0), SIMD3(0.3, 1, 0.35)), (SIMD3(0, 0, 1), SIMD3(0.35, 0.55, 1))]
            for (i, c) in channels.enumerated() {
                let r = CGRect(x: plot.minX + CGFloat(i) * third + 2, y: plot.minY, width: third - 4, height: plot.height).integral
                waveform(px, into: canvas, plot: r, channels: [c])
            }
            drawLevels(ctx, plot: plot, size: size)
            ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 0.5))
            for i in 1...2 {
                let x = plot.minX + CGFloat(i) * third
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: size.height - plot.minY), CGPoint(x: x, y: size.height - plot.maxY)])
            }
        case .vectorscope:
            vectorscope(px, into: canvas, size: size, weights: weights)
            drawVectorGraticule(ctx, size: size, weights: weights)
        case .histogram:
            let plot = plotRect(kind, size: size)
            histogram(px, into: canvas, plot: plot)
            drawHistogramGraticule(ctx, plot: plot, size: size)
        }
        return ctx.makeImage()
    }

    /// Plot area in top-left pixel coordinates.
    static func plotRect(_ kind: Kind, size: CGSize) -> CGRect {
        CGRect(x: 30, y: 8, width: size.width - 38, height: size.height - 16).integral
    }

    /// Vectorscope graticule radius (chroma 0.5) and center, top-left coordinates.
    static func vectorGeometry(_ size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        (CGPoint(x: size.width / 2, y: size.height / 2), min(size.width, size.height) / 2 - 14)
    }

    static func vectorPoint(cb: Double, cr: Double, size: CGSize) -> CGPoint {
        let g = vectorGeometry(size)
        return CGPoint(x: g.center.x + CGFloat(cb / 0.5) * g.radius, y: g.center.y - CGFloat(cr / 0.5) * g.radius)
    }

    /// The six colour-bar targets at `level` (0.75 for the boxes), as (label, cb, cr).
    static func targets(level: Float, weights: SIMD3<Float>) -> [(String, Double, Double)] {
        let bars: [(String, SIMD3<Float>)] = [("R", SIMD3(1, 0, 0)), ("Mg", SIMD3(1, 0, 1)), ("B", SIMD3(0, 0, 1)), ("Cy", SIMD3(0, 1, 1)), ("G", SIMD3(0, 1, 0)), ("Yl", SIMD3(1, 1, 0))]
        return bars.map { name, c in
            let (cb, cr) = chroma(c * level, weights)
            return (name, Double(cb), Double(cr))
        }
    }

    static func lumaWeights(_ space: WorkingSpace) -> SIMD3<Float> {
        space == .rec2020_hlg || space == .rec2020_pq ? SIMD3(0.2627, 0.6780, 0.0593) : SIMD3(0.2126, 0.7152, 0.0722)
    }

    @inline(__always)
    static func chroma(_ c: SIMD3<Float>, _ w: SIMD3<Float>) -> (Float, Float) {
        let y = (c * w).sum()
        return ((c.z - y) / (2 * (1 - w.z)), (c.x - y) / (2 * (1 - w.x)))
    }

    // MARK: Readback

    struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    static func readback(_ image: CIImage, context: CIContext, space: WorkingSpace, maxWidth: Int = 640, maxHeight: Int = 360) -> Pixels? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 1, e.height >= 1 else { return nil }
        let w = min(maxWidth, Int(e.width.rounded())), h = min(maxHeight, Int(e.height.rounded()))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height)))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: ColorManagement.colorSpace(space))
        return Pixels(width: w, height: h, rgba: rgba)
    }

    /// The scope image's pixels, row 0 at the top.
    struct Canvas {
        let data: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int

        @inline(__always)
        func add(_ x: Int, _ y: Int, _ c: SIMD3<Float>) {
            let o = (y * width + x) * 4
            data[o] = UInt8(min(255, Float(data[o]) + c.x * 255))
            data[o + 1] = UInt8(min(255, Float(data[o + 1]) + c.y * 255))
            data[o + 2] = UInt8(min(255, Float(data[o + 2]) + c.z * 255))
            data[o + 3] = 255
        }
    }

    // MARK: Traces

    /// One trace per channel: x follows the picture's columns, y the channel's level (`weights` · RGB).
    static func waveform(_ px: Pixels, into canvas: Canvas, plot: CGRect, channels: [(SIMD3<Float>, SIMD3<Float>)]) {
        let pw = Int(plot.width), ph = Int(plot.height), x0 = Int(plot.minX), y0 = Int(plot.minY)
        guard pw > 0, ph > 0 else { return }
        var counts = [UInt32](repeating: 0, count: pw * ph)
        let perColumn = Float(px.width * px.height) / Float(pw)
        let reference = max(1, perColumn / 24)
        for (weights, color) in channels {
            counts.withUnsafeMutableBufferPointer { cnt in
                for i in 0..<cnt.count { cnt[i] = 0 }
                px.rgba.withUnsafeBufferPointer { src in
                    let scale = Float(ph - 1) / 255
                    for y in 0..<px.height {
                        let row = y * px.width * 4
                        for x in 0..<px.width {
                            let o = row + x * 4
                            let v = Float(src[o]) * weights.x + Float(src[o + 1]) * weights.y + Float(src[o + 2]) * weights.z
                            let col = x * pw / px.width
                            let r = ph - 1 - Int((v * scale).rounded())
                            cnt[max(0, min(ph - 1, r)) * pw + col] += 1
                        }
                    }
                }
                for r in 0..<ph {
                    for c in 0..<pw where cnt[r * pw + c] > 0 {
                        canvas.add(x0 + c, y0 + r, color * min(1, (Float(cnt[r * pw + c]) / reference).squareRoot()))
                    }
                }
            }
        }
    }

    static func vectorscope(_ px: Pixels, into canvas: Canvas, size: CGSize, weights: SIMD3<Float>) {
        let w = canvas.width, h = canvas.height
        var counts = [UInt32](repeating: 0, count: w * h)
        var sums = [SIMD3<Float>](repeating: .zero, count: w * h)
        let g = vectorGeometry(size)
        let cx = Float(g.center.x), cy = Float(g.center.y), radius = Float(g.radius)
        px.rgba.withUnsafeBufferPointer { src in
            counts.withUnsafeMutableBufferPointer { cnt in
                sums.withUnsafeMutableBufferPointer { sum in
                    for i in 0..<(px.width * px.height) {
                        let c = SIMD3(Float(src[i * 4]), Float(src[i * 4 + 1]), Float(src[i * 4 + 2])) / 255
                        let (cb, cr) = chroma(c, weights)
                        let x = Int((cx + cb * 2 * radius).rounded()), y = Int((cy - cr * 2 * radius).rounded())
                        guard x >= 0, x < w, y >= 0, y < h else { continue }
                        cnt[y * w + x] += 1
                        sum[y * w + x] += c
                    }
                }
            }
        }
        let reference = max(1, Float(px.width * px.height) / 4000)
        for i in 0..<(w * h) where counts[i] > 0 {
            let n = Float(counts[i])
            let avg = sums[i] / n
            let tint = avg / max(avg.max(), 0.05)
            let color = (tint * 0.6 + 0.4) * min(1, (n / reference).squareRoot())
            canvas.add(i % w, i / w, color)
        }
    }

    static func histogram(_ px: Pixels, into canvas: Canvas, plot: CGRect) {
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        px.rgba.withUnsafeBufferPointer { src in
            for i in 0..<(px.width * px.height) {
                bins[0][Int(src[i * 4])] += 1
                bins[1][Int(src[i * 4 + 1])] += 1
                bins[2][Int(src[i * 4 + 2])] += 1
            }
        }
        // Square-root scale against the tallest interior bin, so spikes (flat areas, clipping at 0 and 255) don't flatten the rest.
        let peak = max(1, bins.map { $0[1...254].max() ?? 0 }.max() ?? 1)
        let pw = Int(plot.width), ph = Int(plot.height), x0 = Int(plot.minX), y0 = Int(plot.minY)
        let colors: [SIMD3<Float>] = [SIMD3(0.75, 0.15, 0.15), SIMD3(0.15, 0.7, 0.2), SIMD3(0.2, 0.3, 0.8)]
        for c in 0..<3 {
            for x in 0..<pw {
                let bin = min(255, x * 256 / pw)
                let height = min(ph, Int((Double(bins[c][bin]) / Double(peak)).squareRoot() * Double(ph)))
                for y in (ph - height)..<ph { canvas.add(x0 + x, y0 + y, colors[c]) }
            }
        }
    }

    // MARK: Graticules

    static func label(_ ctx: CGContext, _ text: String, at p: CGPoint, color: CGColor = CGColor(gray: 0.75, alpha: 0.9)) {
        let font = CTFontCreateWithName("Menlo" as CFString, 9, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    /// Lines every 10% with 0, 50 and 100 emphasized and labeled (IRE on full-range code values).
    static func drawLevels(_ ctx: CGContext, plot: CGRect, size: CGSize) {
        for i in 0...10 {
            let y = size.height - (plot.maxY - 1 - CGFloat(i) / 10 * (plot.height - 1))
            let major = i % 5 == 0
            ctx.setStrokeColor(CGColor(red: 0.85, green: 0.7, blue: 0.3, alpha: major ? 0.55 : 0.2))
            ctx.setLineWidth(major ? 1 : 0.5)
            ctx.strokeLineSegments(between: [CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)])
            if major { label(ctx, "\(i * 10)", at: CGPoint(x: 4, y: y - 3)) }
        }
    }

    static func drawHistogramGraticule(_ ctx: CGContext, plot: CGRect, size: CGSize) {
        for i in 0...4 {
            let x = plot.minX + CGFloat(i) / 4 * (plot.width - 1)
            ctx.setStrokeColor(CGColor(red: 0.85, green: 0.7, blue: 0.3, alpha: i % 2 == 0 ? 0.5 : 0.2))
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: size.height - plot.minY), CGPoint(x: x, y: size.height - plot.maxY)])
        }
        label(ctx, "0", at: CGPoint(x: plot.minX - 10, y: 2))
        label(ctx, "100", at: CGPoint(x: plot.maxX - 18, y: size.height - plot.minY - 10))
    }

    /// Circle at chroma 0.5, crosshair, 75% target boxes, 100% dots and the skin tone line.
    static func drawVectorGraticule(_ ctx: CGContext, size: CGSize, weights: SIMD3<Float>) {
        let g = vectorGeometry(size)
        let flip = { (p: CGPoint) in CGPoint(x: p.x, y: size.height - p.y) }
        let c = flip(g.center)
        let amber = CGColor(red: 0.85, green: 0.7, blue: 0.3, alpha: 0.55)
        ctx.setStrokeColor(amber)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: c.x - g.radius, y: c.y - g.radius, width: g.radius * 2, height: g.radius * 2))
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.7, blue: 0.3, alpha: 0.25))
        ctx.strokeLineSegments(between: [CGPoint(x: c.x - g.radius, y: c.y), CGPoint(x: c.x + g.radius, y: c.y), CGPoint(x: c.x, y: c.y - g.radius), CGPoint(x: c.x, y: c.y + g.radius)])
        let box = max(5, g.radius * 0.07)
        ctx.setStrokeColor(amber)
        for (name, cb, cr) in targets(level: 0.75, weights: weights) {
            let p = flip(vectorPoint(cb: cb, cr: cr, size: size))
            ctx.stroke(CGRect(x: p.x - box, y: p.y - box, width: box * 2, height: box * 2))
            let out = CGPoint(x: p.x - c.x, y: p.y - c.y)
            let len = max(hypot(out.x, out.y), 1)
            label(ctx, name, at: CGPoint(x: p.x + out.x / len * (box + 6) - 5, y: p.y + out.y / len * (box + 6) - 3))
        }
        ctx.setFillColor(amber)
        for (_, cb, cr) in targets(level: 1, weights: weights) {
            let p = flip(vectorPoint(cb: cb, cr: cr, size: size))
            ctx.fillEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3))
        }
        let a = skinToneAngle * .pi / 180
        ctx.setStrokeColor(CGColor(red: 0.95, green: 0.6, blue: 0.45, alpha: 0.6))
        ctx.strokeLineSegments(between: [c, CGPoint(x: c.x + cos(a) * g.radius, y: c.y + sin(a) * g.radius)])
    }

    // MARK: Numbers

    /// Numbers over the active picture: letterbox or pillarbox bars (near black, or the canvas `background`) are left out.
    public static func stats(_ image: CIImage, context: CIContext, space: WorkingSpace = .rec709, background: RGBA? = nil) -> Stats? {
        guard let px = readback(image, context: context, space: space, maxWidth: 480, maxHeight: 270) else { return nil }
        return stats(px, weights: lumaWeights(space), background: background.map { ColorManagement.codeValues($0, in: space) })
    }

    public static func rgbParadeStats(_ image: CIImage, context: CIContext, space: WorkingSpace = .rec709) -> ParadeStats? {
        stats(image, context: context, space: space)?.parade
    }

    public static func vectorscopeStats(_ image: CIImage, context: CIContext, space: WorkingSpace = .rec709) -> VectorscopeStats? {
        stats(image, context: context, space: space)?.vectorscope
    }

    static func stats(_ px: Pixels, weights: SIMD3<Float>, background: SIMD3<Float>? = nil) -> Stats {
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        var sums = [Double](repeating: 0, count: 4)
        var cbSum = 0.0, crSum = 0.0, magSum = 0.0
        var clipped = 0, crushed = 0
        let area = px.rgba.withUnsafeBufferPointer { PictureArea.active(bytes: $0.baseAddress!, width: px.width, height: px.height, rowBytes: px.width * 4, background: background) }
        let n = area.width * area.height
        px.rgba.withUnsafeBufferPointer { src in
            for row in area.y..<(area.y + area.height) {
                for col in area.x..<(area.x + area.width) {
                    let i = row * px.width + col
                    let c = SIMD3(Float(src[i * 4]), Float(src[i * 4 + 1]), Float(src[i * 4 + 2])) / 255
                    let y = (c * weights).sum()
                    let yi = Int((y * 255).rounded())
                    bins[0][Int(src[i * 4])] += 1
                    bins[1][Int(src[i * 4 + 1])] += 1
                    bins[2][Int(src[i * 4 + 2])] += 1
                    bins[3][min(255, max(0, yi))] += 1
                    sums[0] += Double(c.x); sums[1] += Double(c.y); sums[2] += Double(c.z); sums[3] += Double(y)
                    let (cb, cr) = chroma(c, weights)
                    cbSum += Double(cb); crSum += Double(cr)
                    magSum += Double(hypot(cb, cr))
                    if y >= 0.98 { clipped += 1 }
                    if y <= 0.02 { crushed += 1 }
                }
            }
        }
        let total = Double(max(n, 1))
        func channel(_ k: Int) -> ChannelStats {
            let h = bins[k]
            func percentile(_ q: Double) -> Double {
                let target = q * Double(n - 1)
                var acc = 0
                for (i, count) in h.enumerated() {
                    acc += count
                    if Double(acc) > target { return Double(i) / 255 }
                }
                return 1
            }
            let lo = h.firstIndex { $0 > 0 } ?? 0, hi = h.lastIndex { $0 > 0 } ?? 0
            return ChannelStats(min: Double(lo) / 255, low: percentile(0.01), median: percentile(0.5), high: percentile(0.99), max: Double(hi) / 255, mean: sums[k] / total)
        }
        let cb = cbSum / total, cr = crSum / total
        var hue = atan2(cr, cb) * 180 / .pi
        if hue < 0 { hue += 360 }
        let sat = hypot(cb, cr) / 0.5
        var offset: Double?
        if sat > 0.01 {
            var d = skinToneAngle - hue
            d = (d + 540).truncatingRemainder(dividingBy: 360) - 180
            offset = d
        }
        return Stats(
            parade: ParadeStats(red: channel(0), green: channel(1), blue: channel(2), luma: channel(3)),
            vectorscope: VectorscopeStats(cb: cb, cr: cr, hue: hue, saturation: sat, meanSaturation: magSum / total / 0.5, skinToneOffset: offset),
            clipped: Double(clipped) / total, crushed: Double(crushed) / total, samples: n, picture: Double(n) / Double(max(1, px.width * px.height)))
    }
}
