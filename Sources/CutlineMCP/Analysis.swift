import CutlineCore
import CutlineEngine
import Foundation

enum Feature: String, CaseIterable {
    case transcript, scenes, beats, speakers, shots, sounds, proxy
}

/// Background analysis, mirrored to the bundle's jobs.json so the preview app can show progress and a
/// later server can resume work an exited one left queued or running.
final class JobBoard: @unchecked Sendable {
    struct Job: Codable, Equatable {
        var id: String
        var mediaId: String
        var features: [String]
        var status: String
        var progress: Double
        var message: String?
        /// Speech language for transcript work.
        var language: String?
        var explicit: Bool?
        /// The server process running the job.
        var pid: Int32?

        var isPending: Bool { status == "queued" || status == "running" }
    }

    typealias Work = @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> String

    private let lock = NSLock()
    private var list: [Job] = []
    private var tail: Task<Void, Never>?
    private(set) var bundleURL: URL?
    let pid = ProcessInfo.processInfo.processIdentifier

    var all: [Job] { lock.withLock { list } }
    /// Pending jobs this process runs; ones another live server owns are listed but not waited on.
    var active: [Job] { all.filter { $0.isPending && ($0.pid == nil || $0.pid == pid) } }

    /// Queues work after every earlier job, one at a time.
    func enqueue(_ mediaId: String, _ features: [Feature], bundle: URL, language: String = "en-US", explicit: Bool = false, _ work: @escaping Work) -> String {
        let id = lock.withLock { () -> String in
            if bundleURL != bundle { list.removeAll(); bundleURL = bundle }
            let id = "job\((list.compactMap { Int($0.id.dropFirst(3)) }.max() ?? 0) + 1)"
            list.append(Job(id: id, mediaId: mediaId, features: features.map(\.rawValue), status: "queued", progress: 0, language: language, explicit: explicit, pid: pid))
            return id
        }
        save()
        schedule(id, work)
        return id
    }

    private func schedule(_ id: String, _ work: @escaping Work) {
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
    }

    /// Loads a bundle's jobs.json and claims every pending job whose server has exited, returning them to
    /// run again. Jobs of a live server stay as they are.
    func restore(bundle: URL, alive: (Int32) -> Bool = JobBoard.isAlive) -> [Job] {
        let file = bundle.appendingPathComponent("jobs.json")
        let saved = (try? JSONDecoder().decode([Job].self, from: Data(contentsOf: file))) ?? []
        let claimed = lock.withLock { () -> [Job] in
            guard bundleURL != bundle || !list.contains(where: { $0.isPending && $0.pid == pid }) else { return [] }
            bundleURL = bundle
            list = saved
            var out: [Job] = []
            for i in list.indices where list[i].isPending {
                if let owner = list[i].pid, owner != pid, alive(owner) { continue }
                list[i].status = "queued"
                list[i].progress = 0
                list[i].pid = pid
                list[i].message = "resumed after the previous server exited"
                out.append(list[i])
            }
            return out
        }
        save()
        return claimed
    }

    /// Runs a restored job under its own id.
    func resume(_ job: Job, _ work: @escaping Work) {
        schedule(job.id, work)
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

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

    /// Waits until this process's pending jobs (for `mediaId` when given) finish or the timeout passes;
    /// false on timeout.
    @discardableResult
    func wait(timeout: Seconds, mediaId: String? = nil) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        func pending() -> Bool { active.contains { mediaId == nil || $0.mediaId == mediaId } }
        while pending() && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        return !pending()
    }

    var statusLine: String? {
        let a = active
        guard !a.isEmpty else { return nil }
        return "Analysis running: " + a.map { "\($0.mediaId) \($0.features.joined(separator: "+")) \(Int($0.progress * 100))%" }.joined(separator: ", ")
    }
}

extension Session {
    /// Re-queues analysis an exited server left unfinished in this bundle.
    @discardableResult
    func resumeJobs(_ b: ProjectBundle) -> [String] {
        let claimed = jobs.restore(bundle: b.url)
        guard !claimed.isEmpty, let p = try? b.loadProject() else { return [] }
        var out: [String] = []
        for job in claimed {
            let features = job.features.compactMap(Feature.init(rawValue:))
            guard let m = p.mediaAsset(job.mediaId), !features.isEmpty else {
                jobs.update(job.id) { $0.status = "failed"; $0.message = "media \(job.mediaId) is no longer in the project" }
                continue
            }
            let language = job.language ?? "en-US"
            let explicit = job.explicit ?? (Set(features) != Set(Session.defaultFeatures(m).later))
            jobs.resume(job) { [self] progress in
                try await analyze(m, features: features, language: language, explicit: explicit, progress: progress)
            }
            out.append("\(job.id) \(job.mediaId) \(job.features.joined(separator: "+"))")
        }
        return out
    }
}

extension Session {
    /// What import analyzes right away; everything else runs in the background.
    static func defaultFeatures(_ m: MediaAsset) -> (now: [Feature], later: [Feature]) {
        var now: [Feature] = [], later: [Feature] = []
        if m.hasAudio { now += [.transcript, .beats, .speakers] }
        if m.hasVideo && !m.isImage { now.append(.scenes); later += [.proxy, .shots] }
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
