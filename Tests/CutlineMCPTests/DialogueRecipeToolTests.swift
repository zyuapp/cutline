import AVFoundation
import CutlineCore
@testable import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private let sr = 48_000.0

private func say(_ text: String, voice: String) throws -> [Float] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-say-lines", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(String((voice + "-48000-" + text).map { $0.isLetter || $0.isNumber ? $0 : "_" }) + ".aiff")
    if !FileManager.default.fileExists(atPath: url.path) {
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", tmp.path, "--data-format=BEF32@48000", text]
        try p.run()
        p.waitUntilExit()
        _ = try? FileManager.default.moveItem(at: tmp, to: url)
        try? FileManager.default.removeItem(at: tmp)
    }
    let x = try AudioDSP.read(url).samples[0]
    let lo = max(0, (x.firstIndex { abs($0) > 1e-3 } ?? 0) - 2400), hi = min(x.count, (x.lastIndex { abs($0) > 1e-3 } ?? x.count) + 2400)
    return Array(x[lo..<hi])
}

private func sayAvailable() -> Bool {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "?"]
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return false }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return out.contains("Fred ") && out.contains("Kathy ")
}

/// 1 kHz amplitude over `range` (seconds) of `x`.
private func toneLevel(_ x: [Float], _ from: Double, _ to: Double) -> Double {
    var re = 0.0, im = 0.0
    let a = Int(from * sr), b = min(x.count, Int(to * sr))
    for i in a..<b {
        let w = 2 * .pi * 1000 * Double(i) / sr
        re += Double(x[i]) * cos(w)
        im += Double(x[i]) * sin(w)
    }
    return 20 * log10(max(2 * (re * re + im * im).squareRoot() / Double(b - a), 1e-12))
}

