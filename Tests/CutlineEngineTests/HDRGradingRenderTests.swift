import AVFoundation
import CoreImage
@testable import CutlineCore
@testable import CutlineEngine
import Foundation
import Testing

private func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cutline-hdrgrade-\(UUID().uuidString).\(ext)")
}

/// One second of PQ ProRes at 24 fps: a 100 cd/m² gray band, a 1000 cd/m² band and a 4000 cd/m² band.
private func writePQBands(_ url: URL, width w: Int = 256, height h: Int = 64) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoColorPropertiesKey: ColorManagement.writerColorProperties(.rec2020_pq),
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let levels: [Float] = [100, 1000, 4000].map { Transfer.pqEncode(nits: $0) }
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
                let v = Float16(x < w / 2 ? levels[0] : x < w * 3 / 4 ? levels[1] : levels[2])
                line[x * 4] = v
                line[x * 4 + 1] = v
                line[x * 4 + 2] = v
                line[x * 4 + 3] = 1
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        ColorManagement.tag(buffer, .rec2020_pq)
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}

private func pqProject(_ url: URL, peak: Double? = nil, effects: [Effect] = []) async throws -> BuiltTimeline {
    var canvas = Canvas(width: 256, height: 64, fps: 24)
    canvas.colorSpace = .rec2020_pq
    canvas.masterPeakNits = peak
    var p = Project(name: "HDR grade", canvas: canvas)
    p.media = [try await MediaProbe.probe(url, id: "m")]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 1, effects: effects)]
    return try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
}

/// Light of the frame's columns in a band (fractions of the width).
private func bandNits(_ f: HDRScopes.Frame, _ from: Double, _ to: Double) -> Float {
    var peak: Float = 0
    for y in 0..<f.height {
        for x in Int(Double(f.width) * from)..<Int(Double(f.width) * to) {
            peak = max(peak, LightEncoding.pq.nits(f.rgb[y * f.width + x]).max())
        }
    }
    return peak
}

@Test func hdrLightStatsCountNitsAndGamut() {
    let white = SIMD3<Float>(repeating: Transfer.pqEncode(nits: 1000)), grey = SIMD3<Float>(repeating: Transfer.pqEncode(nits: 100))
    let l = HDRScopes.light(Array(repeating: white, count: 50) + Array(repeating: grey, count: 50), space: .rec2020_pq)
    #expect(abs(l.maxNits - 1000) < 1 && abs(l.averageNits - 550) < 1 && l.outside709 == 0)
    #expect(abs(l.p99 - 1000) < 15 && abs(l.p50 - 100) < 3, "\(l)")
    let green = LightEncoding.pq.encode(SIMD3(0, 300, 0))
    let g = HDRScopes.light([green], space: .rec2020_pq)
    #expect(g.outside709 == 1 && g.outsideP3 == 1)
    let p3ish = LightEncoding.pq.encode(SIMD3(80, 200, 60))
    let q = HDRScopes.light([p3ish], space: .rec2020_pq)
    #expect(q.outsideP3 == 0, "\(q)")
    let hlg = HDRScopes.light([Transfer.hlgInverseEOTF(SIMD3(repeating: 203))], space: .rec2020_hlg)
    #expect(abs(hlg.maxNits - 203) < 2)
}

