import AVFoundation
import CoreAudio
import CutlineCore
import Foundation

public enum HostClock {
    /// Host-clock seconds, the clock audio timestamps and `AVPlayer.setRate(_:time:atHostTime:)` use.
    public static var now: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

/// A sound source recorded as the microphone. `deliver` gets mono samples and the host time the input stamped
/// on the first of them; that stamp is `latency` later than when the sound reached the input.
public protocol RecordingInput: AnyObject {
    var deviceName: String { get }
    /// Valid once started.
    var sampleRate: Double { get }
    var latency: Seconds { get }
    func start(_ deliver: @escaping ([Float], Double) -> Void) throws
    /// When the program starts rolling; a test input starts its sound then.
    func soundStarts(at host: Double)
    func stop()
}

public extension RecordingInput {
    func soundStarts(at host: Double) {}
}

/// The default input device through AVAudioEngine, first channel.
public final class MicrophoneInput: RecordingInput {
    private let engine = AVAudioEngine()
    public let deviceName: String
    public private(set) var sampleRate: Double = 48_000
    public private(set) var latency: Seconds = 0

    public init() {
        deviceName = AudioDevices.defaultDevice(input: true).flatMap(AudioDevices.name) ?? "Default input"
    }

    public func start(_ deliver: @escaping ([Float], Double) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw EditError("No microphone input is available. Connect one or choose it in System Settings › Sound › Input.")
        }
        sampleRate = format.sampleRate
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: data[0], count: n))
            let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : HostClock.now - Double(n) / rate
            deliver(samples, host)
        }
        engine.prepare()
        try engine.start()
        latency = input.presentationLatency > 0 ? input.presentationLatency : (AudioDevices.defaultDevice(input: true).flatMap { AudioDevices.latency($0, input: true) } ?? 0)
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// A sound file played in real time as if a microphone heard it, starting when the program rolls, with
/// timestamps `latency` late like a real input's. Before and after the file it delivers silence.
public final class FileInput: RecordingInput {
    public let deviceName: String
    public let sampleRate: Double
    public let latency: Seconds
    private let samples: [Float]
    private let queue = DispatchQueue(label: "cutline.voiceover.file-input", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var soundStart: Double?
    private var startHost = 0.0
    private var emitted = 0

    public init(url: URL, latency: Seconds = 0) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw EditError("Can't read the test input \(url.path): \(error.localizedDescription)") }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw EditError("Can't read the test input \(url.path)") }
        try file.read(into: buffer)
        samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        sampleRate = format.sampleRate
        self.latency = latency
        deviceName = "Test input \(url.lastPathComponent)"
    }

    public func start(_ deliver: @escaping ([Float], Double) -> Void) throws {
        startHost = HostClock.now
        emitted = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let target = Int((HostClock.now - self.startHost) * self.sampleRate)
            guard target > self.emitted else { return }
            self.lock.lock()
            let offset = self.soundStart.map { Int((($0 - self.startHost) * self.sampleRate).rounded()) }
            self.lock.unlock()
            let chunk = (self.emitted..<target).map { k -> Float in
                guard let offset, self.samples.indices.contains(k - offset) else { return 0 }
                return self.samples[k - offset]
            }
            deliver(chunk, self.startHost + Double(self.emitted) / self.sampleRate + self.latency)
            self.emitted = target
        }
        timer = t
        t.resume()
    }

    public func soundStarts(at host: Double) {
        lock.lock()
        soundStart = host
        lock.unlock()
    }

    public func stop() {
        timer?.cancel()
        queue.sync {}
        timer = nil
    }
}

/// The program clock when it started: timeline time `timeline` played at host time `host`.
public struct ProgramAnchor: Equatable, Sendable {
    public var host: Double
    public var timeline: Seconds
    /// Measured start minus requested start, when the transport can tell.
    public var syncError: Seconds?

    public init(host: Double, timeline: Seconds, syncError: Seconds? = nil) {
        self.host = host
        self.timeline = timeline
        self.syncError = syncError
    }

    public func timeline(atHost h: Double) -> Seconds { timeline + (h - host) }
}

