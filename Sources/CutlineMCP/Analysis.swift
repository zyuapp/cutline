import CutlineCore
import CutlineEngine
import Foundation

enum Feature: String, CaseIterable {
    case transcript, scenes, beats, speakers, shots, sounds
}

/// Background analysis, mirrored to the bundle's jobs.json so the preview app can show progress.
final class JobBoard: @unchecked Sendable {
    struct Job: Codable {
        var id: String
        var mediaId: String
        var features: [String]
        var status: String
        var progress: Double
        var message: String?
    }

    private let lock = NSLock()
    private var list: [Job] = []
    private var tail: Task<Void, Never>?
    private var bundleURL: URL?

    var all: [Job] { lock.withLock { list } }
    var active: [Job] { all.filter { $0.status == "queued" || $0.status == "running" } }

    /// Queues work after every earlier job, one at a time.
    func enqueue(_ mediaId: String, _ features: [Feature], bundle: URL, _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> String) -> String {
        let id = lock.withLock { () -> String in
            if bundleURL != bundle { list.removeAll(); bundleURL = bundle }
            let id = "job\(list.count + 1)"
            list.append(Job(id: id, mediaId: mediaId, features: features.map(\.rawValue), status: "queued", progress: 0))
            return id
        }
        save()
        let previous = lock.withLock { tail }
        let task = Task.detached { [self] in
            await previous?.value
            update(id) { $0.status = "running" }
            do {
                let note = try await work { p in self.update(id) { $0.progress = p } }
                update(id) { $0.status = "done"; $0.progress = 1; $0.message = note }
            } catch {
                update(id) { $0.status = "failed"; $0.message = error.localizedDescription }
            }
        }
        lock.withLock { tail = task }
        return id
    }

    func update(_ id: String, _ body: (inout Job) -> Void) {
        lock.withLock {
            if let i = list.firstIndex(where: { $0.id == id }) { body(&list[i]) }
        }
        save()
    }

    func save() {
        let (jobs, url) = lock.withLock { (list, bundleURL) }
        guard let url, let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: url.appendingPathComponent("jobs.json"), options: .atomic)
    }

    /// Waits until the queue is empty or the timeout passes.
    func wait(timeout: Seconds) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !active.isEmpty && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    var statusLine: String? {
        let a = active
        guard !a.isEmpty else { return nil }
        return "Analysis running: " + a.map { "\($0.mediaId) \($0.features.joined(separator: "+")) \(Int($0.progress * 100))%" }.joined(separator: ", ")
    }
}

extension Session {
    /// What import analyzes right away; everything else runs in the background.
    static func defaultFeatures(_ m: MediaAsset) -> (now: [Feature], later: [Feature]) {
        var now: [Feature] = [], later: [Feature] = []
        if m.hasAudio { now += [.transcript, .beats, .speakers] }
        if m.hasVideo && !m.isImage { now.append(.scenes); later.append(.shots) }
        if m.isImage { later.append(.shots) }
        if m.hasAudio { later.append(.sounds) }
        return (now, later)
    }

    /// Runs analysis features for one media file and stores the results in the bundle.
    /// Beats run only on music-like media (little speech) unless asked for explicitly.
    func analyze(_ media: MediaAsset, features: [Feature], language: String, explicit: Bool, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let b = try requireBundle()
        var notes: [String] = []
        let want = Set(features)
        var transcript = b.transcript(media.id)
        if media.hasAudio && (want.contains(.transcript) || want.contains(.speakers) && transcript == nil) {
            try FileManager.default.createDirectory(at: b.cacheURL, withIntermediateDirectories: true)
            let pcm = b.cacheURL.appendingPathComponent("\(media.id).caf")
            defer { try? FileManager.default.removeItem(at: pcm) }
            let a = try await AudioAnalyzer.analyze(media: media, pcmURL: pcm)
            try b.saveAudioAnalysis(a)
            let long = a.silences.filter { $0.duration >= 0.5 }
            notes.append("audio: loudness \(String(format: "%.1f", a.loudnessDb)) dB, \(long.count) pauses ≥0.5s totaling \(fmt1(long.map(\.duration).reduce(0, +)))s")
            do {
                let raw = try await Transcriber.transcribe(pcmURL: pcm, mediaId: media.id, locale: language)
                let t = Transcriber.tighten(raw, audio: a)
                try b.saveTranscript(t)
                transcript = t
                notes.append("transcript: \(t.words.count) words, \(t.words.filter(\.isFiller).count) fillers")
            } catch {
                notes.append("transcript failed: \(error.localizedDescription)")
            }
        }
        progress?(0.3)
        let words = transcript?.words.count ?? 0
        let musicLike = media.hasAudio && Double(words) < max(4, media.duration / 6)
        if want.contains(.beats), media.hasAudio, explicit || musicLike {
            let beats = try await BeatTracker.analyze(url: media.url, mediaId: media.id)
            try b.saveAnalysis(beats, media.id, "beats")
            notes.append(beats.beats.isEmpty ? "beats: none found" : "beats: \(Int(beats.tempo.rounded())) BPM, \(beats.beats.count) beats (\(media.id).b0…b\(beats.beats.count - 1)), \(beats.downbeats.count) downbeats")
        }
        progress?(0.45)
        if want.contains(.speakers), let transcript, words >= (explicit ? 1 : 20) {
            let s = try await Diarizer.analyze(url: media.url, transcript: transcript)
            try b.saveAnalysis(s, media.id, "speakers")
            notes.append("speakers: \(s.speakers.count) (\(s.speakers.joined(separator: ", ")))")
        }
        progress?(0.55)
        if want.contains(.scenes), media.hasVideo, !media.isImage {
            let cuts = try await SceneDetector.detect(media)
            try b.saveVisualAnalysis(VisualAnalysis(mediaId: media.id, sceneCuts: cuts))
            notes.append("scenes: \(cuts.count) cuts (shots \(media.id).s0…s\(cuts.count))")
        }
        progress?(0.65)
        notes += try await analyzePerception(media, want, bundle: b, progress: progress)
        built = nil
        return notes.joined(separator: "; ")
    }
}
