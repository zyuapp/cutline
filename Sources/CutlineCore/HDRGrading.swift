import Foundation
import simd

/// Code values of a grading encoding and the display light they stand for.
///
/// HDR encodings are absolute: PQ per ST 2084, HLG through its EOTF on a 1000 cd/m² display. SDR grade cubes
/// work on sRGB-encoded values with white at 100 cd/m².
public enum LightEncoding: Sendable, Equatable {
    case pq, hlg, sdr

    public init(_ space: WorkingSpace) {
        switch space {
        case .rec2020_pq: self = .pq
        case .rec2020_hlg: self = .hlg
        case .rec709, .p3: self = .sdr
        }
    }

    public static let sdrWhiteNits: Float = 100

    /// Luma weights of the encoding's primaries.
    public var lumaWeights: SIMD3<Float> { self == .sdr ? SIMD3(0.2126, 0.7152, 0.0722) : SIMD3(0.2627, 0.6780, 0.0593) }

    /// Display light in cd/m², per channel.
    public func nits(_ c: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .pq: SIMD3(Transfer.pqDecode(c.x), Transfer.pqDecode(c.y), Transfer.pqDecode(c.z))
        case .hlg: Transfer.hlgEOTF(pointwiseMax(c, .zero))
        case .sdr: SIMD3(Transfer.srgbDecode(max(c.x, 0)), Transfer.srgbDecode(max(c.y, 0)), Transfer.srgbDecode(max(c.z, 0))) * Self.sdrWhiteNits
        }
    }

    public func encode(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let n = pointwiseMax(n, .zero)
        switch self {
        case .pq: return SIMD3(Transfer.pqEncode(nits: n.x), Transfer.pqEncode(nits: n.y), Transfer.pqEncode(nits: n.z))
        case .hlg: return Transfer.hlgInverseEOTF(n)
        case .sdr:
            let v = n / Self.sdrWhiteNits
            return SIMD3(Transfer.srgbEncode(v.x), Transfer.srgbEncode(v.y), Transfer.srgbEncode(v.z))
        }
    }
}

// MARK: HDR zones

/// Zone-based exposure and saturation like Resolve's HDR palette. Each zone is centered at a luminance in cd/m²;
/// a pixel's weights blend the two zones around its luminance with a raised-cosine crossover in log2 luminance,
/// so the weights always sum to 1 and adjustments never step.
public struct HDRZones: Equatable, Sendable {
    public static let names = ["black", "dark", "shadow", "light", "highlight", "specular"]
    /// Default zone centers in cd/m²: deep black, darks, shadows up to mid grey (≈37 at 203 white), skin and
    /// diffuse white, highlights, speculars.
    public static let defaultNits: [Double] = [0.1, 2, 15, 80, 400, 1500]

    public var nits: [Double] = defaultNits
    /// Stops per zone, -4…4.
    public var exposure: [Double] = Array(repeating: 0, count: 6)
    /// Relative saturation per zone, -1 (gray)…1 (double); 0 is unchanged.
    public var saturation: [Double] = Array(repeating: 0, count: 6)
    /// Share of the distance between neighbouring centers that crosses over, 0.1…1.
    public var softness: Double = 1

    public init() {}

    /// Reads `color.hdr_zones` parameters: `<zone>_exposure`, `<zone>_saturation`, `<zone>_nits`, `softness`.
    public init(_ n: (String) -> Double?) {
        for (i, z) in Self.names.enumerated() {
            exposure[i] = n(z + "_exposure") ?? 0
            saturation[i] = n(z + "_saturation") ?? 0
            nits[i] = n(z + "_nits") ?? Self.defaultNits[i]
        }
        softness = n("softness") ?? 1
    }

    public var isIdentity: Bool { exposure.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 } }

    /// Zone weights at luminance `y` cd/m², summing to 1.
    public func weights(_ y: Double) -> [Double] {
        let centers = nits.map { log2(max($0, 1e-4)) }.enumerated().sorted { $0.element < $1.element }
        var w = [Double](repeating: 0, count: nits.count)
        let x = log2(max(y, 1e-5))
        guard let first = centers.first, let last = centers.last else { return w }
        if x <= first.element { w[first.offset] = 1; return w }
        if x >= last.element { w[last.offset] = 1; return w }
        let soft = min(max(softness, 0.1), 1)
        for (a, b) in zip(centers, centers.dropFirst()) where x <= b.element {
            let span = max(b.element - a.element, 1e-6)
            let t = ((x - a.element) / span - 0.5) / soft + 0.5
            let k = min(max(t, 0), 1)
            let toB = 0.5 - 0.5 * cos(.pi * k)
            w[a.offset] = 1 - toB
            w[b.offset] += toB
            return w
        }
        w[last.offset] = 1
        return w
    }

    /// Exposure (stops) and saturation factor at luminance `y` cd/m².
    public func adjustment(_ y: Double) -> (stops: Double, saturation: Double) {
        let w = weights(y)
        let stops = zip(w, exposure).map { $0 * $1 }.reduce(0, +)
        let sat = zip(w, saturation).map { $0 * $1 }.reduce(0, +)
        return (stops, max(0, 1 + sat))
    }

    /// The grade on code values of `encoding`: exposure scales light, saturation scales chroma around luminance.
    public func transform(_ encoding: LightEncoding) -> ColorMath.Transform {
        let zones = self
        let weights = encoding.lumaWeights
        return { c in
            let light = encoding.nits(simd_clamp(c, .zero, SIMD3(repeating: 1)))
            let y = (light * weights).sum()
            let a = zones.adjustment(Double(y))
            let gain = Float(pow(2, a.stops))
            var out = light * gain
            let ly = y * gain
            out = SIMD3(repeating: ly) + (out - ly) * Float(a.saturation)
            return simd_clamp(encoding.encode(out), .zero, SIMD3(repeating: 1))
        }
    }
}

