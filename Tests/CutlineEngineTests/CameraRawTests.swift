import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// Optional real camera files, fetched once into /tmp/cutline-raw-samples (see `rawSampleNote`); tests that use them
/// are skipped when they are absent.
let rawSamples = URL(fileURLWithPath: "/tmp/cutline-raw-samples")
let proResRawSample = rawSamples.appendingPathComponent("prores-raw/dji-inspire3-8k-proresraw-8f.mov")
let cinemaDNGSample = rawSamples.appendingPathComponent("dng/bmpcc-C0022_000007.dng")
let r3dSample = rawSamples.appendingPathComponent("r3d/4MB-sample.r3d")
let rawSampleNote: Testing.Comment = "camera sample missing under /tmp/cutline-raw-samples: ProRes RAW = first 8 frames of DJI's Inspire 3 sample nature11-A005C0032_230327_4U1Q.MOV (dji.com/inspire-3/samples); DNG = raw.pixls.us Blackmagic Pocket Cinema Camera frame; R3D = fate-suite.ffmpeg.org/r3d/4MB-sample.r3d"

private func tempDir(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-raw-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An uncompressed RGGB DNG whose camera space is linear sRGB (so as-shot output equals the sensel values):
/// left half a gray card at `gray`, right half a patch (0.3, 0.6, 0.1).
func writeDNG(_ url: URL, width w: Int = 640, height h: Int = 480, gray: Double = 0.18, fps: Double? = 24, iso: Int? = 800) throws {
    var entries: [(tag: UInt16, type: UInt16, count: UInt32, data: Data)] = []
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func short(_ tag: UInt16, _ vs: [UInt16]) { entries.append((tag, 3, UInt32(vs.count), vs.reduce(Data()) { $0 + le16($1) })) }
    func long(_ tag: UInt16, _ vs: [UInt32]) { entries.append((tag, 4, UInt32(vs.count), vs.reduce(Data()) { $0 + le32($1) })) }
    func byte(_ tag: UInt16, _ vs: [UInt8]) { entries.append((tag, 1, UInt32(vs.count), Data(vs))) }
    func ascii(_ tag: UInt16, _ s: String) { let d = Data(s.utf8) + Data([0]); entries.append((tag, 2, UInt32(d.count), d)) }
    func rational(_ tag: UInt16, _ vs: [(UInt32, UInt32)]) { entries.append((tag, 5, UInt32(vs.count), vs.reduce(Data()) { $0 + le32($1.0) + le32($1.1) })) }
    func srational(_ tag: UInt16, _ vs: [(Int32, Int32)]) { entries.append((tag, 10, UInt32(vs.count), vs.reduce(Data()) { $0 + le32(UInt32(bitPattern: $1.0)) + le32(UInt32(bitPattern: $1.1)) })) }
    var pixels = Data(capacity: w * h * 2)
    for y in 0..<h {
        for x in 0..<w {
            let red = y % 2 == 0 && x % 2 == 0, blue = y % 2 == 1 && x % 2 == 1
            let v = x < w / 2 ? gray : (red ? 0.3 : blue ? 0.1 : 0.6)
            pixels += le16(UInt16(min(65535, (v * 65535).rounded())))
        }
    }
    long(254, [0]); long(256, [UInt32(w)]); long(257, [UInt32(h)])
    short(258, [16]); short(259, [1]); short(262, [32803])
    long(273, [0])
    short(274, [1]); short(277, [1]); long(278, [UInt32(h)]); long(279, [UInt32(pixels.count)]); short(284, [1])
    short(33421, [2, 2]); byte(33422, [0, 1, 1, 2])
    if let iso { short(34855, [UInt16(iso)]) }
    byte(50706, [1, 4, 0, 0]); byte(50707, [1, 1, 0, 0])
    ascii(50708, "Cutline Test Camera")
    long(50714, [0]); long(50717, [65535])
    let xyzToSRGB: [Double] = [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252]
    srational(50721, xyzToSRGB.map { (Int32(($0 * 1_000_000).rounded()), 1_000_000) })
    rational(50728, [(1, 1), (1, 1), (1, 1)])
    srational(50730, [(0, 1)])
    short(50778, [21])
    if let fps { srational(51044, [(Int32(fps * 1000), 1000)]) }
    entries.sort { $0.tag < $1.tag }
    let extraBase = 8 + 2 + entries.count * 12 + 4
    var ifd = le16(UInt16(entries.count)), extra = Data()
    var stripPatch = 0
    for e in entries {
        ifd += le16(e.tag) + le16(e.type) + le32(e.count)
        if e.tag == 273 { stripPatch = ifd.count }
        if e.data.count <= 4 {
            ifd += e.data + Data(count: 4 - e.data.count)
        } else {
            ifd += le32(UInt32(extraBase + extra.count))
            extra += e.data
            if extra.count % 2 == 1 { extra += Data([0]) }
        }
    }
    ifd += le32(0)
    ifd.replaceSubrange(stripPatch..<(stripPatch + 4), with: le32(UInt32(extraBase + extra.count)))
    try (Data([0x49, 0x49, 42, 0]) + le32(8) + ifd + extra + pixels).write(to: url)
}

private func dngFolder(_ dir: URL, frames: Int = 6) throws -> URL {
    let folder = dir.appendingPathComponent("A001_C003", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<frames { try writeDNG(folder.appendingPathComponent(String(format: "A001_C003_%06d.dng", i + 1))) }
    return folder
}

/// Mean RGB of a frame's region (fractions of the frame), 0…1.
private func mean(_ img: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> SIMD3<Double> {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var s = SIMD3<Double>.zero, n = 0.0
    for py in Int(y.lowerBound * Double(h))..<Int(y.upperBound * Double(h)) {
        for px in Int(x.lowerBound * Double(w))..<Int(x.upperBound * Double(w)) {
            let o = (py * w + px) * 4
            s += SIMD3(Double(buf[o]), Double(buf[o + 1]), Double(buf[o + 2])) / 255
            n += 1
        }
    }
    return s / n
}

/// The first frame of a movie as scene-linear BT.2020 at the center of the left (gray card) half.
private func developedGray(_ url: URL) async throws -> SIMD3<Float> {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
    reader.add(out)
    reader.startReading()
    let pb = try #require(out.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let row = CVPixelBufferGetBaseAddress(pb)!.advanced(by: CVPixelBufferGetHeight(pb) / 2 * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: Float16.self)
    let p = row + CVPixelBufferGetWidth(pb) / 4 * 4
    return CameraRaw.decode(SIMD3(Float(p[0]), Float(p[1]), Float(p[2])))
}

@Test func vendorRawIsRecognizedByExtensionAndMagic() async throws {
    let dir = try tempDir("vendor")
    defer { try? FileManager.default.removeItem(at: dir) }
    let braw = dir.appendingPathComponent("A001_08121513_C001.braw")
    try (Data([0, 0, 0, 20]) + Data("ftypqt  ".utf8) + Data(count: 64)).write(to: braw)
    let renamed = dir.appendingPathComponent("clip.bin")
    try (Data([0, 0, 1, 0x44]) + Data("RED2".utf8) + Data(count: 64)).write(to: renamed)
    let crm = dir.appendingPathComponent("A001C001.CRM")
    try (Data([0, 0, 0, 24]) + Data("ftypcrx ".utf8) + Data(count: 64)).write(to: crm)
    let ari = dir.appendingPathComponent("frame.0001.ari")
    try (Data("ARRI".utf8) + Data([0x78, 0x56, 0x34, 0x12]) + Data(count: 64)).write(to: ari)
    #expect(CameraRawIngest.classify(braw) == .vendor(.braw, braw))
    #expect(CameraRawIngest.classify(renamed) == .vendor(.r3d, renamed))
    #expect(CameraRawIngest.classify(crm) == .vendor(.canon_raw_light, crm))
    #expect(CameraRawIngest.classify(ari) == .vendor(.arriraw, ari))
    let f = CameraRawIngest.vendorFailure(.braw, braw)
    #expect(f.description.contains("Blackmagic RAW SDK") && f.description.contains("Blackmagic RAW Player"), "\(f)")
    do {
        _ = try await MediaIngest.prepare(braw, id: "b", cache: dir, tools: nil)
        Issue.record("BRAW imported")
    } catch let e as MediaIngest.Failure {
        #expect(e.codec == "Blackmagic RAW (BRAW)" && e.description.contains("ProRes 4444 XQ"), "\(e)")
    }
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: r3dSample.path), rawSampleNote)) func realR3DIsReportedNotTranscoded() async throws {
    #expect(CameraRawIngest.vendorMagic(r3dSample) == .r3d)
    do {
        _ = try await MediaIngest.prepare(r3dSample, id: "r", cache: FileManager.default.temporaryDirectory, tools: FFmpeg.tools())
        Issue.record("R3D imported")
    } catch let e as MediaIngest.Failure {
        #expect(e.description.contains("RED SDK") && e.description.contains("REDCINE-X") && e.description.contains("undebayered"), "\(e)")
    }
}

@Test func cinemaDNGTimingIsRead() throws {
    let dir = try tempDir("timing")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("f.dng")
    try writeDNG(url, fps: 25)
    #expect(CameraRawIngest.cinemaDNGTiming(url).fps == 25)
    // DNG photos without CinemaDNG timing stay stills.
    let photos = dir.appendingPathComponent("photos", isDirectory: true)
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    for i in 1...3 { try writeDNG(photos.appendingPathComponent("IMG_000\(i).dng"), fps: nil) }
    #expect(CameraRawIngest.classify(photos) == nil)
    #expect(CameraRawIngest.classify(photos.appendingPathComponent("IMG_0001.dng")) == .still(photos.appendingPathComponent("IMG_0001.dng")))
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: proResRawSample.path), rawSampleNote)) func proResRawSoundIsKeptInTheDevelopedCopy() async throws {
    let dir = try tempDir("prr-sound")
    defer { try? FileManager.default.removeItem(at: dir) }
    let wav = dir.appendingPathComponent("tone.wav")
    do {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: wav, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600)!
        buffer.frameLength = 9_600
        for c in 0..<2 { for i in 0..<9_600 { buffer.floatChannelData![c][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) } }
        try file.write(from: buffer)
    }
    // Mux the sample's ProRes RAW picture with the tone, untouched.
    let pictureAsset = AVURLAsset(url: proResRawSample), soundAsset = AVURLAsset(url: wav)
    let video = try #require(try await pictureAsset.loadTracks(withMediaType: .video).first)
    let sound = try #require(try await soundAsset.loadTracks(withMediaType: .audio).first)
    let range = try await video.load(.timeRange)
    let muxed = dir.appendingPathComponent("with-sound.mov")
    let writer = try AVAssetWriter(outputURL: muxed, fileType: .mov)
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try await video.load(.formatDescriptions).first)
    let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
    writer.add(vIn)
    writer.add(aIn)
    let vReader = try AVAssetReader(asset: pictureAsset), aReader = try AVAssetReader(asset: soundAsset)
    let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil), aOut = AVAssetReaderTrackOutput(track: sound, outputSettings: pcm)
    vReader.add(vOut)
    aReader.add(aOut)
    vReader.startReading()
    aReader.startReading()
    writer.startWriting()
    writer.startSession(atSourceTime: range.start)
    while let s = vOut.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(s) > 0 else { continue }
        while !vIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        vIn.append(s)
    }
    vIn.markAsFinished()
    while let s = aOut.copyNextSampleBuffer() {
        while !aIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        aIn.append(s)
    }
    aIn.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
    #expect(await CameraRawIngest.isProResRaw(muxed))
    guard case .ready(let m) = try await MediaIngest.prepare(muxed, id: "s", cache: dir, tools: nil) else { Issue.record("not developed"); return }
    #expect(m.hasAudio && m.hasVideo && m.raw?.format == .prores_raw, "\(m)")
    #expect(abs(m.duration - (try await AVURLAsset(url: muxed).load(.duration).seconds)) < 0.02)
    #expect(await MediaIngest.verify(m.url) == nil)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: cinemaDNGSample.path), rawSampleNote)) func realCinemaDNGFrameReadsRateTimecodeAndCamera() throws {
    let t = CameraRawIngest.cinemaDNGTiming(cinemaDNGSample)
    #expect(t.fps == 24)
    #expect(t.timecode == "00:53:23:07")
    let (raw, w, h) = try CameraRawIngest.stillMetadata(cinemaDNGSample, format: .cinemadng)
    #expect(w == 1920 && h == 1080)
    #expect(raw.camera?.contains("Blackmagic") == true, "\(raw)")
    #expect((raw.temperature ?? 0) > 2000)
}

