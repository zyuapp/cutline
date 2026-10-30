import Foundation
import simd

/// A camera RAW format.
public enum RawFormat: String, Codable, Sendable, CaseIterable {
    /// Apple ProRes RAW / RAW HQ in QuickTime ('aprn', 'aprh').
    case prores_raw
    /// A folder of DNG frames (CinemaDNG).
    case cinemadng
    /// One still from a stills camera: DNG, CR2/CR3, NEF, ARW, RAF, ORF, RW2…
    case camera_raw
    case braw
    case r3d
    case arriraw
    /// Canon Cinema RAW Light (.crm).
    case canon_raw_light
    /// Nikon N-RAW (.nev).
    case nraw

    public var title: String {
        switch self {
        case .prores_raw: "Apple ProRes RAW"
        case .cinemadng: "CinemaDNG sequence"
        case .camera_raw: "camera raw still"
        case .braw: "Blackmagic RAW (BRAW)"
        case .r3d: "RED R3D (REDCODE RAW)"
        case .arriraw: "ARRIRAW"
        case .canon_raw_light: "Canon Cinema RAW Light"
        case .nraw: "Nikon N-RAW"
        }
    }

    /// Developed on this Mac; the others need the camera maker's SDK.
    public var isDecodable: Bool { self == .prores_raw || self == .cinemadng || self == .camera_raw }

    /// How to bring footage this Mac can't decode into Cutline.
    public var transcodeHint: String? {
        switch self {
        case .braw: "export ProRes 4444 XQ (or a log ProRes) from Blackmagic RAW Player or DaVinci Resolve, then import that"
        case .r3d: "export ProRes 4444 XQ from REDCINE-X PRO or DaVinci Resolve (Log3G10/REDWideGamutRGB keeps the latitude; media_organize log redlog3g10), then import that"
        case .arriraw: "export ProRes 4444 XQ in LogC3 or LogC4 from ARRI Reference Tool or DaVinci Resolve (media_organize log logc3/logc4), then import that"
        case .canon_raw_light: "export ProRes 4444 XQ in Canon Log 2/3 from Canon RAW Development or DaVinci Resolve, then import that"
        case .nraw: "export ProRes 4444 XQ in N-Log from Nikon NX Studio or DaVinci Resolve, or record ProRes RAW, then import that"
        default: nil
        }
    }

    /// What decoding it needs, for import errors.
    public var vendorSDK: String? {
        switch self {
        case .braw: "the Blackmagic RAW SDK"
        case .r3d: "the RED SDK"
        case .arriraw: "the ARRI Image SDK"
        case .canon_raw_light: "Canon's Cinema RAW Development SDK"
        case .nraw: "Nikon's N-RAW SDK"
        default: nil
        }
    }
}

/// How a RAW picture is developed. On a media item (`RawMedia.settings`) these are its defaults; on a clip
/// (`Clip.raw`, raw.* parameters) they adjust the media's: exposure and tint add to it, the rest replace it.
/// nil keeps the inherited (finally the as-shot) value.
public struct RawSettings: Codable, Equatable, Hashable, Sendable {
    /// Stops of exposure in linear sensor light (an ISO change: +1 is double the ISO).
    public var exposure: Double?
    /// ISO to rate the footage at, relative to the as-shot ISO.
    public var iso: Double?
    /// Color temperature in kelvin of the light to neutralize (lower renders cooler).
    public var temperature: Double?
    /// Green–magenta shift of the white balance from as shot, + magenta.
    public var tint: Double?
    /// 0…1: rebuild sensor-clipped channels so clipped highlights go white instead of magenta, keeping the
    /// brightness of the unclipped channels.
    public var highlights: Double?
    /// 0…1 luminance and color noise reduction while debayering (DNG and stills).
    public var noiseReduction: Double?

    public init(exposure: Double? = nil, iso: Double? = nil, temperature: Double? = nil, tint: Double? = nil, highlights: Double? = nil, noiseReduction: Double? = nil) {
        self.exposure = exposure
        self.iso = iso
        self.temperature = temperature
        self.tint = tint
        self.highlights = highlights
        self.noiseReduction = noiseReduction
    }

