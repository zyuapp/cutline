import Foundation

/// Finds the active picture inside letterbox or pillarbox bars, so measurements skip them.
public enum PictureArea {
    public struct Rect: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public func contains(_ px: Int, _ py: Int) -> Bool { px >= x && px < x + width && py >= y && py < y + height }
    }

    /// The picture inside flat bars along the edges. A bar is a run of edge rows (or columns) of one flat color that is
    /// either near black, in which case the bars on opposite sides must be about the same size (a centered letterbox
    /// or pillarbox), or exactly `background`, which may sit on any side. `pixel(x, y)` gives code values 0…1 with
    /// y = 0 at the top. A frame that is flat all over (a fade to black) is returned whole.
    public static func active(width w: Int, height h: Int, background: SIMD3<Float>? = nil, pixel: (Int, Int) -> SIMD3<Float>) -> Rect {
        let full = Rect(x: 0, y: 0, width: w, height: h)
        guard w >= 8, h >= 8 else { return full }

        /// Samples along a row (horizontal) or column at `index`.
        func line(_ index: Int, horizontal: Bool) -> [SIMD3<Float>] {
            let n = horizontal ? w : h
            let count = min(n, 64)
            return (0..<count).map { i in
                let p = (i * (n - 1)) / max(1, count - 1)
                return horizontal ? pixel(p, index) : pixel(index, p)
            }
        }
        func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
        func flat(_ samples: [SIMD3<Float>], _ color: SIMD3<Float>, tolerance: Float, share: Double) -> Bool {
            let inside = samples.filter { distance($0, color) <= tolerance }.count
            return Double(inside) >= share * Double(samples.count)
        }
        func median(_ samples: [SIMD3<Float>]) -> SIMD3<Float> {
            func m(_ k: KeyPath<SIMD3<Float>, Float>) -> Float { samples.map { $0[keyPath: k] }.sorted()[samples.count / 2] }
            return SIMD3(m(\.x), m(\.y), m(\.z))
        }
        func isDark(_ c: SIMD3<Float>) -> Bool { c.max() <= 0.09 }
        func isBackground(_ c: SIMD3<Float>) -> Bool { background.map { distance($0, c) <= 0.04 } ?? false }

        /// How many lines from one edge are bars, and whether they are the background color.
        func run(from start: Int, step: Int, count: Int, horizontal: Bool) -> (Int, Bool) {
            let edge = line(start, horizontal: horizontal)
            let color = median(edge)
            let bg = isBackground(color)
            guard bg || isDark(color) else { return (0, false) }
            let tolerance: Float = bg ? 0.025 : 0.05, share = bg ? 0.99 : 0.97
            var n = 0
            var i = start
            while n < count, flat(line(i, horizontal: horizontal), color, tolerance: tolerance, share: share) {
                n += 1
                i += step
            }
            return (n, bg)
        }

        func pair(_ size: Int, horizontal: Bool) -> (Int, Int)? {
            let (a, aBg) = run(from: 0, step: 1, count: size, horizontal: horizontal)
            let (b, bBg) = run(from: size - 1, step: -1, count: size, horizontal: horizontal)
            if a + b >= size * 9 / 10 { return nil }
            let minBar = max(2, size / 100)
            var lo = a >= minBar ? a : 0, hi = b >= minBar ? b : 0
            let symmetric = lo > 0 && hi > 0 && abs(lo - hi) <= max(4, max(lo, hi) / 5)
            if !symmetric {
                if !aBg { lo = 0 }
                if !bBg { hi = 0 }
            }
            return (lo, hi)
        }

        guard let (top, bottom) = pair(h, horizontal: true), let (left, right) = pair(w, horizontal: false) else { return full }
        return Rect(x: left, y: top, width: w - left - right, height: h - top - bottom)
    }

    /// `active` for 8-bit pixels with four bytes each, rows top to bottom; `order` gives the red, green and blue byte offsets.
    public static func active(bytes: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int, order: (Int, Int, Int) = (0, 1, 2), background: SIMD3<Float>? = nil) -> Rect {
        active(width: width, height: height, background: background) { x, y in
            let p = bytes + y * rowBytes + x * 4
            return SIMD3(Float(p[order.0]), Float(p[order.1]), Float(p[order.2])) / 255
        }
    }
}
