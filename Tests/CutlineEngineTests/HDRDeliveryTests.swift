import AVFoundation
import CoreImage
import CoreMedia
@testable import CutlineCore
@testable import CutlineEngine
import Foundation
import Testing
import VideoToolbox

private func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cutline-hdr-\(UUID().uuidString).\(ext)")
}

/// 75% Rec. 709 bars (white, yellow, cyan, green, magenta, red, blue) and a 100% white bar.
private let bars: [SIMD3<Float>] = [[1, 1, 1], [1, 1, 0], [0, 1, 1], [0, 1, 0], [1, 0, 1], [1, 0, 0], [0, 0, 1]].map { $0 * 0.75 } + [[1, 1, 1]]

/// Writes 1 s of 24 fps frames; `pixel(x, y)` gives RGB in 0…1 encoded for `space`, written at half float.
private func writeMovie(_ url: URL, width w: Int, height h: Int, space: WorkingSpace, codec: AVVideoCodecType = .proRes422HQ, pixel: (Int, Int) -> SIMD3<Float>) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoColorPropertiesKey: ColorManagement.writerColorProperties(space),
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<24 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            let line = (base + y * row).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                let c = pixel(x, y)
                line[x * 4] = Float16(c.x)
                line[x * 4 + 1] = Float16(c.y)
                line[x * 4 + 2] = Float16(c.z)
                line[x * 4 + 3] = 1
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        ColorManagement.tag(buffer, space)
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}

private func writeBars(_ url: URL, width w: Int = 512, height h: Int = 64) async throws {
    try await writeMovie(url, width: w, height: h, space: .rec709) { x, _ in bars[min(bars.count - 1, x * bars.count / w)] }
}

private func project(_ url: URL, space: WorkingSpace, width: Int, height: Int) async throws -> BuiltTimeline {
    var canvas = Canvas(width: width, height: height, fps: 24)
    canvas.colorSpace = space
    var p = Project(name: "HDR", canvas: canvas)
    p.media = [try await MediaProbe.probe(url, id: "m")]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 1)]
    return try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
}

/// Encoded RGB the compositor renders at the middle of each bar, in several frames, read as export reads it.
private func renderedBars(_ built: BuiltTimeline, frames: Int = 6) async throws -> [[SIMD3<Float>]] {
    let reader = try AVAssetReader(asset: built.composition)
    let out = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
    ])
    out.videoComposition = built.videoComposition
    reader.add(out)
    #expect(reader.startReading())
    defer { reader.cancelReading() }
    var all: [[SIMD3<Float>]] = []
    for _ in 0..<frames {
        let next = try await runBlocking { _ in out.copyNextSampleBuffer() }
        let sample = try #require(next)
        let pb = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        all.append(bars.indices.map { k in
            let p = (base + (h / 2) * row).assumingMemoryBound(to: Float16.self) + ((2 * k + 1) * w / (2 * bars.count)) * 4
            return SIMD3(Float(p[0]), Float(p[1]), Float(p[2]))
        })
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }
    return all
}

/// BT.2408 display-light mapping of a Rec. 709 signal into PQ, written out: BT.1886, BT.2020 primaries, 203 cd/m² white.
private func bt2408PQ(_ c: SIMD3<Float>) -> SIMD3<Float> {
    let m = Primaries.matrix(from: .rec709, to: .rec2020).float
    let nits = m * SIMD3(pow(c.x, 2.4), pow(c.y, 2.4), pow(c.z, 2.4)) * 203
    return SIMD3(Transfer.pqEncode(nits: nits.x), Transfer.pqEncode(nits: nits.y), Transfer.pqEncode(nits: nits.z))
}

