import AVFoundation
import CoreImage
import CryptoKit
import CutlineCore
import Foundation
import ImageIO
import VideoToolbox

/// Camera RAW at import: recognizing it, reading how it was shot, and developing video into a playable copy.
///
/// ProRes RAW is decoded by AVFoundation (Apple's debayer, as-shot metadata) to scene-linear BT.2020; DNG frames and
/// raw stills by `CIRAWFilter` with linear output. Video is stored as ProRes 4444 XQ in `CameraRaw.workingLog`, so it
/// enters the compositor's log/ACES input path. ProRes RAW copies stay as shot and every raw.* control is applied
/// live on white-balanced camera RGB; DNG copies bake white balance, highlights and noise reduction (a copy per
/// setting, rendered in the background) and take exposure live.
public enum CameraRawIngest {
    public enum Source: Sendable, Equatable {
        case proresRaw(URL)
        case dngSequence(folder: URL, frames: [URL])
        case still(URL)
        case vendor(RawFormat, URL)
    }

    public static let stillExtensions: Set<String> = ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "erf", "mos", "mrw", "x3f", "gpr", "dcr", "kdc", "rwl"]
    public static let vendorExtensions: [String: RawFormat] = ["braw": .braw, "r3d": .r3d, "ari": .arriraw, "arx": .arriraw, "crm": .canon_raw_light, "nev": .nraw]

    /// DNG frames in a folder, in frame-number order.
    public static func dngFrames(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "dng" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A folder's DNG frames when they form a CinemaDNG clip: at least two, and the first records a frame rate or
    /// timecode, or there are a second's worth (folders of DNG photos are stills).
    public static func sequenceFrames(in folder: URL) -> [URL]? {
        let frames = dngFrames(in: folder)
        guard frames.count >= 2 else { return nil }
        if frames.count >= 24 { return frames }
        let t = cinemaDNGTiming(frames[0])
        return t.fps != nil || t.timecode != nil ? frames : nil
    }

    /// What kind of camera RAW a path is; nil for anything else (ProRes RAW is found by `isProResRaw`).
    public static func classify(_ url: URL) -> Source? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return sequenceFrames(in: url).map { .dngSequence(folder: url, frames: $0) } }
        let ext = url.pathExtension.lowercased()
        if let f = vendorExtensions[ext] ?? vendorMagic(url) { return .vendor(f, url) }
        if stillExtensions.contains(ext) { return .still(url) }
        return nil
    }

    /// Recognizes vendor RAW files by their first bytes: R3D ("RED1"/"RED2" after the size), ARRIRAW frames
    /// ("ARRI" then 0x12345678), Canon Cinema RAW Light (ISO base media with brand "crx ").
    public static func vendorMagic(_ url: URL) -> RawFormat? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 16)) ?? Data()
        guard head.count >= 12 else { return nil }
        let tag = String(decoding: head[4..<8], as: UTF8.self)
        if tag == "RED1" || tag == "RED2" { return .r3d }
        if String(decoding: head[0..<4], as: UTF8.self) == "ARRI", head[4..<8].elementsEqual([0x78, 0x56, 0x34, 0x12]) || head[4..<8].elementsEqual([0x12, 0x34, 0x56, 0x78]) { return .arriraw }
        if tag == "ftyp", String(decoding: head[8..<12], as: UTF8.self) == "crx " { return .canon_raw_light }
        return nil
    }

    /// Whether a movie's picture is ProRes RAW ('aprn', 'aprh').
    public static func isProResRaw(_ url: URL) async -> Bool {
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()),
              let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return false }
        let code = CMFormatDescriptionGetMediaSubType(fd)
        return code == kCMVideoCodecType_AppleProResRAW || code == kCMVideoCodecType_AppleProResRAWHQ
    }

    /// Why a vendor format can't be imported and what to do instead.
    public static func vendorFailure(_ format: RawFormat, _ url: URL) -> MediaIngest.Failure {
        var reason = "\(format.title) needs \(format.vendorSDK ?? "the camera maker's SDK") to debayer, which macOS doesn't include"
        if format == .r3d { reason += "; ffmpeg only reads REDCODE as undebayered sensor planes without RED's color science, so Cutline doesn't use it" }
        return MediaIngest.Failure(file: url.path, codec: format.title, reason: reason, fix: format.transcodeHint.map { $0.prefix(1).uppercased() + $0.dropFirst() })
    }

    // MARK: Metadata

    /// ProRes RAW conversion metadata from the first frame, decoded without processing, and the AVFoundation
    /// decode's scale relative to it (measured on the frame's center).
    public static func proResMetadata(_ url: URL) async throws -> RawMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first, let fd = try await track.load(.formatDescriptions).first else { throw EditError("\(url.lastPathComponent) has no picture") }
        var raw = RawMedia(format: .prores_raw)
        raw.camera = await cameraName(asset)
        let found: (attachments: [String: Any], scale: Double?)? = try await runBlocking { _ in
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }
            var sample = out.nextSample()
            while let s = sample, CMSampleBufferGetNumSamples(s) == 0 { sample = out.nextSample() }
            guard let sample else { return nil }
            var session: VTDecompressionSession?
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: nil, decompressionSessionOut: &session) == noErr, let session else { return nil }
            defer { VTDecompressionSessionInvalidate(session) }
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RequestRAWOutput, value: kCFBooleanTrue)
            nonisolated(unsafe) var rawFrame: CVPixelBuffer?
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, image, _, _ in rawFrame = image }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard let rawFrame else { return nil }
            let attachments = CVBufferCopyAttachments(rawFrame, .shouldPropagate) as? [String: Any] ?? [:]
            return (attachments, try decodeScale(asset: asset, track: track, raw: rawFrame, attachments: attachments))
        }
        guard let a = found?.attachments else { return raw }
        func number(_ k: CFString) -> Double? { (a[k as String] as? NSNumber)?.doubleValue }
        raw.gain = number(kCVPixelBufferProResRAWKey_GainFactor)
        if let r = number(kCVPixelBufferProResRAWKey_WhiteBalanceRedFactor), let b = number(kCVPixelBufferProResRAWKey_WhiteBalanceBlueFactor) { raw.whiteBalance = [r, b] }
        if let cct = number(kCVPixelBufferProResRAWKey_WhiteBalanceCCT), cct > 0 { raw.temperature = cct }
        if let m = a[kCVPixelBufferProResRAWKey_ColorMatrix as String] as? Data, m.count == 36 {
            raw.colorMatrix = m.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }.map(Double.init)
        }
        raw.decodeScale = found?.scale
        return raw
    }

    /// AVFoundation's decode of the first frame over the documented conversion (black/white levels, white balance,
    /// color matrix, gain) of the same raw frame, averaged over the center; nil when the raw layout isn't the
    /// four quarter-size Bayer planes this was measured on.
    static func decodeScale(asset: AVAsset, track: AVAssetTrack, raw: CVPixelBuffer, attachments a: [String: Any]) throws -> Double? {
        guard CVPixelBufferGetPlaneCount(raw) == 4, let black = (a[kCVPixelBufferProResRAWKey_BlackLevel as String] as? NSNumber)?.doubleValue,
              let white = (a[kCVPixelBufferProResRAWKey_WhiteLevel as String] as? NSNumber)?.doubleValue,
              let gain = (a[kCVPixelBufferProResRAWKey_GainFactor as String] as? NSNumber)?.doubleValue,
              let wr = (a[kCVPixelBufferProResRAWKey_WhiteBalanceRedFactor as String] as? NSNumber)?.doubleValue,
              let wb = (a[kCVPixelBufferProResRAWKey_WhiteBalanceBlueFactor as String] as? NSNumber)?.doubleValue,
              let md = a[kCVPixelBufferProResRAWKey_ColorMatrix as String] as? Data, md.count == 36,
              (a[kCVPixelBufferVersatileBayerKey_BayerPattern as String] as? NSNumber)?.intValue ?? 0 == 0, white > black else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(raw, 0), h = CVPixelBufferGetHeightOfPlane(raw, 0)
        let half = max(4, min(w, h) / 8)
        CVPixelBufferLockBaseAddress(raw, .readOnly)
        var means = [Double](repeating: 0, count: 4)
        for i in 0..<4 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(raw, i)?.assumingMemoryBound(to: UInt16.self) else { CVPixelBufferUnlockBaseAddress(raw, .readOnly); return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(raw, i) / 2
            var sum = 0.0
            for y in (h / 2 - half)..<(h / 2 + half) { for x in (w / 2 - half)..<(w / 2 + half) { sum += Double(base[y * stride + x]) } }
            means[i] = sum / Double(4 * half * half)
        }
        CVPixelBufferUnlockBaseAddress(raw, .readOnly)
        let m: [Double] = md.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }.map(Double.init)
        let toXYZ = simd_double3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])])
        let cam = (SIMD3(means[0], (means[1] + means[2]) / 2, means[3]) - black) / (white - black)
        let predicted = Primaries.rec2020.toXYZ.inverse * toXYZ * (cam * SIMD3(wr, 1, wb)) * gain
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        reader.add(out)
        guard reader.startReading(), let s = out.nextSample(), let pb = CMSampleBufferGetImageBuffer(s) else { return nil }
        defer { reader.cancelReading() }
        guard CVPixelBufferGetWidth(pb) == 2 * w, CVPixelBufferGetHeight(pb) == 2 * h else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: Float16.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb) / 2
        var got = SIMD3<Double>.zero
        for y in (h - 2 * half)..<(h + 2 * half) {
            for x in (w - 2 * half)..<(w + 2 * half) {
                let p = base + y * stride + x * 4
                got += SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
            }
        }
        got /= Double(16 * half * half)
        guard predicted.y > 1e-4 else { return nil }
        return got.y / predicted.y
    }

    static func cameraName(_ asset: AVAsset) async -> String? {
        guard let items = try? await asset.load(.metadata) else { return nil }
        var make: String?, model: String?
        for item in items {
            let key = (item.identifier?.rawValue ?? "").lowercased()
            if key.hasSuffix("make"), make == nil { make = try? await item.load(.stringValue) }
            if key.hasSuffix("model"), model == nil { model = try? await item.load(.stringValue) }
        }
        let name = [make, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// Size, camera, as-shot ISO and white balance of a DNG frame or raw still, as `CIRAWFilter` reads it.
    public static func stillMetadata(_ url: URL, format: RawFormat) throws -> (raw: RawMedia, width: Int, height: Int) {
        guard let f = CIRAWFilter(imageURL: url), f.nativeSize.width > 0, let out = f.outputImage else {
            throw MediaIngest.Failure(file: url.path, codec: format.title, reason: "macOS can't decode this camera's raw files", fix: "Convert to DNG with Adobe DNG Converter, or export a 16-bit TIFF, then import that")
        }
        var raw = RawMedia(format: format)
        let props = f.properties
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let dng = props[kCGImagePropertyDNGDictionary as String] as? [String: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let name = [tiff[kCGImagePropertyTIFFMake as String] as? String, tiff[kCGImagePropertyTIFFModel as String] as? String].compactMap { $0 }.joined(separator: " ")
        raw.camera = name.isEmpty ? dng[kCGImagePropertyDNGUniqueCameraModel as String] as? String : name
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue, iso > 0 { raw.iso = iso }
        raw.temperature = Double(f.neutralTemperature)
        raw.tint = Double(f.neutralTint)
        let e = out.extent
        return (raw, Int(e.width.rounded()), Int(e.height.rounded()))
    }

    /// CinemaDNG FrameRate (tag 51044) and TimeCodes (51043, SMPTE 12M packed) from a frame's first IFD.
    public static func cinemaDNGTiming(_ url: URL) -> (fps: Double?, timecode: String?) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 16 else { return (nil, nil) }
        let little = d[0] == 0x49
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(little ? UInt16(d[o]) | UInt16(d[o + 1]) << 8 : UInt16(d[o]) << 8 | UInt16(d[o + 1])) : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? Int(little ? UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 : UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])) : 0 }
        let ifd = u32(4)
        guard ifd > 0, ifd + 2 < d.count else { return (nil, nil) }
        var fps: Double?, tc: String?
        for i in 0..<u16(ifd) {
            let e = ifd + 2 + 12 * i
            guard e + 12 <= d.count else { break }
            let tag = u16(e)
            if tag == 51044 {
                let o = u32(e + 8)
                let num = Int32(truncatingIfNeeded: u32(o)), den = Int32(truncatingIfNeeded: u32(o + 4))
                if den != 0, num > 0 { fps = Double(num) / Double(den) }
            } else if tag == 51043, u32(e + 4) >= 4 {
                let o = u32(e + 8)
                guard o + 4 <= d.count else { continue }
                func bcd(_ b: UInt8, _ mask: UInt8) -> Int { Int((b & mask) >> 4) * 10 + Int(b & 0x0F) }
                let ff = bcd(d[o], 0x30), ss = bcd(d[o + 1], 0x70), mm = bcd(d[o + 2], 0x70), hh = bcd(d[o + 3], 0x30)
                let drop = d[o] & 0x40 != 0
                tc = String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, drop ? ";" : ":", ff)
            }
        }
        return (fps, tc)
    }

    // MARK: Import

    /// The developed copy of a RAW source in a bundle cache; changes when the source changes.
    public static func developedURL(for source: URL, cache: URL) -> URL {
        var stamp = source.standardizedFileURL.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
            let frames = dngFrames(in: source)
            stamp += "|\(frames.count)|\(frames.first?.lastPathComponent ?? "")|\(frames.last?.lastPathComponent ?? "")"
            if let last = frames.last, let a = try? FileManager.default.attributesOfItem(atPath: last.path) { stamp += "|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" }
        } else if let a = try? FileManager.default.attributesOfItem(atPath: source.path) {
            stamp += "|\(a[.size] as? Int ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        stamp += "|\(CameraRaw.workingLog.rawValue)|v1"
        let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)
        let stem = source.deletingPathExtension().lastPathComponent.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return cache.appendingPathComponent("raw", isDirectory: true).appendingPathComponent("\(String(stem).prefix(40))-\(key).mov")
    }

    /// Media for a RAW source: a still is ready as is; video is developed now when small (under `syncPixels`
    /// frame-pixels), otherwise `.deferred` with a placeholder for a background `finish`.
    public static func prepare(_ source: Source, id: String, cache: URL, fps: Double?, syncPixels: Double = 1.5e9, progress: (@Sendable (Double) -> Void)? = nil) async throws -> MediaIngest.Prepared {
        switch source {
        case .vendor(let f, let url):
            throw vendorFailure(f, url)
        case .still(let url):
            let (raw, w, h) = try stillMetadata(url, format: .camera_raw)
            var m = MediaAsset(id: id, path: url.path, name: MediaProbe.displayName(url), duration: 0, width: w, height: h, fps: 0, hasVideo: true, hasAudio: false, isImage: true)
            m.raw = raw
            m.log = CameraRaw.workingLog
            m.signalRange = .full
            return .ready(m)
        case .proresRaw(let url):
            var m = try await MediaProbe.probe(url, id: id)
            m.raw = try await proResMetadata(url)
            return try await placeholderOrFinish(m, original: url, cache: cache, syncPixels: syncPixels, progress: progress)
        case .dngSequence(let folder, let frames):
            guard let first = frames.first else { throw EditError("\(folder.path) has no DNG frames") }
            var (raw, w, h) = try stillMetadata(first, format: .cinemadng)
            raw.frames = frames.count
            let timing = cinemaDNGTiming(first)
            let rate = fps ?? timing.fps ?? 24
            var m = MediaAsset(id: id, path: folder.path, name: MediaProbe.displayName(folder), duration: Double(frames.count) / rate, width: w, height: h, fps: rate, hasVideo: true, hasAudio: false)
            m.raw = raw
            if let tc = timing.timecode {
                let f = TimecodeFormat(fps: rate, label: tc)
                if let n = f.frames(tc) { m.setTimecode(frames: n, format: f) }
            }
            if fps == nil, timing.fps == nil { m.metadata = ["raw_fps": "24 (assumed: the frames record no frame rate; re-import with fps to change)"] }
            return try await placeholderOrFinish(m, original: folder, cache: cache, syncPixels: syncPixels, progress: progress)
        }
    }

    static func placeholderOrFinish(_ probed: MediaAsset, original: URL, cache: URL, syncPixels: Double, progress: (@Sendable (Double) -> Void)?) async throws -> MediaIngest.Prepared {
        var m = probed
        m.originalPath = original.path
        m.log = CameraRaw.workingLog
        m.signalRange = .full
        m.fieldOrder = .progressive
        let dest = developedURL(for: original, cache: cache)
        if FileManager.default.fileExists(atPath: dest.path), await MediaIngest.verify(dest) == nil {
            return .ready(try await link(m, developed: dest))
        }
        let pixels = Double(m.width * m.height) * max(1, m.duration * m.fps)
        m.transcoded = MediaAsset.pendingTranscode + summary(m)
        if pixels > syncPixels { return .developing(m) }
        return .ready(try await finish(m, cache: cache, progress: progress))
    }

    static func summary(_ m: MediaAsset) -> String {
        "\(m.raw?.format.title ?? "RAW") → ProRes 4444 XQ, scene light in \(CameraRaw.workingLog.name) (as shot)"
    }

    /// Develops a placeholder's source as shot and returns the media pointing at the copy.
    public static func finish(_ placeholder: MediaAsset, cache: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> MediaAsset {
        guard let raw = placeholder.raw else { throw EditError("\(placeholder.id) isn't camera RAW") }
        let original = placeholder.conformURL
        let dest = developedURL(for: original, cache: cache)
        do {
            try await CameraRawDevelop.write(source: original, raw: raw, settings: RawSettings(), fps: placeholder.fps, size: (placeholder.width, placeholder.height), to: dest, progress: progress)
        } catch {
            throw MediaIngest.Failure(file: original.path, codec: raw.format.title, reason: "developing it failed (\(MediaIngest.describe(error)))")
        }
        if let why = await MediaIngest.verify(dest) {
            throw MediaIngest.Failure(file: original.path, codec: raw.format.title, reason: "its developed copy doesn't decode (\(why))")
        }
        return try await link(placeholder, developed: dest)
    }

    /// The developed copy's media, keeping the source's name, timing, timecode and RAW facts.
    static func link(_ source: MediaAsset, developed: URL) async throws -> MediaAsset {
        var m = try await MediaProbe.probe(developed, id: source.id)
        m.name = source.name
        m.originalPath = source.originalPath ?? source.path
        m.raw = source.raw
        m.log = CameraRaw.workingLog
        m.signalRange = .full
        m.fieldOrder = .progressive
        m.transcoded = summary(source)
        m.fps = source.fps
        if let tc = source.timecodeLabel, let start = source.timecodeStart { m.timecodeLabel = tc; m.timecodeStart = start }
        m.reel = source.reel ?? m.reel
        m.metadata = source.metadata
        return m
    }
}

