import AVFoundation
import CoreImage
import Foundation
import Metal
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!)

/// RGB floats of the pixel at the center of `image`, rendered in `space`.
private func centerValue(_ image: CIImage, space: CGColorSpace) -> SIMD3<Float> {
    var px = [Float](repeating: 0, count: 4)
    let e = image.extent
    context.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: e.midX.rounded(.down), y: e.midY.rounded(.down), width: 1, height: 1), format: .RGBAf, colorSpace: space)
    return SIMD3(px[0], px[1], px[2])
}

/// An image tagged Rec.709 whose code values are `pixel(x, y)` (0…255, y from the top).
private func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let o = (y * width + x) * 4
            bytes[o] = r; bytes[o + 1] = g; bytes[o + 2] = b
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return CIImage(cgImage: cg)
}

/// RGBA8 pixels of a CGImage, row 0 at the top.
private func pixels(_ cg: CGImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let ctx = CGContext(data: &out, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return out
}

/// Brightest channel sum within `r` pixels of `p`.
private func brightness(_ px: [UInt8], width: Int, height: Int, at p: CGPoint, radius r: Int = 3) -> Int {
    var best = 0
    for dy in -r...r {
        for dx in -r...r {
            let x = Int(p.x) + dx, y = Int(p.y) + dy
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            let o = (y * width + x) * 4
            best = max(best, Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2]))
        }
    }
    return best
}

private let bars75: [(UInt8, UInt8, UInt8)] = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191)]

private func barsImage(width: Int = 700, height: Int = 200) -> CIImage {
    image(width: width, height: height) { x, _ in bars75[min(6, x * 7 / width)] }
}

// MARK: Color management

@Test func cubesHaveExpectedSizes() {
    let log = ColorManagement.inputCube(log: .slog3, target: .rec709, tone: .aces, exposure: 0)
    #expect(log.size == 65)
    #expect(log.data.count == 65 * 65 * 65 * 4 * MemoryLayout<Float>.size)
    let again = ColorManagement.inputCube(log: .slog3, target: .rec709, tone: .aces, exposure: 0)
    #expect(again.data == log.data)
    let display = ColorManagement.displayCube(from: .rec709, to: .rec709, tone: .none, exposure: 0)
    #expect(display.size == 33)
    #expect(display.data.count == 33 * 33 * 33 * 16)
}

@Test func rec709DisplayCubeIsIdentity() {
    let cube = ColorManagement.displayCube(from: .rec709, to: .rec709, tone: .none, exposure: 0)
    let n = cube.size
    let floats = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    var worst: Float = 0
    for b in 0..<n {
        for g in 0..<n {
            for r in 0..<n {
                let o = ((b * n + g) * n + r) * 4
                let expected = SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)
                worst = max(worst, abs(SIMD3(floats[o], floats[o + 1], floats[o + 2]) - expected).max())
                #expect(floats[o + 3] == 1)
            }
        }
    }
    #expect(worst < 1e-3)
    // Applied through Core Image the cube leaves a Rec.709 picture alone.
    let bars = barsImage()
    let applied = bars.applyingFilter("CIColorCubeWithColorSpace", parameters: [
        "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": ColorManagement.colorSpace(.rec709),
    ])
    let space = ColorManagement.colorSpace(.rec709)
    #expect(abs(centerValue(applied, space: space) - centerValue(bars, space: space)).max() < 0.01)
}

/// A 10-bit video-range 4:2:0 frame filled with one neutral Y′ code value.
private func lumaFrame(code: UInt16, width: Int = 64, height: Int = 64) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attrs as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        let count = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
        let value = (plane == 0 ? code : 512) << 6
        for y in 0..<rows { for x in 0..<count { base[y * stride + x] = value } }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return buffer
}

@Test func slog3MidGreyLandsOnDisplayMidGrey() {
    // Sony records 18% grey at 10-bit code value 420.
    let raw = ColorManagement.rawImage(lumaFrame(code: 420))
    let decoded = centerValue(raw, space: ColorManagement.passthroughSpace)
    #expect(abs(decoded.y - (420 - 64) / 876) < 0.003, "raw value \(decoded)")
    let out = ColorManagement.applyInput(raw, log: .slog3, target: .rec709, tone: .aces, exposure: 0)
    let v = centerValue(out, space: ColorManagement.colorSpace(.rec709))
    let expected = ColorPipeline.inputTransform(log: .slog3, target: .rec709, tone: .aces, exposure: 0)(SIMD3(repeating: (420 - 64) / 876))
    #expect(abs(v - expected).max() < 0.01, "rendered \(v), expected \(expected)")
    #expect(abs(v.y - 0.41) < 0.04, "S-Log3 grey → \(v)")
    #expect(abs(v.x - v.z) < 0.01)
    // One stop up brightens it.
    let up = centerValue(ColorManagement.applyInput(raw, log: .slog3, target: .rec709, tone: .aces, exposure: 1), space: ColorManagement.colorSpace(.rec709))
    #expect(up.y > v.y + 0.05)
}