@Test func dngSequenceDevelopsToSceneLinearAndPlaysWithLiveExposure() async throws {
    let dir = try tempDir("dng")
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = try dngFolder(dir)
    #expect(CameraRawIngest.classify(folder) == .dngSequence(folder: folder, frames: CameraRawIngest.dngFrames(in: folder)))
    guard case .ready(let m) = try await MediaIngest.prepare(folder, id: "c003", cache: dir, tools: nil) else { Issue.record("not developed"); return }
    #expect(m.raw?.format == .cinemadng && m.raw?.frames == 6 && m.raw?.camera == "Cutline Test Camera")
    #expect(m.fps == 24 && abs(m.duration - 0.25) < 0.01 && m.width == 640 && m.height == 480)
    #expect(m.log == CameraRaw.workingLog && m.signalRange == .full && m.originalPath == folder.path && !m.isTranscoding)
    #expect(await MediaIngest.verify(m.url) == nil)
    // The copy holds CIRAWFilter's linear output: the 0.18 card (0.1755 after its baseline) in every channel.
    let gray = try await developedGray(m.url)
    #expect(abs(gray.x - 0.1755) < 0.01 && abs(gray.y - 0.1755) < 0.01 && abs(gray.z - 0.1755) < 0.01, "\(gray)")

    var p = Project(name: "RAW", canvas: Canvas(width: 640, height: 480, fps: 24))
    p.media = [m]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "c003", start: 0, duration: 0.25)]
    func frame(_ edit: (inout Clip) throws -> Void) async throws -> CGImage {
        var q = p
        try edit(&q.tracks[0].clips[0])
        try q.validate()
        try await CameraRawDevelop.renderMissing(q)
        let built = try await TimelineBuilder.build(q, transcripts: [:], library: MediaLibrary())
        #expect(built.missingPictures.isEmpty)
        return try #require(try await Frames.timeline(built, times: [0.1], maxSize: CGSize(width: 640, height: 480)).first?.image)
    }
    func linear(_ c: SIMD3<Double>) -> SIMD3<Double> { let t = WorkingSpace.rec709.transfer; return SIMD3(Double(t.decode(Float(c.x))), Double(t.decode(Float(c.y))), Double(t.decode(Float(c.z)))) }
    let card = (x: 0.1...0.4, y: 0.3...0.7)
    let base = linear(mean(try await frame { try $0.set("input.tone", .string("none")) }, x: card.x, y: card.y))
    let up = linear(mean(try await frame { try $0.set("input.tone", .string("none")); try $0.set("raw.exposure", .number(1)) }, x: card.x, y: card.y))
    #expect(abs(base.y - 0.1755) < 0.03, "\(base)")
    #expect(abs(up.y / base.y - 2) < 0.15, "+1 stop: \(base) → \(up)")
    // White balance is developed into a copy: a 3200 K light is neutralized by pushing the card blue.
    let cool = mean(try await frame { try $0.set("raw.temperature", .number(3200)) }, x: card.x, y: card.y)
    let asShot = mean(try await frame { _ in }, x: card.x, y: card.y)
    #expect(abs(asShot.x - asShot.z) < 0.02, "\(asShot)")
    #expect(cool.z > cool.x + 0.1, "3200 K: \(cool)")
    let magenta = mean(try await frame { try $0.set("raw.tint", .number(50)) }, x: card.x, y: card.y)
    #expect(magenta.x > magenta.y + 0.02 && magenta.z > magenta.y + 0.02, "tint +50: \(magenta)")
}

