import Accelerate
import CutlineCore
@testable import CutlineEngine
import Foundation
import Testing

private let rate = 16_000.0
private let voices = ["Fred", "Kathy"]

/// A line read by a macOS voice as 16 kHz mono, cached under the temporary directory.
func spokenLine(_ text: String, voice: String = "Fred", sampleRate: Int = 16_000) throws -> [Float] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-say-lines", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let key = (voice + "-\(sampleRate)-" + text).map { $0.isLetter || $0.isNumber ? $0 : "_" }
    let url = dir.appendingPathComponent(String(key) + ".wav")
    if !FileManager.default.fileExists(atPath: url.path) {
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", tmp.path, "--data-format=LEI16@\(sampleRate)", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw EditError("say failed") }
        _ = try? FileManager.default.moveItem(at: tmp, to: url)
        try? FileManager.default.removeItem(at: tmp)
    }
    let d = try Data(contentsOf: url)
    var i = 12
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<(i + 4)], as: UTF8.self)
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        if id == "data" {
            let body = d[(i + 8)..<min(d.count, i + 8 + size)]
            let raw = stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { k in Float(Int16(bitPattern: UInt16(body[k]) | UInt16(body[k + 1]) << 8)) / 32768 }
            // say pads with silence; keep 50 ms around the voice.
            let lo = max(0, (raw.firstIndex { abs($0) > 1e-3 } ?? 0) - sampleRate / 20)
            let hi = min(raw.count, (raw.lastIndex { abs($0) > 1e-3 } ?? raw.count) + sampleRate / 20)
            return Array(raw[lo..<hi])
        }
        i += 8 + size + (size & 1)
    }
    throw EditError("No audio data")
}

