import CoreVideo
import CutlineCore
import Foundation
import simd

/// Pyramidal Lucas–Kanade on the gray picture: where a point's patch moved from one frame to another.
enum PointTracker {
    static let analysisSize = CGSize(width: 960, height: 960)

    /// A gray picture with a coarse-to-fine pyramid.
    struct Gray {
        let width: Int
        let height: Int
        let v: [Float]

        init(width: Int, height: Int, v: [Float]) {
            self.width = width
            self.height = height
            self.v = v
        }

        init(_ pb: CVPixelBuffer) {
            let view = PixelView(pb)
            defer { view.unlock() }
            var out = [Float](repeating: 0, count: view.width * view.height)
            for y in 0..<view.height {
                let row = view.base + y * view.rowBytes
                for x in 0..<view.width {
                    let p = row + x * 4
                    out[y * view.width + x] = (0.11 * Float(p[0]) + 0.59 * Float(p[1]) + 0.3 * Float(p[2])) / 255
                }
            }
            self.init(width: view.width, height: view.height, v: out)
        }

        var half: Gray {
            let w = max(1, width / 2), h = max(1, height / 2)
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let x0 = min(2 * x, width - 1), x1 = min(2 * x + 1, width - 1), y0 = min(2 * y, height - 1), y1 = min(2 * y + 1, height - 1)
                    out[y * w + x] = (v[y0 * width + x0] + v[y0 * width + x1] + v[y1 * width + x0] + v[y1 * width + x1]) / 4
                }
            }
            return Gray(width: w, height: h, v: out)
        }

        @inline(__always) func at(_ x: Float, _ y: Float) -> Float {
            let cx = min(max(x, 0), Float(width - 1)), cy = min(max(y, 0), Float(height - 1))
            let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let fx = cx - Float(x0), fy = cy - Float(y0)
            let top = v[y0 * width + x0] + (v[y0 * width + x1] - v[y0 * width + x0]) * fx
            let bottom = v[y1 * width + x0] + (v[y1 * width + x1] - v[y1 * width + x0]) * fx
            return top + (bottom - top) * fy
        }
    }

    static func pyramid(_ g: Gray, levels: Int) -> [Gray] {
        var out = [g]
        while out.count < levels, out.last!.width >= 32, out.last!.height >= 32 { out.append(out.last!.half) }
        return out
    }

    /// The displacement taking the patch of `a` around `p` (pixels of `a`'s level) onto `b`, refining `guess`.
    /// Returns nil when the patch has no texture to align or doesn't converge; `residual` is the mean abs difference.
    static func align(_ a: Gray, _ p: SIMD2<Float>, _ b: Gray, guess: SIMD2<Float>, radius: Int) -> (d: SIMD2<Float>, residual: Float)? {
        var gxx: Float = 0, gxy: Float = 0, gyy: Float = 0
        let n = (2 * radius + 1) * (2 * radius + 1)
        var tpl = [Float](repeating: 0, count: n), ix = tpl, iy = tpl
        var k = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = p.x + Float(dx), y = p.y + Float(dy)
                tpl[k] = a.at(x, y)
                ix[k] = (a.at(x + 1, y) - a.at(x - 1, y)) / 2
                iy[k] = (a.at(x, y + 1) - a.at(x, y - 1)) / 2
                gxx += ix[k] * ix[k]; gxy += ix[k] * iy[k]; gyy += iy[k] * iy[k]
                k += 1
            }
        }
        let det = gxx * gyy - gxy * gxy
        let minEigen = (gxx + gyy) / 2 - ((gxx - gyy) * (gxx - gyy) / 4 + gxy * gxy).squareRoot()
        guard det > 1e-9, minEigen / Float(n) > 1e-5 else { return nil }
        var d = guess
        for _ in 0..<30 {
            var bx: Float = 0, by: Float = 0
            k = 0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let e = tpl[k] - b.at(p.x + d.x + Float(dx), p.y + d.y + Float(dy))
                    bx += e * ix[k]; by += e * iy[k]
                    k += 1
                }
            }
            let step = SIMD2((gyy * bx - gxy * by) / det, (gxx * by - gxy * bx) / det)
            d += step
            if !d.x.isFinite || !d.y.isFinite { return nil }
            if simd_length(step) < 0.005 { break }
        }
        var res: Float = 0
        k = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                res += abs(tpl[k] - b.at(p.x + d.x + Float(dx), p.y + d.y + Float(dy)))
                k += 1
            }
        }
        return (d, res / Float(n))
    }

    /// Coarse-to-fine `align` of point `p` (full-resolution pixels) from pyramid `a` to pyramid `b`.
    static func track(_ a: [Gray], _ p: SIMD2<Float>, _ b: [Gray], guess: SIMD2<Float> = .zero, radius: Int) -> (d: SIMD2<Float>, residual: Float)? {
        let levels = min(a.count, b.count)
        var d = guess / Float(1 << (levels - 1))
        var last: (d: SIMD2<Float>, residual: Float)?
        for l in stride(from: levels - 1, through: 0, by: -1) {
            let s = Float(1 << l)
            guard let r = align(a[l], p / s, b[l], guess: d, radius: radius) else {
                if l == 0 { return nil }
                d *= 2
                continue
            }
            last = r
            d = l > 0 ? r.d * 2 : r.d
        }
        return last.map { (d, $0.residual) }
    }
}
