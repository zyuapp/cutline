import Foundation

/// Radial lens model (Brown–Conrady, radial terms only): a ray that would land at normalized radius r lands at
/// r·(1 + k1·r² + k2·r⁴). Radii are normalized to half the frame diagonal, so the corners are at 1 when the center
/// is in the middle. Barrel distortion (wide and action cameras) has k1 < 0, pincushion k1 > 0.
public struct RadialLens: Equatable, Sendable {
    public var k1: Double
    public var k2: Double

    public init(k1: Double, k2: Double) {
        self.k1 = k1
        self.k2 = k2
    }

    public var isIdentity: Bool { abs(k1) < 1e-9 && abs(k2) < 1e-9 }

    /// Distorted radius of undistorted radius `r`.
    public func distort(_ r: Double) -> Double {
        let r2 = r * r
        return r * (1 + k1 * r2 + k2 * r2 * r2)
    }

    /// Slope of `distort`; the model only holds while it is positive.
    public func slope(_ r: Double) -> Double {
        let r2 = r * r
        return 1 + 3 * k1 * r2 + 5 * k2 * r2 * r2
    }

    /// Undistorted radius whose distorted radius is `rd`, or nil past where the model folds back.
    public func undistort(_ rd: Double) -> Double? {
        guard rd > 1e-12 else { return 0 }
        var r = rd
        for _ in 0..<30 {
            let s = slope(r)
            guard s > 1e-6 else { return nil }
            let step = (distort(r) - rd) / s
            r -= step
            if r < 0 { r = rd * 0.5 }
            if abs(step) < 1e-12 { break }
        }
        guard abs(distort(r) - rd) < 1e-7, slope(r) > 0 else { return nil }
        return r
    }

    /// Action and wide cameras with their approximate radial terms (frame-diagonal normalization).
    public static let presets: [String: RadialLens] = [
        "gopro_wide": RadialLens(k1: -0.30, k2: 0.075),
        "gopro_superview": RadialLens(k1: -0.36, k2: 0.10),
        "gopro_linear": RadialLens(k1: -0.05, k2: 0),
        "dji_wide": RadialLens(k1: -0.14, k2: 0.025),
        "phone_ultrawide": RadialLens(k1: -0.10, k2: 0.02),
        "fisheye": RadialLens(k1: -0.45, k2: 0.14),
    ]

    public static let presetNames = ["none"] + presets.keys.sorted()
}

/// A per-pixel radial remap: lens distortion corrected or applied, lateral chromatic aberration as a per-channel
/// scale about the center, and vignetting compensated by a radial gain. Coordinates are pixels with a top-left origin.
public struct RadialRemap: Equatable, Sendable {
    public enum Mode: String, Sendable { case correct, apply }

    public var width: Double
    public var height: Double
    /// Optical center in pixels.
    public var cx: Double
    public var cy: Double
    public var lens: RadialLens
    public var mode: Mode
    /// Output magnification; above 1 crops in.
    public var zoom: Double
    /// Scale of the red and blue sampling positions about the center relative to green.
    public var red: Double
    public var blue: Double
    /// Light lost at normalized radius 1 and the falloff exponent; gain = 1 / (1 − amount·r^power).
    public var vignette: Double
    public var vignettePower: Double

    public init(width: Double, height: Double, cx: Double? = nil, cy: Double? = nil, lens: RadialLens = RadialLens(k1: 0, k2: 0), mode: Mode = .correct, zoom: Double = 1, red: Double = 1, blue: Double = 1, vignette: Double = 0, vignettePower: Double = 2) {
        self.width = width
        self.height = height
        self.cx = cx ?? width / 2
        self.cy = cy ?? height / 2
        self.lens = lens
        self.mode = mode
        self.zoom = zoom
        self.red = red
        self.blue = blue
        self.vignette = vignette
        self.vignettePower = vignettePower
    }

    /// Half the frame diagonal in pixels: normalized radius 1.
    public var unit: Double { hypot(width, height) / 2 }

    public var warps: Bool { !lens.isIdentity || abs(zoom - 1) > 1e-9 }

    /// Ratio mapped/unmapped normalized radius at output radius `r` (before the zoom is divided out); nil where the
    /// lens folds back.
    public func ratio(_ r: Double) -> Double? {
        guard !lens.isIdentity, r > 1e-9 else { return 1 }
        switch mode {
        case .correct: return lens.slope(r) > 0 ? lens.distort(r) / r : nil
        case .apply: return lens.undistort(r).map { $0 / r }
        }
    }

    /// Source position (green channel) for output pixel position (x, y); nil where nothing maps.
    public func source(_ x: Double, _ y: Double) -> (Double, Double)? {
        let u = unit
        let nx = (x - cx) / (u * zoom), ny = (y - cy) / (u * zoom)
        guard let k = ratio(hypot(nx, ny)) else { return nil }
        return (cx + nx * k * u, cy + ny * k * u)
    }

    /// Vignette compensation gain at output position (x, y).
    public func gain(_ x: Double, _ y: Double) -> Double {
        guard vignette > 1e-6 else { return 1 }
        let r = hypot(x - cx, y - cy) / unit
        return 1 / max(0.05, 1 - vignette * pow(r, vignettePower))
    }

