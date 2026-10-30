import AVFoundation
import CutlineCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum VisionAnalyzer {
    public static let maxShotLength: Seconds = 8
    static let sampleSize = CGSize(width: 512, height: 512)
    static let detailSize = CGSize(width: 1024, height: 1024)
    static let concurrency = 4
    static let genericLabels: Set<String> = ["structure", "outdoor", "indoor", "material", "textile", "liquid", "consumer electronics", "machine", "wood processed", "document"]

    struct Sample: Codable {
        var t: Seconds
        var faces: [NormRect]
        var bodies: [NormRect]
        var luma: [UInt8]
    }

    struct Details: Codable {
        var labels: [String] = []
        var text: [String] = []
        var aesthetics: Double?
        var utility: Bool?
        var saliency: NormRect?
        var featurePrint: [Float]?
    }

    /// Describes each shot (spans between `sceneCuts`, split to at most 8 s) and follows faces across samples.
    /// Still images yield one shot covering `duration`.
    /// Frames sampled and described so far, saved after every segment so a restarted analysis continues from them.
    struct Partial: Codable {
        struct Described: Codable {
            var requested: Seconds
            var sample: Sample
            var details: Details
        }

        var key: String
        var gridDone: [Seconds] = []
        var samples: [Sample] = []
        var described: [Described] = []
    }

    /// Frames per checkpointed segment.
    static let segment = 40

    /// With `checkpoint`, finished segments are saved there and a later call with the same arguments skips them;
    /// the file is removed once the analysis completes.
    public static func analyze(url: URL, mediaId: String, sceneCuts: [Seconds], duration: Seconds, samplesPerSecond: Double = 2, checkpoint: URL? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ShotAnalysis {
        let rate = max(0.1, samplesPerSecond)
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: detailSize.width, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { throw EditError("Cannot read \(url.path)") }
            let sample = detect(img, t: 0)
            let shot = makeShot(index: 0, span: TimeRange(0, max(duration, 0)), samples: [sample], details: describe(img))
            progress?(1)
            return ShotAnalysis(mediaId: mediaId, shots: [shot], faces: [], samplesPerSecond: rate)
        }

        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw EditError("\(mediaId) has no video") }
        let cuts = sceneCuts.filter { $0 > 0 && $0 < duration }.sorted()
        let spans = Shot.spans(cuts: cuts, duration: duration, maxLength: maxShotLength)
        let last = max(0, duration - 0.05)
        let grid = Array(Set(stride(from: 0.5 / rate, to: duration, by: 1 / rate).map { min($0, last) })).sorted()
        let total = Double(grid.count + spans.count)
        let key = "\(mediaId) \(duration) \(rate) \(cuts)"
        var partial = checkpoint.flatMap { try? JSONDecoder().decode(Partial.self, from: Data(contentsOf: $0)) }.flatMap { $0.key == key ? $0 : nil } ?? Partial(key: key)
        func save() {
            guard let checkpoint else { return }
            try? FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(partial).write(to: checkpoint, options: .atomic)
        }
        let counter = Counter()
        for _ in 0..<(partial.gridDone.count + partial.described.count) { _ = counter.increment() }

        let gridGen = AVAssetImageGenerator(asset: asset)
        gridGen.appliesPreferredTrackTransform = true
        gridGen.maximumSize = sampleSize
        let tolerance = CMTime(seconds: min(0.5 / rate, 0.25), preferredTimescale: 600)
        gridGen.requestedTimeToleranceBefore = tolerance
        gridGen.requestedTimeToleranceAfter = tolerance
        let gridDone = Set(partial.gridDone)
        let gridTodo = grid.filter { !gridDone.contains($0) }
        for lo in stride(from: 0, to: gridTodo.count, by: segment) {
            try Task.checkCancellation()
            let times = Array(gridTodo[lo..<min(gridTodo.count, lo + segment)])
            let found = try await process(gridGen, times: times) { img, t in
                let s = detect(img, t: t)
                progress?(counter.increment() / total)
                return s
            }
            partial.samples += found.map(\.value)
            partial.gridDone += times
            save()
        }
        var samples = partial.samples

        let detailGen = AVAssetImageGenerator(asset: asset)
        detailGen.appliesPreferredTrackTransform = true
        detailGen.maximumSize = detailSize
        detailGen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        detailGen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let middles = spans.map { min(($0.start + $0.end) / 2, last) }
        let describedDone = Set(partial.described.map(\.requested))
        let middlesTodo = Array(Set(middles.filter { !describedDone.contains($0) })).sorted()
        for lo in stride(from: 0, to: middlesTodo.count, by: segment) {
            try Task.checkCancellation()
            let found = try await process(detailGen, times: Array(middlesTodo[lo..<min(middlesTodo.count, lo + segment)])) { img, t in
                let r = (detect(img, t: t), describe(img))
                progress?(counter.increment() / total)
                return r
            }
            partial.described += found.map { Partial.Described(requested: $0.requested, sample: $0.value.0, details: $0.value.1) }
            save()
        }
        samples += partial.described.map(\.sample)
        samples.sort { $0.t < $1.t }

        let details = Dictionary(partial.described.map { ($0.requested, $0.details) }, uniquingKeysWith: { a, _ in a })
        if let checkpoint { try? FileManager.default.removeItem(at: checkpoint) }
        let shots = spans.enumerated().map { i, span in
            let inside = samples.filter { span.start <= $0.t && $0.t < span.end || (i == spans.count - 1 && $0.t >= span.end) }
            return makeShot(index: i, span: span, samples: inside, details: details[middles[i]] ?? Details())
        }
        let faces = FaceTrack.link(samples.map { (t: $0.t, boxes: $0.faces) }, cuts: cuts)
        return ShotAnalysis(mediaId: mediaId, shots: shots, faces: faces, samplesPerSecond: rate)
    }

    /// Generates frames and runs `work` on up to `concurrency` of them at once while decoding continues.
    static func process<T: Sendable>(_ gen: AVAssetImageGenerator, times: [Seconds], work: @escaping @Sendable (CGImage, Seconds) -> T) async throws -> [(requested: Seconds, value: T)] {
        guard !times.isEmpty else { return [] }
        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        return try await withThrowingTaskGroup(of: (Seconds, T).self) { group in
            var out: [(requested: Seconds, value: T)] = []
            var inflight = 0
            for await result in gen.images(for: cmTimes) {
                try Task.checkCancellation()
                guard let img = try? result.image else { continue }
                let requested = times[cmTimes.firstIndex(of: result.requestedTime) ?? 0]
                let actual = (try? result.actualTime.seconds).flatMap { $0.isFinite ? $0 : nil } ?? result.requestedTime.seconds
                if inflight >= concurrency, let r = try await group.next() {
                    out.append(r)
                    inflight -= 1
                }
                // Vision blocks its calling thread; run it off the cooperative pool so other tasks keep moving.
                group.addTask { (requested, try await runBlocking { _ in work(img, actual) }) }
                inflight += 1
            }
            for try await r in group { out.append(r) }
            return out.sorted { $0.requested < $1.requested }
        }
    }

    static func makeShot(index: Int, span: TimeRange, samples: [Sample], details: Details) -> Shot {
        let people = samples.map { max($0.faces.count, $0.bodies.count) }.max() ?? 0
        let faceHeights = samples.compactMap { $0.faces.map(\.height).max() }
        let bodyHeights = samples.compactMap { $0.bodies.map(\.height).max() }
        let size = Shot.size(faceHeight: median(faceHeights), bodyHeight: median(bodyHeights))
        let lumas = samples.map(\.luma).filter { !$0.isEmpty }
        let brightness = lumas.isEmpty ? 0 : lumas.map { Double($0.reduce(0) { $0 + Int($1) }) / Double($0.count) / 255 }.reduce(0, +) / Double(lumas.count)
        var diffs: [Double] = []
        for (a, b) in zip(lumas, lumas.dropFirst()) where a.count == b.count {
            var sum = 0
            for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
            diffs.append(Double(sum) / Double(a.count))
        }
        let motion = diffs.isEmpty ? 0 : min(1, diffs.reduce(0, +) / Double(diffs.count) / 64)
        return Shot(index: index, start: round(span.start, 3), end: round(span.end, 3), labels: details.labels, size: size, people: people, text: details.text, aesthetics: details.aesthetics.map { round($0, 3) }, utility: details.utility, brightness: round(brightness, 3), motion: round(motion, 3), saliency: details.saliency, featurePrint: details.featurePrint)
    }

    /// Faces, full bodies and a coarse luma grid of one frame.
    static func detect(_ img: CGImage, t: Seconds) -> Sample {
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        try? VNImageRequestHandler(cgImage: img).perform([faces, humans])
        return Sample(
            t: round(t, 3),
            faces: (faces.results ?? []).map { rect($0.boundingBox) },
            bodies: (humans.results ?? []).filter { $0.confidence > 0.3 }.map { rect($0.boundingBox) },
            luma: SceneDetector.luma(img)
        )
    }

    /// Classification, text, saliency, feature print and aesthetics of one frame.
    static func describe(_ img: CGImage) -> Details {
        let handler = VNImageRequestHandler(cgImage: img)
        var d = Details()

        let classify = VNClassifyImageRequest()
        if (try? handler.perform([classify])) != nil {
            let named = (classify.results ?? []).filter { $0.confidence > 0.3 }
                .sorted { $0.confidence > $1.confidence }
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            let specific = named.filter { !genericLabels.contains($0) }
            d.labels = Array((specific.isEmpty ? named : specific).prefix(6))
        }

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        if (try? handler.perform([text])) != nil {
            var seen = Set<String>()
            for obs in text.results ?? [] {
                guard let c = obs.topCandidates(1).first, c.confidence >= 0.5 else { continue }
                let line = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count >= 2,
                      seen.insert(line.lowercased()).inserted else { continue }
                d.text.append(line)
                if d.text.count == 5 { break }
            }
        }

        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([saliency])) != nil, let objects = saliency.results?.first?.salientObjects, let first = objects.first {
            let u = objects.dropFirst().reduce(rect(first.boundingBox)) { $0.union(rect($1.boundingBox)) }
            d.saliency = NormRect(x: round(u.x, 4), y: round(u.y, 4), width: round(u.width, 4), height: round(u.height, 4))
        }

        let print = VNGenerateImageFeaturePrintRequest()
        if (try? handler.perform([print])) != nil, let obs = print.results?.first {
            d.featurePrint = floats(obs)
        }

        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        if (try? handler.perform([aesthetics])) != nil, let obs = aesthetics.results?.first {
            d.aesthetics = Double(obs.overallScore)
            d.utility = obs.isUtility
        }
        return d
    }

    static func floats(_ obs: VNFeaturePrintObservation) -> [Float] {
        let n = obs.elementCount
        return obs.data.withUnsafeBytes { raw in
            switch obs.elementType {
            case .float: return Array(raw.bindMemory(to: Float.self).prefix(n))
            case .double: return raw.bindMemory(to: Double.self).prefix(n).map { Float($0) }
            default: return []
            }
        }
    }

    /// Vision's bottom-left normalized box as a top-left `NormRect`.
    static func rect(_ b: CGRect) -> NormRect {
        NormRect(x: Double(b.minX), y: Double(1 - b.maxY), width: Double(b.width), height: Double(b.height))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    static func round(_ v: Double, _ places: Int) -> Double {
        let p = pow(10, Double(places))
        return (v * p).rounded() / p
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0.0

        func increment() -> Double {
            lock.lock()
            defer { lock.unlock() }
            n += 1
            return n
        }
    }
}
