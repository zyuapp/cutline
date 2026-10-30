import AVFoundation
import CryptoKit
import CutlineCore
import Foundation

/// Import-time checks that a file really plays, and ProRes mezzanines (made with ffmpeg) for files
/// AVFoundation can't open or decode, such as MXF, DNxHR and XDCAM.
public enum MediaIngest {
    /// Why one file can't be imported, naming the file, its codec and what to do.
    public struct Failure: Error, CustomStringConvertible, LocalizedError {
        public var file: String
        public var codec: String?
        public var reason: String
        public var fix: String?

        public var description: String {
            "\((file as NSString).lastPathComponent): " + reason + (codec.map { " — \($0)" } ?? "") + (fix.map { ". \($0)" } ?? "")
        }

        public var errorDescription: String? { description }
    }

    public enum Prepared: Sendable {
        /// Ready to use: playable as is, or linked to its mezzanine.
        case ready(MediaAsset)
        /// Needs a long transcode; the placeholder points at the original until `finish` links the mezzanine.
        case deferred(MediaAsset, ProbeInfo)
        /// Camera RAW video whose developed copy is still to be made by `CameraRawIngest.finish`; the placeholder
        /// points at the original.
        case developing(MediaAsset)
    }

    /// Probes a file and checks it decodes. Undecodable files are transcoded with ffmpeg when `tools`
    /// is given: synchronously up to `syncLimit` seconds of media, otherwise `.deferred` for a background `finish`.
    /// Camera RAW (a file, or a folder of DNG frames played at `sequenceFPS` when they record no rate) goes
    /// through `CameraRawIngest`.
    public static func prepare(_ url: URL, id: String, cache: URL, tools: FFmpeg.Tools?, syncLimit: Seconds = 120, sequenceFPS: Double? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Prepared {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(file: url.path, reason: "file not found") }
        if let source = CameraRawIngest.classify(url) {
            return try await CameraRawIngest.prepare(source, id: id, cache: cache, fps: sequenceFPS, progress: progress)
        }
        if await CameraRawIngest.isProResRaw(url) {
            return try await CameraRawIngest.prepare(.proresRaw(url), id: id, cache: cache, fps: nil, progress: progress)
        }
        if MediaProbe.isImage(url) { return .ready(try await MediaProbe.probe(url, id: id)) }
        var probed: MediaAsset?
        var reason: String?
        do {
            probed = try await MediaProbe.probe(url, id: id)
            reason = await verify(url)
        } catch {
            reason = describe(error)
        }
        if var m = probed, reason == nil {
            if m.hasVideo, m.fieldOrder == nil, let ffprobe = tools?.ffprobe { m.fieldOrder = (try? await FFmpeg.probe(url, ffprobe: ffprobe))?.fieldOrder }
            return .ready(m)
        }
        var info: ProbeInfo?
        var probeError: String?
        if let ffprobe = tools?.ffprobe {
            do { info = try await FFmpeg.probe(url, ffprobe: ffprobe) } catch { probeError = describe(error) }
        }
        var codec = info?.codecSummary
        if codec == nil { codec = await containerCodec(url) }
        guard let tools else {
            throw Failure(file: url.path, codec: codec, reason: "this Mac can't \(probed == nil ? "open" : "decode") it (\(reason ?? "unknown error"))",
                          fix: "Install ffmpeg (brew install ffmpeg) and re-import so Cutline can transcode it, or transcode it to ProRes yourself")
        }
        guard let info else {
            if let probeError { throw Failure(file: url.path, codec: codec, reason: "neither this Mac (\(reason ?? "unknown error")) nor ffprobe (\(probeError)) can read it") }
            throw Failure(file: url.path, codec: codec, reason: "this Mac can't read it (\(reason ?? "unknown error")) and ffprobe wasn't found beside \(tools.ffmpeg.path)", fix: "Install ffmpeg with ffprobe (brew install ffmpeg)")
        }
        guard info.video != nil || !info.audio.isEmpty else {
            throw Failure(file: url.path, codec: codec, reason: "neither AVFoundation nor ffmpeg finds audio or video in it")
        }
        let dest = mezzanineURL(for: url, cache: cache)
        let cached = FileManager.default.fileExists(atPath: dest.path) ? await verify(dest) == nil : false
        if cached {
            return .ready(try await link(url, id: id, mezzanine: dest, info: info, summary: summary(info)))
        }
        if info.duration > syncLimit { return .deferred(placeholder(url, id: id, info: info), info) }
        return .ready(try await finish(url, id: id, info: info, cache: cache, tools: tools, progress: progress))
    }

    /// Transcodes a file to its mezzanine and returns the media pointing at it.
    public static func finish(_ url: URL, id: String, info: ProbeInfo, cache: URL, tools: FFmpeg.Tools, progress: (@Sendable (Double) -> Void)? = nil) async throws -> MediaAsset {
        let dest = mezzanineURL(for: url, cache: cache)
        do {
            try await transcode(url, info: info, to: dest, tools: tools, progress: progress)
        } catch {
            throw Failure(file: url.path, codec: info.codecSummary, reason: "the ProRes transcode failed (\(describe(error)))")
        }
        if let why = await verify(dest) {
            throw Failure(file: url.path, codec: info.codecSummary, reason: "its ProRes transcode doesn't decode (\(why))")
        }
        return try await link(url, id: id, mezzanine: dest, info: info, summary: summary(info))
    }