@Test(.enabled(if: sayAvailable())) func dialogueRecipesRideMatchAndRepair() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-dialogue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lines = ["Did you bring the cables?", "Yes, they are in the van.", "Which van, the blue one?", "No, the white one by the gate."]
    let gains: [Float] = [0.5, 0.16, 0.35, 0.22]
    var dialog = [Float](repeating: 0, count: Int(sr * 0.5))
    var spans: [(Double, Double)] = []
    for (line, g) in zip(lines, gains) {
        let s = try say(line, voice: "Fred").map { $0 * g }
        spans.append((Double(dialog.count) / sr, Double(dialog.count + s.count) / sr))
        dialog += s + [Float](repeating: 0, count: Int(sr * 0.7))
    }
    // A 1 kHz beep over the third line.
    let beepAt = spans[2].0 + 0.3
    for i in Int(beepAt * sr)..<Int((beepAt + 0.35) * sr) { dialog[i] += 0.05 * Float(sin(2 * .pi * 1000 * Double(i) / sr)) }
    var noise: UInt64 = 11
    dialog = dialog.map { v in
        noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
        return v + 0.0005 * (Float(noise >> 40) / Float(1 << 24) * 2 - 1)
    }
    try AudioDSP.write([dialog], sampleRate: sr, to: dir.appendingPathComponent("dialog.caf"))
    func hiss() -> Float {
        noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
        return 0.0005 * (Float(noise >> 40) / Float(1 << 24) * 2 - 1)
    }
    let boom = try say(lines[0], voice: "Kathy") + say(lines[2], voice: "Kathy")
    try AudioDSP.write([boom.map { $0 * 0.4 + hiss() }], sampleRate: sr, to: dir.appendingPathComponent("boom.caf"))
    let clean = try say(lines[1], voice: "Kathy") + say(lines[3], voice: "Kathy")
    let bp = AudioDSP.Biquad.bandPass(250, q: 0.8, sr), lp = AudioDSP.Biquad.lowPass(2500, q: 0.7, sr)
    let lav = zip(zip(AudioDSP.filter(clean, [lp]), clean).map { 0.6 * $0 + 0.4 * $1 }, AudioDSP.filter(clean, [bp])).map { 0.4 * ($0 + 1.5 * $1) + hiss() }
    try AudioDSP.write([lav], sampleRate: sr, to: dir.appendingPathComponent("lav.caf"))

    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180, "fps": 25])).isError)
    let imported = await box.call("media_import", ["paths": .array(["dialog.caf", "boom.caf", "lav.caf"].map { .string(dir.appendingPathComponent($0).path) }), "analyze": false])
    #expect(!imported.isError, "\(imported.plainText)")
    let start = 1.0
    #expect(!(await box.call("clip_add", ["media_id": "dialog", "start": .number(start)])).isError)
    let dialogClip = try #require(box.session.project().tracks.flatMap(\.clips).first { $0.mediaId == "dialog" })

    // Rides: phrases from the sound's pauses (no transcript), each line to −23 LUFS.
    let ride = await box.call("recipe", ["name": "clip_gain_ride", "args": ["clips": [.string(dialogClip.id)], "max_db": 12]])
    #expect(!ride.isError && ride.plainText.contains("4 phrase(s)"), "\(ride.plainText)")
    let rode = try #require(box.session.project().clip(dialogClip.id))
    #expect((rode.anim["audio.volume"]?.keys.count ?? 0) >= 4)
    let mix = try await AudioDSP.mix(of: try await box.session.timeline(for: try box.session.project()))
    let before = spans.map { AudioDSP.loudness([dialog], sampleRate: sr, from: $0.0, to: $0.1) }
    let after = spans.map { AudioDSP.loudness(mix, sampleRate: sr, from: start + $0.0, to: start + $0.1) }
    print("clip_gain_ride: \(before.map { String(format: "%.1f", $0) }) → \(after.map { String(format: "%.1f", $0) }) LUFS\n\(ride.plainText)")
    #expect(before.max()! - before.min()! > 9)
    #expect(after.max()! - after.min()! < 2.5)
    #expect(after.allSatisfy { abs($0 + 23) < 2 })

    // Spectral repair: the detector finds the beep, the repair removes it in the rendered clip stem.
    let listed = await box.call("recipe", ["name": "spectral_repair", "args": ["clip": .string(dialogClip.id)]])
    let tones = listed.plainText.split(separator: "\n").filter { $0.contains("tone at") }
    #expect(tones.count == 1, "\(listed.plainText)")
    let toneLine = try #require(tones.first)
    let at = try #require(Double(toneLine.split(separator: " ")[2].dropLast()))
    #expect(abs(at - (start + beepAt)) < 0.06)
    let repaired = await box.call("recipe", ["name": "spectral_repair", "args": ["clip": .string(dialogClip.id), "at": .number(start + beepAt - 0.03), "duration": 0.41, "band": "900-1100"]])
    #expect(!repaired.isError && repaired.plainText.contains("repair1"), "\(repaired.plainText)")
    let fixed = try await AudioDSP.mix(of: try await box.session.timeline(for: try box.session.project()))
    let beepBefore = toneLevel(mix[0], start + beepAt + 0.03, start + beepAt + 0.32), beepAfter = toneLevel(fixed[0], start + beepAt + 0.03, start + beepAt + 0.32)
    print("spectral_repair: 1 kHz \(beepBefore) → \(beepAfter) dB")
    #expect(beepBefore - beepAfter > 15)

    // Match EQ: lav toward boom.
    #expect(!(await box.call("clip_add", ["media_id": "boom", "start": 30, "track": "new"])).isError)
    #expect(!(await box.call("clip_add", ["media_id": "lav", "start": 40, "track": "new"])).isError)
    let p = try box.session.project()
    let boomClip = try #require(p.tracks.flatMap(\.clips).first { $0.mediaId == "boom" }), lavClip = try #require(p.tracks.flatMap(\.clips).first { $0.mediaId == "lav" })
    let matched = await box.call("recipe", ["name": "match_eq", "args": ["clips": [.string(lavClip.id)], "reference": .string(boomClip.id)]])
    #expect(!matched.isError, "\(matched.plainText)")
    print("match_eq: \(matched.plainText)")
    let numbers = matched.plainText.components(separatedBy: "spectral distance to \(boomClip.id) ").last?.split(separator: " ")
    let d0 = Double(numbers?[0] ?? "") ?? 0, d1 = Double(numbers?[2] ?? "") ?? 99
    #expect(d0 > 3 && d1 < d0 / 2, "\(d0) → \(d1)")
    let fx = try #require(box.session.project().clip(lavClip.id)?.effects.first { $0.type == "audio.match_eq" })
    print("match_eq curve: \(fx.params["curve"]?.string ?? "")")
    #expect(EQCurve(text: fx.params["curve"]?.string ?? "")?.points.count ?? 0 > 10)
    let again = await box.call("recipe", ["name": "match_eq", "args": ["clips": [.string(lavClip.id)], "reference": .string(boomClip.id)]])
    #expect(!again.isError)
    #expect(try box.session.project().clip(lavClip.id)?.effects.filter { $0.type == "audio.match_eq" }.count == 1)
}

@Test func dialogueRecipesAreListedAndSearchable() async {
    let box = Toolbox()
    for name in ["clip_gain_ride", "match_eq", "spectral_repair"] {
        #expect(Toolbox.recipe(name) != nil)
    }
    for (query, expected) in [("dialogue leveler", "audio.leveler"), ("clip gain rides", "clip_gain_ride"), ("match eq lav to boom", "match_eq"), ("remove room echo", "audio.dereverb"), ("remove a cough", "spectral_repair"), ("phone ring in the dialogue", "spectral_repair"), ("plosive pop", "spectral_repair"), ("hum", "audio.dehum")] {
        let r = await box.call("catalog", ["search": .string(query)])
        #expect(r.plainText.contains(expected), "\(query): \(r.plainText.prefix(600))")
    }
}
