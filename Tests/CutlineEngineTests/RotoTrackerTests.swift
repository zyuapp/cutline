import AppKit
import AVFoundation
import CoreImage
import CutlineCore
@testable import CutlineEngine
import Foundation
import simd
import Testing

private let w = 640, h = 360, frames = 40

/// Corners (top-left origin pixels) of a printed card drifting right and down while turning toward the camera.
private func cardCorners(_ i: Int) -> [SIMD2<Double>] {
    let t = Double(i)
    return [SIMD2(180 + 3 * t, 90 + 1.2 * t), SIMD2(420 + 3.4 * t, 100 + 1.0 * t), SIMD2(430 + 3.6 * t, 270 + 1.6 * t), SIMD2(170 + 3 * t, 260 + 1.4 * t)]
}

/// Where card-texture position (u, v) in 0…1 (top-left origin) is in frame `i`, in pixels.
private func onCard(_ u: Double, _ v: Double, frame i: Int) -> SIMD2<Double> {
    let unit = [SIMD2(0.0, 0.0), SIMD2(1.0, 0.0), SIMD2(1.0, 1.0), SIMD2(0.0, 1.0)]
    let hm = PlanarTracker.fourPoint(from: unit, to: cardCorners(i))!
    return PlanarTracker.apply(hm, SIMD2(u, v))
}

private func cardTexture() -> CIImage {
    let size = CGSize(width: 300, height: 220)
    let ctx = CGContext(data: nil, width: 300, height: 220, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.85, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    let colors = [CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1)]
    for i in 0..<14 {
        ctx.setFillColor(colors[i % 3])
        let x = Double((i * 73) % 260), y = Double((i * 47) % 190)
        if i % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: 18 + Double(i % 4) * 6, height: 12 + Double(i % 3) * 7)) } else { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 20, height: 20)) }
    }
    let line = NSAttributedString(string: "ROTO 2026 Cutline", attributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black])
    for (k, y) in [20.0, 90.0, 160.0].enumerated() {
        ctx.textPosition = CGPoint(x: 10 + Double(k) * 12, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(line), ctx)
    }
    return CIImage(cgImage: ctx.makeImage()!)
}

/// The moving card over a gray background with faint texture, 25 fps.
func writeRotoCardVideo(_ url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let ctx = CIContext()
    let texture = cardTexture()
    let background = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    for i in 0..<frames {
        let c = cardCorners(i).map { CIVector(x: $0.x, y: Double(h) - $0.y) }
        let card = texture.applyingFilter("CIPerspectiveTransform", parameters: ["inputTopLeft": c[0], "inputTopRight": c[1], "inputBottomRight": c[2], "inputBottomLeft": c[3]])
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        ctx.render(card.composited(over: background), to: pb!)
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 25))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// A six-point roto shape on the card: its corners inset a little and the middles of its top and bottom edges.
private let shapeUV: [(Double, Double)] = [(0.05, 0.05), (0.5, 0.04), (0.95, 0.05), (0.95, 0.95), (0.5, 0.96), (0.05, 0.95)]

private func worstError(_ keys: [RotoTracker.Key], frame i: Int) throws -> Double {
    let t = Double(i) / 25
    let key = try #require(keys.min { abs($0.t - t) < abs($1.t - t) })
    #expect(abs(key.t - t) < 0.03)
    let size = SIMD2(Double(w), Double(h))
    return zip(key.points, shapeUV).map { simd_distance($0 * size, onCard($1.0, $1.1, frame: i)) }.max()!
}

@Test func trackedRotoFollowsAMovingCardPlanar() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-roto-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    try await writeRotoCardVideo(url)
    let size = SIMD2(Double(w), Double(h))
    let start = shapeUV.map { onCard($0.0, $0.1, frame: 0) / size }
    let quad = cardCorners(0).map { $0 / size }
    let end = Double(frames - 1) / 25
    let planar = try await RotoTracker.track(media: url, from: 0, to: end, points: start, mode: .planar, quad: quad)
    let byBox = try await RotoTracker.track(media: url, from: 0, to: end, points: start, mode: .planar)
    let points = try await RotoTracker.track(media: url, from: 0, to: end, points: start, mode: .points)
    var report: [String] = []
    for (name, r, limit) in [("planar (card corners)", planar, 2.0), ("planar (shape bounds)", byBox, 2.0), ("points", points, 3.0)] {
        let worst = try [10, 25, frames - 1].map { try worstError(r.keys, frame: $0) }.max()!
        report.append("\(name) \(String(format: "%.2f", worst)) px")
        #expect(worst < limit, "\(name): worst point error \(worst) px")
    }
    print("tracked roto worst error over frames 10/25/39: " + report.joined(separator: ", "))
    // Thinning keeps every tracked position within half a pixel.
    let thin = RotoTracker.thinned(planar.keys, tolerance: 0.0005)
    #expect(thin.count <= planar.keys.count)
    for k in planar.keys {
        guard let j = thin.firstIndex(where: { $0.t >= k.t - 1e-9 }) else { continue }
        let b = thin[j], a = j > 0 ? thin[j - 1] : b
        let f = b.t > a.t ? (k.t - a.t) / (b.t - a.t) : 0
        for (p, (pa, pb)) in zip(k.points, zip(a.points, b.points)) {
            #expect(simd_distance(p, pa + (pb - pa) * f) < 0.0006)
        }
    }
}

@Test func magneticSnapFindsTheMatteEdge() {
    // A matte that is white left of x = 0.6: a point at 0.55 on a vertical edge moves to the boundary.
    let mw = 200, mh = 100
    let values = (0..<(mw * mh)).map { i -> Float in Double(i % mw) + 0.5 < 0.6 * Double(mw) ? 1 : 0 }
    let mask = MaskBuffer(width: mw, height: mh, values: values)
    let p = RotoTracker.snap(SIMD2(0.55, 0.5), prev: SIMD2(0.55, 0.3), next: SIMD2(0.55, 0.7), mask: mask, radius: 0.1, aspect: 2)
    #expect(p != nil && abs(p!.x - 0.6) < 0.003 && abs(p!.y - 0.5) < 1e-6, "\(String(describing: p))")
    #expect(RotoTracker.snap(SIMD2(0.2, 0.5), prev: SIMD2(0.2, 0.3), next: SIMD2(0.2, 0.7), mask: mask, radius: 0.05, aspect: 2) == nil)
}
