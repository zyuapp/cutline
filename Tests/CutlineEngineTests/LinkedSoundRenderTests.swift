import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

/// A 48 kHz mono sine at `freq`, amplitude 0.25.
private func writeTone(_ url: URL, freq: Double, seconds: Double = 8) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let n = Int(seconds * 48_000)
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = Float(0.25 * sin(2 * .pi * freq * Double(i) / 48_000)) }
    try file.write(from: buf)
}

private func left(_ built: BuiltTimeline) async throws -> [Float] {
    var l: [Float] = []
    try await AudioIO.read(built, range: nil) { s, n in for i in 0..<n { l.append(s[2 * i]) } }
    return l
}

/// Amplitude of the `freq` component of `x` over `range`.
private func tone(_ x: [Float], _ freq: Double, _ range: TimeRange) -> Double {
    let a = Int(range.start * 48_000), b = min(x.count, Int(range.end * 48_000))
    guard b > a else { return 0 }
    var re = 0.0, im = 0.0
    for i in a..<b {
        let ph = 2 * .pi * freq * Double(i) / 48_000
        re += Double(x[i]) * cos(ph)
        im += Double(x[i]) * sin(ph)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(b - a)
}

private func rms(_ x: [Float], _ range: TimeRange) -> Double {
    let a = Int(range.start * 48_000), b = min(x.count, Int(range.end * 48_000))
    guard b > a else { return 0 }
    return (x[a..<b].reduce(0) { $0 + Double($1) * Double($1) } / Double(b - a)).squareRoot()
}

/// Clip a (0–5 s, a 440 Hz line) then b (5–10 s, an 880 Hz line) on V1.
private func twoShots(_ dir: URL) async throws -> Project {
    let a = dir.appendingPathComponent("a.caf"), b = dir.appendingPathComponent("b.caf")
    try writeTone(a, freq: 440)
    try writeTone(b, freq: 880)
    var p = Project(name: "Linked", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(a, id: "a"), try await MediaProbe.probe(b, id: "b")]
    p.tracks[0].clips = [
        Clip(id: "A", kind: .media, mediaId: "a", start: 0, duration: 5, sourceIn: 1),
        Clip(id: "B", kind: .media, mediaId: "b", start: 5, duration: 5, sourceIn: 1),
    ]
    p.tracks[1].clips = []
    return p
}

private func scratch(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func jCutOnADetachedClipMovesItsSoundClip() async throws {
    let dir = try scratch("jdetached")
    defer { try? FileManager.default.removeItem(at: dir) }
    var p = try await twoShots(dir)
    let (sound, _) = try p.detachAudio("B")
    let (applied, moved) = try p.splitEditMoving(left: "A", right: "B", offset: 0.5)
    #expect(applied == 0.5 && moved == [sound.id])
    #expect(p.clip(sound.id)?.start == 4.5 && p.clip(sound.id)?.sourceIn == 0.5, "B's sound clip starts half a second early")
    #expect(p.clip("B")?.audioLead == 0 && p.clip("A")?.audioLag == -0.5)
    #expect(p.linkSyncIssues().isEmpty && p.linkRangeIssues().isEmpty)

    let x = try await left(try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary()))
    let hole = TimeRange(4.55, 4.95)
    #expect(rms(x, TimeRange(4.25, 4.79)) > 0.1, "no hole before the cut: \(rms(x, TimeRange(4.25, 4.79)))")
    #expect(tone(x, 880, hole) > 0.2 && tone(x, 440, hole) < 0.01, "B's line plays under the end of A")
    #expect(tone(x, 440, TimeRange(4.0, 4.45)) > 0.2 && tone(x, 880, TimeRange(4.0, 4.45)) < 0.01)
}

@Test func splitEditsBetweenTwoDetachedClipsRollTheirSoundClips() async throws {
    let dir = try scratch("ldetached")
    defer { try? FileManager.default.removeItem(at: dir) }
    var p = try await twoShots(dir)
    let (sa, ta) = try p.detachAudio("A")
    let (sb, tb) = try p.detachAudio("B")
    #expect(ta == tb)
    try p.splitEdit(left: "A", right: "B", offset: -0.5)
    #expect(p.clip(sa.id)?.end == 5.5 && p.clip(sb.id)?.start == 5.5)
    let x = try await left(try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary()))
    let tail = TimeRange(5.05, 5.45)
    #expect(tone(x, 440, tail) > 0.2 && tone(x, 880, tail) < 0.01, "A's line runs over the start of B")
    #expect(tone(x, 880, TimeRange(5.55, 6)) > 0.2 && tone(x, 440, TimeRange(5.55, 6)) < 0.01)

    // trim part:audio on the silent picture rolls the sound cut back to a J.
    let line = try p.trimAudio("B", edge: .start, delta: -1)
    #expect(line.contains(sb.id), "\(line)")
    #expect(p.clip(sa.id)?.end == 4.5 && p.clip(sb.id)?.start == 4.5 && p.clip("B")?.audioLead == 0)
    let y = try await left(try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary()))
    #expect(tone(y, 880, TimeRange(4.55, 4.95)) > 0.2 && tone(y, 440, TimeRange(4.55, 4.95)) < 0.01)
}

@Test func slidingANeighbourCarriesItsLinkedSound() async throws {
    let dir = try scratch("slidelinked")
    defer { try? FileManager.default.removeItem(at: dir) }
    var p = try await twoShots(dir)
    let (sa, _) = try p.detachAudio("A")
    let line = try p.trim("B", mode: .slide, edge: .start, delta: -0.2)
    #expect(p.clip("A")?.end == 4.8 && p.clip(sa.id)?.end == 4.8, "\(line)")
    #expect(line.contains(sa.id), "\(line)")
    #expect(p.linkRangeIssues().isEmpty && p.linkSyncIssues().isEmpty)
    let x = try await left(try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary()))
    #expect(tone(x, 440, TimeRange(4.82, 4.98)) < 0.01, "A's line stops at its picture, not over B")
    #expect(tone(x, 880, TimeRange(4.82, 4.98)) > 0.2)
}
