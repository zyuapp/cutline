import CutlineCore
import Foundation

/// The ffmpeg and ffprobe command-line tools, used for formats AVFoundation can't read or write
/// (MXF, DNxHR, XDCAM). Nothing here is required: callers fall back to a precise error without them.
public enum FFmpeg {
    public struct Tools: Sendable {
        public var ffmpeg: URL
        public var ffprobe: URL?

        public init(ffmpeg: URL, ffprobe: URL?) {
            self.ffmpeg = ffmpeg
            self.ffprobe = ffprobe
        }
    }

    public static let searchFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
    public static let installHint = "install ffmpeg (brew install ffmpeg)"

    /// ffmpeg from CUTLINE_FFMPEG (a binary path; "none" disables it), else PATH, /opt/homebrew/bin
    /// or /usr/local/bin. ffprobe is taken from CUTLINE_FFPROBE, beside ffmpeg, or the same search.
    public static func tools(environment: [String: String] = ProcessInfo.processInfo.environment) -> Tools? {
        let fm = FileManager.default
        func runnable(_ path: String) -> URL? { fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil }
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + searchFolders
        func search(_ name: String) -> URL? { folders.lazy.compactMap { runnable(($0 as NSString).appendingPathComponent(name)) }.first }
        let ffmpeg: URL?
        if let forced = environment["CUTLINE_FFMPEG"], !forced.isEmpty {
            ffmpeg = forced == "none" ? nil : runnable(forced)
        } else {
            ffmpeg = search("ffmpeg")
        }
        guard let ffmpeg else { return nil }
        let probe = environment["CUTLINE_FFPROBE"].flatMap(runnable)
            ?? runnable(ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe").path)
            ?? search("ffprobe")
        return Tools(ffmpeg: ffmpeg, ffprobe: probe)
    }

    /// Runs a tool to completion. With `duration`, ffmpeg's `-progress pipe:1` output is turned into
    /// a 0…1 fraction. The process is killed after `stall` seconds without output, or when the task is
    /// cancelled. Throws with the end of stderr when it exits non-zero.
    @discardableResult
    public static func run(_ tool: URL, _ arguments: [String], duration: Seconds? = nil, stall: Seconds = 120, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let state = RunState()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { state.close(stdout: true); h.readabilityHandler = nil; return }
            state.touch(stdout: data)
            guard let duration, duration > 0, let progress else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)) { progress(min(1, max(0, us / 1_000_000 / duration))) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { state.close(stdout: false); h.readabilityHandler = nil } else { state.touch(stderr: data) }
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int32, Error>) in
                proc.terminationHandler = { p in done.resume(returning: p.terminationStatus) }
                do { try proc.run() } catch {
                    proc.terminationHandler = nil
                    done.resume(throwing: EditError("Cannot run \(tool.path): \(error.localizedDescription)"))
                    return
                }
                Task.detached {
                    while proc.isRunning {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if state.idle > stall, proc.isRunning {
                            state.stalled = true
                            proc.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
        // The handlers drain each pipe to its end; output read after exit could otherwise race them and be lost.
        let drained = Date().addingTimeInterval(10)
        while !state.bothClosed, Date() < drained { try? await Task.sleep(nanoseconds: 5_000_000) }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let tail = state.stderrTail
        if Task.isCancelled { throw CancellationError() }
        if state.stalled { throw EditError("\(tool.lastPathComponent) made no progress for \(Int(stall))s and was stopped") }
        guard status == 0 else {
            let last = tail.split(separator: "\n").suffix(4).joined(separator: " | ")
            throw EditError("\(tool.lastPathComponent) failed (exit \(status))" + (last.isEmpty ? "" : ": \(last)"))
        }
        return state.stdoutText
    }

    final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var stdout = Data()
        private var stderr = Data()
        var stalled = false

        private var closed = (stdout: false, stderr: false)
        func close(stdout: Bool) { lock.withLock { if stdout { closed.stdout = true } else { closed.stderr = true } } }
        var bothClosed: Bool { lock.withLock { closed.stdout && closed.stderr } }

        func touch(stdout data: Data) { lock.withLock { last = Date(); if stdout.count < 8_000_000 { stdout.append(data) } } }
        func touch(stderr data: Data) {
            lock.withLock {
                last = Date()
                stderr.append(data)
                if stderr.count > 16_384 { stderr = stderr.suffix(8192) }
            }
        }

        var idle: Seconds { lock.withLock { Date().timeIntervalSince(last) } }
        var stderrTail: String { lock.withLock { String(decoding: stderr, as: UTF8.self) } }
        var stdoutText: String { lock.withLock { String(decoding: stdout, as: UTF8.self) } }
    }

    /// The encoders an ffmpeg build has, with the pixel formats of the ones asked about.
    public struct Encoders: Sendable {
        public var names: Set<String>
        public var pixelFormats: [String: Set<String>]

        public init(names: Set<String>, pixelFormats: [String: Set<String>] = [:]) {
            self.names = names
            self.pixelFormats = pixelFormats
        }
    }

    final class EncoderCache: @unchecked Sendable {
        let lock = NSLock()
        var names: [String: Set<String>] = [:]
        var formats: [String: Set<String>] = [:]
    }

    static let encoderCache = EncoderCache()

    /// `ffmpeg -encoders`, and `-h encoder=` for each of `pixelFormatsOf` the build has; cached per binary.
    public static func encoders(_ tool: URL, pixelFormatsOf: [String] = []) async throws -> Encoders {
        let cache = encoderCache
        var names = cache.lock.withLock { cache.names[tool.path] }
        if names == nil {
            let text = try await run(tool, ["-hide_banner", "-encoders"], stall: 30)
            let parsed = Set(text.split(separator: "\n").compactMap { line -> String? in
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 2, cols[0].count == 6, cols[0].first.map({ "VAS".contains($0) }) == true else { return nil }
                return String(cols[1])
            })
            cache.lock.withLock { cache.names[tool.path] = parsed }
            names = parsed
        }
        var out = Encoders(names: names ?? [])
        for e in pixelFormatsOf where out.names.contains(e) {
            let key = tool.path + "|" + e
            if let f = cache.lock.withLock({ cache.formats[key] }) {
                out.pixelFormats[e] = f
                continue
            }
            let help = try await run(tool, ["-hide_banner", "-h", "encoder=\(e)"], stall: 30)
            guard let line = help.split(separator: "\n").first(where: { $0.contains("Supported pixel formats:") }) else { continue }
            let f = Set(line.split(separator: ":", maxSplits: 1).last?.split(separator: " ").map(String.init) ?? [])
            cache.lock.withLock { cache.formats[key] = f }
            out.pixelFormats[e] = f
        }
        return out
    }

    /// ffprobe's view of a file's container and streams.
    public static func probe(_ url: URL, ffprobe: URL) async throws -> ProbeInfo {
        let json = try await run(ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path], stall: 60)
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw EditError("ffprobe returned no description of \(url.lastPathComponent)") }
        return ProbeInfo(root)
    }
}

