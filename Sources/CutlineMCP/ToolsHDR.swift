import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static func nits(_ v: Double) -> String {
        v >= 100 ? "\(Int(v.rounded()))" : v >= 1 ? fmt1(v) : fmt2(v)
    }

    /// Light levels of one frame or a span, with gamut warnings.
    static func describeLight(_ l: HDRScopes.Light, indent: String) -> [String] {
        var lines = ["\(indent)Light (cd/m²): peak \(nits(l.maxNits)), average \(nits(l.averageNits)), median \(nits(l.p50)), 90th percentile \(nits(l.p90)), 99th \(nits(l.p99)); mean luminance \(nits(l.luminance))"]
        if let g = gamutWarning(outsideP3: l.outsideP3, outside709: l.outside709) { lines.append(indent + g) }
        return lines
    }

    static func gamutWarning(outsideP3: Double, outside709: Double) -> String? {
        guard outside709 >= 0.001 else { return nil }
        let p3 = outsideP3 >= 0.001 ? "\(fmt1(outsideP3 * 100))% outside P3 (clips on P3 mastering displays; pull saturation down with color.hue_curves sat_sat or color.hdr_zones)" : "within P3"
        return "Gamut: \(fmt1(outside709 * 100))% of pixels outside Rec. 709 (an SDR version compresses them), \(p3)"
    }

    /// timeline_measure picture on HDR timelines: light per shot and MaxCLL/MaxFALL estimates.
    func measureLight(_ built: BuiltTimeline, _ p: Project, range: TimeRange?, shots bounds: [Seconds]) async throws -> [String] {
        let frames = try await HDRScopes.measure(built, range: range)
        guard !frames.isEmpty else { return [] }
        var lines = ["Light (cd/m², HDR \(p.canvas.colorSpace.rawValue)):"]
        func span(_ fs: [HDRScopes.Light]) -> String {
            let n = Double(fs.count)
            var s = "peak \(Toolbox.nits(fs.map(\.maxNits).max() ?? 0)), average \(Toolbox.nits(fs.map(\.averageNits).reduce(0, +) / n)), 99th percentile \(Toolbox.nits(fs.map(\.p99).max() ?? 0))"
            let out709 = fs.map(\.outside709).reduce(0, +) / n, outP3 = fs.map(\.outsideP3).reduce(0, +) / n
            if out709 >= 0.001 { s += ", \(fmt1(out709 * 100))% outside Rec. 709" }
            if outP3 >= 0.001 { s += ", \(fmt1(outP3 * 100))% outside P3" }
            return s
        }
        for (a, z) in zip(bounds, bounds.dropFirst()) where z - a > 0.3 {
            let fs = frames.filter { $0.time >= a + 0.05 && $0.time < z - 0.05 }
            guard !fs.isEmpty else { continue }
            let label = p.pictureLayers(at: (a + z) / 2).max { $0.visible < $1.visible }?.clip.id ?? ""
            lines.append("  \(fmt2(a))–\(fmt2(z)) \(label): " + span(fs))
        }
        let maxCLL = frames.map(\.maxNits).max() ?? 0, maxFALL = frames.map(\.averageNits).max() ?? 0
        lines.append("  Program estimate: MaxCLL \(Int(maxCLL.rounded())), MaxFALL \(Int(maxFALL.rounded())) (at measuring resolution; small specular highlights read lower than export measures)")
        if let peak = p.canvas.peakRolloff?.peakNits {
            lines.append("  Highlights roll off to the master peak of \(Toolbox.nits(peak)) cd/m² (canvas master_peak_nits)")
        } else if p.canvas.colorSpace == .rec2020_pq, maxCLL > 1000 {
            lines.append("  Warning: peaks reach \(Toolbox.nits(maxCLL)) cd/m², above a 1000 cd/m² mastering display; set canvas_set master_peak_nits:1000 to roll them off, or lower them with color.hdr_zones specular_exposure")
        }
        if maxFALL > 400 { lines.append("  Warning: frame average reaches \(Int(maxFALL.rounded())) cd/m²; many HDR TVs dim frames averaging above ~400") }
        let out709 = frames.map(\.outside709).max() ?? 0, outP3 = frames.map(\.outsideP3).max() ?? 0
        if let g = Toolbox.gamutWarning(outsideP3: outP3, outside709: out709) { lines.append("  " + g.replacingOccurrences(of: "Gamut: ", with: "Gamut at worst: ")) }
        return lines
    }

    /// export sdr_from_hdr: true or {method, target_nits, source_nits}.
    static func sdrTrim(_ raw: JSON?, _ p: Project) throws -> SDRTrim? {
        guard let raw else { return nil }
        if raw.bool == false { return nil }
        guard p.canvas.colorSpace.isHDR else { throw EditError("sdr_from_hdr makes an SDR version of an HDR timeline; this canvas is \(p.canvas.colorSpace.rawValue)") }
        var trim = SDRTrim(sourcePeakNits: p.canvas.peakRolloff?.peakNits ?? 1000)
        guard raw.bool == true || raw.object != nil else { throw EditError("sdr_from_hdr is true or {method: bt2390|reinhard|clip, target_nits, source_nits}") }
        if let o = raw.object {
            if let m = o["method"]?.string {
                guard let method = SDRTrim.Method(rawValue: m) else { throw EditError("sdr_from_hdr.method is one of \(SDRTrim.Method.allCases.map(\.rawValue).joined(separator: ", "))") }
                trim.method = method
            }
            if let t = o["target_nits"]?.double {
                guard (48...400).contains(t) else { throw EditError("sdr_from_hdr.target_nits is 48…400 (SDR white, default 100)") }
                trim.targetNits = t
            }
            if let s = o["source_nits"]?.double {
                guard (100...10_000).contains(s) else { throw EditError("sdr_from_hdr.source_nits is 100…10000 (the HDR peak that maps to SDR white)") }
                trim.sourcePeakNits = s
            }
        }
        return trim
    }
}
