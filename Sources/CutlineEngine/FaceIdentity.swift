import AVFoundation
import CutlineCore
import Foundation
import Vision

/// Which face tracks show the same person across shots: Vision feature prints of each track's face crops, clustered.
/// Feature prints describe the whole crop, not identity, so only near-identical faces (the same framing and light, as
/// in shot/reverse-shot) join; a wide shot and a close-up of one person stay apart.
public enum FaceIdentity {
    /// Crops per track.
    static let perTrack = 3
    /// Faces smaller than this (fraction of frame height) are too coarse to compare.
    static let minHeight = 0.07
    /// Average-linkage distance under which two tracks are one person.
    static let sameDistance = 0.45

    /// `tracks` with `person` set: one number per person, shared by every track that shows them.
    public static func identify(url: URL, tracks: [FaceTrack]) async throws -> [FaceTrack] {
        let prints = try await prints(url: url, tracks: tracks)
        let people = cluster(prints, tracks: tracks)
        return tracks.map { t in
            var t = t
            t.person = people[t.id]
            return t
        }
    }

    /// L2-normalized feature prints of up to `perTrack` crops per track, spread over its samples.
    static func prints(url: URL, tracks: [FaceTrack]) async throws -> [Int: [[Float]]] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [:] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        var wanted: [(track: Int, sample: FaceSample)] = []
        for t in tracks {
            let usable = t.samples.filter { $0.box.height >= minHeight }
            guard !usable.isEmpty else { continue }
            let n = min(perTrack, usable.count)
            for k in 0..<n { wanted.append((t.id, usable[(2 * k + 1) * usable.count / (2 * n)])) }
        }
        var out: [Int: [[Float]]] = [:]
        for (track, sample) in wanted {
            try Task.checkCancellation()
            guard let img = try? await gen.image(at: CMTime(seconds: sample.t, preferredTimescale: 600)).image,
                  let crop = crop(img, sample.box), let v = try await runBlocking({ _ in vector(crop) }) else { continue }
            out[track, default: []].append(v)
        }
        return out
    }

    /// The face box squared, in pixels of `img`.
    static func crop(_ img: CGImage, _ box: NormRect) -> CGImage? {
        let w = Double(img.width), h = Double(img.height)
        let side = max(box.width * w, box.height * h)
        let cx = box.midX * w, cy = box.midY * h
        let r = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 24, r.height >= 24 else { return nil }
        return img.cropping(to: r.integral)
    }

    static func vector(_ img: CGImage) -> [Float]? {
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: img).perform([req])
        guard let obs = req.results?.first else { return nil }
        let v = VisionAnalyzer.floats(obs)
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : nil
    }

    static func distance(_ a: [[Float]], _ b: [[Float]]) -> Double {
        var s = 0.0
        for x in a {
            for y in b {
                var d: Float = 0
                for i in 0..<min(x.count, y.count) { let e = x[i] - y[i]; d += e * e }
                s += Double(d.squareRoot())
            }
        }
        return s / Double(max(1, a.count * b.count))
    }

    /// Average-linkage clustering of tracks; two tracks seen at the same time are never one person. Returns a person
    /// number per printed track, numbered by first appearance.
    static func cluster(_ prints: [Int: [[Float]]], tracks: [FaceTrack], threshold: Double = sameDistance) -> [Int: Int] {
        let ids = tracks.map(\.id).filter { prints[$0] != nil }
        let span = Dictionary(tracks.map { ($0.id, ($0.start, $0.end)) }, uniquingKeysWith: { a, _ in a })
        var groups = ids.map { [$0] }
        func together(_ a: Int, _ b: Int) -> Bool {
            guard let x = span[a], let y = span[b] else { return false }
            return min(x.1, y.1) - max(x.0, y.0) > 0
        }
        var pair: [String: Double] = [:]
        func d(_ a: Int, _ b: Int) -> Double {
            let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
            if let v = pair[key] { return v }
            let v = distance(prints[a]!, prints[b]!)
            pair[key] = v
            return v
        }
        while groups.count > 1 {
            var best = (d: Double.infinity, i: -1, j: -1)
            for i in groups.indices {
                for j in (i + 1)..<groups.count {
                    if groups[i].contains(where: { a in groups[j].contains { together(a, $0) } }) { continue }
                    let link = groups[i].reduce(0.0) { s, a in s + groups[j].reduce(0.0) { $0 + d(a, $1) } } / Double(groups[i].count * groups[j].count)
                    if link < best.d { best = (link, i, j) }
                }
            }
            guard best.i >= 0, best.d < threshold else { break }
            groups[best.i] += groups[best.j]
            groups.remove(at: best.j)
        }
        let first = Dictionary(tracks.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        groups.sort { ($0.compactMap { first[$0] }.min() ?? 0) < ($1.compactMap { first[$0] }.min() ?? 0) }
        var out: [Int: Int] = [:]
        for (n, g) in groups.enumerated() { for id in g { out[id] = n } }
        return out
    }
}