/// Plays the program the performer follows.
public protocol ProgramTransport: AnyObject {
    /// Readies the program at `timeline` so it can start on time.
    func cue(_ timeline: Seconds, muted: Bool) async throws
    /// Starts the cued program when the host clock reaches `host`, and returns its clock as measured once it runs.
    func start(atHost host: Double) async throws -> ProgramAnchor
    func stop() async
    var outputLatency: Seconds? { get }
}

/// No program sound: the clock alone, for recording without the preview's player.
public final class SilentProgram: ProgramTransport {
    private var cued: Seconds = 0
    public init() {}
    public func cue(_ timeline: Seconds, muted: Bool) async throws { cued = timeline }
    public func start(atHost host: Double) async throws -> ProgramAnchor {
        ProgramAnchor(host: host, timeline: cued, syncError: 0)
    }
    public func stop() async {}
    public var outputLatency: Seconds? { nil }
}

/// Records the takes of one voice-over request: count down, roll the program from the preroll, capture the
/// input, then write each take as a 48 kHz 24-bit mono WAV lined up with the timeline, and `result.json`.
/// The preview app drives it with its player; tests drive it with `SilentProgram` and a `FileInput`.
public final class VoiceOverSession: @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        case countdown(Int), preroll, recording, saving, done, failed(String)
    }

    public struct State: Equatable, Sendable {
        public var phase: Phase
        public var take: Int
        /// Recent input peak, dBFS.
        public var level: Double
        /// Program time, once rolling.
        public var timeline: Seconds?
        /// 0…1 through the line.
        public var progress: Double
        /// Takes kept so far.
        public var recorded: Int

        public init(phase: Phase, take: Int, level: Double, timeline: Seconds?, progress: Double, recorded: Int) {
            self.phase = phase
            self.take = take
            self.level = level
            self.timeline = timeline
            self.progress = progress
            self.recorded = recorded
        }
    }

    public static let outputRate = 48_000.0

    public let request: VoiceOverRequest
    public let directory: URL
    private let transport: ProgramTransport
    private let makeInput: () throws -> RecordingInput
    public var onState: ((State) -> Void)?
    private let lock = NSLock()
    private var stopRequested = false
    private var retakeRequested = false
    private var recorded = 0

    public init(request: VoiceOverRequest, directory: URL, transport: ProgramTransport, makeInput: @escaping () throws -> RecordingInput) {
        self.request = request
        self.directory = directory
        self.transport = transport
        self.makeInput = makeInput
    }

    /// A session with the input the request asks for: its `testInput` (or the environment's) as the microphone,
    /// else the real one.
    public convenience init(request: VoiceOverRequest, directory: URL, transport: ProgramTransport, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let test = VoiceOverSession.testInput(request, environment: environment)
        self.init(request: request, directory: directory, transport: transport) {
            if let test { return try FileInput(url: URL(fileURLWithPath: test.path), latency: test.latency) }
            return MicrophoneInput()
        }
    }

    public static func testInput(_ request: VoiceOverRequest, environment: [String: String]) -> (path: String, latency: Seconds)? {
        guard let path = request.testInput ?? environment[VoiceOver.testInputEnvironment], !path.isEmpty else { return nil }
        return (path, request.testLatency ?? environment[VoiceOver.testLatencyEnvironment].flatMap(Double.init) ?? 0)
    }

    /// Whether recording may use the microphone, asking the human if they haven't decided. Never prompts once denied.
    public static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func stop() { lock.withLock { stopRequested = true } }
    public func retake() { lock.withLock { retakeRequested = true } }

    private func flags() -> (stop: Bool, retake: Bool) {
        lock.withLock {
            let f = (stopRequested, retakeRequested)
            retakeRequested = false
            return f
        }
    }

    private func publish(_ phase: Phase, take: Int, level: Double = -120, timeline: Seconds? = nil) {
        let progress = timeline.map { min(1, max(0, ($0 - request.start) / max(0.001, request.end - request.start))) } ?? 0
        onState?(State(phase: phase, take: take, level: level, timeline: timeline, progress: progress, recorded: recorded))
    }

    private func save(_ result: VoiceOverResult) {
        var r = result
        r.updatedAt = Date()
        try? VoiceOver.write(r, to: VoiceOver.resultURL(directory))
    }

    /// Records every take. The timing loop runs on a thread of its own so a busy cooperative pool can't delay it.
    public func run() async -> VoiceOverResult {
        await withCheckedContinuation { c in
            let thread = Thread { c.resume(returning: self.runTakes()) }
            thread.qualityOfService = .userInteractive
            thread.name = "cutline.voiceover"
            thread.start()
        }
    }

    /// Runs `body` on the concurrency runtime and waits for it; for the transport's async calls from the timing thread.
    private func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var out: Result<T, Error>!
        Task.detached {
            do { out = .success(try await body()) } catch { out = .failure(error) }
            done.signal()
        }
        done.wait()
        return try out.get()
    }

    private func runTakes() -> VoiceOverResult {
        var result = VoiceOverResult(id: request.id, status: .recording, currentTake: 1)
        save(result)
        var take = 1
        loop: while take <= request.takes {
            do {
                switch try record(take) {
                case .kept(let t):
                    result.takes.append(t)
                    recorded = result.takes.count
                    take += 1
                    result.currentTake = take <= request.takes ? take : nil
                    save(result)
                case .retake:
                    continue
                case .stopped(let t):
                    if let t { result.takes.append(t) }
                    recorded = result.takes.count
                    break loop
                }
            } catch {
                result.status = .failed
                result.error = error.localizedDescription
                result.currentTake = nil
                save(result)
                publish(.failed(error.localizedDescription), take: take)
                return result
            }
        }
        result.status = result.takes.isEmpty ? .cancelled : .done
        result.currentTake = nil
        save(result)
        publish(.done, take: min(take, request.takes))
        return result
    }

    private enum Outcome { case kept(VoiceOverTake), retake, stopped(VoiceOverTake?) }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var samples: [Float] = []
        private(set) var firstHost: Double?
        private var peak: Float = 0

        func append(_ s: [Float], host: Double) {
            lock.withLock {
                if firstHost == nil { firstHost = host }
                samples += s
                for v in s where abs(v) > peak { peak = abs(v) }
            }
        }

        var count: Int { lock.withLock { samples.count } }
        var first: Double? { lock.withLock { firstHost } }
        var all: [Float] { lock.withLock { samples } }

        /// The peak since the last call, dBFS.
        func takePeak() -> Double {
            lock.withLock {
                defer { peak = 0 }
                return peak > 0 ? max(-120, 20 * log10(Double(peak))) : -120
            }
        }
    }

    private func record(_ take: Int) throws -> Outcome {
        let input = try makeInput()
        let capture = Capture()
        try input.start { capture.append($0, host: $1) }
        var running = true
        defer { if running { input.stop() } }
        for n in stride(from: request.countdown, to: 0, by: -1) {
            let until = HostClock.now + 1
            while HostClock.now < until {
                let f = flags()
                if f.stop { return .stopped(nil) }
                if f.retake { return .retake }
                publish(.countdown(n), take: take, level: capture.takePeak())
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        let transport = transport
        let request = request
        try blocking { try await transport.cue(request.rollFrom, muted: request.muteProgram) }
        let host = HostClock.now + 0.12
        input.soundStarts(at: host)
        let anchor = try blocking { try await transport.start(atHost: host) }
        var stoppedAt: Seconds?
        let stopTime = request.end + request.postroll
        while true {
            let now = anchor.timeline(atHost: HostClock.now)
            publish(now < request.start ? .preroll : .recording, take: take, level: capture.takePeak(), timeline: now)
            let f = flags()
            if f.retake {
                try? blocking { await transport.stop() }
                return .retake
            }
            if f.stop {
                stoppedAt = now
                break
            }
            if let first = capture.first {
                let firstTime = VoiceOver.timelineTime(host: first, inputLatency: input.latency, anchorHost: anchor.host, anchorTimeline: anchor.timeline)
                if firstTime + Double(capture.count) / input.sampleRate >= stopTime { break }
            }
            if now > stopTime + 2 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try? blocking { await transport.stop() }
        input.stop()
        running = false
        publish(.saving, take: take, timeline: stoppedAt)
        guard let first = capture.first else { throw EditError("No sound arrived from \(input.deviceName).") }
        let firstTime = VoiceOver.timelineTime(host: first, inputLatency: input.latency, anchorHost: anchor.host, anchorTimeline: anchor.timeline)
        let samples = capture.all
        let rate = input.sampleRate
        guard let span = VoiceOver.takeSpan(firstSample: firstTime, captured: Double(samples.count) / rate, request: request, stoppedAt: stoppedAt) else {
            if stoppedAt != nil { return .stopped(nil) }
            throw EditError("\(input.deviceName) delivered no sound over the line.")
        }
        let i0 = max(0, Int((span.keepFrom * rate).rounded()))
        let i1 = min(samples.count, Int((span.keepTo * rate).rounded()))
        let kept = Array(samples[i0..<i1])
        let sourceIn = span.start - (firstTime + Double(i0) / rate)
        let l0 = max(0, min(kept.count, Int((sourceIn * rate).rounded())))
        let l1 = max(l0, min(kept.count, Int(((sourceIn + span.duration) * rate).rounded())))
        let levels = RecordingLevels.measure(kept[l0..<l1])
        let url = VoiceOver.takeURL(directory, id: request.id, take: take)
        let frames = try VoiceOverSession.writeWAV(kept, sampleRate: rate, to: url)
        let t = VoiceOverTake(take: take, file: url.path, start: span.start, duration: span.duration, sourceIn: sourceIn,
                              fileDuration: Double(frames) / VoiceOverSession.outputRate, sampleRate: VoiceOverSession.outputRate,
                              device: input.deviceName, inputLatency: input.latency, outputLatency: transport.outputLatency,
                              programSyncError: anchor.syncError, levels: levels)
        return stoppedAt == nil ? .kept(t) : .stopped(t)
    }

    /// Writes mono samples as a 48 kHz 24-bit WAV, resampling first if needed. Returns the frames written.
    @discardableResult
    public static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws -> Int {
        let data = sampleRate == outputRate ? samples : try resample(samples, from: sampleRate, to: outputRate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: outputRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let chunk = 65_536
        var i = 0
        while i < data.count {
            let n = min(chunk, data.count - i)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            data.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress! + i, count: n) }
            try file.write(from: buffer)
            i += n
        }
        return data.count
    }

    /// Mono sample-rate conversion with the converter's priming, so the output starts at the same instant.
    public static func resample(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: from, channels: 1)!
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: to, channels: 1)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw EditError("Can't convert \(from) Hz audio to \(to) Hz") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let expected = Int((Double(samples.count) * to / from).rounded())
        var out: [Float] = []
        out.reserveCapacity(expected)
        var fed = false
        while true {
            let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)!
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            if status == .endOfStream || status == .error || buffer.frameLength == 0 { break }
        }
        return Array(out.prefix(expected))
    }
}

/// Default audio devices through Core Audio.
public enum AudioDevices {
    public static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    public static func name(_ id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Device latency, safety offset, stream latency and one I/O buffer, in seconds.
    public static func latency(_ id: AudioDeviceID, input: Bool) -> Seconds? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        func value(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var v = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &v) == noErr ? v : 0
        }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        var streams = UInt32(0)
        var streamLatency = UInt32(0)
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streams) == noErr, streams >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var ids = [AudioStreamID](repeating: 0, count: Int(streams) / MemoryLayout<AudioStreamID>.size)
            var s = streams
            if AudioObjectGetPropertyData(id, &streamsAddress, 0, nil, &s, &ids) == noErr, let first = ids.first {
                var v = UInt32(0)
                var vs = UInt32(MemoryLayout<UInt32>.size)
                var a = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(first, &a, 0, nil, &vs, &v) == noErr { streamLatency = v }
            }
        }
        let frames = value(kAudioDevicePropertyLatency, scope) + value(kAudioDevicePropertySafetyOffset, scope) + streamLatency + value(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        return Double(frames) / rate
    }
}
