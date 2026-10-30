import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// Short alternating lines read by macOS voices, with word times spread over each line's spoken span.
struct SpokenScene {
    var samples: [Float]
    var transcript: Transcript
    /// Voice index per word.
    var truth: [Int]
}

private let lines = [
    "Did you bring the cables?", "Yes, they are in the van.", "Which van, the blue one?", "No, the white one by the gate.",
    "Okay. I will grab them now.", "Wait, take the tripod too.", "The heavy one or the small one?", "The small one is fine.",
    "Got it. Anything else?", "Maybe the spare batteries.", "Where did you leave those?", "On the table near the door.",
    "Right. Back in a minute.", "Thanks, I will set up the lights.", "Do you need help with that?", "No, I can manage it.",
    "Then I will check the sound.", "Good idea, the room echoes.", "We could hang some blankets.", "That might just work.",
    "I saw some in the trunk.", "Bring two if you can.", "Sure. Should I start the camera?", "Not yet, let me focus first.",
    "Tell me when you are ready.", "Almost there. Okay, ready.", "Rolling. Speed. Action.", "Hello, and welcome to the show.",
]

private func say(_ text: String, voice: String, to url: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw EditError("say failed for \(voice)") }
}

/// Samples of a 16-bit little-endian mono WAV, read without AVFoundation so parallel tests can't starve its readers.
private func readWav(_ url: URL) throws -> [Float] {
    let d = try Data(contentsOf: url)
    var i = 12
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<(i + 4)], as: UTF8.self)
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        if id == "data" {
            let body = d[(i + 8)..<min(d.count, i + 8 + size)]
            return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { k in
                Float(Int16(bitPattern: UInt16(body[k]) | UInt16(body[k + 1]) << 8)) / 32768
            }
        }
        i += 8 + size + (size & 1)
    }
    throw EditError("No audio data in \(url.lastPathComponent)")
}

func voicesAvailable(_ voices: [String]) -> Bool {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "?"]
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return false }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return voices.allSatisfy { v in out.split(separator: "\n").contains { $0.hasPrefix(v + " ") } }
}

/// Reads `lines` alternating between `voices`, `gap` seconds apart. Words get times by character share of the line's
/// voiced span. Rendered audio is cached under the temporary directory.
func spokenScene(voices: [String], lines: [String] = lines, gaps: [Double] = [0.12, 0.25, 0.4, 0.18]) async throws -> SpokenScene {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-say", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rate = Diarizer.decodeRate
    var samples = [Float](repeating: 0, count: Int(0.3 * rate))
    var words: [Word] = []
    var truth: [Int] = []
    for (i, line) in lines.enumerated() {
        let v = i % voices.count
        let key = "\(voices[v])-\(abs(line.hashValue))-\(line.count)".replacingOccurrences(of: " ", with: "_")
        let url = dir.appendingPathComponent(key + ".wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = dir.appendingPathComponent(UUID().uuidString + ".wav")
            try say(line, voice: voices[v], to: tmp)
            _ = try? FileManager.default.moveItem(at: tmp, to: url)
            try? FileManager.default.removeItem(at: tmp)
        }
        var clip = try readWav(url)
        // Trim to the voiced span.
        let hop = Int(0.01 * rate)
        let level = stride(from: 0, to: max(0, clip.count - hop), by: hop).map { i in clip[i..<(i + hop)].map { $0 * $0 }.reduce(0, +) / Float(hop) }
        let floor = (level.max() ?? 0) * 1e-3
        let first = level.firstIndex { $0 > floor } ?? 0, last = level.lastIndex { $0 > floor } ?? (level.count - 1)
        clip = Array(clip[(first * hop)..<min(clip.count, (last + 1) * hop)])
        let start = Double(samples.count) / rate, span = Double(clip.count) / rate
        let tokens = line.split(separator: " ").map(String.init)
        let total = Double(tokens.reduce(0) { $0 + $1.count + 1 })
        var t = start
        for tok in tokens {
            let d = span * Double(tok.count + 1) / total
            words.append(Word(text: tok, start: t, end: t + d * 0.9))
            truth.append(v)
            t += d
        }
        samples += clip
        samples += [Float](repeating: 0, count: Int(gaps[i % gaps.count] * rate))
    }
    var seed: UInt32 = 12345
    for i in samples.indices {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        samples[i] += (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * 0.0003
    }
    return SpokenScene(samples: samples, transcript: Transcript(mediaId: "say", locale: "en", words: words), truth: truth)
}

/// Share of words matching the truth under the best mapping of labels to voices.
func wordAccuracy(_ result: SpeakerAnalysis, truth: [Int], voices: Int) -> Double {
    func permutations(_ a: [Int]) -> [[Int]] {
        a.count <= 1 ? [a] : a.indices.flatMap { i -> [[Int]] in
            var rest = a
            let x = rest.remove(at: i)
            return permutations(rest).map { [x] + $0 }
        }
    }
    let k = max(voices, result.speakers.count)
    let labels = result.wordSpeakers.map { $0.flatMap { result.speakers.firstIndex(of: $0) } ?? -1 }
    let best = permutations(Array(0..<k)).map { p in zip(labels, truth).filter { $0 >= 0 && p[$0] == $1 }.count }.max() ?? 0
    return Double(best) / Double(max(1, truth.count))
}

@Test(.enabled(if: voicesAvailable(["Samantha", "Daniel"])))
func alternatingRealVoicesAreSeparatedWordByWord() async throws {
    let scene = try await spokenScene(voices: ["Samantha", "Daniel"])
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript)
    let score = wordAccuracy(result, truth: scene.truth, voices: 2)
    print("say Samantha/Daniel accuracy \(score), speakers \(result.speakers), turns \(result.segments.count) for \(lines.count) lines")
    #expect((2...3).contains(result.speakers.count))
    #expect(score >= 0.9)
}

