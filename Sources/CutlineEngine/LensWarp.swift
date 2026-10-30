import CoreImage
import CutlineCore
import Foundation

/// Renders `RadialRemap`s (lens distortion, chromatic aberration, vignette compensation) on the CPU inside the
/// Core Image graph, sampling float RGBA bilinearly.
enum LensWarp {
    /// `distort.lens`, `distort.chromatic_aberration` and `color.vignette_correct` on `img`, whose extent is the frame.
    static func render(_ type: String, _ img: CIImage, _ v: @escaping (String) -> ParamValue) -> CIImage {
        let e = img.extent
        guard !e.isInfinite, e.width >= 2, e.height >= 2 else { return img }
        let n: (String) -> Double = { v($0).number ?? 0 }
        var m = RadialRemap(width: e.width, height: e.height, cx: n("center_x") * e.width, cy: n("center_y") * e.height)
        switch type {
        case "distort.lens":
            m.lens = remapLens(v)
            m.mode = v("mode").string == "apply" ? .apply : .correct
            let extra = max(0.25, n("zoom"))
            m.zoom = (v("scale").string ?? "fill") == "fill" ? m.fillZoom() * extra : extra
            guard m.warps else { return img }
        case "distort.chromatic_aberration":
            let sign = v("mode").string == "apply" ? -1.0 : 1.0
            m.red = 1 + sign * n("red") / 100
            m.blue = 1 + sign * n("blue") / 100
            guard abs(m.red - 1) > 1e-7 || abs(m.blue - 1) > 1e-7 else { return img }
        case "color.vignette_correct":
            m.vignette = min(0.95, max(0, n("amount")))
            m.vignettePower = max(0.5, n("falloff"))
            guard m.vignette > 1e-6 else { return img }
        default:
            return img
        }
        return apply(m, to: img)
    }

    /// The lens terms of a `distort.lens` effect: its preset, with k1/k2 overriding it when set.
    static func remapLens(_ v: (String) -> ParamValue) -> RadialLens {
        var lens = RadialLens.presets[v("preset").string ?? "none"] ?? RadialLens(k1: 0, k2: 0)
        if let k = v("k1").number, k != 0 { lens.k1 = k }
        if let k = v("k2").number, k != 0 { lens.k2 = k }
        return lens
    }

    static func apply(_ m: RadialRemap, to img: CIImage) -> CIImage {
        let e = img.extent
        let box = Box(m)
        let args: [String: Any] = ["extent": CIVector(cgRect: e), "remap": box]
        return (try? RadialRemapKernel.apply(withExtent: e, inputs: [img], arguments: args)) ?? img
    }

    final class Box: NSObject, @unchecked Sendable {
        let remap: RadialRemap
        /// Mapped/unmapped radius ratio over output radii 0…`top`.
        let table: [Double]
        let top: Double
        init(_ m: RadialRemap) {
            remap = m
            let corners = [(0.0, 0.0), (m.width, 0.0), (0.0, m.height), (m.width, m.height)]
            let top = corners.map { hypot($0.0 - m.cx, $0.1 - m.cy) / (m.unit * m.zoom) }.max()! * 1.01 + 1e-6
            let n = 4096
            self.top = top
            table = (0...n).map { m.ratio(top * Double($0) / Double(n)) ?? .nan }
        }

        /// Green-channel source position of top-left pixel position (x, y), or nil.
        @inline(__always) func source(_ x: Double, _ y: Double) -> (Double, Double)? {
            let m = remap
            let u = m.unit * m.zoom
            let nx = (x - m.cx) / u, ny = (y - m.cy) / u
            var k = 1.0
            if !m.lens.isIdentity {
                let f = min(hypot(nx, ny) / top, 1) * Double(table.count - 1)
                let i = min(Int(f), table.count - 2)
                let a = table[i], b = table[i + 1]
                guard a.isFinite, b.isFinite else { return nil }
                k = a + (b - a) * (f - Double(i))
            }
            return (m.cx + nx * k * m.unit, m.cy + ny * k * m.unit)
        }
    }
}