@Test func hdrTimelineMeasuresRollsOffGradesAndTrimsToSDR() async throws {
    let movie = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: movie) }
    try await writePQBands(movie)

    let plain = try await pqProject(movie)
    let frame = try await HDRScopes.frame(plain, at: 0.5)
    print("PQ bands rendered: \(bandNits(frame, 0, 0.45)) / \(bandNits(frame, 0.55, 0.7)) / \(bandNits(frame, 0.8, 1)) cd/m²")
    #expect(abs(bandNits(frame, 0.8, 1) - 4000) / 4000 < 0.05)
    #expect(HDRScopes.waveform(frame, space: .rec2020_pq, size: CGSize(width: 512, height: 288)) != nil)
    let frames = try await HDRScopes.measure(plain)
    let maxCLL = frames.map(\.maxNits).max() ?? 0, fall = frames.map(\.averageNits).max() ?? 0
    print("measure: \(frames.count) frames, MaxCLL \(maxCLL), MaxFALL \(fall)")
    #expect(frames.count >= 20 && abs(maxCLL - 4000) / 4000 < 0.05)
    #expect(abs(fall - (100 * 0.5 + 1000 * 0.25 + 4000 * 0.25)) / 1300 < 0.06)

    // master_peak_nits rolls the 4000 cd/m² band off under 1000 and leaves 100 cd/m² alone.
    let rolled = try await HDRScopes.frame(try await pqProject(movie, peak: 1000), at: 0.5)
    print("rolled off: \(bandNits(rolled, 0, 0.45)) / \(bandNits(rolled, 0.55, 0.7)) / \(bandNits(rolled, 0.8, 1))")
    #expect(bandNits(rolled, 0.8, 1) <= 1005 && bandNits(rolled, 0.8, 1) > 950)
    #expect(abs(bandNits(rolled, 0, 0.45) - 100) < 3)

    // Pulling the specular zone down a stop halves the 4000 cd/m² band.
    let zones = Effect(id: "z", type: "color.hdr_zones", params: ["specular_exposure": .number(-1)])
    let graded = try await HDRScopes.frame(try await pqProject(movie, effects: [zones]), at: 0.5)
    print("specular -1: \(bandNits(graded, 0, 0.45)) / \(bandNits(graded, 0.55, 0.7)) / \(bandNits(graded, 0.8, 1))")
    #expect(abs(bandNits(graded, 0.8, 1) - 2000) / 2000 < 0.06)
    #expect(abs(bandNits(graded, 0, 0.45) - 100) / 100 < 0.06)

    // The SDR version writes Rec. 709 with the bands in order and the highlights folded under white.
    let sdr = try #require(plain.sdrVersion(SDRTrim()))
    #expect(sdr.outputSpace == .rec709)
    let out = tempURL("mov")
    defer { try? FileManager.default.removeItem(at: out) }
    try await Exporter.export(sdr, to: out, options: ExportOptions(preset: .prores))
    let asset = AVURLAsset(url: out)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let desc = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
    let reader = try AVAssetReader(asset: asset)
    let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
    reader.add(ro)
    #expect(reader.startReading())
    let next = try await runBlocking { _ in ro.copyNextSampleBuffer() }
    let pb = try #require(next.flatMap(CMSampleBufferGetImageBuffer))
    let decoded = try #require(HDRScopes.codeValues(pb))
    reader.cancelReading()
    func band(_ x: Double) -> Float { decoded.rgb[decoded.height / 2 * decoded.width + Int(Double(decoded.width) * x)].x }
    let expect = SDRTrim().transform(from: .rec2020_pq)
    print("SDR bt2390 code values: 100 nits \(band(0.25)) (expected \(expect(SIMD3(repeating: Transfer.pqEncode(nits: 100))).x)), 1000 nits \(band(0.62)), 4000 nits \(band(0.9))")
    #expect(band(0.25) < band(0.62) && band(0.62) <= band(0.9) + 0.01)
    #expect(abs(band(0.25) - expect(SIMD3(repeating: Transfer.pqEncode(nits: 100))).x) < 0.04)
    #expect(band(0.9) > 0.95)
}

@Test func gradeCubesForHueCurvesAndZones() {
    let curves = ColorCubes.make("color.hue_curves", { name in name == "hue_sat" ? .string("120,0.5") : .string("") })
    #expect(curves?.size == 64)
    #expect(ColorCubes.make("color.hue_curves", { _ in .string("") }) == nil)
    #expect(ColorCubes.make("color.hdr_zones", { _ in .number(0) }) == nil)
    let specs = EffectCatalog.type("color.hdr_zones")!.params
    let value: (String) -> ParamValue = { name in name == "highlight_exposure" ? .number(1) : specs.first { $0.name == name }?.defaultValue ?? .number(0) }
    let pqZones = ColorCubes.cube("color.hdr_zones", value, space: ColorManagement.colorSpace(.rec2020_pq))
    let sdrZones = ColorCubes.cube("color.hdr_zones", value)
    #expect(pqZones != nil && sdrZones != nil && pqZones !== sdrZones)
}

@Test func footageSamplerTellsSharpFromSoftAndStillFromMoving() {
    let w = 32, h = 32
    let checker = FootageSampler.Luma(width: w, height: h, values: (0..<(w * h)).map { i in ((i % w) / 2 + (i / w) / 2) % 2 == 0 ? 40 : 200 })
    let flat = FootageSampler.Luma(width: w, height: h, values: Array(repeating: 120, count: w * h))
    let sharp = FootageSampler.measure(checker, checker, time: 0), soft = FootageSampler.measure(flat, checker, time: 0)
    #expect(sharp.sharpness > soft.sharpness + 0.1 && sharp.motion == 0 && soft.motion > 0.2)
    #expect(sharp.quality > soft.quality)
    let black = FootageSampler.measure(FootageSampler.Luma(width: w, height: h, values: Array(repeating: 2, count: w * h)), nil, time: 0)
    #expect(black.quality < soft.quality)
}
