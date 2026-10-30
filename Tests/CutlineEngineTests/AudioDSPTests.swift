import AVFoundation
import CutlineCore
import CutlineEngine
import Foundation
import Testing

private let sr = 48_000.0

private struct Noise {
    var state: UInt64

    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 40) / Float(1 << 24) * 2 - 1
    }

    /// Uniform white noise at `db` dBFS RMS.
    mutating func white(_ n: Int, db: Double) -> [Float] {
        let a = Float(pow(10, db / 20) * 3.0.squareRoot())
        return (0..<n).map { _ in a * next() }
    }
}

private func sine(_ f: Double, _ amp: Float, _ n: Int, phase: Double = 0) -> [Float] {
    (0..<n).map { amp * Float(sin(2 * .pi * f * Double($0) / sr + phase)) }
}

private func energy(_ x: [[Float]], _ ranges: [Range<Int>]) -> Double {
    x.reduce(0) { acc, ch in acc + ranges.reduce(0) { a, r in a + r.reduce(0) { $0 + Double(ch[$1] * ch[$1]) } } }
}

private func db(_ ratio: Double) -> Double { 10 * log10(ratio) }

/// Amplitude of the `f` component over `range` of one channel.
private func amplitude(_ x: [Float], _ f: Double, _ range: Range<Int>) -> Double {
    var re = 0.0, im = 0.0
    for i in range {
        let w = 2 * .pi * f * Double(i) / sr
        re += Double(x[i]) * cos(w)
        im += Double(x[i]) * sin(w)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(range.count)
}

@Test func denoiseLowersNoiseAndKeepsSpeech() {
    let n = Int(sr * 4.4)
    let burst = Int(sr * 0.4), ramp = Int(sr * 0.02)
    var clean = [Float](repeating: 0, count: n)
    var bursts: [Range<Int>] = [], gaps: [Range<Int>] = []
    for b in 0..<5 {
        let start = Int(sr * 0.2) + b * 2 * burst
        for i in 0..<burst {
            let env = Float(min(1, Double(min(i, burst - i)) / Double(ramp)))
            let t = Double(i) / sr
            var v = 0.0
            for k in 1...10 { v += 0.1 / Double(k) * sin(2 * .pi * 180 * Double(k) * t) }
            clean[start + i] = env * Float(v)
        }
        bursts.append((start + Int(sr * 0.03))..<(start + burst - Int(sr * 0.03)))
        gaps.append((start + burst + Int(sr * 0.06))..<(start + 2 * burst - Int(sr * 0.03)))
    }
    var rng = Noise(state: 0x9E37_79B9_7F4A_7C15)
    let input = (0..<2).map { _ in zip(clean, rng.white(n, db: -30)).map(+) }
    let out = AudioDSP.denoise(input, sampleRate: sr, reduction: 24, sensitivity: 0.5)

    let snrIn = db(energy(input, bursts) / energy(input, gaps))
    let snrOut = db(energy(out, bursts) / energy(out, gaps))
    let burstChange = db(energy(out, bursts) / energy([clean, clean], bursts))
    #expect(snrOut - snrIn >= 10, "SNR \(snrIn) → \(snrOut) dB")
    #expect(abs(burstChange) <= 2, "burst energy changed \(burstChange) dB")
    #expect(out.count == 2 && out[0].count == n)
}

@Test func noiseProfileMatchesWhiteNoise() {
    var rng = Noise(state: 42)
    let x = [rng.white(Int(sr * 2), db: -30)]
    let profile = AudioDSP.noiseProfile(x, sampleRate: sr)
    let mid = profile[profile.count / 4..<profile.count * 3 / 4]
    let mean = mid.reduce(0, +) / Float(mid.count)
    #expect(mid.allSatisfy { abs(db(Double($0 / mean))) < 3 })
    #expect(AudioDSP.denoise([[Float](repeating: 0, count: 4800)], sampleRate: sr, reduction: 20, sensitivity: 0.5)[0].allSatisfy { $0 == 0 })
}

@Test func deEsserTamesSibilanceOnly() {
    let n = Int(sr * 2)
    let tone = sine(500, 0.25, n)
    var hiss = [Float](repeating: 0, count: n)
    let bursts = [Int(sr * 0.5)..<Int(sr * 0.8), Int(sr * 1.2)..<Int(sr * 1.5)]
    for r in bursts { for i in r { hiss[i] = 0.3 * Float(sin(2 * .pi * 7000 * Double(i) / sr)) } }
    let input = [zip(tone, hiss).map(+), zip(tone, hiss).map(+)]
    let out = AudioDSP.deEss(input, sampleRate: sr, frequency: 5000, threshold: -30, reduction: 12)
    for r in bursts {
        let inner = (r.lowerBound + Int(sr * 0.01))..<r.upperBound
        let drop = 20 * log10(amplitude(input[0], 7000, inner) / amplitude(out[0], 7000, inner))
        #expect(drop >= 6, "7 kHz reduced \(drop) dB")
        let toneChange = 20 * log10(amplitude(out[0], 500, inner) / amplitude(input[0], 500, inner))
        #expect(abs(toneChange) <= 0.5, "500 Hz during sibilance changed \(toneChange) dB")
    }
    let quiet = Int(sr * 0.1)..<Int(sr * 0.45)
    let toneChange = 20 * log10(amplitude(out[1], 500, quiet) / amplitude(input[1], 500, quiet))
    #expect(abs(toneChange) <= 0.5, "500 Hz changed \(toneChange) dB")
}

@Test func deHumRemovesMainsHarmonics() {
    let n = Int(sr * 3)
    let hum: [(Double, Float)] = [(60, 0.1), (120, 0.05), (180, 0.03), (240, 0.02)]
    var x = sine(1000, 0.2, n)
    for (f, a) in hum { x = zip(x, sine(f, a, n, phase: f / 100)).map(+) }
    #expect(abs((AudioDSP.detectHum([x], sampleRate: sr) ?? 0) - 60) < 0.05)
    #expect(AudioDSP.detectHum([sine(1000, 0.2, n)], sampleRate: sr) == nil)
    let steady = Int(sr)..<n
    for fundamental in [60.0, 0] {
        let out = AudioDSP.deHum([x, x], sampleRate: sr, fundamental: fundamental, harmonics: 4)
        for (f, _) in hum {
            let drop = 20 * log10(amplitude(x, f, steady) / amplitude(out[0], f, steady))
            #expect(drop >= 30, "\(f) Hz reduced \(drop) dB (fundamental \(fundamental))")
        }
        let tone = 20 * log10(amplitude(out[1], 1000, steady) / amplitude(x, 1000, steady))
        #expect(abs(tone) < 0.1, "1 kHz changed \(tone) dB")
    }
}

@Test func deClickRepairsImpulsesOnly() {
    let clean = sine(440, 0.3, Int(sr))
    var x = clean
    for i in [4_000, 13_001, 30_500] { x[i] += 0.8; x[i + 1] -= 0.5 }
    let fixed = AudioDSP.deClick([x], sampleRate: sr)[0]
    #expect(zip(fixed, clean).map { abs($0 - $1) }.max()! < 0.05)
    #expect(AudioDSP.deClick([clean], sampleRate: sr)[0] == clean)
}

@Test func panIsConstantPower() {
    let x = sine(300, 0.5, 4800)
    #expect(AudioDSP.pan([x, x], pan: 0) == [x, x])
    for p in [-1.0, -0.6, -0.2, 0.3, 0.75, 1] {
        let out = AudioDSP.pan([x, x], pan: p)
        let power = energy(out, [0..<4800]), reference = 2 * energy([x], [0..<4800])
        #expect(abs(db(power / reference)) < 0.01, "pan \(p)")
        #expect(p < 0 ? energy([out[0]], [0..<4800]) > energy([out[1]], [0..<4800]) : energy([out[0]], [0..<4800]) < energy([out[1]], [0..<4800]))
    }
    let left = AudioDSP.pan([x], pan: -1)
    #expect(left.count == 2 && left[1].allSatisfy { abs($0) < 1e-6 })
    #expect(abs(left[0][100] - 2.0.squareRoot().float * x[100]) < 1e-5)
}

@Test func widthAndNormalize() {
    let l = sine(300, 0.5, 4800), r = sine(500, 0.2, 4800)
    let mono = AudioDSP.stereoWidth([l, r], width: 0)
    #expect(mono[0] == mono[1])
    let same = AudioDSP.stereoWidth([l, r], width: 1)
    #expect(zip(same[0], l).allSatisfy { abs($0 - $1) < 1e-6 })
    let wide = AudioDSP.stereoWidth([l, r], width: 2)
    let side = { (s: [[Float]]) in energy([zip(s[0], s[1]).map(-)], [0..<4800]) }
    #expect(abs(db(side(wide) / side([l, r])) - 6.02) < 0.05)
    let peak = AudioDSP.normalizePeak([l, r], peak: -6)
    #expect(abs(Double(peak.flatMap { $0 }.map(abs).max()!) - pow(10, -6.0 / 20)) < 1e-4)
}

@Test func proCatalogEffectsRender() {
    #expect(ProAudioCatalog.all.map(\.id) == ["audio.denoise", "audio.deess", "audio.dehum", "audio.pan", "audio.width"])
    #expect(ProAudioCatalog.all.allSatisfy { EffectCatalog.isAudio($0.id) && $0.category == "audio" })
    #expect(ProAudioCatalog.isPlugin("au.appl.dely.aufx"))
    let x = [sine(300, 0.5, 4800), sine(300, 0.5, 4800)]
    let half = AudioDSP.apply(Effect(id: "p", type: "audio.pan", mix: 0.5, params: ["pan": .number(-1)]), to: x, sampleRate: sr)!
    #expect(abs(half[1][100] - 0.5 * x[1][100]) < 1e-5)
    #expect(AudioDSP.apply(Effect(id: "e", type: "audio.eq"), to: x, sampleRate: sr) == nil)
}

@Test func installedEffectsIncludeApple() async throws {
    let all = AudioUnitHost.installedEffects()
    let ids = Set(all.map(\.id))
    #expect(ids.contains("au.appl.dely.aufx"))
    #expect(ids.contains("au.appl.rvb2.aufx"))
    #expect(all.first { $0.id == "au.appl.dely.aufx" }?.apple == true)
    #expect(all.allSatisfy { (try? AudioUnitHost.description(for: $0.id)).map(AudioUnitHost.id(for:)) == $0.id })

    let params = try await AudioUnitHost.parameters(of: "au.appl.dely.aufx")
    #expect(!params.isEmpty)
    #expect(params.contains { $0.unit == "seconds" && $0.max > $0.min })
    #expect(try await !AudioUnitHost.presets(of: "au.appl.rvb2.aufx").isEmpty)
    await #expect(throws: EditError.self) { try await AudioUnitHost.makeUnit(id: "au.appl.dely.aufx", params: ["nope": 1], preset: nil) }
    await #expect(throws: EditError.self) { try await AudioUnitHost.makeUnit(id: "au.appl.hshf.aufx", params: ["0": 1000], preset: nil) }
    await #expect(throws: EditError.self) { try await AudioUnitHost.makeUnit(id: "au.appl.rvb2.aufx", params: [:], preset: "No Such Room") }
    let reverb = try await AudioUnitHost.makeUnit(id: "au.appl.rvb2.aufx", params: [:], preset: AudioUnitHost.presets(of: "au.appl.rvb2.aufx").last)
    #expect(reverb.auAudioUnit.currentPreset != nil)
    await #expect(throws: EditError.self) { try await AudioUnitHost.parameters(of: "au.zzzz.zzzz.aufx") }
    #expect(throws: EditError.self) { try AudioUnitHost.description(for: "au.appl.dely") }
}

@Test func pluginsRenderOffline() async throws {
    let n = Int(sr * 0.5)
    let x = [sine(15000, 0.5, n), sine(15000, 0.5, n)]
    let shelf = try await AudioUnitHost.makeUnit(id: "au.appl.hshf.aufx", params: ["global.0": 10000, "Gain": -20], preset: nil)
    let delay = try await AudioUnitHost.makeUnit(id: "au.appl.dely.aufx", params: ["0": 100, "1": 0.05, "2": 0, "3": 20000], preset: nil)
    let out = try await AudioDSP.offline { try AudioUnitHost.render(x, sampleRate: sr, units: [shelf, delay], tail: 0.25) }
    #expect(out.count == 2 && out[0].count == n + Int(sr * 0.25))
    let late = Int(sr * 0.1)..<n
    let drop = 20 * log10(amplitude(x[0], 15000, late) / amplitude(out[0], 15000, late))
    #expect(drop > 15, "shelf lowered 15 kHz by \(drop) dB")
    #expect(out[0][0..<Int(sr * 0.04)].allSatisfy { abs($0) < 1e-3 }, "100% wet delay starts silent")
    #expect(out[0][n..<(n + Int(sr * 0.04))].contains { abs($0) > 0.01 }, "tail carries the echo")
    let again = try AudioUnitHost.render(x, sampleRate: sr, units: [shelf, delay], tail: 0.25)
    #expect(zip(again[0], out[0]).allSatisfy { abs($0 - $1) < 1e-4 })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_BENCH"] != nil)) func dspThroughput() async throws {
    let seconds = 60.0
    var rng = Noise(state: 7)
    let x = [rng.white(Int(sr * seconds), db: -20), rng.white(Int(sr * seconds), db: -20)]
    func time(_ name: String, _ body: () throws -> Void) rethrows {
        let t = Date()
        try body()
        print("bench \(name): \(Int(seconds / Date().timeIntervalSince(t)))× real time")
    }
    time("denoise") { _ = AudioDSP.denoise(x, sampleRate: sr, reduction: 12, sensitivity: 0.5) }
    time("deess") { _ = AudioDSP.deEss(x, sampleRate: sr, frequency: 6000, threshold: -30, reduction: 8) }
    time("dehum auto") { _ = AudioDSP.deHum(x, sampleRate: sr, fundamental: 0, harmonics: 8) }
    time("dehum 60") { _ = AudioDSP.deHum(x, sampleRate: sr, fundamental: 60, harmonics: 8) }
    time("declick") { _ = AudioDSP.deClick(x, sampleRate: sr) }
    time("pan+width") { _ = AudioDSP.stereoWidth(AudioDSP.pan(x, pan: 0.3), width: 1.4) }
    let units = [try await AudioUnitHost.makeUnit(id: "au.appl.hshf.aufx", params: [:], preset: nil), try await AudioUnitHost.makeUnit(id: "au.appl.rvb2.aufx", params: [:], preset: nil)]
    try time("AU shelf+reverb") { _ = try AudioUnitHost.render(x, sampleRate: sr, units: units) }
}

private extension Double {
    var float: Float { Float(self) }
}
