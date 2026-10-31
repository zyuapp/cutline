import CutlineCore
import CutlineEngine
import Foundation

/// Renders of this server process: `background:true` exports run here while other calls go on. Every render,
/// background or not, is stopped when its heartbeat stays still past `stallLimit`.
final class RenderJobs: @unchecked Sendable {
    final class Job: @unchecked Sendable {
        let id: String
        let label: String
        let started = Date()
        let heartbeat = Heartbeat()
        fileprivate(set) var status = "running"
        fileprivate(set) var report: String?
        fileprivate(set) var ended: Date?
        fileprivate var task: Task<Void, Never>?

        init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        var isRunning: Bool { status == "running" }
    }

    /// Seconds a render may go without progress before it is stopped (CUTLINE_RENDER_STALL_SECONDS overrides).
    nonisolated(unsafe) static var stallLimit: Seconds = ProcessInfo.processInfo.environment["CUTLINE_RENDER_STALL_SECONDS"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 240

    private let lock = NSLock()
    private var list: [Job] = []
    private var counter = 0

    var all: [Job] { lock.withLock { list } }
    var running: [Job] { all.filter(\.isRunning) }

    /// Starts `work` detached from the calling task; its result or error becomes the job's report.
    func start(_ label: String, limit: Seconds = RenderJobs.stallLimit, _ work: @escaping @Sendable () async throws -> String) -> Job {
        let job = lock.withLock { () -> Job in
            counter += 1
            let j = Job(id: "render\(counter)", label: label)
            list.append(j)
            return j
        }
        job.task = Task.detached { [self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await RenderJobs.watched(label, limit: limit, heartbeat: job.heartbeat, work))
            } catch {
                outcome = .failure(error)
            }
            finish(job, outcome)
        }
        return job
    }

    private func finish(_ job: Job, _ outcome: Result<String, Error>) {
        lock.withLock {
            guard job.status == "running" else { return }
            switch outcome {
            case .success(let text):
                job.status = "done"
                job.report = text
            case .failure(let error):
                job.status = error is CancellationError ? "cancelled" : error is RenderStalled ? "stalled" : "failed"
                job.report = error is CancellationError ? "Cancelled; its partial output is removed." : error.localizedDescription
            }
            job.ended = Date()
        }
    }

    /// Cancels a running render; its partial output is removed.
    func cancel(_ id: String) throws -> String {
        guard let job = all.first(where: { $0.id == id }) else {
            let known = all.map(\.id)
            throw EditError("No render job \(id)" + (known.isEmpty ? "" : " (jobs: \(known.joined(separator: ", ")))"))
        }
        guard job.isRunning else { return "\(id) already \(job.status)." }
        job.task?.cancel()
        finish(job, .failure(CancellationError()))
        return "Cancelled \(id) (\(job.label))."
    }

    func line(_ j: Job) -> String {
        let took = Int((j.ended ?? Date()).timeIntervalSince(j.started))
        var s = "  \(j.id) \(j.label): \(j.status)"
        if j.isRunning { s += j.heartbeat.progress.map { " \(Int($0 * 100))%" } ?? "" }
        s += " (\(took)s)"
        if j.isRunning { s += " — cancel with analysis_read cancel:\"\(j.id)\"" }
        return s
    }

    /// Render jobs, with the reports of finished ones when `reports`.
    func lines(reports: Bool) -> [String] {
        let jobs = all
        guard !jobs.isEmpty else { return [] }
        var out = ["Renders:"]
        for j in jobs {
            out.append(line(j))
            if reports, let r = j.report { out += r.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 } }
        }
        return out
    }

    /// Waits until no render runs or `timeout` passes; false on timeout.
    func wait(timeout: Seconds) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !running.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        return running.isEmpty
    }

    var statusLine: String? {
        let r = running
        guard !r.isEmpty else { return nil }
        return "Rendering: " + r.map { "\($0.id) \($0.heartbeat.progress.map { "\(Int($0 * 100))%" } ?? "starting")" }.joined(separator: ", ")
    }

    /// Runs `work` with `heartbeat` bound; when the heartbeat stays still for `limit` seconds the work is cancelled
    /// and this throws at once, even if the work never returns.
    static func watched<T>(_ what: String, limit: Seconds = stallLimit, heartbeat: Heartbeat = Heartbeat(), _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = ResultGate<T>()
        let task = Task.detached {
            let r: Result<T, Error>
            do { r = .success(try await Heartbeat.$current.withValue(heartbeat) { try await work() }) } catch { r = .failure(error) }
            gate.resume(r)
        }
        heartbeat.beat()
        let watcher = Watchdog.every(min(0.25, limit / 2)) { timer in
            if gate.isDone { timer.cancel(); return }
            if heartbeat.idle > limit {
                task.cancel()
                gate.resume(.failure(RenderStalled(what, seconds: limit)))
                timer.cancel()
            }
        }
        watcher.resume()
        defer { watcher.cancel() }
        return try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            task.cancel()
            gate.resume(.failure(CancellationError()))
        }
    }
}

/// A result delivered once, to one waiter, whichever side gets there first.
private final class ResultGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    var isDone: Bool { lock.withLock { result != nil } }

    func resume(_ r: Result<T, Error>) {
        let w: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = r
            defer { waiter = nil }
            return waiter
        }
        w?.resume(with: r)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            let ready: Result<T, Error>? = lock.withLock {
                if result == nil { waiter = c }
                return result
            }
            if let ready { c.resume(with: ready) }
        }
    }
}

extension Toolbox {
    /// Runs a render tool's body under the no-progress limit, or with `background:true` in a job on a separate
    /// toolbox over the same bundle (so it never shares this session's caches) and returns its id at once.
    func rendering(_ tool: String, _ args: Args, _ body: @escaping (Args) async throws -> ToolResult) async throws -> ToolResult {
        guard args.bool("background", default: false) else {
            // The closure keeps this toolbox alive while an abandoned (stalled or cancelled) render winds down.
            nonisolated(unsafe) let run = body, keep = self
            return try await RenderJobs.watched(tool, heartbeat: Heartbeat.current ?? Heartbeat()) {
                defer { withExtendedLifetime(keep) {} }
                return try await run(args)
            }
        }
        let b = try session.requireBundle()
        if args.raw["variants"]?.array?.isEmpty == false { throw EditError("variants edit the project while they render, so they run in the foreground; drop background") }
        var given = args.raw
        given["background"] = nil
        let label = tool + (given["deliver"]?.string.map { " " + $0 } ?? "") + (given["path"]?.string.map { " " + URL(fileURLWithPath: $0).lastPathComponent } ?? "")
        let worker = Toolbox()
        worker.session.bundle = ProjectBundle(url: b.url)
        let call = JSON.object(given)
        let job = session.renders.start(label) {
            let r = await worker.call(tool, call)
            if r.isError { throw EditError(r.plainText.hasPrefix("Error: ") ? String(r.plainText.dropFirst(7)) : r.plainText) }
            return r.plainText
        }
        return .text("Started \(job.id): \(label), in the background. analysis_read what:\"jobs\" (or project_status) shows its progress and, when done, its report; analysis_read cancel:\"\(job.id)\" stops it.")
    }
}