/// Writing developed copies, and the copies DNG clips need for settings other than as shot.
public enum CameraRawDevelop {
    static let lock = NSLock()
    nonisolated(unsafe) static var inFlight: [String: Task<URL, Error>] = [:]

    /// A copy a clip of DNG media needs: its source developed with `settings` (the baked part).
    public struct Request: Sendable {
        public var media: MediaAsset
        public var settings: RawSettings
        public var url: URL
        public var key: String { url.path }
        public var summary: String { "\(media.id) developed \(settings.summary)" }
    }

    /// The copy of DNG media developed with a clip's baked settings; nil when it plays the media's own copy
    /// (as shot, ProRes RAW, stills).
    public static func request(_ media: MediaAsset, clip: Clip?) -> Request? {
        guard let raw = media.raw, raw.format == .cinemadng, !media.isTranscoding, let s = media.rawSettings(for: clip)?.baked, !s.isEmpty else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let key = SHA256.hash(data: (try? enc.encode(s)) ?? Data()).map { String(format: "%02x", $0) }.joined().prefix(10)
        let url = media.url.deletingPathExtension().appendingPathExtension("dev-\(key).mov")
        return Request(media: media, settings: s, url: url)
    }

    /// Every developed copy a project's picture uses, nested sequences included.
    public static func requests(_ project: Project) -> [Request] {
        var out: [String: Request] = [:]
        for track in project.tracks where track.kind == .video {
            for c in track.clips {
                let clips = c.kind == .sequence ? project.expanded(c).filter { $0.clip.kind == .media && $0.kind == .video }.map(\.clip) : (c.kind == .media ? [c] : [])
                for clip in clips {
                    guard let m = clip.mediaId.flatMap({ project.mediaAsset($0) }), let r = request(m, clip: clip) else { continue }
                    out[r.key] = r
                }
            }
        }
        return out.values.sorted { $0.key < $1.key }
    }