    enum CodingKeys: String, CodingKey {
        case exposure, iso, temperature, tint, highlights
        case noiseReduction = "noise_reduction"
    }

    public var isEmpty: Bool { self == RawSettings() }

    /// Sets one setting by its raw.* name without the prefix, validated like the clip parameter; the value that
    /// follows the media (0, or -1 for highlights and noise reduction) clears it.
    public mutating func set(_ name: String, _ n: Double) throws {
        let path = "raw." + name
        guard let spec = CameraRaw.specs.first(where: { $0.name == path }) else {
            throw EditError("No RAW setting \(name); settings: \(CameraRaw.specs.map { String($0.name.dropFirst(4)) }.joined(separator: ", "))")
        }
        _ = try spec.validate(.number(n), path: path)
        var s: RawSettings? = self
        CameraRaw.set(&s, path, n)
        self = s ?? RawSettings()
    }

    /// These clip settings applied on top of a media's.
    public func over(_ base: RawSettings?) -> RawSettings {
        let b = base ?? RawSettings()
        func sum(_ a: Double?, _ c: Double?) -> Double? { a == nil && c == nil ? nil : (a ?? 0) + (c ?? 0) }
        return RawSettings(exposure: sum(b.exposure, exposure), iso: iso ?? b.iso, temperature: temperature ?? b.temperature, tint: sum(b.tint, tint),
                           highlights: highlights ?? b.highlights, noiseReduction: noiseReduction ?? b.noiseReduction)
    }

    /// The settings a developed copy bakes in: everything but exposure, which is applied live.
    public var baked: RawSettings { RawSettings(temperature: temperature, tint: tint, highlights: highlights, noiseReduction: noiseReduction) }

    /// "exposure +1, 3200K, tint +5"; "as shot" when empty.
    public var summary: String {
        var parts: [String] = []
        if let v = exposure, v != 0 { parts.append("exposure \(v > 0 ? "+" : "")\(fmt2(v))") }
        if let v = iso { parts.append("ISO \(Int(v.rounded()))") }
        if let v = temperature { parts.append("\(Int(v.rounded()))K") }
        if let v = tint, v != 0 { parts.append("tint \(v > 0 ? "+" : "")\(fmt2(v))") }
        if let v = highlights { parts.append("highlights \(fmt2(v))") }
        if let v = noiseReduction { parts.append("noise reduction \(fmt2(v))") }
        return parts.isEmpty ? "as shot" : parts.joined(separator: ", ")
    }
}

/// A camera RAW media item: what it is, how it was shot and how it is developed by default.
public struct RawMedia: Codable, Equatable, Sendable {
    public var format: RawFormat
    /// Frames in a DNG sequence.
    public var frames: Int?
    public var camera: String?
    /// As shot.
    public var iso: Double?
    /// As-shot white balance color temperature in kelvin; nil when the file doesn't say.
    public var temperature: Double?
    /// As-shot tint in the decoder's units (DNG and stills).
    public var tint: Double?
    /// ProRes RAW conversion metadata from the first frame (kCVPixelBufferProResRAWKey_*): overall gain, white balance
    /// red and blue factors, camera RGB → XYZ (D65) matrix row-major, and the decoder's output per unit of that
    /// conversion (measured at import).
    public var gain: Double?
    public var whiteBalance: [Double]?
    public var colorMatrix: [Double]?
    public var decodeScale: Double?
    /// The media's own development settings; clips adjust them with raw.* parameters.
    public var settings: RawSettings

    public init(format: RawFormat, settings: RawSettings = RawSettings()) {
        self.format = format
        self.settings = settings
    }