@Test func sdrBarsLandOnBT2408CodeValuesInHDR() async throws {
    // Reference points from BT.2408: SDR white at 203 cd/m² is 58% PQ and 75% HLG.
    #expect(abs(Transfer.pqEncode(nits: 203) - 0.5807) < 0.0005)
    #expect(abs(ColorPipeline.displayTransform(from: .rec709, to: .rec2020_hlg, tone: .none, exposure: 0)(SIMD3(repeating: 1)).y - 0.75) < 0.002)
    let url = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeBars(url)
    for space in [WorkingSpace.rec2020_pq, .rec2020_hlg, .p3] {
        let frames = try await renderedBars(try await project(url, space: space, width: 512, height: 64))
        var worst: Float = 0
        for got in frames {
            for (k, c) in bars.enumerated() {
                let want = space == .rec2020_pq ? bt2408PQ(c) : ColorPipeline.displayTransform(from: .rec709, to: space, tone: .none, exposure: 0)(c)
                worst = max(worst, abs(got[k] - want).max())
            }
        }
        // 75% white: 101.8 cd/m², PQ 0.510; yellow keeps its BT.2020 blue at 10.6 cd/m² instead of clipping.
        if space == .rec2020_pq {
            #expect(abs(frames[0][0].y - 0.5098) < 0.003, "\(frames[0][0])")
            #expect(abs(frames[0][1].z - 0.3045) < 0.003, "\(frames[0][1])")
            #expect(abs(frames[0][7].y - 0.5807) < 0.003, "\(frames[0][7])")
        }
        print("SDR bars on \(space): worst code value error \(String(format: "%.4f", worst)) (\(String(format: "%.1f", worst * 1023)) 10-bit codes) over \(frames.count) frames")
        #expect(worst < 0.006, "\(space): \(worst)")
    }
}

@Test func sdrMaterialPassesThroughARec709TimelineUnchanged() async throws {
    let url = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeBars(url)
    let frames = try await renderedBars(try await project(url, space: .rec709, width: 512, height: 64), frames: 3)
    let worst = frames.flatMap { zip($0, bars).map { abs($0 - $1).max() } }.max()!
    print("Rec. 709 passthrough: worst error \(String(format: "%.4f", worst))")
    #expect(worst < 0.006)
}

