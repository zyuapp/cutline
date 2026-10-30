import CutlineCore
import CutlineEngine
import Darwin
import Foundation

/// An exclusive `flock` on a lock file, held until `release` or until the process exits.
final class FileLock: @unchecked Sendable {
    private var fd: Int32

    /// Nil when another holder has it and `wait` is false, or the file can't be opened.
    init?(_ url: URL, wait: Bool) {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else { close(fd); return nil }
        self.fd = fd
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// Background work of one bundle, kept in its jobs.json, which the preview app shows. Jobs run one at a time in a
/// runner that holds the bundle's worker lock: a detached `cutline-mcp --worker <bundle>` process when
/// `workerExecutable` is set, so analysis outlives the server that queued it, else a task in this process.
/// Servers only queue and watch. A job a runner left running when it died is continued by the next runner from the
/// steps it recorded as finished.
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
        /// The process running the job.
        var pid: Int32?
        /// Steps finished so far, which a restarted job skips.
        var done: [String]?
        /// What the finished steps found.
        var notes: [String]?
        /// Transcode jobs: run the default analysis once linked (default true).
        var analyze: Bool?
        /// Processed-picture jobs: the renders to make.
        var keys: [String]?

        init(id: String, mediaId: String, features: [String], status: String, progress: Double, message: String? = nil, language: String? = nil, explicit: Bool? = nil, pid: Int32? = nil, analyze: Bool? = nil, keys: [String]? = nil) {
            self.id = id
            self.mediaId = mediaId
            self.features = features
            self.status = status
            self.progress = progress
            self.message = message
            self.language = language
            self.explicit = explicit
            self.pid = pid
            self.analyze = analyze
            self.keys = keys
        }

        var isPending: Bool { status == "queued" || status == "running" }
    }

    /// What a runner hands the work of one job.
    struct Context: Sendable {
        var job: Job
        /// Overall progress 0…1; never moves backwards.
        var progress: @Sendable (Double) -> Void
        /// Records a finished step and what it found, so a restart skips it.
        var finished: @Sendable (_ step: String, _ notes: [String]) -> Void
    }

    typealias Work = @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// The work for a job, or nil when it can't run (its media is gone).
    typealias Factory = (Context) -> (@Sendable () async throws -> String)?

    /// Set by the cutline-mcp executable: jobs run in a detached worker process started from it.
    nonisolated(unsafe) static var workerExecutable: URL?

    private let lock = NSLock()
    private(set) var bundleURL: URL?
    var factory: Factory?
    let pid = ProcessInfo.processInfo.processIdentifier
    private var lastHeal = Date.distantPast

    var workerLockURL: URL? { bundleURL?.appendingPathComponent(".worker.lock") }

    var all: [Job] { read() }
    /// Jobs queued or running for this bundle, whichever process runs them.
    var active: [Job] {
        let jobs = read().filter(\.isPending)
        if !jobs.isEmpty { heal() }
        return jobs
    }

    /// Points the board at a bundle and starts a runner for work left pending there. Returns those jobs.
    @discardableResult
    func attach(_ bundle: URL, run: Bool = true) -> [Job] {
        lock.withLock { bundleURL = bundle }
        let pending = read().filter(\.isPending)
        if run, !pending.isEmpty { ensureRunner() }
        return pending
    }

    /// Queues work; a runner picks it up after every earlier job.
    func enqueue(_ mediaId: String, _ features: [Feature], bundle: URL, language: String = "en-US", explicit: Bool = false) -> String {
        enqueue(mediaId, named: features.map(\.rawValue), bundle: bundle, language: language, explicit: explicit)
    }

    /// `enqueue` for work other than analysis features, such as "transcode".
    func enqueue(_ mediaId: String, named features: [String], bundle: URL, language: String = "en-US", explicit: Bool = false, analyze: Bool? = nil, keys: [String]? = nil) -> String {
        if lock.withLock({ bundleURL }) != bundle { attach(bundle, run: false) }
        let id = mutate { list -> String in
            let id = "job\((list.compactMap { Int($0.id.dropFirst(3)) }.max() ?? 0) + 1)"
            list.append(Job(id: id, mediaId: mediaId, features: features, status: "queued", progress: 0, language: language, explicit: explicit, analyze: analyze, keys: keys))
            return id
        }
        ensureRunner()
        return id
    }

