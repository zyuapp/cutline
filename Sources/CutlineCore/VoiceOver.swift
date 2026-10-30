import Foundation

/// A voice-over or ADR recording the agent asks the preview app to make. The tool writes it to
/// `<bundle>/media/recordings/<id>/request.json`; the app records into that folder and answers in `result.json`.
public struct VoiceOverRequest: Codable, Equatable, Sendable {
    public var id: String
    /// Timeline range of the line.
    public var start: Seconds
    public var end: Seconds
    /// Seconds counted down on screen before the program rolls.
    public var countdown: Int
    /// Program played before `start`, recorded as a head handle.
    public var preroll: Seconds
    /// Recorded past `end` as a tail handle.
    public var postroll: Seconds
    public var muteProgram: Bool
    public var takes: Int
    public var script: String?
    /// A sound file played as the microphone, for runs without one.
    public var testInput: String?
    /// Input latency the test input reports and delays its timestamps by.
    public var testLatency: Seconds?

    public init(id: String, start: Seconds, end: Seconds, countdown: Int = 3, preroll: Seconds = 2, postroll: Seconds = 0.5, muteProgram: Bool = false, takes: Int = 1, script: String? = nil, testInput: String? = nil, testLatency: Seconds? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.countdown = countdown
        self.preroll = preroll
        self.postroll = postroll
        self.muteProgram = muteProgram
        self.takes = takes
        self.script = script
        self.testInput = testInput
        self.testLatency = testLatency
    }

    /// Where the program starts rolling: `preroll` before the line, never before the timeline's start.
    public var rollFrom: Seconds { max(0, start - preroll) }
}

public struct RecordingLevels: Codable, Equatable, Sendable {
    /// dBFS over the line, −120 for silence.
    public var peakDB: Double
    public var rmsDB: Double
    /// Samples at or above full scale.
    public var clippedSamples: Int
    public var clipped: Bool { clippedSamples > 0 }
    public var warnings: [String]

    public init(peakDB: Double, rmsDB: Double, clippedSamples: Int, warnings: [String]) {
        self.peakDB = peakDB
        self.rmsDB = rmsDB
        self.clippedSamples = clippedSamples
        self.warnings = warnings
    }

    public static let fullScale: Float = 0.999

    /// Levels of `samples` with warnings for clipping, hot peaks, a quiet take or no signal.
    public static func measure(_ samples: ArraySlice<Float>) -> RecordingLevels {
        var peak: Float = 0
        var sum = 0.0
        var clipped = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            if a >= fullScale { clipped += 1 }
            sum += Double(s) * Double(s)
        }
        let peakDB = db(Double(peak))
        let rmsDB = db(samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot())
        var warnings: [String] = []
        if clipped > 0 {
            warnings.append("clipping: \(clipped) sample(s) at full scale; lower the input gain and retake")
        } else if peakDB > -1 {
            warnings.append("hot: peaks at \(String(format: "%.1f", peakDB)) dBFS, close to clipping")
        }
        if peakDB < -60 {
            warnings.append("no signal (peak \(String(format: "%.0f", peakDB)) dBFS): check the input device")
        } else if peakDB < -20 || rmsDB < -45 {
            warnings.append("too quiet (peak \(String(format: "%.1f", peakDB)) dBFS, RMS \(String(format: "%.1f", rmsDB)) dBFS): raise the input gain or move closer to the mic")
        }
        return RecordingLevels(peakDB: peakDB, rmsDB: rmsDB, clippedSamples: clipped, warnings: warnings)
    }

    static func db(_ v: Double) -> Double { v > 0 ? max(-120, 20 * log10(v)) : -120 }
}

/// One recorded take as written to disk.
public struct VoiceOverTake: Codable, Equatable, Sendable {
    public var take: Int
    /// Absolute path of the WAV file.
    public var file: String
    /// Timeline time `sourceIn` lines up with: the line's start, or later if the take began late.
    public var start: Seconds
    /// Recorded length from `start`, at most to the line's end.
    public var duration: Seconds
    /// Where `start` falls in the file, after input latency is taken out. The head before it is preroll.
    public var sourceIn: Seconds
    public var fileDuration: Seconds
    public var sampleRate: Double
    public var device: String
    /// Latency taken out of the input timestamps.
    public var inputLatency: Seconds
    /// Latency of the output the program played on, as the device reports it.
    public var outputLatency: Seconds?
    /// How far the program started from the host time it was asked to, from its own clock.
    public var programSyncError: Seconds?
    public var levels: RecordingLevels

    public init(take: Int, file: String, start: Seconds, duration: Seconds, sourceIn: Seconds, fileDuration: Seconds, sampleRate: Double, device: String, inputLatency: Seconds, outputLatency: Seconds? = nil, programSyncError: Seconds? = nil, levels: RecordingLevels) {
        self.take = take
        self.file = file
        self.start = start
        self.duration = duration
        self.sourceIn = sourceIn
        self.fileDuration = fileDuration
        self.sampleRate = sampleRate
        self.device = device
        self.inputLatency = inputLatency
        self.outputLatency = outputLatency
        self.programSyncError = programSyncError
        self.levels = levels
    }
}

public struct VoiceOverResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording, done, cancelled, failed
        public var isFinal: Bool { self != .recording }
    }

    public var id: String
    public var status: Status
    public var error: String?
    /// The take being recorded while `status` is recording.
    public var currentTake: Int?
    public var takes: [VoiceOverTake]
    public var updatedAt: Date

    public init(id: String, status: Status, error: String? = nil, currentTake: Int? = nil, takes: [VoiceOverTake] = [], updatedAt: Date = Date()) {
        self.id = id
        self.status = status
        self.error = error
        self.currentTake = currentTake
        self.takes = takes
        self.updatedAt = updatedAt
    }
}