@Test func rawStillsDevelopOnTheFly() async throws {
    let dir = try tempDir("still")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("IMG_0001.dng")
    try writeDNG(url, fps: nil)
    guard case .ready(let m) = try await MediaIngest.prepare(url, id: "img", cache: dir, tools: nil) else { Issue.record("not ready"); return }
    #expect(m.isImage && m.raw?.format == .camera_raw && m.path == url.path)
    var p = Project(name: "Still", canvas: Canvas(width: 640, height: 480, fps: 24))
    p.media = [m]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "img", start: 0, duration: 1)]
    func card(_ edit: (inout Clip) throws -> Void) async throws -> SIMD3<Double> {
        var q = p
        try edit(&q.tracks[0].clips[0])
        let built = try await TimelineBuilder.build(q, transcripts: [:], library: MediaLibrary())
        let img = try #require(try await Frames.timeline(built, times: [0.5], maxSize: CGSize(width: 640, height: 480)).first?.image)
        return mean(img, x: 0.1...0.4, y: 0.3...0.7)
    }
    let base = try await card { _ in }
    let bright = try await card { try $0.set("raw.exposure", .number(2)) }
    let warm = try await card { try $0.set("raw.temperature", .number(9000)) }
    #expect(bright.y > base.y + 0.1, "\(base) → \(bright)")
    #expect(warm.x > warm.z + 0.05, "9000 K: \(warm)")
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: proResRawSample.path), rawSampleNote)) func proResRawMetadataMatchesAVFoundationsDecode() async throws {
    #expect(await CameraRawIngest.isProResRaw(proResRawSample))
    let raw = try await CameraRawIngest.proResMetadata(proResRawSample)
    #expect(raw.temperature == 5400, "\(raw)")
    #expect(abs((raw.gain ?? 0) - 8.451) < 0.01)
    #expect(raw.colorMatrix?.count == 9 && raw.whiteBalance?.count == 2)
    // AVFoundation's decode is the documented conversion times one constant across channels and regions (≈1.11).
    let scale = try #require(raw.decodeScale)
    #expect(scale > 1.05 && scale < 1.2, "\(scale)")
    // The color matrix maps white-balanced camera white to D65.
    let m = raw.colorMatrix!
    #expect(abs(m[0] + m[1] + m[2] - 0.9504) < 0.002 && abs(m[3] + m[4] + m[5] - 1) < 0.002)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: proResRawSample.path), rawSampleNote)) func proResRawDevelopsAndTakesLiveControls() async throws {
    let dir = try tempDir("prr")
    defer { try? FileManager.default.removeItem(at: dir) }
    guard case .ready(let m) = try await MediaIngest.prepare(proResRawSample, id: "prr", cache: dir, tools: nil) else { Issue.record("not developed"); return }
    #expect(m.raw?.format == .prores_raw && m.log == CameraRaw.workingLog && m.originalPath == proResRawSample.path)
    #expect(m.width == 8192 && m.height == 3424 && m.fps == 60)
    #expect(await MediaIngest.verify(m.url) == nil)
    // The copy holds AVFoundation's scene-linear decode, through the working log and back.
    let asset = AVURLAsset(url: proResRawSample)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
    reader.add(out)
    reader.startReading()
    let pb = try #require(out.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let row = CVPixelBufferGetBaseAddress(pb)!.advanced(by: CVPixelBufferGetHeight(pb) / 2 * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: Float16.self)
    let p0 = row + CVPixelBufferGetWidth(pb) / 4 * 4
    let source = SIMD3(Float(p0[0]), Float(p0[1]), Float(p0[2]))
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    let developed = try await developedGray(m.url)
    #expect(simd_length(developed - source) < 0.02 * max(0.05, simd_length(source)) + 0.002, "\(source) vs \(developed)")

    var p = Project(name: "PRR", canvas: Canvas(width: 1920, height: 802, fps: 60))
    p.media = [m]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "prr", start: 0, duration: 0.1)]
    func frame(_ edit: (inout Clip) throws -> Void) async throws -> SIMD3<Double> {
        var q = p
        try edit(&q.tracks[0].clips[0])
        let built = try await TimelineBuilder.build(q, transcripts: [:], library: MediaLibrary())
        let img = try #require(try await Frames.timeline(built, times: [0.02], maxSize: CGSize(width: 960, height: 401)).first?.image)
        return mean(img, x: 0.0...1.0, y: 0.0...1.0)
    }
    let base = try await frame { _ in }
    let up = try await frame { try $0.set("raw.exposure", .number(1)) }
    let cool = try await frame { try $0.set("raw.temperature", .number(3200)) }
    let warm = try await frame { try $0.set("raw.temperature", .number(9000)) }
    #expect(up.y > base.y + 0.03, "\(base) → \(up)")
    #expect(cool.z - cool.x > base.z - base.x + 0.05, "3200 K \(cool) vs \(base)")
    #expect(warm.x - warm.z > base.x - base.z + 0.05, "9000 K \(warm) vs \(base)")
}