    /// The smallest zoom at which every output edge pixel maps inside the source frame, so no empty border shows.
    /// Barrel corrections may zoom out below 1; pincushion corrections and added barrel zoom in.
    public func fillZoom() -> Double {
        var probe = self
        func covered(_ s: Double) -> Bool {
            probe.zoom = s
            let n = 48
            for i in 0...n {
                let f = Double(i) / Double(n)
                for (x, y) in [(f * width, 0.0), (f * width, height), (0.0, f * height), (width, f * height)] {
                    guard let p = probe.source(x, y) else { return false }
                    let worst = max(abs(red - 1), abs(blue - 1))
                    let pad = 0.5 + worst * hypot(p.0 - cx, p.1 - cy)
                    if p.0 < -pad || p.1 < -pad || p.0 > width + pad || p.1 > height + pad { return false }
                }
            }
            return true
        }
        var lo = 0.25, hi = 6.0
        guard !covered(lo) else { return lo }
        guard covered(hi) else { return hi }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if covered(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }
}

extension EffectCatalog {
    static let lensCenter: [ParamSpec] = [
        ParamSpec("center_x", .number, .number(0.5), min: 0, max: 1, animatable: false, "Optical center, 0 left to 1 right"),
        ParamSpec("center_y", .number, .number(0.5), min: 0, max: 1, animatable: false, "Optical center, 0 top to 1 bottom"),
    ]

    /// Lens and sensor corrections: distortion, chromatic aberration, vignetting and rolling shutter.
    static let lensEffects: [EffectType] = [
        EffectType(id: "distort.lens", category: "distort", summary: "Lens distortion correction like Resolve's Lens Correction or Premiere's Lens Distortion: straightens the barrel bend of wide, fisheye and action-camera (GoPro, DJI) lenses, or pincushion, with radial k1/k2 terms or a camera preset; mode apply adds the distortion instead (a fisheye look, or matching CG to a plate). scale fill zooms just enough that no empty border shows", params: [
            ParamSpec("preset", .choice(RadialLens.presetNames), .string("none"), animatable: false, "Approximate terms of a camera: gopro_wide (GoPro Wide), gopro_superview, gopro_linear (residual of Linear mode), dji_wide, phone_ultrawide, fisheye; k1/k2 you set override it"),
            ParamSpec("mode", .choice(["correct", "apply"]), .string("correct"), animatable: false, "correct removes the distortion, apply adds it"),
            ParamSpec("k1", .number, .number(0), min: -1, max: 1, "Main radial term with radius normalized to half the frame diagonal: negative is barrel (wide lenses, about -0.3 for GoPro Wide), positive pincushion"),
            ParamSpec("k2", .number, .number(0), min: -1, max: 1, "Fourth-order radial term, for the edge of strong wide lenses (a small positive value with negative k1)"),
            ParamSpec("scale", .choice(["fill", "none"]), .string("fill"), animatable: false, "fill: smallest zoom that leaves no empty border (corrected barrel may zoom out to keep more of the picture); none: keep the frame size and leave empty areas transparent"),
            ParamSpec("zoom", .number, .number(1), min: 0.25, max: 4, "Extra magnification on top of scale"),
        ] + lensCenter),
        EffectType(id: "distort.chromatic_aberration", category: "distort", summary: "Lateral chromatic aberration (color fringing) correction: scales the red and blue channels about the optical center so their edges line up with green again, removing purple/green and red/cyan fringes toward the frame edges of wide lenses; mode apply adds fringing as a look", params: [
            ParamSpec("red", .number, .number(0), min: -2, max: 2, unit: "% of radius", "How much larger the red image is than green at the edge, in percent (0.2 is a typical fringe); correct shrinks it back"),
            ParamSpec("blue", .number, .number(0), min: -2, max: 2, unit: "% of radius", "How much larger the blue image is than green, in percent (often the opposite sign of red)"),
            ParamSpec("mode", .choice(["correct", "apply"]), .string("correct"), animatable: false, "correct removes the fringe, apply adds it"),
        ] + lensCenter),
        EffectType(id: "color.vignette_correct", category: "color", summary: "Lens vignette correction (flat-field): brightens the corners by the light the lens loses toward its edges, a radial gain 1 / (1 − amount·r^falloff) in linear light; the opposite of stylize.vignette", params: [
            ParamSpec("amount", .number, .number(0.3), min: 0, max: 0.95, "Fraction of light lost at the corners (0.3: corners 30% darker than the center)"),
            ParamSpec("falloff", .number, .number(2), min: 0.5, max: 8, "Exponent of the falloff with radius; 2 for a natural lens, higher keeps the darkening in the far corners"),
        ] + lensCenter),
    ]

    static let rollingShutterEffect = EffectType(id: "video.rolling_shutter", category: "video", summary: "Rolling shutter repair: removes the skew, wobble and jello of CMOS sensors that read rows one after another, on pans and shaky handheld or drone shots. Measures each row band's motion from frame to frame (optical flow) and moves every row to where it was when the middle row was read. Rendered in the background as a processed copy; put it first among video.* effects", params: [
        ParamSpec("readout", .number, .number(0.7), min: 0.05, max: 1, animatable: false, "Sensor readout time as a fraction of the frame interval (top row to bottom row); about 0.5-0.9 for phones and action cameras, near 1 for slow-readout DSLRs"),
        ParamSpec("direction", .choice(["top_down", "bottom_up"]), .string("top_down"), animatable: false, "Order the sensor reads rows; bottom_up for upside-down mounts"),
        ParamSpec("bands", .number, .number(12), min: 1, max: 48, animatable: false, "Horizontal bands motion is measured in; more follows faster jello, fewer is steadier; 1 corrects a uniform pan skew only"),
        ParamSpec("strength", .number, .number(1), min: 0, max: 1.5, animatable: false, "Share of the measured skew removed"),
    ])
}
