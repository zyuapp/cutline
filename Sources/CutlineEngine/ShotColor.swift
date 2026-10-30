import CoreGraphics
import CoreImage
import CutlineCore
import Foundation
import Vision

/// Picture sampling for grading tools: pixels of a frame without its letterbox bars, a clip's picture partway
/// through its effect stack, faces and scene similarity.
public enum ShotColor {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    nonisolated(unsafe) static let context = CIContext(options: [.cacheIntermediates: false])

    /// RGBA8 sRGB bytes of an image, row 0 at the top.
    static func bytes(_ img: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (data, w, h) : nil
    }

    /// sRGB-encoded pixels inside the picture (letterbox and pillarbox bars left out) and inside `crop`
    /// (left, top, right, bottom fractions), every `step`-th pixel in a checkerboard.
    public static func pictureSamples(_ img: CGImage, crop: (Double, Double, Double, Double) = (0, 0, 0, 0), step: Int = 2, background: SIMD3<Float>? = nil) -> [SIMD3<Float>] {
        guard let (px, w, h) = bytes(img) else { return [] }
        let area = px.withUnsafeBufferPointer { PictureArea.active(bytes: $0.baseAddress!, width: w, height: h, rowBytes: w * 4, background: background) }
        let x0 = max(area.x, Int(Double(w) * crop.0)), x1 = min(area.x + area.width, w - Int(Double(w) * crop.2))
        let y0 = max(area.y, Int(Double(h) * crop.1)), y1 = min(area.y + area.height, h - Int(Double(h) * crop.3))
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(max(0, (x1 - x0) * (y1 - y0) / step))
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) where (x + y) % step == 0 {
                let i = (y * w + x) * 4
                out.append(SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) / 255)
            }
        }
        return out
    }

    /// sRGB-encoded pixels inside a rectangle given in frame fractions from the top left.
    public static func samples(_ img: CGImage, in rect: CGRect) -> [SIMD3<Float>] {
        guard let (px, w, h) = bytes(img) else { return [] }
        let x0 = max(0, Int(rect.minX * Double(w))), x1 = min(w, Int((rect.maxX * Double(w)).rounded(.up)))
        let y0 = max(0, Int(rect.minY * Double(h))), y1 = min(h, Int((rect.maxY * Double(h)).rounded(.up)))
        var out: [SIMD3<Float>] = []
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                let i = (y * w + x) * 4
                out.append(SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) / 255)
            }
        }
        return out
    }

    /// A clip's picture with the effects before `effect` applied (all of them when nil or absent), at `local`
    /// seconds into the clip, as an sRGB image of the same size.
    public static func picture(_ frame: CGImage, effects: [Effect], before effect: String?, clip: Clip?, at local: Seconds) -> CGImage {
        let upTo = effect.flatMap { id in effects.firstIndex { $0.id == id } } ?? effects.count
        let stack = effects[..<upTo].filter { !EffectCatalog.isAudio($0.type) && EffectCatalog.type($0.type)?.category != "mask" }
        guard !stack.isEmpty else { return frame }
        let img = CIImage(cgImage: frame)
        let ctx = EffectRenderer.Context(unit: img.extent.height, time: local, opaque: true)
        let out = EffectRenderer.apply(Array(stack), to: img, context: ctx) { e, name in clip?.anim["fx.\(e.id).\(name)"]?.value(at: local) }
        return context.createCGImage(out, from: img.extent, format: .RGBA8, colorSpace: space) ?? frame
    }

    /// Face boxes in frame fractions from the top left, largest first.
    public static func faces(_ img: CGImage) -> [CGRect] {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).filter { $0.confidence > 0.5 }
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// Skin-bearing middle of a face box: cheeks, nose and mouth, clear of hair, brows and background.
    public static func skinPatch(of face: CGRect) -> CGRect {
        CGRect(x: face.minX + face.width * 0.25, y: face.minY + face.height * 0.45, width: face.width * 0.5, height: face.height * 0.4)
    }

    public static func featurePrint(_ img: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return req.results?.first
    }

    /// Vision's distance between two pictures' content: about 0 for the same shot, above 0.9 for unrelated scenes.
    public static func contentDistance(_ a: VNFeaturePrintObservation?, _ b: VNFeaturePrintObservation?) -> Double? {
        guard let a, let b else { return nil }
        var d: Float = 0
        guard (try? a.computeDistance(&d, to: b)) != nil else { return nil }
        return Double(d)
    }
}