/// sRGB bytes at the middle of each bar, drawn the way contact sheets draw frames.
private func sheetBars(_ img: CGImage) -> [SIMD3<Int>] {
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return bars.indices.map { k in
        let o = ((h / 2) * w + (2 * k + 1) * w / (2 * bars.count)) * 4
        return SIMD3(Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
    }
}

@Test func hdrFramePreviewsLookLikeTheSDRTimeline() async throws {
    let url = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeBars(url)
    let reference = sheetBars(try await Frames.timeline(try await project(url, space: .rec709, width: 512, height: 64), times: [0.5], maxSize: .zero)[0].image)
    for space in [WorkingSpace.rec2020_pq, .rec2020_hlg] {
        let img = try await Frames.timeline(try await project(url, space: space, width: 512, height: 64), times: [0.25, 0.5], maxSize: .zero)[1].image
        let got = sheetBars(img)
        let diffs = zip(got, reference).map { a, b in (0..<3).map { Swift.abs(a[$0] - b[$0]) }.max()! }
        // Saturation: the spread between the strongest and weakest channel of each colored bar.
        let spread = { (v: [SIMD3<Int>]) in v[1..<7].map { $0.max() - $0.min() }.reduce(0, +) }
        print("\(space) preview vs Rec. 709 timeline: max channel difference \(diffs.max()!), mean \(String(format: "%.1f", Double(diffs.reduce(0, +)) / Double(diffs.count))); saturation \(spread(got)) vs \(spread(reference))")
        #expect(diffs.max()! <= 16, "\(space): \(got) vs \(reference)")
        #expect(Double(diffs.reduce(0, +)) / Double(diffs.count) < 5)
        #expect(abs(spread(got) - spread(reference)) < 40)
    }
}

@Test func sdrPreviewRollsHighlightsOffAndKeepsSDRRange() {
    let f = ColorPipeline.sdrPreview(from: .rec2020_pq)
    let toPQ = ColorPipeline.displayTransform(from: .rec709, to: .rec2020_pq, tone: .none, exposure: 0)
    for v: Float in [0.05, 0.2, 0.5, 0.75, 0.9] {
        #expect(abs(f(toPQ(SIMD3(v, v * 0.6, v * 0.2))).x - v) < 0.002)
    }
    let white = f(SIMD3(repeating: Transfer.pqEncode(nits: 203))).x, bright = f(SIMD3(repeating: Transfer.pqEncode(nits: 1000))).x
    #expect(white > 0.97 && white < 1 && bright > white && bright <= 1)
}

// MARK: HDR10 metadata

@Test func masteringDisplayDataFollowsST2086() {
    let meta = HDRMetadata()
    let d = [UInt8](meta.masteringDisplayData)
    #expect(d.count == 24)
    // P3 green x = 0.265 → 13250, white x = 0.3127 → 15635, 1000 cd/m² → 10 000 000, 0.0001 → 1.
    let u16 = { (i: Int) -> Int in Int(d[i]) << 8 | Int(d[i + 1]) }
    let u32 = { (i: Int) -> Int in u16(i) << 16 | u16(i + 2) }
    #expect(u16(0) == 13250)
    #expect(u16(12) == 15635)
    #expect(u32(16) == 10_000_000)
    #expect(u32(20) == 1)
    #expect(HDRMetadata(masteringDisplay: meta.masteringDisplayData) == meta)
    #expect([UInt8](HDRMetadata.contentLightData(maxCLL: 1000, maxFALL: 400)) == [0x03, 0xE8, 0x01, 0x90])
}

@Test func hdrBitrateScalesWithPictureSizeAndRate() {
    #expect(HDRMetadata.defaultBitrate(width: 1920, height: 1080, fps: 24) >= 20_000_000)
    #expect(HDRMetadata.defaultBitrate(width: 1920, height: 1080, fps: 60) > 30_000_000)
    let uhd = HDRMetadata.defaultBitrate(width: 3840, height: 2160, fps: 30)
    #expect(uhd > 50_000_000 && uhd < 60_000_000)
    #expect(HDRMetadata.defaultBitrate(width: 1280, height: 720, fps: 30) > 10_000_000)
}

private struct Probe: Decodable {
    struct Stream: Decodable {
        var color_transfer: String?
        var color_primaries: String?
        var color_space: String?
        var bit_rate: String?
        var side_data_list: [[String: AnyJSON]]?
    }
    var streams: [Stream]
}

private enum AnyJSON: Decodable, CustomStringConvertible {
    case string(String), number(Double), other
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) } else if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .other }
    }
    var description: String {
        switch self {
        case .string(let s): s
        case .number(let n): "\(n)"
        case .other: "?"
        }
    }
}

private func ffprobe(_ url: URL) throws -> Probe.Stream? {
    guard let tool = FFmpeg.tools()?.ffprobe else { return nil }
    let p = Process()
    p.executableURL = tool
    p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", url.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return try JSONDecoder().decode(Probe.self, from: data).streams.first
}

/// A PQ source: a 1000 cd/m² patch over `patch` of the frame on a 100 cd/m² field.
private func writeHDRPatch(_ url: URL, width w: Int, height h: Int, patch: Double) async throws {
    let high = Transfer.pqEncode(nits: 1000), low = Transfer.pqEncode(nits: 100)
    let side = Int((patch * Double(w * h)).squareRoot())
    try await writeMovie(url, width: w, height: h, space: .rec2020_pq) { x, y in
        x < side && y < side ? SIMD3(repeating: high) : SIMD3(repeating: low)
    }
}