public enum VoiceOver {
    public static let trackName = "Voice-over"
    public static let permissionMessage = "Cutline has no microphone access. Grant it in System Settings › Privacy & Security › Microphone (turn on Cutline), then call voiceover_record again."
    public static let testInputEnvironment = "CUTLINE_RECORD_TEST_INPUT"
    public static let testLatencyEnvironment = "CUTLINE_RECORD_TEST_LATENCY"

    public static func requestURL(_ dir: URL) -> URL { dir.appendingPathComponent("request.json") }
    public static func resultURL(_ dir: URL) -> URL { dir.appendingPathComponent("result.json") }
    public static func takeURL(_ dir: URL, id: String, take: Int) -> URL { dir.appendingPathComponent("\(id)-take\(take).wav") }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(value).write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(type, from: $0) }
    }

    /// Timeline time of a captured sample stamped `host` (host-clock seconds, as the input reported it), given the
    /// program clock `anchor`: the input's latency is taken out, so the sample lines up with what was heard.
    public static func timelineTime(host: Double, inputLatency: Seconds, anchorHost: Double, anchorTimeline: Seconds) -> Seconds {
        anchorTimeline + (host - inputLatency - anchorHost)
    }

    /// The part of a capture to keep and where the line falls in it. `firstSample` is the capture's first sample in
    /// timeline time, `captured` its length; `stoppedAt` ends a take cut short.
    public static func takeSpan(firstSample: Seconds, captured: Seconds, request: VoiceOverRequest, stoppedAt: Seconds? = nil) -> (keepFrom: Seconds, keepTo: Seconds, start: Seconds, duration: Seconds)? {
        let captureEnd = firstSample + captured
        let keepFrom = max(firstSample, request.rollFrom)
        let keepTo = min(captureEnd, request.end + request.postroll, stoppedAt ?? .infinity)
        let start = max(request.start, keepFrom)
        let lineEnd = min(request.end, keepTo)
        guard lineEnd > start, keepTo > keepFrom else { return nil }
        return (keepFrom - firstSample, keepTo - firstSample, start, lineEnd - start)
    }

    /// The take to place: the last one without clipping or level warnings, else the last.
    public static func preferredTake(_ takes: [VoiceOverTake]) -> VoiceOverTake? {
        takes.last { $0.levels.warnings.isEmpty } ?? takes.last
    }

    /// The next free session id, vo1, vo2…, for the folders already in `recordings`.
    public static func nextId(in recordings: URL) -> String {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? [])
        var n = 1
        while names.contains("vo\(n)") { n += 1 }
        return "vo\(n)"
    }
}

extension ProjectBundle {
    /// Recorded audio: the one place the preview app writes media.
    public var recordingsURL: URL { url.appendingPathComponent("media/recordings", isDirectory: true) }
}

extension Project {
    /// Places a recorded take of media `mediaId` with its line on the timeline. `track` nil uses the last
    /// Voice-over track free over the line, else a new one; "new" always adds one. The clip starts on the frame
    /// nearest the line's start, with the source moved by the same amount so the take stays in sync.
    @discardableResult
    public mutating func placeVoiceOver(_ take: VoiceOverTake, mediaId: String, track: String?, sessionId: String) throws -> (clip: Clip, track: String) {
        guard let m = mediaAsset(mediaId) else { throw EditError("No media \(mediaId)") }
        let start = canvas.snap(take.start)
        let sourceIn = take.sourceIn + (start - take.start)
        let duration = min(take.duration, m.duration - sourceIn)
        guard sourceIn >= 0, duration >= canvas.frameDuration else { throw EditError("Take \(take.take) is shorter than one frame") }
        let range = TimeRange(start, start + duration)
        let trackId: String
        if let track, track != "new" {
            guard trackIndex(track) != nil else { throw EditError("No track \(track)") }
            trackId = track
        } else if track == nil, let free = tracks.last(where: { t in
            t.kind == .audio && t.name == VoiceOver.trackName && !t.clips.contains { TimeRange($0.start, $0.end).intersection(range) != nil }
        }) {
            trackId = free.id
        } else {
            let t = addTrack(kind: .audio, name: VoiceOver.trackName)
            if let i = trackIndex(t.id) { tracks[i].role = "dialogue" }
            trackId = t.id
        }
        let clip = Clip(id: Project.newClipId(), kind: .media, name: "\(sessionId) take \(take.take)", mediaId: mediaId, start: start, duration: duration, sourceIn: sourceIn)
        return (try addClip(clip, trackId: trackId, mode: .place), trackId)
    }

    /// Marks a take's media: metadata take/scene/line timing, and a tag over the line in source time.
    public mutating func tagVoiceOver(_ take: VoiceOverTake, mediaId: String, sessionId: String, placed: Bool) {
        guard let i = media.firstIndex(where: { $0.id == mediaId }) else { return }
        var meta = media[i].metadata ?? [:]
        meta["scene"] = sessionId
        meta["take"] = "\(take.take)"
        meta["line_start"] = String(format: "%.3f", take.start)
        meta["source_in"] = String(format: "%.4f", take.sourceIn)
        meta["line_duration"] = String(format: "%.3f", take.duration)
        if !take.levels.warnings.isEmpty { meta["levels"] = take.levels.warnings.joined(separator: "; ") }
        media[i].metadata = meta
        let label = "\(sessionId) take \(take.take)" + (placed ? " (placed)" : " (alternate)")
        var tags = (media[i].tags ?? []).filter { !$0.label.hasPrefix("\(sessionId) take ") }
        tags.append(MediaTag(label: label, start: take.sourceIn, end: take.sourceIn + take.duration))
        media[i].tags = tags
        media[i].bin = media[i].bin ?? "Voice-over"
    }
}