@Test(.enabled(if: voicesAvailable(["Samantha", "Karen"])))
func alternatingSimilarVoicesAreSeparated() async throws {
    let scene = try await spokenScene(voices: ["Samantha", "Karen"])
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript)
    let score = wordAccuracy(result, truth: scene.truth, voices: 2)
    print("say Samantha/Karen accuracy \(score), speakers \(result.speakers), turns \(result.segments.count)")
    #expect(score >= 0.9)
}

private let rapid = [
    "Ready?", "Yes.", "Go on then.", "Me first?", "You first.", "Fine. So it started last spring.", "Spring?", "Late spring, in May.",
    "And then?", "Then the rain came.", "Lots of it?", "Weeks of it.", "Wow.", "We lost the whole crop.", "All of it?", "Nearly all.",
    "That is awful.", "It was.", "What did you do?", "We started again.", "Just like that?", "Just like that.",
]

@Test(.enabled(if: voicesAvailable(["Samantha", "Daniel", "Fred"])))
func rapidBackAndForthKeepsTurns() async throws {
    for pair in [["Samantha", "Daniel"], ["Daniel", "Fred"]] {
        let scene = try await spokenScene(voices: pair, lines: rapid, gaps: [0.05, 0.1, 0.15, 0.08])
        let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript)
        let score = wordAccuracy(result, truth: scene.truth, voices: 2)
        print("say rapid \(pair) accuracy \(score), speakers \(result.speakers), turns \(result.segments.count) for \(rapid.count) lines")
        #expect(score >= 0.9, "\(pair)")
    }
}

@Test(.enabled(if: voicesAvailable(["Samantha"])))
func oneRealVoiceIsOneSpeaker() async throws {
    let scene = try await spokenScene(voices: ["Samantha"])
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript)
    print("say single voice speakers \(result.speakers)")
    #expect(result.speakers == ["S1"])
}

@Test(.enabled(if: voicesAvailable(["Samantha", "Daniel", "Karen"])))
func threeRealVoicesAreSeparated() async throws {
    let scene = try await spokenScene(voices: ["Samantha", "Daniel", "Karen"])
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript)
    let score = wordAccuracy(result, truth: scene.truth, voices: 3)
    print("say three-voice accuracy \(score), speakers \(result.speakers)")
    #expect(score >= 0.85)
}