final class RadialRemapKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let e = (arguments?["extent"] as? CIVector)?.cgRectValue, let box = arguments?["remap"] as? LensWarp.Box else { return outputRect }
        // The remap is a homeomorphism, so the source of a rectangle is bounded by the source of its edges.
        var lo = (Double.infinity, Double.infinity), hi = (-Double.infinity, -Double.infinity)
        let x0 = Double(outputRect.minX - e.minX), x1 = Double(outputRect.maxX - e.minX)
        let y0 = Double(e.maxY - outputRect.maxY), y1 = Double(e.maxY - outputRect.minY)
        let scales = [1, box.remap.red, box.remap.blue]
        let n = 32
        for i in 0...n {
            let f = Double(i) / Double(n)
            for (x, y) in [(x0 + f * (x1 - x0), y0), (x0 + f * (x1 - x0), y1), (x0, y0 + f * (y1 - y0)), (x1, y0 + f * (y1 - y0))] {
                guard let p = box.source(x, y) else { continue }
                for s in scales {
                    let px = box.remap.cx + (p.0 - box.remap.cx) * s, py = box.remap.cy + (p.1 - box.remap.cy) * s
                    lo = (min(lo.0, px), min(lo.1, py))
                    hi = (max(hi.0, px), max(hi.1, py))
                }
            }
        }
        guard lo.0.isFinite else { return CGRect(x: e.minX, y: e.minY, width: 1, height: 1) }
        let r = CGRect(x: e.minX + lo.0 - 3, y: e.maxY - hi.1 - 3, width: hi.0 - lo.0 + 6, height: hi.1 - lo.1 + 6)
        let clipped = r.intersection(e)
        return clipped.isNull || clipped.isEmpty ? CGRect(x: e.minX, y: e.minY, width: 1, height: 1) : clipped
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let e = (arguments?["extent"] as? CIVector)?.cgRectValue, let box = arguments?["remap"] as? LensWarp.Box else { return }
        let m = box.remap
        let src = UnsafePointer(input.baseAddress.assumingMemoryBound(to: Float.self))
        let dst = output.baseAddress.assumingMemoryBound(to: Float.self)
        let inR = input.region, outR = output.region
        let srcStride = input.bytesPerRow / 4, dstStride = output.bytesPerRow / 4
        let iw = Int(inR.width), ih = Int(inR.height)
        let ow = Int(outR.width), oh = Int(outR.height)
        // Top-left frame pixel position → input buffer column/row (pixel centers at integers).
        let colOffset = Double(e.minX - inR.minX) - 0.5
        let rowOffset = Double(inR.maxY - e.maxY) - 0.5
        let frameW = Double(e.width), frameH = Double(e.height)
        let chroma = abs(m.red - 1) > 1e-9 || abs(m.blue - 1) > 1e-9
        let lensOnly = !chroma && m.vignette <= 1e-6

        /// Bilinear sample of channel(s) at top-left frame position; positions just outside the frame clamp to its
        /// edge, farther ones are transparent.
        @inline(__always) func sample(_ x: Double, _ y: Double, _ out: UnsafeMutablePointer<Float>, channel: Int) {
            if x < -1 || y < -1 || x > frameW + 1 || y > frameH + 1 {
                if channel < 0 { out[0] = 0; out[1] = 0; out[2] = 0; out[3] = 0 } else { out[channel] = 0 }
                return
            }
            let cx = min(max(x + colOffset, 0), Double(iw - 1)), cy = min(max(y + rowOffset, 0), Double(ih - 1))
            let x0 = Int(cx), y0 = Int(cy)
            let x1 = min(x0 + 1, iw - 1), y1 = min(y0 + 1, ih - 1)
            let fx = Float(cx - Double(x0)), fy = Float(cy - Double(y0))
            let a = src + y0 * srcStride + x0 * 4, b = src + y0 * srcStride + x1 * 4
            let c = src + y1 * srcStride + x0 * 4, d = src + y1 * srcStride + x1 * 4
            let wa = (1 - fx) * (1 - fy), wb = fx * (1 - fy), wc = (1 - fx) * fy, wd = fx * fy
            if channel < 0 {
                for k in 0..<4 { out[k] = wa * a[k] + wb * b[k] + wc * c[k] + wd * d[k] }
            } else {
                out[channel] = wa * a[channel] + wb * b[channel] + wc * c[channel] + wd * d[channel]
            }
        }

        let rows = oh
        let chunks = max(1, min(rows, ProcessInfo.processInfo.activeProcessorCount * 2))
        DispatchQueue.concurrentPerform(iterations: chunks) { k in
            var px = [Float](repeating: 0, count: 4)
            px.withUnsafeMutableBufferPointer { pb in
                let p = pb.baseAddress!
                for r in rows * k / chunks..<rows * (k + 1) / chunks {
                    let y = Double(e.maxY - outR.maxY) + Double(r) + 0.5
                    let line = dst + r * dstStride
                    for col in 0..<ow {
                        let x = Double(outR.minX - e.minX) + Double(col) + 0.5
                        let o = line + col * 4
                        guard let s = box.source(x, y) else {
                            o[0] = 0; o[1] = 0; o[2] = 0; o[3] = 0
                            continue
                        }
                        if chroma {
                            sample(s.0, s.1, p, channel: -1)
                            let g = p[1], alpha = p[3]
                            sample(m.cx + (s.0 - m.cx) * m.red, m.cy + (s.1 - m.cy) * m.red, p, channel: 0)
                            let rr = p[0]
                            sample(m.cx + (s.0 - m.cx) * m.blue, m.cy + (s.1 - m.cy) * m.blue, p, channel: 2)
                            p[0] = rr; p[1] = g; p[3] = alpha
                        } else {
                            sample(s.0, s.1, p, channel: -1)
                        }
                        if lensOnly {
                            o[0] = p[0]; o[1] = p[1]; o[2] = p[2]; o[3] = p[3]
                        } else {
                            let gain = Float(m.gain(x, y))
                            o[0] = p[0] * gain; o[1] = p[1] * gain; o[2] = p[2] * gain; o[3] = p[3]
                        }
                    }
                }
            }
        }
    }
}