    /// "ProRes RAW, as shot 5400K, ISO 800"
    public var summary: String {
        var parts = [format.title]
        if let c = camera, !c.isEmpty { parts.append(c) }
        if let f = frames { parts.append("\(f) frames") }
        var shot: [String] = []
        if let t = temperature { shot.append("\(Int(t.rounded()))K") }
        if let t = tint, abs(t) >= 0.5 { shot.append("tint \(fmt2(t))") }
        if let i = iso { shot.append("ISO \(Int(i.rounded()))") }
        if let g = gain { shot.append("gain ×\(fmt2(g))") }
        if !shot.isEmpty { parts.append("as shot " + shot.joined(separator: " ")) }
        if !settings.isEmpty { parts.append("developed " + settings.summary) }
        return parts.joined(separator: ", ")
    }
}

extension MediaAsset {
    /// A clip's development of this media; nil when it isn't camera RAW.
    public func rawSettings(for clip: Clip?) -> RawSettings? {
        guard let raw else { return nil }
        return (clip?.raw ?? RawSettings()).over(raw.settings)
    }
}

/// Camera RAW development math. Developed video is stored as scene-linear light encoded in `workingLog` /
/// `workingPrimaries` (12-bit ProRes 4444 XQ), so it enters the log/ACES input pipeline like camera log footage.
public enum CameraRaw {
    public static let workingLog = LogProfile.logc4
    public static var workingPrimaries: Primaries { workingLog.primaries }

    static let rec2020ToWorking = Primaries.matrix(from: .rec2020, to: workingLog.primaries).float
    static let workingToRec2020 = Primaries.matrix(from: workingLog.primaries, to: .rec2020).float

    /// Scene-linear BT.2020 to the working encoding (code values 0…1, full range).
    public static func encode(_ rec2020: SIMD3<Float>) -> SIMD3<Float> {
        let w = rec2020ToWorking * rec2020
        return simd_clamp(SIMD3(workingLog.fromLinear(w.x), workingLog.fromLinear(w.y), workingLog.fromLinear(w.z)), .zero, SIMD3(repeating: 1))
    }

    /// The working encoding back to scene-linear BT.2020.
    public static func decode(_ code: SIMD3<Float>) -> SIMD3<Float> {
        workingToRec2020 * SIMD3(workingLog.toLinear(code.x), workingLog.toLinear(code.y), workingLog.toLinear(code.z))
    }

    // MARK: White balance

    /// Chromaticity of a blackbody at `kelvin` (Kim et al. cubic fit, 1667–25000 K).
    public static func planckian(_ kelvin: Double) -> SIMD2<Double> {
        let t = min(max(kelvin, 1667), 25000)
        let x = t <= 4000
            ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        let y: Double
        if t <= 2222 { y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683 }
        else if t <= 4000 { y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867 }
        else { y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483 }
        return SIMD2(x, y)
    }

    /// One tint unit moves the white this far (Δuv, CIE 1960) off the blackbody locus.
    public static let tintScale = 1.0 / 3000

    /// The white of a light at `kelvin`, `tint` units off the locus: + toward green (the light), which balances to magenta.
    public static func whitePoint(kelvin: Double, tint: Double) -> SIMD2<Double> {
        func uv(_ xy: SIMD2<Double>) -> SIMD2<Double> { let d = -2 * xy.x + 12 * xy.y + 3; return SIMD2(4 * xy.x / d, 6 * xy.y / d) }
        let p = uv(planckian(kelvin))
        guard tint != 0 else { return planckian(kelvin) }
        let a = uv(planckian(kelvin - 10)), b = uv(planckian(kelvin + 10))
        var n = simd_normalize(SIMD2(-(b.y - a.y), b.x - a.x))
        if n.y < 0 { n = -n }
        let q = p + n * tint * tintScale
        let d = 2 * q.x - 8 * q.y + 4
        return SIMD2(3 * q.x / d, 2 * q.y / d)
    }

    // MARK: ProRes RAW

