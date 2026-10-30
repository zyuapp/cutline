import AVFoundation
import CutlineCore
import CoreMedia
import CoreVideo
import VideoToolbox

extension FieldOrder {
    var fieldDetail: CFString {
        self == .bff ? kCVImageBufferFieldDetailSpatialFirstLineLate : kCVImageBufferFieldDetailSpatialFirstLineEarly
    }
}

/// Weaves pairs of field-rate frames into interlaced frames.
enum Interlace {
    /// Reads two frames rendered at the field rate and returns one frame holding the first in time on
    /// the leading field's lines and the second on the others, timed as the first and lasting both.
    static func nextFrame(_ output: AVAssetReaderOutput?, order: FieldOrder) -> CMSampleBuffer? {
        guard let first = output?.copyNextSampleBuffer() else { return nil }
        let second = output?.copyNextSampleBuffer()
        guard let a = CMSampleBufferGetImageBuffer(first) else { return first }
        let b = second.flatMap(CMSampleBufferGetImageBuffer) ?? a
        guard let woven = weave(a, b, order: order) else { return first }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: woven, formatDescriptionOut: &format)
        guard let format else { return first }
        let pts = CMSampleBufferGetPresentationTimeStamp(first)
        let fieldDuration = CMSampleBufferGetDuration(first)
        var timing = CMSampleTimingInfo(duration: fieldDuration.isValid ? fieldDuration + fieldDuration : .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: woven, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }

    /// `a` (earlier) on the leading field's lines, `b` on the other lines; every plane is woven by rows.
    static func weave(_ a: CVPixelBuffer, _ b: CVPixelBuffer, order: FieldOrder) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let format = CVPixelBufferGetPixelFormatType(a)
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &out) == kCVReturnSuccess, let out else { return nil }
        CVBufferPropagateAttachments(a, out)
        CVBufferSetAttachment(out, kCVImageBufferFieldCountKey, 2 as CFNumber, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferFieldDetailKey, order.fieldDetail, .shouldPropagate)
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
        }
        let lead = order == .tff ? 0 : 1
        let planes = max(1, CVPixelBufferGetPlaneCount(a))
        let planar = CVPixelBufferIsPlanar(a)
        for p in 0..<planes {
            let rows = planar ? CVPixelBufferGetHeightOfPlane(a, p) : h
            guard let src0 = planar ? CVPixelBufferGetBaseAddressOfPlane(a, p) : CVPixelBufferGetBaseAddress(a),
                  let src1 = planar ? CVPixelBufferGetBaseAddressOfPlane(b, p) : CVPixelBufferGetBaseAddress(b),
                  let dst = planar ? CVPixelBufferGetBaseAddressOfPlane(out, p) : CVPixelBufferGetBaseAddress(out) else { return nil }
            let sa = planar ? CVPixelBufferGetBytesPerRowOfPlane(a, p) : CVPixelBufferGetBytesPerRow(a)
            let sb = planar ? CVPixelBufferGetBytesPerRowOfPlane(b, p) : CVPixelBufferGetBytesPerRow(b)
            let sd = planar ? CVPixelBufferGetBytesPerRowOfPlane(out, p) : CVPixelBufferGetBytesPerRow(out)
            let bytes = min(sa, sb, sd)
            for r in 0..<rows {
                let fromA = r % 2 == lead
                memcpy(dst + r * sd, (fromA ? src0 + r * sa : src1 + r * sb), bytes)
            }
        }
        return out
    }
}
