import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

/// RGBA 0–255 of one pixel in CI coordinates (y up).
private func rgba(_ img: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Int] {
    var px = [UInt8](repeating: 0, count: 4)
    ctx.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return px.map(Int.init)
}

private func solid(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: rect)
}

/// Green screen with a red square and a greenish strip beside it.
private func greenScreen() -> CIImage {
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    return solid(0.9, 0.1, 0.1, CGRect(x: 50, y: 50, width: 100, height: 100))
        .composited(over: solid(0.55, 0.7, 0.45, CGRect(x: 150, y: 50, width: 20, height: 100)))
        .composited(over: solid(0.1, 0.8, 0.2, frame))
}

@Test func chromaKeyRemovesScreenKeepsSubject() {
    let out = ChromaKey.key(greenScreen(), color: nil, tolerance: 0.35, softness: 0.25, spill: 0.8, edgeFeather: 1)
    let square = rgba(out, 100, 100)
    #expect(square[3] == 255, "square \(square)")
    #expect(square[0] > 200 && square[1] < 60, "square \(square)")
    #expect(rgba(out, 10, 10)[3] == 0)
    #expect(rgba(out, 190, 180)[3] == 0)
    let strip = rgba(out, 160, 100)
    #expect(strip[3] > 230, "strip \(strip)")
    #expect(strip[1] < Int(0.7 * 255) - 25, "spill not reduced: \(strip)")
}

@Test func detectsScreenColors() {
    let green = ChromaKey.detectKeyColor(greenScreen())
    #expect(green != nil)
    if let green { #expect(green.g > 0.7 && green.r < 0.2 && green.b < 0.3, "\(green)") }
    let blue = ChromaKey.detectKeyColor(solid(0.1, 0.2, 0.85, CGRect(x: 0, y: 0, width: 120, height: 80)))
    #expect(blue.map { $0.b > 0.7 && $0.g < 0.3 } == true)
    #expect(ChromaKey.detectKeyColor(solid(0.5, 0.5, 0.5, CGRect(x: 0, y: 0, width: 50, height: 50))) == nil)
}

@Test func maskApplyKeepsInvertsFeathersAndExpands() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let image = solid(0.2, 0.4, 0.9, frame)
    let mask = solid(1, 1, 1, CGRect(x: 0, y: 0, width: 50, height: 100)).composited(over: solid(0, 0, 0, frame))

    let kept = Segmentation.apply(mask: mask, to: image)
    #expect(rgba(kept, 20, 50)[3] == 255)
    #expect(rgba(kept, 80, 50)[3] == 0)

    let inverted = Segmentation.apply(mask: mask, to: image, invert: true)
    #expect(rgba(inverted, 20, 50)[3] == 0)
    #expect(rgba(inverted, 80, 50)[3] == 255)

    let feathered = Segmentation.apply(mask: mask, to: image, feather: 20)
    let edge = rgba(feathered, 50, 50)[3]
    #expect(edge > 60 && edge < 200, "edge \(edge)")
    #expect(rgba(feathered, 45, 50)[3] < 255)
    #expect(rgba(feathered, 5, 50)[3] == 255)

    #expect(rgba(Segmentation.apply(mask: mask, to: image, expand: 10), 55, 50)[3] == 255)
    #expect(rgba(Segmentation.apply(mask: mask, to: image, expand: -10), 45, 50)[3] == 0)
}