    /// Decodes the first video frame and the first audio buffer; nil when both work, else why not.
    public static func verify(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let videoSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
            let checks = [("video", video, videoSettings), ("audio", audio, audioSettings)].compactMap { kind, track, settings in track.map { (kind, $0, settings) } }
            // Decoding blocks, so it runs off the cooperative pool.
            return try await runBlocking { _ in
                for (kind, track, settings) in checks {
                    let reader = try AVAssetReader(asset: asset)
                    let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    out.alwaysCopiesSampleData = false
                    reader.add(out)
                    guard reader.startReading() else { return "\(kind): " + describe(reader.error) }
                    let failed = out.copyNextSampleBuffer() == nil && reader.status == .failed
                    let error = reader.error
                    reader.cancelReading()
                    if failed { return "\(kind): " + describe(error) }
                }
                return nil
            }
        } catch {
            return describe(error)
        }
    }

    /// "Cannot Decode: The decoder required for this media cannot be found."
    static func describe(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        let ns = error as NSError
        if let reason = ns.localizedFailureReason, !reason.isEmpty, reason != ns.localizedDescription { return "\(ns.localizedDescription): \(reason)" }
        return ns.localizedDescription
    }

    /// The video codec as the container names it, for errors without ffprobe.
    static func containerCodec(_ url: URL) async -> String {
        if url.pathExtension.lowercased() == "mxf" { return "MXF container (AVFoundation can't open MXF)" }
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return "codec unknown" }
        let code = CMFormatDescriptionGetMediaSubType(fd)
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
        return (knownCodecs[fourCC].map { "\($0) " } ?? "") + "('\(fourCC)')"
    }

    static let knownCodecs: [String: String] = [
        "AVdh": "Avid DNxHR/DNxHD", "AVdn": "Avid DNxHD", "AVd1": "Avid DV100", "mx5p": "XDCAM IMX", "xd5a": "XDCAM HD422", "xd5b": "XDCAM HD422", "xd5c": "XDCAM HD422",
        "xd5d": "XDCAM HD422", "xd5e": "XDCAM HD422", "xd5f": "XDCAM HD422", "xdv1": "XDCAM HD", "xdv2": "XDCAM HD", "xdv3": "XDCAM HD", "xdv7": "XDCAM EX", "xdvc": "XDCAM HD",
        "mp2v": "MPEG-2", "mpeg": "MPEG-1/2", "cfhd": "GoPro CineForm", "VP80": "VP8", "VP90": "VP9", "av01": "AV1", "H263": "H.263", "MJPG": "Motion JPEG",
    ]

    /// Where a file's mezzanine lives in a bundle cache; changes when the file's size or date changes.
    public static func mezzanineURL(for original: URL, cache: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: original.path)
        let stamp = "\(original.standardizedFileURL.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|v1"
        let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)
        let stem = original.deletingPathExtension().lastPathComponent.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return cache.appendingPathComponent("mezzanine", isDirectory: true).appendingPathComponent("\(String(stem).prefix(40))-\(key).mov")
    }

    /// "MPEG-2 video (mpeg2video, 4:2:2) in MXF → ProRes 422 HQ, 8 audio channels (1+2 stereo program, 3–8 extra tracks)".
    static func summary(_ info: ProbeInfo) -> String {
        var s = info.codecSummary + " → " + (info.video == nil ? "PCM audio" : alpha(info) ? "ProRes 4444" : "ProRes 422 HQ")
        let a = info.audio
        if !a.isEmpty {
            let channels = info.audioChannels
            s += ", \(channels) audio channel\(channels == 1 ? "" : "s")"
            if pairsMonos(info) { s += " (1+2 stereo program track" + (a.count > 2 ? ", 3–\(a.count) as extra tracks)" : ")") } else if a.count > 1 { s += " in \(a.count) tracks" }
        }
        return s
    }

    static func alpha(_ info: ProbeInfo) -> Bool {
        guard let f = info.video?.pixelFormat else { return false }
        return f.hasPrefix("yuva") || f.hasPrefix("rgba") || f.hasPrefix("bgra") || f.hasPrefix("argb") || f.hasPrefix("gbrap") || f.hasPrefix("ya")
    }

    /// Mono tracks, as XDCAM and broadcast MXF carry: channels 1 and 2 become one stereo track.
    static func pairsMonos(_ info: ProbeInfo) -> Bool {
        info.audio.count >= 2 && info.audio.allSatisfy { $0.channels == 1 }
    }

    /// ffmpeg arguments for the mezzanine: ProRes 422 HQ (4444 with alpha), 24-bit PCM, the source's
    /// frame timing, timecode, field order and color tags, and every audio channel.
    static func arguments(_ src: URL, info: ProbeInfo, to dest: URL) -> [String] {
        var a = ["-nostdin", "-hide_banner", "-y", "-i", src.path, "-map_metadata", "0"]
        if let v = info.video {
            a += ["-map", "0:\(v.index)"]
            let order = info.fieldOrder
            a += ["-c:v", "prores_ks", "-vendor", "apl0", "-fps_mode", "passthrough"]
            a += alpha(info) ? ["-profile:v", "4", "-pix_fmt", "yuva444p10le"] : ["-profile:v", "3", "-pix_fmt", "yuv422p10le"]
            if order == .tff || order == .bff { a += ["-flags", "+ildct+ilme", "-field_order", order == .tff ? "tt" : "bb"] }
            if let p = v.colorPrimaries { a += ["-color_primaries", p] }
            if let t = v.colorTransfer { a += ["-color_trc", t] }
            if let c = v.colorSpace { a += ["-colorspace", c] }
            if let r = v.colorRange { a += ["-color_range", r] }
        }
        let audio = info.audio
        if pairsMonos(info) {
            a += ["-filter_complex", "[0:\(audio[0].index)][0:\(audio[1].index)]amerge=inputs=2[program]", "-map", "[program]"]
            for s in audio.dropFirst(2) { a += ["-map", "0:\(s.index)"] }
        } else {
            for s in audio { a += ["-map", "0:\(s.index)"] }
        }
        if !audio.isEmpty { a += ["-c:a", "pcm_s24le"] }
        if let tc = info.timecode, info.video != nil { a += ["-timecode", tc] }
        a += ["-progress", "pipe:1", "-nostats", "-f", "mov", dest.path]
        return a
    }

    static func transcode(_ src: URL, info: ProbeInfo, to dest: URL, tools: FFmpeg.Tools, progress: (@Sendable (Double) -> Void)?) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tmp) }
        try await FFmpeg.run(tools.ffmpeg, arguments(src, info: info, to: tmp), duration: info.duration, progress: progress)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        progress?(1)
    }

    /// The mezzanine's media item, named after and pointing back to the original.
    static func link(_ original: URL, id: String, mezzanine: URL, info: ProbeInfo, summary: String) async throws -> MediaAsset {
        var m = try await MediaProbe.probe(mezzanine, id: id)
        m.name = MediaProbe.displayName(original)
        m.originalPath = original.path
        m.transcoded = summary
        if m.hasVideo { m.fieldOrder = info.fieldOrder ?? m.fieldOrder }
        if var chs = m.audioChannels {
            for (i, name) in sourceChannelNames(info) where i < chs.count && chs[i].name == nil { chs[i].name = name }
            if let planned = mezzanineChannels(info), planned.count == chs.count {
                for i in chs.indices { chs[i].originalTrack = planned[i].originalTrack }
            }
            m.audioChannels = chs
        }
        if m.timecodeStart == nil, let tc = info.timecode, let fps = info.video?.frameRate, fps > 0 {
            let f = TimecodeFormat(fps: fps, label: tc)
            if let frames = f.frames(tc) { m.setTimecode(frames: frames, format: f) }
        }
        if let reel = info.reel { m.reel = reel }
        return m
    }

    /// The media as ffprobe sees it, before its mezzanine exists.
    static func placeholder(_ url: URL, id: String, info: ProbeInfo) -> MediaAsset {
        let v = info.video
        var m = MediaAsset(id: id, path: url.path, name: MediaProbe.displayName(url), duration: info.duration, width: v?.width ?? 0, height: v?.height ?? 0,
                           fps: v?.frameRate ?? 0, hasVideo: v != nil, hasAudio: !info.audio.isEmpty)
        m.originalPath = url.path
        m.transcoded = MediaAsset.pendingTranscode + summary(info)
        m.fieldOrder = v == nil ? nil : info.fieldOrder
        m.audioChannels = mezzanineChannels(info)
        if let tc = info.timecode, let fps = v?.frameRate, fps > 0 {
            let f = TimecodeFormat(fps: fps, label: tc)
            if let frames = f.frames(tc) { m.setTimecode(frames: frames, format: f) }
        }
        m.reel = info.reel
        return m
    }

    /// The mezzanine's source channels: ch1+ch2 paired in track 1 when the original has mono tracks, the rest one per track.
    static func mezzanineChannels(_ info: ProbeInfo) -> [SourceChannel]? {
        guard !info.audio.isEmpty else { return nil }
        let names = sourceChannelNames(info)
        var out: [SourceChannel] = []
        let paired = pairsMonos(info)
        for (s, stream) in info.audio.enumerated() {
            for c in 0..<max(1, stream.channels) {
                let track = paired ? max(1, s) : s + 1
                let channel = paired ? (s < 2 ? s + 1 : 1) : c + 1
                out.append(SourceChannel(track: track, channel: channel, name: names[out.count], originalTrack: paired ? s + 1 : nil))
            }
        }
        return out
    }

    /// Titles of mono audio streams, by source channel index from 0.
    static func sourceChannelNames(_ info: ProbeInfo) -> [Int: String] {
        var names: [Int: String] = [:]
        var g = 0
        for s in info.audio {
            if s.channels <= 1, let t = s.title { names[g] = t }
            g += max(1, s.channels)
        }
        return names
    }
}

