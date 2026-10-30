import Foundation

/// Stable pseudo-random numbers: the same inputs give the same values in every process.
public enum StableRandom {
    public static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) for a seed, an index and a stream.
    public static func unit(_ seed: UInt64, _ index: Int64, _ stream: UInt64) -> Double {
        let h = mix(mix(seed &+ stream &* 0x632B_E59B_D9B4_E019) ^ UInt64(bitPattern: index))
        return Double(h >> 11) / Double(1 << 53)
    }

    /// FNV-1a of a string.
    public static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        return h
    }

    /// Smooth 1D gradient noise in about −1…1, zero at whole numbers.
    public static func noise(_ seed: UInt64, _ x: Double) -> Double {
        let i = x.rounded(.down), f = x - i
        func grad(_ k: Double) -> Double { unit(seed, Int64(k), 7) * 2 - 1 }
        let a = grad(i) * f, b = grad(i + 1) * (f - 1)
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        return (a + (b - a) * u) * 2
    }

    /// Fractal noise: octaves at doubling frequency and halving amplitude, normalized to about −1…1.
    public static func fractal(_ seed: UInt64, _ x: Double, octaves: Int) -> Double {
        var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0
        for o in 0..<max(1, min(octaves, 8)) {
            sum += noise(seed &+ UInt64(o) &* 0x9E37, x * freq + Double(o) * 17.13) * amp
            norm += amp
            amp *= 0.5
            freq *= 2
        }
        return sum / norm
    }
}

/// One particle as drawn at a moment, in canvas pixels (y down).
public struct Particle: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Velocity in pixels per second, for streaks.
    public var vx: Double
    public var vy: Double
    /// Diameter in pixels.
    public var size: Double
    /// Degrees.
    public var rotation: Double
    public var color: RGBA
    /// 0…1 through its life.
    public var age: Double
    /// −1…1: how much of a tumbling sprite faces the camera.
    public var flip: Double
}

/// A stateless particle simulation: every particle's birth and path come from the seed and its index,
/// so any frame can be drawn on its own and preview matches export.
public enum ParticleSystem {
    public static let confetti: [RGBA] = ["#FF375F", "#FFD60A", "#30D158", "#0A84FF", "#BF5AF2", "#FF9F0A", "#64D2FF"].compactMap { RGBA(hex: $0) }

