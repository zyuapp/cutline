import AVFoundation
import CutlineCore
import Foundation

/// Liveness of a long render: writer appends, sample reads and progress reports beat it, so a watcher can tell a
/// slow render from a stuck one. Bound per task with `Heartbeat.$current.withValue`.
public final class Heartbeat: @unchecked Sendable {
    @TaskLocal public static var current: Heartbeat?

    private let lock = NSLock()
    private var last = Date()
    private var fraction: Double?

    public init() {}

    public func beat(progress: Double? = nil) {
        lock.withLock {
            last = Date()
            if let progress, progress.isFinite { fraction = max(fraction ?? 0, min(1, progress)) }
        }
    }

    /// Seconds since the last beat.
    public var idle: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
    public var progress: Double? { lock.withLock { fraction } }

    public static func beat() { current?.beat() }
}

/// A writer or reader that stopped making progress.
public struct RenderStalled: LocalizedError, Sendable {
    public var what: String
    public var seconds: Seconds
    public init(_ what: String, seconds: Seconds) {
        self.what = what
        self.seconds = seconds
    }

    public var errorDescription: String? { "\(what) made no progress for \(Int(seconds))s and was stopped" }
}

/// Waits on AVAssetWriter inputs with a no-progress limit, so a writer that stops taking samples fails instead of
/// spinning forever.
public enum WriterWait {
    /// Seconds an input may refuse samples before the write fails (CUTLINE_STALL_SECONDS overrides).
    nonisolated(unsafe) public static var stallLimit: Seconds = ProcessInfo.processInfo.environment["CUTLINE_STALL_SECONDS"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 180

    /// Suspends until `input` takes more data; throws when the writer failed, the task was cancelled or the input
    /// refused data for `limit` seconds. Cancels the writer on a stall.
    public static func ready(_ input: AVAssetWriterInput, _ writer: AVAssetWriter, _ what: String, limit: Seconds = stallLimit) async throws {
        let start = Date()
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? EditError("\(what) failed") }
            if writer.status == .cancelled { throw CancellationError() }
            if Date().timeIntervalSince(start) > limit {
                writer.cancelWriting()
                throw RenderStalled(what, seconds: limit)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Heartbeat.beat()
    }

    /// Removes `tmp-*` files an earlier process left unfinished in a cache folder.
    static func sweepTemporaries(in dir: URL, olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("tmp-") {
            let url = dir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
        }
    }

    /// `ready` for blocking threads.
    public static func readySync(_ input: AVAssetWriterInput, _ writer: AVAssetWriter, _ what: String, cancelled: () -> Bool, limit: Seconds = stallLimit) throws {
        let start = Date()
        while !input.isReadyForMoreMediaData {
            if cancelled() { throw CancellationError() }
            if writer.status == .failed { throw writer.error ?? EditError("\(what) failed") }
            if writer.status == .cancelled { throw CancellationError() }
            if Date().timeIntervalSince(start) > limit {
                writer.cancelWriting()
                throw RenderStalled(what, seconds: limit)
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        Heartbeat.beat()
    }
}

/// Fails `requestMediaDataWhenReady` pumps that stop moving: every append touches it, and when none happens for
/// `limit` seconds (or the task is cancelled) each registered pump resumes with the error and `onTrip` runs once.
public final class StallWatch: @unchecked Sendable {
    let limit: Seconds
    let what: String
    private let lock = NSLock()
    /// Shared by writer calls, so a blocking append never holds up another input's; exclusive while tripping.
    private let writing: UnsafeMutablePointer<pthread_rwlock_t> = {
        let p = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(p, nil)
        return p
    }()
    private var last = Date()
    private var failure: Error?
    private var waiters: [(Error) -> Void] = []
    private var onTrip: (() -> Void)?
    private let timer: DispatchSourceTimer
    let heartbeat = Heartbeat.current

    init(_ what: String, limit: Seconds = WriterWait.stallLimit, onTrip: @escaping () -> Void) {
        self.what = what
        self.limit = limit
        self.onTrip = onTrip
        timer = Watchdog.every(min(0.5, limit / 2)) { _ in }
        timer.setEventHandler { [weak self] in
            guard let self, self.idle > self.limit else { return }
            self.trip(RenderStalled(self.what, seconds: self.limit))
        }
        timer.resume()
    }

    deinit {
        timer.cancel()
        pthread_rwlock_destroy(writing)
        writing.deallocate()
    }

    var idle: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
    var failed: Error? { lock.withLock { failure } }

    func touch() {
        lock.withLock { last = Date() }
        heartbeat?.beat()
    }

    /// Calls `fail` when the watch trips; at once when it already has.
    func register(_ fail: @escaping (Error) -> Void) {
        let already: Error? = lock.withLock {
            if failure == nil { waiters.append(fail) }
            return failure
        }
        if let already { fail(already) }
    }

    /// Runs `body` (a writer call) unless the watch tripped; a trip waits for it, so the writer isn't cancelled
    /// under it. Nil when tripped.
    func live<T>(_ body: () -> T) -> T? {
        pthread_rwlock_rdlock(writing)
        defer { pthread_rwlock_unlock(writing) }
        guard failed == nil else { return nil }
        return body()
    }

    func trip(_ error: Error) {
        var held = false
        let deadline = Date().addingTimeInterval(5)
        while !held, Date() < deadline {
            held = pthread_rwlock_trywrlock(writing) == 0
            if !held { usleep(1000) }
        }
        let (list, action): ([(Error) -> Void], (() -> Void)?) = lock.withLock {
            guard failure == nil else { return ([], nil) }
            failure = error
            defer { waiters = []; onTrip = nil }
            return (waiters, onTrip)
        }
        if held { pthread_rwlock_unlock(writing) }
        action?()
        list.forEach { $0(error) }
    }

    func stop() {
        timer.cancel()
        lock.withLock { waiters = []; onTrip = nil }
    }
}

/// Timers for watchdogs, on GCD rather than the cooperative pool so a pool busy with blocking work can't hold
/// them back.
public enum Watchdog {
    /// A started timer calling `body` every `interval` seconds until cancelled.
    public static func every(_ interval: Seconds, _ body: @escaping @Sendable (DispatchSourceTimer) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let ns = Int(max(0.01, interval) * 1e9)
        t.schedule(deadline: .now() + .nanoseconds(ns), repeating: .nanoseconds(ns))
        t.setEventHandler { [unowned t] in body(t) }
        return t
    }
}

/// Resumes a continuation once, from whichever of its pump or its watch gets there first.
final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }

    var isDone: Bool { lock.withLock { continuation == nil } }

    func resume(_ result: Result<Void, Error>) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}

extension AVAssetReaderOutput {
    /// `copyNextSampleBuffer`, beating the current heartbeat.
    func nextSample() -> CMSampleBuffer? {
        Heartbeat.beat()
        return copyNextSampleBuffer()
    }
}