    /// Camera RGB (white balanced) → linear BT.2020 for a ProRes RAW item's color matrix.
    static func cameraToRec2020(_ m: RawMedia) -> simd_double3x3? {
        guard let c = m.colorMatrix, c.count == 9 else { return nil }
        let toXYZ = simd_double3x3(rows: [SIMD3(c[0], c[1], c[2]), SIMD3(c[3], c[4], c[5]), SIMD3(c[6], c[7], c[8])])
        return Primaries.rec2020.toXYZ.inverse * toXYZ
    }

    /// Per-channel gains on white-balanced camera RGB that re-balance a ProRes RAW picture from its as-shot white to
    /// `kelvin`/`tint` (green stays 1). The as-shot white is the recorded CCT on the locus (D65 when unrecorded).
    public static func whiteBalanceGains(_ m: RawMedia, kelvin: Double?, tint: Double?) -> SIMD3<Double> {
        guard kelvin != nil || (tint ?? 0) != 0, let c = m.colorMatrix, c.count == 9 else { return SIMD3(repeating: 1) }
        let toXYZ = simd_double3x3(rows: [SIMD3(c[0], c[1], c[2]), SIMD3(c[3], c[4], c[5]), SIMD3(c[6], c[7], c[8])])
        let shot = m.temperature.map { planckian($0) } ?? Primaries.d65
        let target = whitePoint(kelvin: kelvin ?? m.temperature ?? 6504, tint: tint ?? 0)
        let seen = Primaries.bradford(from: shot, to: Primaries.d65) * Primaries.xyz(target)
        let cam = toXYZ.inverse * seen
        guard cam.x > 1e-6, cam.y > 1e-6, cam.z > 1e-6 else { return SIMD3(repeating: 1) }
        return SIMD3(cam.y / cam.x, 1, cam.y / cam.z)
    }

    /// Where each white-balanced camera channel saturates, in the decoder's output units.
    static func clipLevels(_ m: RawMedia) -> SIMD3<Double>? {
        guard let wb = m.whiteBalance, wb.count == 2, let g = m.gain else { return nil }
        return SIMD3(wb[0], 1, wb[1]) * g * (m.decodeScale ?? 1)
    }

    /// Rebuilds channels at or near their clip level: `amount` 0 leaves `u` alone, 1 replaces clipped chroma with
    /// the neutral clip while keeping the mean of the unclipped values.
    public static func recoverHighlights(_ u: SIMD3<Double>, clip l: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let knee = 0.85
        let m = (u / l).max()
        guard amount > 0, m > knee else { return u }
        let x = min(1, (m - knee) / (1 - knee))
        let w = amount * x * x * (3 - 2 * x)
        let floor = l.min()
        let clipped = simd_min(u, SIMD3(repeating: floor))
        let rebuilt = clipped + (u.sum() - clipped.sum()) / 3
        return u + (rebuilt - u) * w
    }

    // MARK: Live adjustment

    /// Exposure in stops a development adds, ISO included.
    public static func stops(_ m: RawMedia, _ s: RawSettings) -> Double {
        var ev = s.exposure ?? 0
        if let iso = s.iso, iso > 0, let shot = m.iso, shot > 0 { ev += log2(iso / shot) }
        return ev
    }

    /// The part of a development applied while playing, on scene-linear BT.2020 of the developed copy; nil when
    /// it changes nothing. ProRes RAW copies are developed as shot, so white balance and highlights apply here
    /// (exactly, on white-balanced camera RGB); DNG and still copies bake those in and only take exposure.
    public static func liveAdjustment(_ m: RawMedia, _ s: RawSettings) -> ((SIMD3<Float>) -> SIMD3<Float>)? {
        let gain = pow(2, stops(m, s))
        guard m.format == .prores_raw, let toOut = cameraToRec2020(m) else {
            guard abs(gain - 1) > 1e-9 else { return nil }
            let g = Float(gain)
            return { $0 * g }
        }
        let k = whiteBalanceGains(m, kelvin: s.temperature, tint: s.tint)
        let highlights = s.highlights ?? 0
        let levels = clipLevels(m)
        guard abs(gain - 1) > 1e-9 || k != SIMD3(repeating: 1) || (highlights > 0 && levels != nil) else { return nil }
        let toCam = toOut.inverse
        let out = (toOut * simd_double3x3(diagonal: k) * gain).float
        let inCam = toCam.float
        guard highlights > 0, let levels else {
            let whole = out * inCam
            return { whole * $0 }
        }
        return { c in
            let u = inCam * c
            let r = recoverHighlights(SIMD3<Double>(u), clip: levels, amount: highlights)
            return out * SIMD3<Float>(r)
        }
    }