    public static func cached(_ r: Request) -> URL? { FileManager.default.fileExists(atPath: r.url.path) ? r.url : nil }

    public static func isRendering(_ r: Request) -> Bool { lock.withLock { inFlight[r.key] != nil } }

    /// Develops every copy the project is missing; returns their summaries.
    @discardableResult
    public static func renderMissing(_ project: Project, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [String] {
        let missing = requests(project).filter { cached($0) == nil }
        for (k, r) in missing.enumerated() {
            let n = Double(missing.count)
            _ = try await render(r) { p in progress?((Double(k) + p) / n) }
        }
        return missing.map(\.summary)
    }

    /// The developed copy, rendering it unless cached; concurrent calls share one render.
    public static func render(_ r: Request, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let url = cached(r) { return url }
        let task = lock.withLock { () -> Task<URL, Error> in
            if let t = inFlight[r.key] { return t }
            let t = Task<URL, Error> {
                guard let raw = r.media.raw else { throw EditError("\(r.media.id) isn't camera RAW") }
                let tmp = r.url.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString).mov")
                do {
                    try await write(source: r.media.conformURL, raw: raw, settings: r.settings, fps: r.media.fps, size: (r.media.width, r.media.height), to: tmp, progress: progress)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    throw error
                }
                try? FileManager.default.removeItem(at: r.url)
                try FileManager.default.moveItem(at: tmp, to: r.url)
                return r.url
            }
            inFlight[r.key] = t
            return t
        }
        defer { lock.withLock { _ = inFlight.removeValue(forKey: r.key) } }
        return try await task.value
    }