/// The parts of `ffprobe -show_format -show_streams` that ingest and delivery use.
public struct ProbeInfo: Sendable {
    public struct Stream: Sendable {
        public var index: Int
        public var type: String
        public var codec: String
        public var codecLongName: String
        public var profile: String?
        public var tag: String?
        public var width: Int
        public var height: Int
        public var pixelFormat: String?
        /// ffprobe's field_order: progressive, tt, bb, tb or bt.
        public var fieldOrderName: String?
        public var frameRate: Double
        public var channels: Int
        public var sampleRate: Int
        public var bitsPerSample: Int
        public var bitRate: Int?
        public var timecode: String?
        public var colorPrimaries: String?
        public var colorTransfer: String?
        public var colorSpace: String?
        public var colorRange: String?
        public var isAttachedPicture: Bool
        /// The stream's title tag, e.g. a track name from the recorder or editor.
        public var title: String? = nil
    }

    public var formatName: String
    public var formatLongName: String
    public var duration: Seconds
    public var formatTimecode: String?
    /// Reel or tape name from the container's or a stream's tags (reel_name, tape_name, reel).
    public var reel: String?
    public var streams: [Stream]

    init(_ root: [String: Any]) {
        let format = root["format"] as? [String: Any] ?? [:]
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        func rate(_ v: Any?) -> Double {
            guard let s = v as? String else { return 0 }
            let parts = s.split(separator: "/").compactMap { Double($0) }
            return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : parts.first ?? 0
        }
        formatName = format["format_name"] as? String ?? ""
        formatLongName = format["format_long_name"] as? String ?? formatName
        duration = num(format["duration"]) ?? 0
        formatTimecode = (format["tags"] as? [String: Any])?["timecode"] as? String
        let tagSets = [format["tags"] as? [String: Any] ?? [:]] + (root["streams"] as? [[String: Any]] ?? []).map { $0["tags"] as? [String: Any] ?? [:] }
        reel = tagSets.lazy.compactMap { tags -> String? in
            let lower = Dictionary(tags.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            return ["reel_name", "tape_name", "reel", "com.apple.proapps.reel"].lazy.compactMap { (lower[$0] as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }.first
        streams = (root["streams"] as? [[String: Any]] ?? []).map { s in
            let tags = s["tags"] as? [String: Any] ?? [:]
            let known = { (k: String) -> String? in
                guard let v = s[k] as? String, !v.isEmpty, v != "unknown" else { return nil }
                return v
            }
            let bits = Int(num(s["bits_per_raw_sample"]) ?? num(s["bits_per_sample"]) ?? 0)
            var stream = Stream(index: Int(num(s["index"]) ?? 0), type: s["codec_type"] as? String ?? "", codec: s["codec_name"] as? String ?? "unknown",
                          codecLongName: s["codec_long_name"] as? String ?? (s["codec_name"] as? String ?? "unknown"), profile: known("profile"),
                          tag: (s["codec_tag_string"] as? String).flatMap { $0.hasPrefix("[0]") ? nil : $0 },
                          width: Int(num(s["width"]) ?? 0), height: Int(num(s["height"]) ?? 0), pixelFormat: known("pix_fmt"),
                          fieldOrderName: known("field_order"), frameRate: rate(s["avg_frame_rate"]) > 0 ? rate(s["avg_frame_rate"]) : rate(s["r_frame_rate"]),
                          channels: Int(num(s["channels"]) ?? 0), sampleRate: Int(num(s["sample_rate"]) ?? 0), bitsPerSample: bits,
                          bitRate: num(s["bit_rate"]).map { Int($0) }, timecode: tags["timecode"] as? String,
                          colorPrimaries: known("color_primaries"), colorTransfer: known("color_transfer"), colorSpace: known("color_space"), colorRange: known("color_range"),
                          isAttachedPicture: ((s["disposition"] as? [String: Any])?["attached_pic"] as? NSNumber)?.intValue == 1)
            stream.title = (tags["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return stream
        }
    }

    public var video: Stream? { streams.first { $0.type == "video" && !$0.isAttachedPicture } }
    public var audio: [Stream] { streams.filter { $0.type == "audio" } }
    /// Timecode of the first frame from the container, the video stream or a tmcd stream.
    public var timecode: String? { formatTimecode ?? video?.timecode ?? streams.lazy.compactMap(\.timecode).first }
    public var audioChannels: Int { audio.reduce(0) { $0 + $1.channels } }

    /// tt and tb are coded top field first, bb and bt bottom field first.
    public var fieldOrder: FieldOrder? {
        switch video?.fieldOrderName {
        case "progressive": .progressive
        case "tt", "tb": .tff
        case "bb", "bt": .bff
        default: nil
        }
    }

    /// "MPEG-2 video (mpeg2video, 4:2:2) in MXF".
    public var codecSummary: String {
        var parts: [String] = []
        if let v = video { parts.append("\(v.codecLongName) (\(v.codec)\(v.profile.map { ", \($0)" } ?? ""))") }
        if video == nil, let a = audio.first { parts.append("\(a.codecLongName) (\(a.codec))") }
        let container = formatName.split(separator: ",").first.map(String.init) ?? formatName
        return parts.joined() + " in \(container.uppercased() == "MXF" ? "MXF" : container)"
    }
}