@Test func pqOutputSurvivesTheWorkingSpace() {
    let raw = ColorManagement.rawImage(lumaFrame(code: 420))
    let out = ColorManagement.applyInput(raw, log: .slog3, target: .rec2020_pq, tone: .none, exposure: 0)
    let v = centerValue(out, space: ColorManagement.colorSpace(.rec2020_pq))
    let expected = Transfer.pqEncode(nits: 0.18 * ColorPipeline.referenceWhiteNits)
    #expect(abs(v.y - expected) < 0.01, "PQ grey \(v) vs \(expected)")
}

@Test func hdrHelpers() {
    #expect(ColorManagement.colorSpace(.rec709).name == CGColorSpace.itur_709)
    #expect(ColorManagement.colorSpace(.p3).name == CGColorSpace.displayP3)
    #expect(ColorManagement.colorSpace(.rec2020_hlg).name == CGColorSpace.itur_2100_HLG)
    #expect(ColorManagement.colorSpace(.rec2020_pq).name == CGColorSpace.itur_2100_PQ)
    #expect(ColorManagement.passthroughSpace.name == CGColorSpace.extendedLinearSRGB)
    let pq = ColorManagement.videoCompositionTags(.rec2020_pq)
    #expect(pq.primaries == AVVideoColorPrimaries_ITU_R_2020 && pq.transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ && pq.matrix == AVVideoYCbCrMatrix_ITU_R_2020)
    #expect(ColorManagement.videoCompositionTags(.rec2020_hlg).transfer == AVVideoTransferFunction_ITU_R_2100_HLG)
    #expect(ColorManagement.videoCompositionTags(.p3).primaries == AVVideoColorPrimaries_P3_D65)
    #expect(ColorManagement.writerColorProperties(.rec709)[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_709_2)
    #expect(ColorManagement.pixelFormat(.rec2020_pq) == kCVPixelFormatType_64RGBAHalf)
    #expect(ColorManagement.pixelFormat(.rec709) == kCVPixelFormatType_32BGRA)
    #expect(ColorManagement.writerVideoSettings(.rec2020_hlg, width: 64, height: 64)[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
}

@Test func hdrWriterAcceptsTaggedHalfFloatFrames() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-pq-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: ColorManagement.writerVideoSettings(.rec2020_pq, width: 128, height: 128))
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: ColorManagement.pixelFormat(.rec2020_pq),
        kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 128,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let frame = ColorManagement.applyInput(ColorManagement.rawImage(lumaFrame(code: 420, width: 128, height: 128)), log: .slog3, target: .rec2020_pq, tone: .aces, exposure: 0)
    for i in 0..<3 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        context.render(frame, to: buffer, bounds: CGRect(x: 0, y: 0, width: 128, height: 128), colorSpace: ColorManagement.colorSpace(.rec2020_pq))
        ColorManagement.tag(buffer, .rec2020_pq)
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    let desc = try #require(try await track.load(.formatDescriptions).first)
    let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] ?? [:]
    #expect(ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
    #expect(ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String == AVVideoColorPrimaries_ITU_R_2020)
}