    /// `value(name, t)` reads a parameter at `t` seconds into the clip; emitter position, direction, spread and speed
    /// are read when each particle is born, everything else at `time`.
    public static func particles(at time: Double, width: Double, height: Double, value: (String, Double) -> ParamValue) -> [Particle] {
        func num(_ k: String, _ t: Double = time) -> Double { value(k, t).number ?? 0 }
        let H = height
        let seed = UInt64(max(0, num("seed")))
        let rate = max(0, num("rate"))
        let burst = Int(max(0, num("burst")).rounded())
        let life = max(0.05, num("lifetime"))
        let lifeRand = min(max(num("lifetime_random"), 0), 1)
        let maxLife = life * (1 + lifeRand)
        let prewarm = max(0, num("prewarm"))
        let clock = time + prewarm
        guard clock >= 0 else { return [] }
        let gravity = num("gravity") * H, wind = num("wind") * H, drag = max(0, num("drag"))
        let turbulence = num("turbulence") * H
        let size = num("size") * H, sizeRand = min(max(num("size_random"), 0), 1), sizeEnd = max(0, num("size_end"))
        let speedRand = min(max(num("speed_random"), 0), 1)
        let spin = num("spin")
        let fadeIn = min(max(num("fade_in"), 0), 1), fadeOut = min(max(num("fade_out"), 0), 1)
        let sprite = value("sprite", time).string ?? "soft"
        let base = value("color", time).color ?? .white
        let endText = value("color_end", time).string ?? ""
        let end = RGBA(hex: endText) ?? RGBA.named(endText)
        var palette = (value("palette", time).string ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { RGBA(hex: String($0)) ?? RGBA.named(String($0)) }
        if palette.isEmpty && sprite == "confetti" && base == .white { palette = confetti }
        let emitter = value("emitter", time).string ?? "point"

        var out: [Particle] = []
        func spawn(_ index: Int64, born: Double) {
            let age = clock - born
            guard age >= 0 else { return }
            func r(_ s: UInt64) -> Double { StableRandom.unit(seed, index, s) }
            let lifetime = life * (1 + lifeRand * (r(1) * 2 - 1))
            guard age < lifetime else { return }
            let t0 = born - prewarm
            var px = num("x", t0) * width, py = num("y", t0) * H
            let ew = num("emitter_width", t0) * H, eh = num("emitter_height", t0) * H
            switch emitter {
            case "line": px += (r(2) - 0.5) * ew
            case "box": px += (r(2) - 0.5) * ew; py += (r(3) - 0.5) * eh
            case "circle":
                let a = r(2) * 2 * .pi, d = sqrt(r(3))
                px += cos(a) * d * ew / 2; py += sin(a) * d * eh / 2
            default: break
            }
            let dir = (num("direction", t0) + (r(4) * 2 - 1) * num("spread", t0)) * .pi / 180
            let speed = num("speed", t0) * H * (1 + speedRand * (r(5) * 2 - 1))
            let v0x = sin(dir) * speed, v0y = -cos(dir) * speed
            // Constant acceleration under linear drag, solved in closed form.
            let a = age
            let decay: Double, travel: Double
            if drag > 1e-6 {
                decay = exp(-drag * a)
                travel = (1 - decay) / drag
            } else {
                decay = 1
                travel = a
            }
            func pos(_ v0: Double, _ acc: Double) -> Double {
                drag > 1e-6 ? v0 * travel + acc / drag * (a - travel) : v0 * a + 0.5 * acc * a * a
            }
            func vel(_ v0: Double, _ acc: Double) -> Double {
                drag > 1e-6 ? v0 * decay + acc / drag * (1 - decay) : v0 + acc * a
            }
            var x = px + pos(v0x, wind), y = py + pos(v0y, gravity)
            var vx = vel(v0x, wind), vy = vel(v0y, gravity)
            if turbulence > 0 {
                let k = min(1, a / 0.5)
                let s = seed &+ UInt64(bitPattern: index) &* 31
                x += turbulence * k * StableRandom.fractal(s, a * 0.9 + r(6) * 10, octaves: 2)
                y += turbulence * k * StableRandom.fractal(s &+ 101, a * 0.9 + r(7) * 10, octaves: 2)
            }
            if sprite == "snow" {
                // Flakes sway as they fall.
                let sway = size * 2.5 * sin(a * (1.2 + r(8)) + r(9) * 6.283)
                x += sway
                vx += size * 2.5 * (1.2 + r(8)) * cos(a * (1.2 + r(8)) + r(9) * 6.283)
            }
            let u = a / lifetime
            var alpha = 1.0
            if fadeIn > 0 { alpha = min(alpha, u / fadeIn) }
            if fadeOut > 0 { alpha = min(alpha, (1 - u) / fadeOut) }
            alpha = min(max(alpha, 0), 1)
            let start = palette.isEmpty ? base : palette[Int(r(10) * Double(palette.count)) % palette.count]
            let finish = end ?? start
            var c = RGBA(r: start.r + (finish.r - start.r) * u, g: start.g + (finish.g - start.g) * u, b: start.b + (finish.b - start.b) * u, a: start.a + (finish.a - start.a) * u)
            c.a *= alpha
            guard c.a > 0.002 else { return }
            let sz = size * (1 + sizeRand * (r(11) * 2 - 1)) * (1 + (sizeEnd - 1) * u)
            guard sz > 0.05 else { return }
            let spinRate = spin * (r(12) * 2 - 1)
            let rot = r(13) * 360 + spinRate * a
            let flip = cos(a * (3 + r(14) * 6) + r(15) * 6.283)
            out.append(Particle(x: x, y: y, vx: vx, vy: vy, size: sz, rotation: rot, color: c, age: u, flip: flip))
        }
        for j in 0..<min(burst, 5000) { spawn(-1 - Int64(j), born: prewarm) }
        if rate > 0 {
            let first = max(0, Int64(((clock - maxLife) * rate).rounded(.down)))
            let last = Int64((clock * rate).rounded(.down))
            if last >= first {
                for i in first...last {
                    let born = (Double(i) + StableRandom.unit(seed, i, 0) * 0.999) / rate
                    spawn(i, born: born)
                }
            }
        }
        return out
    }
}
