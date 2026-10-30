import CoreImage
import CutlineCore
import Foundation

/// Motion-adaptive deinterlacing of woven frames. The first field is kept; each line of the second
/// field is rebuilt from the first field's lines around it (4-tap cubic) wherever it combs against
/// them, so moving areas lose the combing and still areas keep full vertical resolution.
public enum Deinterlace {
    /// Comb strength (summed RGB distance from the neighbours' mean, beyond their own difference)
    /// where blending starts and where it is full.
    static let threshold: CGFloat = 0.06
    static let fullAt: CGFloat = 0.18

    /// `image` must be the decoded frame at its stored size, before orientation or scaling.
    public static func apply(_ image: CIImage, order: FieldOrder?) -> CIImage {
        guard let order, order != .progressive else { return image }
        let e = image.extent
        guard e.height >= 8, e.width >= 1, e.height.isFinite, e.width.isFinite else { return image }
        // Every intermediate stays opaque so premultiplied and straight color agree.
        let src = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent()
        let size = CGRect(origin: .zero, size: e.size)
        let interpolated = src.applyingFilter("CIConvolutionRGB9Vertical", parameters: [
            "inputWeights": CIVector(values: [0, -1.0 / 16, 0, 9.0 / 16, 0, 9.0 / 16, 0, -1.0 / 16, 0], count: 9),
        ])
        let average = src.applyingFilter("CIConvolutionRGB3X3", parameters: [
            "inputWeights": CIVector(values: [0, 0.5, 0, 0, 0, 0, 0, 0.5, 0], count: 9),
        ])
        let above = src.transformed(by: CGAffineTransform(translationX: 0, y: -1))
        let below = src.transformed(by: CGAffineTransform(translationX: 0, y: 1))
        let gain = 1 / (fullAt - threshold)
        let comb = gray(difference(src, average), weight: gain, bias: 0)
        let edge = gray(difference(above, below), weight: gain, bias: threshold * gain)
        // max(comb, edge) − edge is how far the comb exceeds the edge, or 0.
        let excess = difference(comb.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: edge]), edge)
        var mask = excess.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        // Spread over neighbouring lines and pixels so a moving edge is replaced as a whole.
        mask = mask.applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": 3, "inputHeight": 3])
        mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: secondField(height: Int(e.height), width: e.width, order: order)])
        let out = interpolated.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: mask])
            .cropped(to: size)
        return out.transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    }

    static func difference(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
    }

    /// (r+g+b)·weight + bias in every color channel, opaque.
    static func gray(_ img: CIImage, weight: CGFloat, bias: CGFloat) -> CIImage {
        let v = CIVector(x: weight, y: weight, z: weight, w: 0)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
        ])
    }

    /// White on the lines of the second field, black on the first: odd lines counted from the top
    /// for top field first, even lines for bottom field first.
    static func secondField(height: Int, width: CGFloat, order: FieldOrder) -> CIImage {
        let key = "\(height)-\(order.rawValue)"
        let column = lock.withLock { columns[key] } ?? {
            var rows = [UInt8](repeating: 0, count: height)
            for r in 0..<height where (r % 2 == 1) == (order == .tff) { rows[r] = 255 }
            let provider = CGDataProvider(data: Data(rows) as CFData)!
            let cg = CGImage(width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let img = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            lock.withLock { columns[key] = img }
            return img
        }()
        return column.samplingNearest().transformed(by: CGAffineTransform(scaleX: width, y: 1)).cropped(to: CGRect(x: 0, y: 0, width: width, height: CGFloat(height)))
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var columns: [String: CIImage] = [:]
}