private struct Rng {
    var state: UInt64
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 40) / Float(1 << 24) * 2 - 1
    }

    mutating func gaussian() -> Float {
        let u = max(1e-7, (next() + 1) / 2), v = (next() + 1) / 2
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

private func energy(_ x: [Float], _ r: Range<Int>) -> Double {
    let r = max(0, r.lowerBound)..<min(x.count, r.upperBound)
    return x[r].reduce(0) { $0 + Double($1 * $1) }
}

private func db(_ v: Double) -> Double { 10 * log10(max(v, 1e-30)) }

private func gainDb(_ v: Float) -> Float { pow(10, v / 20) }

private func spectralDistance(_ a: [Float], _ b: [Float]) -> Double { AudioDSP.spectralDistance(a, b, sampleRate: rate, high: 7000) }

private let lines = ["Did you bring the cables?", "Yes, they are in the van.", "Which van, the blue one?", "No, the white one by the gate.", "Okay. I will grab them now."]

@Test(.enabled(if: voicesAvailable(voices))) func levelerEvensOutLinesWithoutPumpingPauses() throws {
    let levels: [Float] = [0, -15, -7, -11, -3]
    var x: [Float] = []
    var spans: [Range<Int>] = [], pauses: [Range<Int>] = []
    for (i, line) in lines.enumerated() {
        let pause = Int(rate * 0.9)
        if i > 0 { pauses.append((x.count + Int(rate * 0.2))..<(x.count + pause - Int(rate * 0.2))) }
        x += [Float](repeating: 0, count: pause)
        let s = try spokenLine(line).map { $0 * 0.9 * gainDb(levels[i]) }
        spans.append(x.count..<(x.count + s.count))
        x += s
    }
    x += [Float](repeating: 0, count: Int(rate * 0.5))
    var rng = Rng(state: 7)
    let floorAmp = gainDb(-62) * Float(3).squareRoot()
    x = x.map { $0 + floorAmp * rng.next() }
    func lineLoudness(_ y: [Float]) -> [Double] { spans.map { AudioDSP.loudness([y], sampleRate: rate, from: Double($0.lowerBound) / rate, to: Double($0.upperBound) / rate) } }
    let before = lineLoudness(x)
    let out = AudioDSP.level([x], sampleRate: rate, target: -23, maxBoost: 18, maxCut: 12, speed: 0.5, floor: -50)[0]
    let after = lineLoudness(out)
    let spreadBefore = before.max()! - before.min()!, spreadAfter = after.max()! - after.min()!
    print("leveler: line loudness \(before.map { String(format: "%.1f", $0) }) → \(after.map { String(format: "%.1f", $0) }), spread \(spreadBefore) → \(spreadAfter) LU")
    #expect(spreadBefore > 13)
    #expect(spreadAfter < 3, "spread after \(spreadAfter)")
    #expect(after.allSatisfy { abs($0 + 23) < 2.5 })
    // Pauses keep the gain of the lines around them: the noise floor isn't pumped above either neighbor's gain.
    for (i, p) in pauses.enumerated() {
        let g = db(energy(out, p) / energy(x, p))
        let neighbors = [spans[i], spans[i + 1]].map { db(energy(out, $0) / energy(x, $0)) }
        #expect(g <= neighbors.max()! + 1.5, "pause \(i) gain \(g) dB, lines \(neighbors)")
    }
    #expect(out.map(abs).max()! <= gainDb(-1) + 0.01)
}

@Test(.enabled(if: voicesAvailable(voices))) func matchEQBringsALavToTheBoom() throws {
    var rng = Rng(state: 21)
    let boom = try (spokenLine(lines[0]) + spokenLine(lines[2]) + spokenLine(lines[4])).map { $0 + 0.0005 * rng.next() }
    let clean = try spokenLine(lines[1]) + spokenLine(lines[3])
    // Lav: chesty (a low-mid resonance) and dull (half the top rolled off), over its own noise floor.
    let lp = AudioDSP.Biquad.lowPass(2500, q: 0.7, rate), bp = AudioDSP.Biquad.bandPass(250, q: 0.8, rate)
    let dull = zip(AudioDSP.filter(clean, [lp]), clean).map { 0.6 * $0 + 0.4 * $1 }
    let lav = zip(dull, AudioDSP.filter(clean, [bp])).map { $0 + 1.5 * $1 + 0.0005 * rng.next() }
    let ref = AudioDSP.longTermSpectrum([boom], sampleRate: rate)
    let src = AudioDSP.longTermSpectrum([lav], sampleRate: rate)
    let floor = spectralDistance(AudioDSP.longTermSpectrum([clean], sampleRate: rate), ref)
    let curve = AudioDSP.matchCurve(source: src, reference: ref, sampleRate: rate, sourceNoise: AudioDSP.noiseProfile([lav], sampleRate: rate), referenceNoise: AudioDSP.noiseProfile([boom], sampleRate: rate))
    let matched = AudioDSP.matchEQ([lav], sampleRate: rate, curve: curve, amount: 1)
    let before = spectralDistance(src, ref), after = spectralDistance(AudioDSP.longTermSpectrum(matched, sampleRate: rate), ref)
    print("match EQ: spectral distance \(before) → \(after) dB (same voice, different words: \(floor)); curve \(curve.text)")
    #expect(before > 4)
    #expect(after < floor + 1, "after \(after), floor \(floor)")
    #expect(curve.points.allSatisfy { abs($0.db) <= 12 })
    #expect(abs(db(energy(matched[0], 0..<lav.count) / energy(lav, 0..<lav.count))) < 3.5)
    let same = AudioDSP.matchCurve(source: ref, reference: ref, sampleRate: rate)
    #expect(same.points.allSatisfy { abs($0.db) < 0.05 })
    #expect(EQCurve(text: curve.text)?.text == curve.text)
}

/// Dry speech through a synthetic room: direct sound, three early reflections and an exponentially decaying
/// noise tail with the given RT60, its energy `lateDb` relative to the direct sound.
private func reverberant(_ dry: [Float], rt60: Double, lateDb: Double) -> [Float] {
    let len = Int(rate * rt60 * 1.2)
    var h = [Float](repeating: 0, count: len)
    h[0] = 1
    for (t, a) in [(0.007, 0.5), (0.013, -0.4), (0.023, 0.3)] { h[Int(t * rate)] += Float(a) }
    var rng = Rng(state: 99)
    var tail = (0..<len).map { i -> Float in i < Int(0.005 * rate) ? 0 : rng.gaussian() * Float(exp(-6.9078 * Double(i) / rate / rt60)) }
    let scale = Float((pow(10, lateDb / 10) / tail.reduce(0) { $0 + Double($1 * $1) }).squareRoot())
    tail = tail.map { $0 * scale }
    for i in 0..<len { h[i] += tail[i] }
    let padded = [Float](repeating: 0, count: len - 1) + dry + [Float](repeating: 0, count: len)
    var out = [Float](repeating: 0, count: dry.count + len)
    let reversed = Array(h.reversed())
    vDSP_conv(padded, 1, reversed, 1, &out, 1, vDSP_Length(out.count), vDSP_Length(len))
    return out
}

@Test(.enabled(if: voicesAvailable(voices))) func dereverbRemovesRoomTailsAndKeepsSpeech() throws {
    var dry: [Float] = []
    var speech: [Range<Int>] = [], tails: [Range<Int>] = []
    for line in lines.prefix(4) {
        let s = try spokenLine(line, voice: "Kathy").map { $0 * 0.4 }
        speech.append(dry.count..<(dry.count + s.count))
        tails.append((dry.count + s.count + Int(0.08 * rate))..<(dry.count + s.count + Int(0.6 * rate)))
        dry += s + [Float](repeating: 0, count: Int(rate * 0.9))
    }
    let wet = Array(reverberant(dry, rt60: 0.8, lateDb: 3).prefix(dry.count))
    let rt = AudioDSP.estimateRT60([wet], sampleRate: rate)
    let estimates = [0.4, 1.4].map { AudioDSP.estimateRT60([Array(reverberant(dry, rt60: $0, lateDb: 3).prefix(dry.count))], sampleRate: rate) ?? -1 }
    let out = AudioDSP.dereverb([wet], sampleRate: rate, strength: 0.6, reduction: 15, rt60: 0)[0]
    func tailRatio(_ y: [Float]) -> Double { db(tails.reduce(0) { $0 + energy(y, $1) } / speech.reduce(0) { $0 + energy(y, $1) }) }
    func earlyLate(_ y: [Float]) -> Double {
        // C50-like: energy in the 50 ms after each line ends over the next 50–500 ms.
        db(speech.reduce(0) { $0 + energy(y, $1.upperBound..<($1.upperBound + Int(0.05 * rate))) } / speech.reduce(0) { $0 + energy(y, ($1.upperBound + Int(0.05 * rate))..<($1.upperBound + Int(0.5 * rate))) })
    }
    let speechKept = db(speech.reduce(0) { $0 + energy(out, $1) } / speech.reduce(0) { $0 + energy(dry, $1) })
    print("dereverb: RT60 estimate \(rt ?? -1) s (true 0.8; 0.4 → \(estimates[0]), 1.4 → \(estimates[1])); tail/speech \(tailRatio(dry)) dry, \(tailRatio(wet)) wet → \(tailRatio(out)) dB; C50-like \(earlyLate(wet)) → \(earlyLate(out)) dB; speech vs dry \(speechKept) dB")
    let estimate = try #require(rt)
    #expect(abs(estimate / 0.8 - 1) < 0.2)
    #expect(abs(estimates[0] / 0.4 - 1) < 0.2 && abs(estimates[1] / 1.4 - 1) < 0.2, "\(estimates)")
    #expect(tailRatio(wet) - tailRatio(out) >= 8)
    #expect(earlyLate(out) - earlyLate(wet) >= 2.5)
    #expect(speechKept > -4)
    let untouched = AudioDSP.dereverb([dry], sampleRate: rate, strength: 0.6, reduction: 15, rt60: 0)[0]
    #expect(abs(db(speech.reduce(0) { $0 + energy(untouched, $1) } / speech.reduce(0) { $0 + energy(dry, $1) })) < 1.5)
}

@Test(.enabled(if: voicesAvailable(voices))) func spectralRepairRemovesBeepAndClick() throws {
    let clean = try spokenLine(lines[1]) + spokenLine(lines[2])
    let beepAt = 0.9, beepLen = 0.4, clickAt = Double(clean.count) / rate - 1.2
    var beep = [Float](repeating: 0, count: clean.count)
    for i in Int(beepAt * rate)..<Int((beepAt + beepLen) * rate) {
        let t = Double(i) / rate - beepAt
        let ramp = Float(min(1, min(t, beepLen - t) / 0.005))
        beep[i] = 0.15 * ramp * Float(sin(2 * .pi * 1000 * t))
    }
    var click = [Float](repeating: 0, count: clean.count)
    let c0 = Int(clickAt * rate)
    for (k, v) in [0.0, 0.7, -0.9, 0.5, -0.2].enumerated() { click[c0 + k] = Float(v) }
    let x = zip(zip(clean, beep).map(+), click).map(+)

    let found = AudioDSP.repairCandidates([x], sampleRate: rate)
    print("candidates: " + found.map { "\($0.kind.rawValue) \(String(format: "%.3f–%.3f", $0.start, $0.end)) \(Int($0.low))–\(Int($0.high)) Hz \(String(format: "%.0f", $0.strength)) dB" }.joined(separator: "; "))
    let tone = try #require(found.first { $0.kind == .tone })
    #expect(abs(tone.start - beepAt) < 0.06 && abs(tone.end - (beepAt + beepLen)) < 0.08)
    #expect(tone.low < 1000 && tone.high > 1000 && tone.high - tone.low < 300)
    #expect(found.contains { $0.kind == .click && abs($0.start - clickAt) < 0.01 })
    #expect(found.filter { $0.kind == .tone }.count == 1)

    let fixed = AudioDSP.spectralRepair([x], sampleRate: rate, from: tone.start, to: tone.end, low: tone.low, high: tone.high, mode: .interpolate, reduction: 0)[0]
    let inside = Int((beepAt + 0.02) * rate)..<Int((beepAt + beepLen - 0.02) * rate)
    let residual = zip(fixed, clean).map { $0 - $1 }
    let beepBefore = db(energy(beep, inside)), beepAfter = db(energy(residual, inside))
    print("spectral repair: beep \(beepBefore) → residual \(beepAfter) dB (\(beepBefore - beepAfter) dB removed)")
    #expect(beepBefore - beepAfter >= 20)
    let outside = (0..<x.count).filter { Double($0) / rate < tone.start - 0.05 || Double($0) / rate > tone.end + 0.05 }
    #expect(outside.allSatisfy { abs(fixed[$0] - x[$0]) < 1e-4 })

    let declicked = AudioDSP.spectralRepair([x], sampleRate: rate, from: clickAt - 0.003, to: clickAt + 0.006, low: 0, high: 0, mode: .interpolate, reduction: 0)[0]
    let around = (c0 - Int(0.02 * rate))..<(c0 + Int(0.02 * rate))
    let clickBefore = db(energy(click, around)), clickAfter = db(energy(zip(declicked, clean).map { $0 - $1 }, around))
    print("spectral repair: click \(clickBefore) → residual \(clickAfter) dB")
    #expect(clickBefore - clickAfter >= 10)

    let attenuated = AudioDSP.apply(Effect(id: "r", type: "audio.spectral_repair", params: ["start": .number(beepAt - 0.4), "end": .number(beepAt - 0.4 + beepLen), "freq_low": .number(900), "freq_high": .number(1100), "mode": .string("attenuate"), "reduction": .number(40)]), to: [x], sampleRate: rate, origin: 0.4)![0]
    #expect(beepBefore - db(energy(zip(attenuated, clean).map { $0 - $1 }, inside)) >= 20)
}

@Test func newDialogueEffectsRenderThroughApply() {
    let n = Int(rate * 2)
    var rng = Rng(state: 3)
    let x = [(0..<n).map { i -> Float in
        let tone = Float(0.1 * sin(2 * .pi * 440 * Double(i) / rate))
        let gap = abs(i - n / 2) < Int(rate * 0.15)
        return (gap ? 0 : tone * (i < n / 2 ? 1 : 0.3)) + 0.0003 * rng.next()
    }]
    for type in ["audio.leveler", "audio.match_eq", "audio.dereverb", "audio.spectral_repair"] {
        let y = AudioDSP.apply(Effect(id: "e", type: type), to: x, sampleRate: rate)
        #expect(y?.count == 1 && y?[0].count == n, "\(type)")
    }
    let leveled = AudioDSP.apply(Effect(id: "e", type: "audio.leveler"), to: x, sampleRate: rate)![0]
    let quiet = n / 2 + Int(rate * 0.3)..<n - Int(rate * 0.3), loud = Int(rate * 0.3)..<n / 2 - Int(rate * 0.3)
    #expect(db(energy(x[0], loud) / energy(x[0], quiet)) > 10)
    #expect(db(energy(leveled, loud) / energy(leveled, quiet)) < 3)
    let tilt = AudioDSP.apply(Effect(id: "e", type: "audio.match_eq", params: ["curve": .string("100:-6 440:-6 1000:-6")]), to: x, sampleRate: rate)![0]
    #expect(abs(db(energy(tilt, loud) / energy(x[0], loud)) + 6) < 0.5)
}
