import AVFoundation
import CutlineCore
import Foundation
import Vision

/// Finds who is talking on screen: during each speaker turn, the face whose lips move most.
public enum ActiveSpeakerDetector {
    static let samplesPerTurn = 10
    static let minActivity = 0.012

    /// Lines of speech: words grouped at sentence ends and pauses, labeled with the voice heard most.
    static func lines(_ transcript: Transcript, _ speakers: SpeakerAnalysis) -> [SpeakerSegment] {
        var out: [SpeakerSegment] = []
        var group: [Int] = []
        func flush() {
            guard let a = group.first, let b = group.last else { return }
            var votes: [String: Int] = [:]
            for i in group { if speakers.wordSpeakers.indices.contains(i), let s = speakers.wordSpeakers[i] { votes[s, default: 0] += 1 } }
            out.append(SpeakerSegment(start: transcript.words[a].start, end: transcript.words[b].end, speaker: votes.max { $0.value < $1.value }?.key ?? "S1"))
            group = []
        }
        for (i, w) in transcript.words.enumerated() {
            if let last = group.last, w.start - transcript.words[last].end > 0.3 { flush() }
            group.append(i)
            if w.text.last.map({ ".?!".contains($0) }) ?? false { flush() }
        }
        flush()
        return out
    }

    public static func analyze(url: URL, transcript: Transcript, speakers: SpeakerAnalysis, shots: ShotAnalysis) async throws -> ActiveSpeakers {
        let turns = lines(transcript, speakers).filter { $0.end - $0.start >= 0.4 }
        guard !turns.isEmpty, !shots.faces.isEmpty else { return ActiveSpeakers(mediaId: speakers.mediaId, spans: [], speakerFaces: [:]) }
        let frames = try await SourceFrames.open(url: url, maxSize: CGSize(width: 960, height: 960), from: turns[0].start)
        let spans = try await runBlocking { cancelled -> [ActiveSpeakers.Span] in
            var out: [ActiveSpeakers.Span] = []
            for turn in turns {
                if cancelled() { throw CancellationError() }
                let n = samplesPerTurn
                let step = (turn.end - turn.start) / Double(n)
                var mouths: [Int: [Double]] = [:]
                for k in 0..<n {
                    let t = turn.start + step * (Double(k) + 0.5)
                    guard let frame = try? frames.frame(near: t) else { continue }
                    let request = VNDetectFaceLandmarksRequest()
                    try? VNImageRequestHandler(cvPixelBuffer: frame.buffer, options: [:]).perform([request])
                    for face in request.results ?? [] {
                        guard let lips = face.landmarks?.innerLips?.normalizedPoints, lips.count >= 4 else { continue }
                        let ys = lips.map(\.y)
                        let opening = Double(ys.max()! - ys.min()!)
                        // Vision boxes are bottom-left origin; face tracks are top-left.
                        let box = face.boundingBox
                        let center = (x: Double(box.midX), y: 1 - Double(box.midY))
                        guard let id = nearestTrack(shots.faces, at: t, center: center) else { continue }
                        mouths[id, default: []].append(opening)
                    }
                }
                var scored: [(id: Int, activity: Double)] = []
                for (id, values) in mouths where values.count >= 3 {
                    let mean = values.reduce(0, +) / Double(values.count)
                    let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
                    scored.append((id, sd))
                }
                scored.sort { $0.activity > $1.activity }
                let best = scored.first
                let face = best.flatMap { $0.activity >= minActivity ? $0.id : nil }
                let margin = scored.count > 1 ? best!.activity / max(scored[1].activity, 1e-6) : nil
                out.append(.init(start: turn.start, end: turn.end, speaker: turn.speaker, face: face, activity: best?.activity ?? 0, margin: margin))
            }
            return out
        }
        return ActiveSpeakers(mediaId: speakers.mediaId, spans: spans, speakerFaces: faces(of: spans))
    }

    /// The face each speaker most often has.
    static func faces(of spans: [ActiveSpeakers.Span]) -> [String: Int] {
        var votes: [String: [Int: Double]] = [:]
        for s in spans { if let f = s.face { votes[s.speaker, default: [:]][f, default: 0] += s.end - s.start } }
        return votes.compactMapValues { $0.max { $0.value < $1.value }?.key }
    }

    /// `active` with each span's speaker taken from `speakers` (the voice heard most in it).
    public static func relabel(_ active: ActiveSpeakers, with speakers: SpeakerAnalysis, transcript: Transcript) -> ActiveSpeakers {
        var out = active
        for i in out.spans.indices {
            var votes: [String: Int] = [:]
            for (k, w) in transcript.words.enumerated() where w.start >= out.spans[i].start - 0.01 && w.end <= out.spans[i].end + 0.01 {
                if speakers.wordSpeakers.indices.contains(k), let s = speakers.wordSpeakers[k] { votes[s, default: 0] += 1 }
            }
            if let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { out.spans[i].speaker = best.key }
        }
        out.speakerFaces = faces(of: out.spans)
        return out
    }

    static func nearestTrack(_ tracks: [FaceTrack], at t: Seconds, center: (x: Double, y: Double)) -> Int? {
        var best: (Int, Double)?
        for track in tracks {
            guard let s = track.samples.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(s.t - t) < 0.75 else { continue }
            let d = hypot(s.box.midX - center.x, s.box.midY - center.y)
            if d < 0.15, best == nil || d < best!.1 { best = (track.id, d) }
        }
        return best?.0
    }
}