@Test func visionMasksSurviveSyntheticFrames() {
    let frame = CGRect(x: 10, y: 20, width: 640, height: 360)
    let image = solid(0.9, 0.1, 0.1, CGRect(x: 250, y: 100, width: 120, height: 200)).composited(over: solid(0.3, 0.5, 0.7, frame))
    if let m = Segmentation.personMask(image, quality: .fast) {
        #expect(m.extent == frame)
        #expect(rgba(m, 30, 40)[3] == 255)
    }
    if let m = Segmentation.subjectMask(image) { #expect(m.extent == frame) }

    let cache = MaskCache()
    let key = MaskCache.Key(mediaId: "m", time: 1.0)
    let first = cache.mask(kind: .person(.fast), key: key, image: image, smoothing: 0.5)
    let again = cache.mask(kind: .person(.fast), key: key, image: image, smoothing: 0.5)
    #expect((first == nil) == (again == nil))
    _ = cache.mask(kind: .person(.fast), key: MaskCache.Key(mediaId: "m", time: 1.0 + 1 / 30), image: image, smoothing: 0.5)
}

@Test func maskBuffersBlendTowardPrevious() {
    let a = MaskBuffer(width: 2, height: 1, values: [0, 1])
    let b = MaskBuffer(width: 2, height: 1, values: [1, 1])
    #expect(a.blended(with: b, weight: 0.75).values == [0.75, 1])
    let img = a.image(fitting: CGRect(x: 0, y: 0, width: 20, height: 10))
    #expect(rgba(img, 2, 5)[0] < 10)
    #expect(rgba(img, 18, 5)[0] > 245)
}

/// Deterministic noise in −1…1.
private struct Noise {
    var state: UInt64
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(1 << 53)) * 2 - 1
    }
}

/// Speech-like bursts: noise under a slowly varying envelope.
private func source(seconds: Double, rate: Double, seed: UInt64) -> [Float] {
    var noise = Noise(state: seed)
    let n = Int(seconds * rate)
    var out = [Float](repeating: 0, count: n)
    var env: Float = 0
    for i in 0..<n {
        if i % Int(rate / 10) == 0 { env = max(0, noise.next()) }
        out[i] = env * noise.next()
    }
    return out
}

/// `signal` shifted so it plays `delay` seconds later, plus independent noise.
private func noisyCopy(_ signal: [Float], delay: Double, rate: Double, seed: UInt64) -> [Float] {
    var noise = Noise(state: seed)
    let shift = Int((delay * rate).rounded())
    return (0..<signal.count).map { i in
        let j = i - shift
        return (j >= 0 && j < signal.count ? signal[j] : 0) + 0.3 * noise.next()
    }
}

@Test func audioSyncFindsKnownOffsets() {
    let rate = 8_000.0
    let s = source(seconds: 20, rate: rate, seed: 1)
    for delay in [1.234, -1.234] {
        let reference = noisyCopy(s, delay: 0, rate: rate, seed: 2)
        let other = noisyCopy(s, delay: delay, rate: rate, seed: 3)
        let (offset, confidence) = AudioSync.offset(reference: reference, other: other, sampleRate: rate, maxOffset: 5)
        #expect(abs(offset - delay) < 0.002, "offset \(offset) for \(delay)")
        #expect(confidence > 0.8, "confidence \(confidence)")
    }
    let a = source(seconds: 10, rate: rate, seed: 7), b = source(seconds: 10, rate: rate, seed: 8)
    let (_, confidence) = AudioSync.offset(reference: a, other: b, sampleRate: rate, maxOffset: 5)
    #expect(confidence < 0.3, "unrelated confidence \(confidence)")
}

@Test func audioSyncReadsFiles() async throws {
    let rate = 16_000.0
    let s = source(seconds: 12, rate: rate, seed: 11)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func write(_ samples: [Float], _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        try file.write(from: buffer)
        return url
    }
    let ref = try write(noisyCopy(s, delay: 0, rate: rate, seed: 12).map { $0 * 0.5 }, "ref.caf")
    let other = try write(noisyCopy(s, delay: -0.75, rate: rate, seed: 13).map { $0 * 0.5 }, "other.caf")
    let result = try await AudioSync.offset(reference: ref, other: other, maxOffset: 3)
    #expect(abs(result.offset - -0.75) < 0.002, "offset \(result.offset)")
    #expect(result.confidence > 0.8)
}