    // MARK: Writing

    static let linear2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// A DNG frame or raw still developed with `settings` (exposure excluded), scene-linear.
    public static func developed(_ url: URL, raw: RawMedia, settings s: RawSettings) -> CIImage? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        f.boostAmount = 0
        f.extendedDynamicRangeAmount = 2
        if let t = s.temperature { f.neutralTemperature = Float(t) }
        if let t = s.tint { f.neutralTint = Float((raw.tint ?? Double(f.neutralTint)) + t) }
        if let h = s.highlights, f.isHighlightRecoverySupported { f.isHighlightRecoveryEnabled = h > 0 }
        if let n = s.noiseReduction {
            if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = Float(n) }
            if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = Float(n) }
        }
        return f.outputImage
    }

    /// Encodes a scene-linear BT.2020 RGBA half-float buffer in place into the working log.
    static func encodeInPlace(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rowBytes = CVPixelBufferGetBytesPerRow(pb)
        nonisolated(unsafe) let start = base
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let row = (start + y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                let p = row + x * 4
                let c = CameraRaw.encode(SIMD3(Float(p[0]), Float(p[1]), Float(p[2])))
                p[0] = Float16(c.x); p[1] = Float16(c.y); p[2] = Float16(c.z); p[3] = 1
            }
        }
    }

    /// Writes a developed copy: ProRes 4444 XQ at the source size and rate, scene light in the working log,
    /// with a ProRes RAW file's sound copied across.
    public static func write(source: URL, raw: RawMedia, settings: RawSettings, fps: Double, size: (Int, Int), to dest: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        let (w, h) = size
        guard w > 0, h > 0 else { throw EditError("Nothing to develop in \(source.lastPathComponent)") }
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType(rawValue: "ap4x"), AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(video)
        switch raw.format {
        case .prores_raw:
            try await writeProResRaw(source, writer: writer, video: video, adaptor: adaptor, size: size, progress: progress)
        case .cinemadng:
            let frames = CameraRawIngest.dngFrames(in: source)
            guard !frames.isEmpty else { throw EditError("\(source.path) has no DNG frames") }
            guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write \(dest.lastPathComponent)") }
            writer.startSession(atSourceTime: .zero)
            let rate = fps > 0 ? fps : 24
            let timescale = CMTimeScale(max(600, Int((rate * 1000).rounded())))
            try await runBlocking { cancelled in
                for (i, url) in frames.enumerated() {
                    if cancelled() { throw CancellationError() }
                    guard let img = developed(url, raw: raw, settings: settings) else { throw EditError("Cannot decode \(url.lastPathComponent)") }
                    try append(img, at: CMTime(value: CMTimeValue((Double(i) * Double(timescale) / rate).rounded()), timescale: timescale), video: video, adaptor: adaptor, writer: writer, cancelled: cancelled)
                    if i % 4 == 0 { progress?(min(0.99, Double(i) / Double(frames.count))) }
                }
            }
            video.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue((Double(frames.count) * Double(timescale) / rate).rounded()), timescale: timescale))
        default:
            throw EditError("\(raw.format.title) can't be developed on this Mac")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Cannot finish \(dest.lastPathComponent)") }
        progress?(1)
    }

    /// Renders a scene-linear picture (any color space) into a pool buffer, encodes it and appends it.
    static func append(_ img: CIImage, at t: CMTime, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter, cancelled: () -> Bool) throws {
        try WriterWait.readySync(video, writer, "The developed copy", cancelled: cancelled)
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? EditError("Cannot allocate frames") }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { throw EditError("Cannot allocate a frame") }
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        let placed = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        context.render(placed.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)), to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: linear2020)
        encodeInPlace(pb)
        guard adaptor.append(pb, withPresentationTime: t) else { throw writer.error ?? EditError("Cannot write a frame") }
    }

    static func writeProResRaw(_ source: URL, writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, size: (Int, Int), progress: (@Sendable (Double) -> Void)?) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditError("\(source.lastPathComponent) has no picture") }
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let pictures = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        pictures.alwaysCopiesSampleData = false
        reader.add(pictures)
        var sound: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for a in audioTracks {
            let out = AVAssetReaderTrackOutput(track: a, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            guard reader.canAdd(out) else { continue }
            reader.add(out)
            let fd = try await a.load(.formatDescriptions).first
            let asbd = fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: asbd?.mSampleRate ?? 48000, AVNumberOfChannelsKey: Int(asbd?.mChannelsPerFrame ?? 2),
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            sound.append((out, input))
        }
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read \(source.lastPathComponent)") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write the developed copy") }
        writer.startSession(atSourceTime: .zero)
        let start = try await track.load(.timeRange).start
        nonisolated(unsafe) let soundInputs = sound
        // Each sound track is copied on its own task so the writer can interleave them with the pictures.
        let soundDone = Task.detached {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (out, input) in soundInputs {
                    group.addTask {
                        while let s = out.nextSample() {
                            try await WriterWait.ready(input, writer, "The developed copy's sound")
                            var timed = s
                            let pts = CMSampleBufferGetPresentationTimeStamp(s)
                            if start != .zero, var info = Optional(CMSampleTimingInfo(duration: CMSampleBufferGetDuration(s), presentationTimeStamp: pts - start, decodeTimeStamp: .invalid)) {
                                var copy: CMSampleBuffer?
                                CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: s, sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleBufferOut: &copy)
                                if let copy { timed = copy }
                            }
                            guard input.append(timed) else { throw writer.error ?? EditError("Cannot write the developed copy's sound") }
                        }
                        input.markAsFinished()
                    }
                }
                try await group.waitForAll()
            }
        }
        do {
            try await runBlocking { cancelled in
                while let s = pictures.nextSample() {
                    guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
                    let t = CMSampleBufferGetPresentationTimeStamp(s) - start
                    try append(CIImage(cvPixelBuffer: pb), at: t, video: video, adaptor: adaptor, writer: writer, cancelled: cancelled)
                    if duration > 0 { progress?(min(0.99, t.seconds / duration)) }
                }
                if reader.status == .failed { throw reader.error ?? EditError("Cannot decode \(source.lastPathComponent)") }
            }
        } catch {
            soundDone.cancel()
            writer.cancelWriting()
            throw error
        }
        video.markAsFinished()
        try await soundDone.value
    }
}

