import AppKit
import AVFoundation
import CoreImage
import CutlineCore
@testable import CutlineEngine
import Foundation
import simd
import Testing

/// Corners (top-left origin pixels) of a textured card drifting right and down while turning toward the camera.
private func truth(_ i: Int) -> [SIMD2<Double>] {
    let t = Double(i)
    return [SIMD2(180 + 3 * t, 90 + 1.2 * t), SIMD2(420 + 3.4 * t, 100 + 1.0 * t), SIMD2(430 + 3.6 * t, 270 + 1.6 * t), SIMD2(170 + 3 * t, 260 + 1.4 * t)]
}

/// A 300×220 card with print and shapes, the kind of detail a screen or sign has.
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
    let line = NSAttributedString(string: "PLANAR 2026 Cutline", attributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black])
    for (k, y) in [20.0, 90.0, 160.0].enumerated() {
        ctx.textPosition = CGPoint(x: 10 + Double(k) * 12, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(line), ctx)
    }
    return CIImage(cgImage: ctx.makeImage()!)
}

private func writeCardVideo(_ url: URL, frames: Int) async throws {
    let w = 640, h = 360
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
        let c = truth(i).map { CIVector(x: $0.x, y: Double(h) - $0.y) }
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

@Test func planarTrackerFollowsAMovingCard() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-card-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let n = 40
    try await writeCardVideo(url, frames: n)
    let size = SIMD2(640.0, 360.0)
    let start = truth(0).map { $0 / size }
    let end = Double(n - 1) / 25
    let samples = try await PlanarTracker.track(media: url, from: 0, to: end, corners: start)
    let last = try #require(samples.last)
    #expect(last.confidence > 0.5 && abs(last.t - end) < 0.05)
    let got = try #require(last.corners)
    let want = truth(n - 1).map { $0 / size }
    for k in 0..<4 {
        #expect(abs(got[2 * k] - want[k].x) < 0.01, "corner \(k) x \(got[2 * k]) vs \(want[k].x)")
        #expect(abs(got[2 * k + 1] - want[k].y) < 0.015, "corner \(k) y \(got[2 * k + 1]) vs \(want[k].y)")
    }
}
