import AVFoundation
import CryptoKit
import CutlineCore
import Foundation

/// A media file's audio as numbered source channels across all its audio tracks: describing them, reading any
/// of them, and the cached files that routing and analysis read.
public enum SourceChannels {
    static let rate = AudioStems.sampleRate

    // MARK: Description

    /// Every source channel of the file, in track order, with layout labels and recorder names when it has them.
    public static func describe(_ url: URL) async -> [SourceChannel]? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return nil }
        var out: [SourceChannel] = []
        for (t, track) in tracks.enumerated() {
            let fd = try? await track.load(.formatDescriptions).first
            let count = fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }.map(Int.init) ?? 1
            let labels = fd.map { labelsOf($0, count: count) } ?? []
            var title: String?
            if let items = try? await track.load(.commonMetadata),
               let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first {
                title = try? await item.load(.stringValue)
            }
            for c in 0..<max(count, 1) {
                out.append(SourceChannel(track: t + 1, channel: c + 1, label: c < labels.count ? labels[c] : nil, name: count == 1 ? title : nil))
            }
        }
        for (i, name) in recorderNames(url) where i >= 1 && i <= out.count { out[i - 1].name = name }
        return out
    }

    /// Speaker labels of a track's channels from its layout; nil entries where the layout says nothing useful.
    static func labelsOf(_ fd: CMAudioFormatDescription, count: Int) -> [String?] {
        var size = 0
        guard count > 1, let ptr = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size) else { return [] }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) ?? 12
        func labels(_ p: UnsafeRawPointer) -> [AudioChannelLabel] {
            let l = p.assumingMemoryBound(to: AudioChannelLayout.self).pointee
            let d = (p + offset).assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<Int(l.mNumberChannelDescriptions)).map { d[$0].mChannelLabel }
        }
        var codes: [AudioChannelLabel] = []
        let tag0 = ptr.pointee.mChannelLayoutTag
        if tag0 == kAudioChannelLayoutTag_UseChannelDescriptions {
            codes = labels(UnsafeRawPointer(ptr))
        } else if tag0 != kAudioChannelLayoutTag_UseChannelBitmap {
            var tag = tag0
            var bytes: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &bytes) == noErr, bytes > 0 else { return [] }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: 16)
            defer { raw.deallocate() }
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &bytes, raw) == noErr else { return [] }
            codes = labels(UnsafeRawPointer(raw))
        }
        let names: [AudioChannelLabel: String] = [
            kAudioChannelLabel_Left: "L", kAudioChannelLabel_Right: "R", kAudioChannelLabel_Center: "C", kAudioChannelLabel_LFEScreen: "LFE",
            kAudioChannelLabel_LeftSurround: "Ls", kAudioChannelLabel_RightSurround: "Rs", kAudioChannelLabel_RearSurroundLeft: "Lrs", kAudioChannelLabel_RearSurroundRight: "Rrs",
            kAudioChannelLabel_CenterSurround: "Cs", kAudioChannelLabel_LeftCenter: "Lc", kAudioChannelLabel_RightCenter: "Rc",
            kAudioChannelLabel_LeftSurroundDirect: "Lsd", kAudioChannelLabel_RightSurroundDirect: "Rsd", kAudioChannelLabel_Mono: "M",
            kAudioChannelLabel_LeftTotal: "Lt", kAudioChannelLabel_RightTotal: "Rt",
        ]
        return codes.prefix(count).map { names[$0] }
    }

    /// Track names a recorder wrote into a Broadcast WAV: iXML TRACK_LIST, else bext "sTRK1=Boom" lines. Keyed from 1.
    public static func recorderNames(_ url: URL) -> [Int: String] {
        guard ["wav", "bwf", "wave"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              String(decoding: head.prefix(4), as: UTF8.self) == "RIFF" || String(decoding: head.prefix(4), as: UTF8.self) == "RF64" else { return [:] }
        var ixml: String?, bext: String?
        var offset: UInt64 = 12
        while let hdr = try? { () throws -> Data? in try handle.seek(toOffset: offset); return try handle.read(upToCount: 8) }(), hdr.count == 8 {
            let id = String(decoding: hdr.prefix(4), as: UTF8.self)
            let size = UInt64(hdr[4]) | UInt64(hdr[5]) << 8 | UInt64(hdr[6]) << 16 | UInt64(hdr[7]) << 24
            if id == "iXML" || id == "bext", size < 4_000_000, let body = try? handle.read(upToCount: Int(size)) {
                if id == "iXML" { ixml = String(decoding: body, as: UTF8.self) } else if body.count > 256 {
                    bext = String(decoding: body.prefix(256), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
                }
            }
            if id == "data" && size == 0xFFFF_FFFF { break }
            offset += 8 + size + (size & 1)
        }
        var names: [Int: String] = [:]
        if let ixml {
            for block in ixml.components(separatedBy: "<TRACK>").dropFirst() {
                func field(_ tag: String) -> String? {
                    guard let a = block.range(of: "<\(tag)>"), let b = block.range(of: "</\(tag)>", range: a.upperBound..<block.endIndex) else { return nil }
                    let v = block[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    return v.isEmpty ? nil : v
                }
                guard let i = (field("CHANNEL_INDEX") ?? field("INTERLEAVE_INDEX")).flatMap(Int.init), let n = field("NAME") else { continue }
                names[i] = n
            }
        }
        if names.isEmpty, let bext {
            for line in bext.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].count > 4, parts[0].dropFirst().hasPrefix("TRK"), let i = Int(parts[0].dropFirst(4)) else { continue }
                let n = parts[1].trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { names[i] = n }
            }
        }
        return names
    }

    // MARK: Reading

    /// Streams the file's audio at 48 kHz as one array per source channel (all of them, in order), in chunks.
    /// Every audio track is read separately and kept aligned by presentation time; shorter tracks are padded with silence.
    public static func read(_ url: URL, _ body: ([[Float]]) throws -> Void) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw EditError("\(url.lastPathComponent) has no audio") }
        var counts: [Int] = []
        for t in tracks {
            let fd = try await t.load(.formatDescriptions).first
            counts.append(max(1, fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }.map(Int.init) ?? 1))
        }
        let reader = try AVAssetReader(asset: asset)
        let outputs = zip(tracks, counts).map { track, n -> AVAssetReaderTrackOutput in
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: n,
            ]
            if n > 2 { settings[AVChannelLayoutKey] = AudioLayout.layoutData(kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(n)) }
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            o.alwaysCopiesSampleData = false
            reader.add(o)
            return o
        }
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the audio of \(url.lastPathComponent)") }
        try await withoutActuallyEscaping(body) { body in
            try await AudioIO.offPool {
                // Per track: channels waiting to be handed out, and where (in frames) the next sample belongs.
                var queues = counts.map { [[Float]](repeating: [], count: $0) }
                var positions = [Int64](repeating: 0, count: tracks.count)
                var done = [Bool](repeating: false, count: tracks.count)
                let target = 32_768
                func pull(_ t: Int) {
                    guard !done[t], let sample = outputs[t].copyNextSampleBuffer() else { done[t] = true; return }
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
                    let n = counts[t]
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let at = pts.isValid ? Int64((pts.seconds * rate).rounded()) : positions[t]
                    if at > positions[t] {
                        let gap = Int(min(at - positions[t], Int64(rate * 3600)))
                        for c in 0..<n { queues[t][c] += [Float](repeating: 0, count: gap) }
                        positions[t] += Int64(gap)
                    }
                    var length = 0
                    var ptr: UnsafeMutablePointer<CChar>?
                    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { return }
                    let frames = length / (MemoryLayout<Float>.size * n)
                    ptr.withMemoryRebound(to: Float.self, capacity: frames * n) { s in
                        for c in 0..<n {
                            var ch = [Float](repeating: 0, count: frames)
                            for i in 0..<frames { ch[i] = s[i * n + c] }
                            queues[t][c] += ch
                        }
                    }
                    positions[t] += Int64(frames)
                }
                func emit(_ count: Int) throws {
                    guard count > 0 else { return }
                    var out: [[Float]] = []
                    for t in queues.indices {
                        for c in queues[t].indices {
                            let have = min(count, queues[t][c].count)
                            out.append(Array(queues[t][c].prefix(have)) + [Float](repeating: 0, count: count - have))
                            queues[t][c].removeFirst(have)
                        }
                    }
                    try body(out)
                }
                while true {
                    for t in tracks.indices where !done[t] && (queues[t].first?.count ?? 0) < target { pull(t) }
                    let live = tracks.indices.filter { !done[$0] }
                    if live.isEmpty { break }
                    let ready = live.map { queues[$0].first?.count ?? 0 }.min() ?? 0
                    if ready >= target { try emit(ready) }
                }
                let rest = queues.map { $0.first?.count ?? 0 }.max() ?? 0
                try emit(rest)
            }
        }
        if reader.status == .failed { throw reader.error ?? EditError("Reading the audio of \(url.lastPathComponent) failed") }
    }

    // MARK: Routed sound

    static func stamp(_ media: MediaAsset) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: media.path)
        return "\(media.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    static func key(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    /// The stereo file a clip with `routing` plays: the whole media, 48 kHz, with its source channels routed to left and right.
    static func routedURL(_ media: MediaAsset, _ routing: ChannelRouting, in dir: URL) -> URL {
        dir.appendingPathComponent("route-\(key(stamp(media), routing.rawValue, "v1")).caf")
    }

    /// Writes `media`'s sound routed by `routing` as 24-bit ALAC stereo whose time matches the media's.
    static func renderRouted(_ media: MediaAsset, _ routing: ChannelRouting, to url: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("stem-\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: tmp) }
        let file = try AVAudioFile(forWriting: tmp, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try await read(media.url) { x in
            let m = routing.matrix(count: x.count)
            let n = x.first?.count ?? 0
            var l = [Float](repeating: 0, count: n), r = l
            for (c, ch) in x.enumerated() {
                if c < m.left.count, m.left[c] != 0 { let g = Float(m.left[c]); for i in 0..<n { l[i] += g * ch[i] } }
                if c < m.right.count, m.right[c] != 0 { let g = Float(m.right[c]); for i in 0..<n { r[i] += g * ch[i] } }
            }
            try AudioIO.write([l, r], to: file)
        }
        file.close()
        try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
    }

    // MARK: Analysis source

    /// What analysis and sync hear from a media file: `channel` when given, else for files with more than one
    /// stereo or mono track, every channel with sound summed at 1/n. Returns nil when the file's first track is
    /// the whole sound and no channel was asked for, so callers read the file itself.
    public static func analysisSource(_ media: MediaAsset, channel: ChannelRouting?, cache: URL) async throws -> (url: URL, heard: String)? {
        var chs = media.audioChannels
        if chs == nil { chs = await describe(media.url) }
        let count = chs?.count ?? 0
        let multi = Set((chs ?? []).map(\.track)).count > 1 || count > 2
        if let channel, let why = channel.problem(count: count) { throw EditError("channel \(channel.rawValue): \(why)") }
        guard channel != nil || multi else { return nil }
        if let channel, channel.isAsRecorded { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let url = cache.appendingPathComponent("analysis-\(media.id)-\(key(stamp(media), channel?.rawValue ?? "auto", "v1")).caf")
        var weights: [Double]
        var heard: String
        if let channel {
            let m = channel.matrix(count: max(count, 1))
            weights = zip(m.left, m.right).map { ($0 + $1) / 2 }
            heard = channel.rawValue
        } else {
            // Channels with sound: those within 40 dB of the loudest.
            var energy = [Double](repeating: 0, count: count)
            try await read(media.url) { x in
                for c in 0..<min(count, x.count) { energy[c] += x[c].reduce(0) { $0 + Double($1 * $1) } }
            }
            let loudest = energy.max() ?? 0
            let active = energy.indices.filter { loudest > 0 && energy[$0] > loudest * 1e-4 }
            weights = energy.indices.map { active.contains($0) ? 1 / Double(max(active.count, 1)) : 0 }
            heard = active.isEmpty ? "silence" : active.count == 1 ? "ch\(active[0] + 1)" : "mix of " + active.map { "ch\($0 + 1)" }.joined(separator: ", ")
            if active.count < count { heard += " (\(count - active.count) silent channel\(count - active.count == 1 ? "" : "s") left out)" }
        }
        if fm.fileExists(atPath: url.path) { return (url, heard) }
        let tmp = cache.appendingPathComponent("analysis-\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: tmp) }
        let file = try AVAudioFile(forWriting: tmp, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 24,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try await read(media.url) { x in
            let n = x.first?.count ?? 0
            var y = [Float](repeating: 0, count: n)
            for (c, ch) in x.enumerated() where c < weights.count && weights[c] != 0 {
                let g = Float(weights[c])
                for i in 0..<n { y[i] += g * ch[i] }
            }
            try AudioIO.write([y], to: file)
        }
        file.close()
        try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
        return (url, heard)
    }
}

extension AudioStems {
    /// The routed source a clip with non-default `audio.channels` plays, when it's rendered.
    public func cachedRoute(_ media: MediaAsset, _ routing: ChannelRouting) -> URL? {
        let u = SourceChannels.routedURL(media, routing, in: directory)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