@Test func logDetection() async {
    #expect(await ColorManagement.detectLog(AVMutableComposition()) == nil)
    #expect(ColorManagement.profile(fromMarker: "s-log3-cine") == .slog3)
    #expect(ColorManagement.profile(fromMarker: "S-Log3 S-Gamut3") == .slog3_sgamut3)
    #expect(ColorManagement.profile(fromMarker: "ARRI LogC4") == .logc4)
    #expect(ColorManagement.profile(fromMarker: "Log-C") == .logc3)
    #expect(ColorManagement.profile(fromMarker: "V-Log") == .vlog)
    #expect(ColorManagement.profile(fromMarker: "Canon Log 3") == .clog3)
    #expect(ColorManagement.profile(fromMarker: "F-Log2") == .flog2)
    #expect(ColorManagement.profile(fromMarker: "D-Log M") == nil)
    #expect(ColorManagement.profile(fromMarker: "my travel vlog") == nil)
    #expect(ColorManagement.logTransfer(kCMFormatDescriptionLogTransferFunction_AppleLog as String) == .apple_log)
    let xml = Data(#"<Item name="CaptureGammaEquation" value="s-log3"/><Item name="CaptureColorPrimaries" value="S-Gamut3"/>"#.utf8)
    #expect(ColorManagement.sonyMarker(Data(repeating: 0, count: 100) + xml) == .slog3_sgamut3)
}

// MARK: Scopes

@Test func vectorscopeBarsHitTargetBoxes() throws {
    let size = CGSize(width: 320, height: 320)
    let cg = try #require(Scopes.render(barsImage(), kind: .vectorscope, size: size, context: context))
    let px = pixels(cg)
    let weights = Scopes.lumaWeights(.rec709)
    for (name, cb, cr) in Scopes.targets(level: 0.75, weights: weights) {
        let p = Scopes.vectorPoint(cb: cb, cr: cr, size: size)
        #expect(brightness(px, width: 320, height: 320, at: p) > 300, "no trace in the \(name) box")
    }
    let empty = Scopes.vectorPoint(cb: 0.2, cr: -0.25, size: size)
    #expect(brightness(px, width: 320, height: 320, at: empty, radius: 1) < 120)

    let stats = try #require(Scopes.vectorscopeStats(image(width: 64, height: 64) { _, _ in (191, 0, 0) }, context: context))
    #expect(abs(stats.hue - 103) < 2, "red hue \(stats.hue)")
    #expect(abs(stats.saturation - 0.75 * 1.026) < 0.03, "red saturation \(stats.saturation)")
    let grey = try #require(Scopes.vectorscopeStats(image(width: 64, height: 64) { _, _ in (128, 128, 128) }, context: context))
    #expect(grey.saturation < 0.01 && grey.skinToneOffset == nil)
}

@Test func waveformOfARampIsADiagonal() throws {
    let size = CGSize(width: 400, height: 240)
    let ramp = image(width: 512, height: 64) { x, _ in let v = UInt8(x * 255 / 511); return (v, v, v) }
    let cg = try #require(Scopes.render(ramp, kind: .waveform, size: size, context: context))
    let px = pixels(cg)
    let plot = Scopes.plotRect(.waveform, size: size)
    for f in stride(from: 0.1, through: 0.9, by: 0.1) {
        let col = Int(plot.minX + CGFloat(f) * (plot.width - 1))
        var bestRow = 0, best = 0
        for row in Int(plot.minY)..<Int(plot.maxY) {
            let g = Int(px[(row * cg.width + col) * 4 + 1])
            if g > best { best = g; bestRow = row }
        }
        let expected = plot.maxY - 1 - CGFloat(f) * (plot.height - 1)
        #expect(abs(CGFloat(bestRow) - expected) <= 4, "column \(f): trace at \(bestRow), expected \(expected)")
        #expect(best > 150)
    }
}

@Test func paradeAndHistogramDrawTraces() throws {
    let size = CGSize(width: 480, height: 200)
    for kind in [Scopes.Kind.parade, .histogram] {
        let cg = try #require(Scopes.render(barsImage(), kind: kind, size: size, context: context))
        let px = pixels(cg)
        var lit = 0
        for o in stride(from: 0, to: px.count, by: 4) {
            let sum = Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2])
            if sum > 300 { lit += 1 }
        }
        #expect(lit > 200, "\(kind) drew \(lit) bright pixels")
    }
    let stats = try #require(Scopes.rgbParadeStats(barsImage(), context: context))
    #expect(abs(stats.red.max - 0.749) < 0.01 && stats.red.min < 0.01)
    #expect(abs(stats.green.mean - 4.0 / 7 * 0.749) < 0.02)
    let s = try #require(Scopes.stats(image(width: 64, height: 64) { _, _ in (255, 255, 255) }, context: context))
    #expect(s.clipped > 0.99 && s.crushed == 0)
}

@Test func scopesAreFast() throws {
    let hd = image(width: 1920, height: 1080) { x, y in (UInt8(x % 256), UInt8(y % 256), UInt8((x + y) % 256)) }
    let size = CGSize(width: 512, height: 256)
    for kind in Scopes.Kind.allCases {
        _ = Scopes.render(hd, kind: kind, size: size, context: context)
        // The fastest of five, so a busy machine running other tests doesn't fail it.
        var ms = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            _ = try #require(Scopes.render(hd, kind: kind, size: size, context: context))
            ms = min(ms, Date().timeIntervalSince(start) * 1000)
        }
        print("scope \(kind.rawValue): \(String(format: "%.1f", ms)) ms")
        #expect(ms < 1000)
    }
    let start = Date()
    for _ in 0..<5 { _ = Scopes.stats(hd, context: context) }
    print("scope stats: \(String(format: "%.1f", Date().timeIntervalSince(start) / 5 * 1000)) ms")
    let bake = Date()
    _ = ColorManagement.inputCube(log: .logc4, target: .rec2020_hlg, tone: .hable, exposure: 0.5)
    print("65³ cube bake: \(String(format: "%.1f", Date().timeIntervalSince(bake) * 1000)) ms")
}