@Test func pqExportCarriesMasteringDisplayAndMeasuredLightLevels() async throws {
    let src = tempURL("mov"), out = tempURL("mp4")
    defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
    let (w, h) = (640, 360)
    try await writeHDRPatch(src, width: w, height: h, patch: 0.1)
    let built = try await project(src, space: .rec2020_pq, width: w, height: h)
    let began = Date()
    let levels = try await HDRMetadata.measure(built, range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))
    let measureTime = Date().timeIntervalSince(began)
    let side = Int((0.1 * Double(w * h)).squareRoot())
    let fraction = Double(side * side) / Double(w * h)
    let expectedFALL = fraction * 1000 + (1 - fraction) * 100
    print("measured MaxCLL \(String(format: "%.1f", levels.maxCLL)) MaxFALL \(String(format: "%.1f", levels.maxFALL)) (expected 1000 / \(String(format: "%.1f", expectedFALL))) over \(levels.frames) frames in \(String(format: "%.2f", measureTime))s")
    #expect(levels.frames == 24)
    #expect(abs(levels.maxCLL - 1000) < 15)
    #expect(abs(levels.maxFALL - expectedFALL) < 5)

    try await Exporter.export(built, to: out, options: ExportOptions(preset: .hevc))
    let meta = try #require(try await HDRMetadata.read(out))
    #expect(meta.primaries == .p3_d65)
    #expect(abs(meta.maxLuminance - 1000) < 0.01)
    #expect(abs(meta.minLuminance - 0.0001) < 1e-6)
    let cll = Double(meta.maxCLL ?? 0), fall = Double(meta.maxFALL ?? 0)
    #expect(abs(cll - 1000) < 15, "\(meta)")
    #expect(abs(fall - expectedFALL) < 5, "\(meta)")
    if let stream = try ffprobe(out) {
        let side = stream.side_data_list ?? []
        print("ffprobe: \(stream.color_primaries ?? "?")/\(stream.color_transfer ?? "?")/\(stream.color_space ?? "?") side data \(side.map { $0.mapValues(\.description) })")
        #expect(stream.color_transfer == "smpte2084" && stream.color_primaries == "bt2020")
        let mastering = try #require(side.first { $0["side_data_type"]?.description == "Mastering display metadata" })
        #expect(mastering["max_luminance"]?.description == "10000000/10000")
        #expect(mastering["red_x"]?.description == "34000/50000")
        let light = try #require(side.first { $0["side_data_type"]?.description == "Content light level metadata" })
        #expect(light["max_content"]?.description == "\(meta.maxCLL!)" || light["max_content"]?.description == "\(Double(meta.maxCLL!))")
    }

    // Given levels and a BT.2020 4000 cd/m² monitor are written as given.
    let given = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: given) }
    var options = ExportOptions(preset: .hevc_10bit)
    options.hdr = HDRMetadata(primaries: .bt2020, maxLuminance: 4000, minLuminance: 0.005, maxCLL: 1200, maxFALL: 300)
    try await Exporter.export(built, to: given, options: options)
    let back = try #require(try await HDRMetadata.read(given))
    #expect(back.primaries == .bt2020)
    #expect(abs(back.maxLuminance - 4000) < 0.01)
    #expect(abs(back.minLuminance - 0.005) < 1e-6)
    #expect(back.maxCLL == 1200 && back.maxFALL == 300)
}

@Test func hlgExportIsTaggedWithoutStaticMetadata() async throws {
    let src = tempURL("mov"), out = tempURL("mp4")
    defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
    try await writeBars(src, width: 320, height: 64)
    try await Exporter.export(try await project(src, space: .rec2020_hlg, width: 320, height: 64), to: out, options: ExportOptions(preset: .hevc))
    let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
    let fd = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == AVVideoTransferFunction_ITU_R_2100_HLG)
    #expect(CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String == AVVideoColorPrimaries_ITU_R_2020)
    #expect(try await HDRMetadata.read(out) == nil)
    if let stream = try ffprobe(out) {
        #expect(stream.color_transfer == "arib-std-b67" && stream.color_primaries == "bt2020" && stream.color_space == "bt2020nc")
    }
}