    /// Working-encoded RGB of a developed RAW picture (0…1) to the encoded `target` signal: the live adjustment in
    /// scene light, then the same input pipeline as camera log (`ColorPipeline.inputTransform`).
    public static func inputTransform(_ m: RawMedia, _ s: RawSettings, target: WorkingSpace, tone: ToneMap, exposure: Float) -> ColorMath.Transform {
        let pipeline = ColorPipeline.inputTransform(log: workingLog, target: target, tone: tone, exposure: exposure, recordedIn: .full)
        guard let adjust = liveAdjustment(m, s) else { return pipeline }
        let toWorking = rec2020ToWorking
        return { c in
            let lin = adjust(decode(c))
            let w = toWorking * lin
            return pipeline(SIMD3(workingLog.fromLinear(w.x), workingLog.fromLinear(w.y), workingLog.fromLinear(w.z)))
        }
    }

    /// raw.* paths, on media clips of camera RAW media.
    public static let specs: [ParamSpec] = [
        ParamSpec("raw.exposure", .number, .number(0), min: -8, max: 8, unit: "stops", animatable: false, "Camera RAW: exposure in linear sensor light, added to the media's (+1 = double the ISO)"),
        ParamSpec("raw.iso", .number, .number(0), min: 0, max: 409_600, animatable: false, "Camera RAW: ISO to rate the footage at, relative to the as-shot ISO; 0 follows the media"),
        ParamSpec("raw.temperature", .number, .number(0), min: 0, max: 50000, unit: "K", animatable: false, "Camera RAW: white balance, the color temperature of the light to neutralize (lower renders cooler); 0 follows the media (as shot)"),
        ParamSpec("raw.tint", .number, .number(0), min: -150, max: 150, animatable: false, "Camera RAW: white balance tint added to the media's, + magenta, - green"),
        ParamSpec("raw.highlights", .number, .number(-1), min: -1, max: 1, animatable: false, "Camera RAW: highlight recovery 0…1 (rebuild sensor-clipped channels so blown areas go white, not magenta); -1 follows the media"),
        ParamSpec("raw.noise_reduction", .number, .number(-1), min: -1, max: 1, animatable: false, "Camera RAW DNG and stills: noise reduction 0…1 while debayering; -1 follows the media"),
    ]

    static func value(_ s: RawSettings?, _ path: String) -> ParamValue? {
        let s = s ?? RawSettings()
        switch path {
        case "raw.exposure": return .number(s.exposure ?? 0)
        case "raw.iso": return .number(s.iso ?? 0)
        case "raw.temperature": return .number(s.temperature ?? 0)
        case "raw.tint": return .number(s.tint ?? 0)
        case "raw.highlights": return .number(s.highlights ?? -1)
        case "raw.noise_reduction": return .number(s.noiseReduction ?? -1)
        default: return nil
        }
    }

    /// Sets one raw.* path; the "follows the media" value clears it.
    static func set(_ s: inout RawSettings?, _ path: String, _ n: Double) {
        var r = s ?? RawSettings()
        switch path {
        case "raw.exposure": r.exposure = n == 0 ? nil : n
        case "raw.iso": r.iso = n <= 0 ? nil : n
        case "raw.temperature": r.temperature = n <= 0 ? nil : max(1667, n)
        case "raw.tint": r.tint = n == 0 ? nil : n
        case "raw.highlights": r.highlights = n < 0 ? nil : n
        case "raw.noise_reduction": r.noiseReduction = n < 0 ? nil : n
        default: return
        }
        s = r.isEmpty ? nil : r
    }
}