// MARK: Delivery tone mapping

/// Converts an HDR program to an SDR Rec. 709 deliverable: HDR reference white (203 cd/m², BT.2408) lands on
/// `targetNits` SDR white, then highlights up to `sourcePeakNits` are compressed into the SDR range.
public struct SDRTrim: Equatable, Sendable {
    public enum Method: String, CaseIterable, Sendable {
        /// BT.2390 EETF: a Hermite knee in PQ space, as HDR TVs and Resolve's HDR→SDR trims use.
        case bt2390
        /// Extended Reinhard on max RGB with the source peak as its white point.
        case reinhard
        /// Hard clip at SDR white.
        case clip
    }

    public var method: Method
    /// SDR white in cd/m², 80…300.
    public var targetNits: Double
    /// The brightest light the HDR program holds, in cd/m²; maps to SDR white.
    public var sourcePeakNits: Double

    public init(method: Method = .bt2390, targetNits: Double = 100, sourcePeakNits: Double = 1000) {
        self.method = method
        self.targetNits = targetNits
        self.sourcePeakNits = sourcePeakNits
    }

    /// BT.2390 EETF in PQ space from 0…`source` to 0…`target` cd/m², black level kept at 0.
    public static func eetf(_ nits: Float, source: Float, target: Float) -> Float {
        guard source > target, nits > 0 else { return min(max(nits, 0), max(source, target)) }
        let ps = Transfer.pqEncode(nits: source)
        let e1 = Transfer.pqEncode(nits: nits) / ps
        let maxLum = Transfer.pqEncode(nits: target) / ps
        let ks = 1.5 * maxLum - 0.5
        var e2 = e1
        if e1 >= 1 {
            e2 = maxLum
        } else if e1 > ks {
            let t = (e1 - ks) / (1 - ks)
            let t2 = t * t, t3 = t2 * t
            e2 = (2 * t3 - 3 * t2 + 1) * ks + (t3 - 2 * t2 + t) * (1 - ks) + (-2 * t3 + 3 * t2) * maxLum
        }
        return Transfer.pqDecode(e2 * ps)
    }

    /// SDR light (cd/m², before the gamut change) for a max-RGB light level `m` already scaled to SDR white.
    func curve(_ m: Float, peak: Float, target: Float) -> Float {
        switch method {
        case .clip: return min(m, target)
        case .reinhard:
            let x = m / target, w = max(peak / target, 1.0001)
            return min(target, x * (1 + x / (w * w)) / (1 + x) * target)
        case .bt2390:
            return Self.eetf(m, source: max(peak, target), target: target)
        }
    }

    /// HDR code values of `source` (PQ or HLG) to BT.1886 Rec. 709 code values.
    public func transform(from source: WorkingSpace) -> ColorMath.Transform {
        let encoding = LightEncoding(source)
        let toRec709 = Primaries.matrix(from: source.primaries, to: .rec709).float
        let target = Float(targetNits)
        let scale = target / ColorPipeline.referenceWhiteNits
        let peak = Float(sourcePeakNits) * scale
        let trim = self
        return { c in
            var light = encoding.nits(simd_clamp(c, .zero, SIMD3(repeating: 1))) * scale
            if trim.method == .clip {
                light = pointwiseMin(light, SIMD3(repeating: target))
            } else {
                let m = max(light.x, max(light.y, light.z))
                if m > 1e-6 { light *= trim.curve(m, peak: peak, target: target) / m }
            }
            let v = simd_clamp(ColorPipeline.compressGamut(toRec709 * light) / target, .zero, SIMD3(repeating: 1))
            return SIMD3(Transfer.gammaEncode(v.x, 2.4), Transfer.gammaEncode(v.y, 2.4), Transfer.gammaEncode(v.z, 2.4))
        }
    }
}

/// Highlight roll-off for PQ masters: each channel's light above `knee` × `peakNits` is compressed smoothly so
/// nothing exceeds `peakNits`. Per-channel curves bake exactly into a 3D LUT; the cost is that saturated
/// highlights drift toward white as they near the peak, as on film.
public struct PeakRolloff: Equatable, Sendable {
    public var peakNits: Double
    public var knee: Double

    public init(peakNits: Double, knee: Double = 0.75) {
        self.peakNits = peakNits
        self.knee = knee
    }

    /// Approaches 99% of the peak, leaving room for LUT interpolation and 10-bit rounding.
    public func curve(_ m: Float) -> Float {
        let p = Float(peakNits) * 0.99, k = Float(knee * peakNits)
        guard m > k else { return m }
        return k + (p - k) * (1 - exp(-(m - k) / (p - k)))
    }

    /// PQ code values to PQ code values.
    public var transform: ColorMath.Transform {
        let r = self
        return { c in
            let light = LightEncoding.pq.nits(simd_clamp(c, .zero, SIMD3(repeating: 1)))
            return LightEncoding.pq.encode(SIMD3(r.curve(light.x), r.curve(light.y), r.curve(light.z)))
        }
    }
}