    func update(_ id: String, in bundle: URL? = nil, _ body: (inout Job) -> Void) {
        mutate(bundle) { list in if let i = list.firstIndex(where: { $0.id == id }) { body(&list[i]) } }
    }

    /// Waits until pending jobs (of `mediaId` when given) finish or the timeout passes; false on timeout.
    @discardableResult
    func wait(timeout: Seconds, mediaId: String? = nil) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        func pending() -> Bool { active.contains { mediaId == nil || $0.mediaId == mediaId } }
        while pending() && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
        return !pending()
    }

    var statusLine: String? {
        let a = active
        guard !a.isEmpty else { return nil }
        return "Analysis running: " + a.map { "\($0.mediaId) \($0.features.joined(separator: "+")) \(Int($0.progress * 100))%" }.joined(separator: ", ")
    }

    // MARK: jobs.json

    /// The jobs of `bundle`, default the attached one.
    private func read(_ bundle: URL? = nil) -> [Job] {
        guard let url = bundle ?? bundleURL else { return [] }
        return (try? JSONDecoder().decode([Job].self, from: Data(contentsOf: url.appendingPathComponent("jobs.json")))) ?? []
    }

    /// Changes jobs.json under the bundle's jobs lock, so servers and the worker never lose each other's writes.
    @discardableResult
    func mutate<T>(_ bundle: URL? = nil, _ body: (inout [Job]) -> T) -> T {
        lock.withLock {
            let url = bundle ?? bundleURL
            let held = url.flatMap { FileLock($0.appendingPathComponent(".jobs.lock"), wait: true) }
            defer { held?.release() }
            var list = read(url)
            let before = list
            let out = body(&list)
            if list != before, let url, let data = try? JSONEncoder().encode(list) { try? data.write(to: url.appendingPathComponent("jobs.json"), options: .atomic) }
            return out
        }
    }

    // MARK: Runner

    /// Starts a runner unless one holds the worker lock.
    func ensureRunner() {
        guard let lockURL = workerLockURL, let bundle = bundleURL, read().contains(where: \.isPending) else { return }
        guard let probe = FileLock(lockURL, wait: false) else { return }
        if let exe = JobBoard.workerExecutable {
            probe.release()
            JobBoard.spawnWorker(exe, bundle: bundle)
        } else {
            Task.detached { [self] in await drain(holding: probe, bundle: bundle) }
        }
    }

    /// Restarts a runner that died with work pending; checked at most every few seconds.
    private func heal() {
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastHeal) > 3 else { return false }
            lastHeal = Date()
            return true
        }
        if due { ensureRunner() }
    }

    /// Runs pending jobs one at a time while holding the worker lock, lingering briefly for new ones, then
    /// releases the lock (under the jobs lock, so a job queued meanwhile always finds a runner).
    func drain(holding runner: FileLock, bundle: URL, linger: Seconds = 2) async {
        var idle = Date()
        while true {
            let stop = Date().timeIntervalSince(idle) >= linger
            guard let job = claimNext(bundle, releasingIfIdle: stop ? runner : nil) else {
                if stop { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            await run(job, bundle)
            idle = Date()
        }
    }

    /// The next queued job, or one a dead runner left running, marked as ours.
    private func claimNext(_ bundle: URL, releasingIfIdle runner: FileLock?) -> Job? {
        mutate(bundle) { list -> Job? in
            guard let i = list.firstIndex(where: { $0.status == "running" }) ?? list.firstIndex(where: { $0.status == "queued" }) else {
                runner?.release()
                return nil
            }
            if list[i].status == "running" { list[i].message = "continuing after the previous runner stopped" + (list[i].done.map { $0.isEmpty ? "" : " (done: \($0.joined(separator: ", ")))" } ?? "") }
            list[i].status = "running"
            list[i].pid = pid
            return list[i]
        }
    }

    private func run(_ job: Job, _ bundle: URL) async {
        let id = job.id
        let throttle = Throttle(start: job.progress)
        let context = Context(job: job, progress: { [self] p in
            guard let v = throttle.next(p) else { return }
            update(id, in: bundle) { $0.progress = max($0.progress, v) }
        }, finished: { [self] step, notes in
            update(id, in: bundle) { j in
                j.done = (j.done ?? []) + [step]
                j.notes = (j.notes ?? []) + notes
            }
        })
        guard let work = factory?(context) else {
            update(id, in: bundle) { $0.status = "failed"; $0.message = "media \(job.mediaId) is no longer in the project" }
            return
        }
        do {
            let note = try await work()
            update(id, in: bundle) { $0.status = "done"; $0.progress = 1; $0.message = note }
        } catch {
            update(id, in: bundle) { $0.status = "failed"; $0.message = error.localizedDescription }
        }
    }

    /// Starts `cutline-mcp --worker <bundle>` in its own session, detached from the server's stdio, so it keeps
    /// running when the server exits. Its stderr goes to the bundle's cache/worker.log.
    @discardableResult
    static func spawnWorker(_ exe: URL, bundle: URL) -> Bool {
        let log = bundle.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, log.appendingPathComponent("worker.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let args = [exe.path, "--worker", bundle.path]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        guard posix_spawn(&child, exe.path, &actions, &attr, &argv, environ) == 0 else { return false }
        // Reap it if it finishes while this server still runs; after the server exits launchd does.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        return true
    }
}

/// Lets through progress values a percent apart or a second apart.
private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double
    private var at = Date.distantPast

    init(start: Double) { last = start }

    func next(_ p: Double) -> Double? {
        lock.withLock {
            guard p > last + 1e-9, p - last >= 0.01 || Date().timeIntervalSince(at) >= 1 || p >= 1 else { return nil }
            last = p
            at = Date()
            return p
        }
    }
}

/// `cutline-mcp --worker <bundle>`: runs the bundle's pending jobs, then exits.
public enum AnalysisWorker {
    public static func run(bundle path: String) async -> Int32 {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard ProjectBundle.isBundle(url) else {
            FileHandle.standardError.write(Data("No Cutline project at \(path)\n".utf8))
            return 2
        }
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let session = Session()
        session.bundle = ProjectBundle(url: url)
        session.jobs.attach(url, run: false)
        guard let lockURL = session.jobs.workerLockURL, let held = FileLock(lockURL, wait: false) else { return 0 }
        await session.jobs.drain(holding: held, bundle: url, linger: 3)
        return 0
    }
}

extension Session {
    /// Rebuilds a queued job's work from what jobs.json records about it.
    func work(for ctx: JobBoard.Context) -> (@Sendable () async throws -> String)? {
        let job = ctx.job
        guard let b = bundle, let p = try? b.loadProject(), let m = p.mediaAsset(job.mediaId) else { return nil }
        let language = job.language ?? "en-US"
        if job.features == [Session.transcodeJob] {
            guard m.isTranscoding else { return { "\(m.id) is already linked to its mezzanine" } }
            let work = transcodeWork(m, info: nil, language: language, analyze: job.analyze ?? true)
            return { try await work(ctx.progress) }
        }
        if job.features == [Session.pictureJob] {
            let requests = ProcessedPicture.requests(p, cuts: Session.sceneCuts(p, b)).filter { $0.media.id == job.mediaId && ProcessedPicture.cached($0) == nil && (job.keys?.contains($0.key) ?? true) }
            guard !requests.isEmpty else { return { "nothing left to render" } }
            let work = pictureWork(requests)
            return { try await work(ctx.progress) }
        }
        let done = Set(job.done ?? [])
        let all = job.features.compactMap(Feature.init(rawValue:))
        let features = all.filter { !done.contains($0.rawValue) }
        guard !all.isEmpty else { return nil }
        let explicit = job.explicit ?? (Set(all) != Set(Session.defaultFeatures(m).later))
        let earlier = job.notes ?? []
        return { [self] in
            guard !features.isEmpty else { return earlier.joined(separator: "; ") }
            let notes = try await analyze(m, features: features, language: language, explicit: explicit, progress: ctx.progress, finished: ctx.finished)
            return (earlier + [notes]).filter { !$0.isEmpty }.joined(separator: "; ")
        }
    }

    /// Points the job board at the opened bundle; a runner continues whatever an exited server or worker left.
    @discardableResult
    func resumeJobs(_ b: ProjectBundle) -> [String] {
        jobs.attach(b.url).map { "\($0.id) \($0.mediaId) \($0.features.joined(separator: "+"))" + ($0.status == "running" ? " \(Int($0.progress * 100))%" : "") }
    }
}