/// Plays RAW media: the live part of a development (`CameraRaw.inputTransform`) as a cube on the developed picture,
/// and developed raw stills.
public enum CameraRawRender {
    /// A developed picture's raw code values (`ColorManagement.rawImage`) to the working space.
    public static func applyInput(_ raw: CIImage, media: RawMedia, settings: RawSettings, target: WorkingSpace, tone: ToneMap, exposure: Float) -> CIImage {
        guard CameraRaw.liveAdjustment(media, settings) != nil else {
            return ColorManagement.applyInput(raw, log: CameraRaw.workingLog, target: target, tone: tone, exposure: exposure, recordedIn: .full)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var identity = media
        identity.settings = RawSettings()
        let facts = (try? enc.encode(identity)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let live = (try? enc.encode(RawSettings(exposure: settings.exposure, iso: settings.iso, temperature: settings.temperature, tint: settings.tint, highlights: settings.highlights))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let key = "raw|\(facts)|\(live)|\(target.rawValue)|\(tone.rawValue)|\(String(format: "%.4f", exposure))" as NSString
        let cube: ColorManagement.Cube
        if let hit = ColorManagement.cubes.object(forKey: key) {
            cube = hit
        } else {
            cube = ColorManagement.bake(size: 65, CameraRaw.inputTransform(media, settings, target: target, tone: tone, exposure: exposure))
            ColorManagement.cubes.setObject(cube, forKey: key)
        }
        let mapped = raw.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": ColorManagement.passthroughSpace,
        ])
        return mapped.matchedToWorkingSpace(from: ColorManagement.colorSpace(target)) ?? mapped
    }

    final class Still {
        let image: CIImage
        init(_ image: CIImage) { self.image = image }
    }

    nonisolated(unsafe) static let stills: NSCache<NSString, Still> = {
        let c = NSCache<NSString, Still>()
        c.countLimit = 16
        return c
    }()

    /// A raw still developed with `settings` (exposure is applied live), as working-log code values to pass to
    /// `applyInput`.
    public static func stillImage(_ media: MediaAsset, settings: RawSettings) -> CIImage? {
        guard let raw = media.raw else { return nil }
        let baked = settings.baked
        let key = "\(media.path)|\(baked.summary)" as NSString
        if let hit = stills.object(forKey: key) { return hit.image }
        guard let img = CameraRawDevelop.developed(media.url, raw: raw, settings: baked) else { return nil }
        let e = img.extent.integral
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(e.width), Int(e.height), kCVPixelFormatType_64RGBAHalf, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        let placed = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        CameraRawDevelop.context.render(placed, to: pb, bounds: CGRect(origin: .zero, size: e.size), colorSpace: CameraRawDevelop.linear2020)
        CameraRawDevelop.encodeInPlace(pb)
        let out = ColorManagement.rawImage(pb)
        stills.setObject(Still(out), forKey: key)
        return out
    }
}
