import CoreImage
import CutlineCore
import Foundation
import simd
import Vision

/// Follows a flat surface (screen, sign, wall) through a media file by chaining frame-to-frame homographies
/// measured inside the surface, so its four corners can drive a corner pin.
public enum PlanarTracker {
    static let analysisSize = CGSize(width: 960, height: 960)

    /// `corners` are tl, tr, br, bl at `start`, as frame fractions with a top-left origin. Tracking stops at a cut
    /// (`cuts` from scene analysis, or detected from the frames).
    public static func track(media url: URL, from start: Seconds, to end: Seconds, corners: [SIMD2<Double>], fps: Double = 25, cuts: [Seconds] = [], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TrackSample] {
        try await run(media: url, from: start, to: end, corners: corners, fps: fps, cuts: cuts, progress: progress).samples
    }

    /// `track`, saying where it stopped at a cut.
    public static func run(media url: URL, from start: Seconds, to end: Seconds, corners: [SIMD2<Double>], fps: Double = 25, cuts: [Seconds] = [], progress: (@Sendable (Double) -> Void)? = nil) async throws -> TrackRun {
        guard corners.count == 4 else { throw EditError("Give four corners: top-left, top-right, bottom-right, bottom-left") }
        let forward = end >= start
        let frames = try await SourceFrames.open(url: url, maxSize: analysisSize, forward: forward, from: start)
        let step = 1 / max(1, min(fps, frames.fps))
        let n = Int((abs(end - start) / step + 1e-6).rounded(.down))
        let times = (0...n).map { start + (forward ? 1 : -1) * Double($0) * step }
        let size = SIMD2(Double(frames.size.width), Double(frames.size.height))
        let result = try await runBlocking { cancelled -> TrackRun in
            let shots = TrackerShotGuard(cuts: cuts, frameDuration: max(step, frames.frameDuration))
            var quad = corners.map { $0 * size }
            var samples = [sample(start, quad, size: size, confidence: 1)]
            var prev = try frames.frame(near: start)
            var cut = shots.feed(prev.buffer, time: prev.time)
            let reference = (buffer: prev.buffer, quad: quad)
            for (k, t) in times.enumerated().dropFirst() {
                if cancelled() { throw CancellationError() }
                let next = try frames.frame(near: t)
                if next.time != prev.time {
                    if let b = shots.feed(next.buffer, time: next.time) {
                        cut = b
                        break
                    }
                    guard let h = homography(from: prev.buffer, to: next.buffer, inside: quad, size: size) else {
                        samples.append(sample(t, quad, size: size, confidence: 0))
                        break
                    }
                    let moved = quad.map { apply(h, $0) }
                    guard moved.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), convex(moved), area(moved) > 0.2 * area(quad), area(moved) < 5 * area(quad) else {
                        samples.append(sample(t, quad, size: size, confidence: 0))
                        break
                    }
                    quad = refine(moved, in: next.buffer, reference: reference, size: size) ?? moved
                    prev = next
                }
                samples.append(sample(t, quad, size: size, confidence: 1))
                if k % 10 == 0 { progress?(Double(k) / Double(times.count)) }
            }
            if cut == nil { cut = shots.finish() }
            if let cut { samples.removeAll { forward ? $0.t >= cut.time : $0.t <= cut.time } }
            if samples.isEmpty { samples = [sample(start, corners.map { $0 * size }, size: size, confidence: 1)] }
            return TrackRun(samples: samples, cut: cut)
        }
        progress?(1)
        return TrackRun(samples: result.samples.sorted { $0.t < $1.t }, cut: result.cut)
    }

    static func sample(_ t: Seconds, _ quad: [SIMD2<Double>], size: SIMD2<Double>, confidence: Double) -> TrackSample {
        let pts = quad.map { $0 / size }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        var s = TrackSample(t: t, box: NormRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!), confidence: confidence)
        s.corners = pts.flatMap { [$0.x, $0.y] }
        return s
    }

    /// Homography taking pixel positions (top-left origin) in `a` to the same surface points in `b`,
    /// measured on the part of both frames inside the quad's bounding box, shrunk to stay on the surface.
    static func homography(from a: CVPixelBuffer, to b: CVPixelBuffer, inside quad: [SIMD2<Double>], size: SIMD2<Double>) -> simd_double3x3? {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        let hw = (xs.max()! - xs.min()!) * 0.45, hh = (ys.max()! - ys.min()!) * 0.45
        let x0 = max(0, (cx - hw).rounded(.down)), y0 = max(0, (cy - hh).rounded(.down))
        let x1 = min(size.x, (cx + hw).rounded(.up)), y1 = min(size.y, (cy + hh).rounded(.up))
        guard x1 - x0 >= 24, y1 - y0 >= 24 else { return nil }
        // Vision works bottom-up; crop the same rect from both frames.
        let rect = CGRect(x: x0, y: size.y - y1, width: x1 - x0, height: y1 - y0)
        let ia = CIImage(cvPixelBuffer: a).cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let ib = CIImage(cvPixelBuffer: b).cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard let pa = render(ia, rect.size), let pb = render(ib, rect.size) else { return nil }
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: pa, options: [:])
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        guard (try? handler.perform([request])) != nil, let m = (request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform else { return nil }
        // warpTransform maps points of the targeted image (a) onto the reference (b), in the crop's bottom-up pixels.
        let warp = simd_double3x3(
            SIMD3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
            SIMD3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
            SIMD3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
        // Top-left frame pixels → bottom-up crop pixels, and back.
        let toCrop = simd_double3x3(SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(-x0, y1, 1))
        return toCrop.inverse * warp * toCrop
    }

    /// Corrects drift: unwarps the surface in the reference frame and in `buffer` to the same rectangle,
    /// measures what's left between them, and maps the rectangle's corners back into `buffer`.
    static func refine(_ quad: [SIMD2<Double>], in buffer: CVPixelBuffer, reference: (buffer: CVPixelBuffer, quad: [SIMD2<Double>]), size: SIMD2<Double>) -> [SIMD2<Double>]? {
        let q0 = reference.quad
        let w = (simd_distance(q0[0], q0[1]) + simd_distance(q0[3], q0[2])) / 2, h = (simd_distance(q0[0], q0[3]) + simd_distance(q0[1], q0[2])) / 2
        let scale = min(1, 320 / max(w, h))
        let rect = SIMD2((w * scale).rounded(), (h * scale).rounded())
        guard rect.x >= 32, rect.y >= 32,
              let a = rectified(reference.buffer, q0, rect, size), let b = rectified(buffer, quad, rect, size) else { return nil }
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: a, options: [:])
        guard (try? VNImageRequestHandler(cvPixelBuffer: b, options: [:]).perform([request])) != nil,
              let m = (request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform else { return nil }
        let warp = simd_double3x3(
            SIMD3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
            SIMD3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
            SIMD3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
        let flip = simd_double3x3(SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, rect.y, 1))
        let corners = [SIMD2(0, 0), SIMD2(rect.x, 0), rect, SIMD2(0, rect.y)]
        guard let back = fourPoint(from: corners, to: quad) else { return nil }
        let fixed = corners.map { apply(back, apply(flip * warp * flip, $0)) }
        // A wild correction means the registration failed; keep the chained estimate.
        let worst = zip(fixed, quad).map { simd_distance($0, $1) }.max() ?? .infinity
        return worst < 0.1 * max(w, h) && convex(fixed) ? fixed : nil
    }

    /// The surface inside `quad` (top-left pixels) unwarped to a `rect`-sized picture.
    static func rectified(_ buffer: CVPixelBuffer, _ quad: [SIMD2<Double>], _ rect: SIMD2<Double>, _ size: SIMD2<Double>) -> CVPixelBuffer? {
        func v(_ p: SIMD2<Double>) -> CIVector { CIVector(x: p.x, y: size.y - p.y) }
        let flat = CIImage(cvPixelBuffer: buffer).applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": v(quad[0]), "inputTopRight": v(quad[1]), "inputBottomRight": v(quad[2]), "inputBottomLeft": v(quad[3]),
        ])
        let e = flat.extent
        guard e.width > 1, e.height > 1 else { return nil }
        let fitted = flat.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: rect.x / e.width, y: rect.y / e.height)))
        return render(fitted, CGSize(width: rect.x, height: rect.y))
    }

    /// The homography taking four points to four others.
    static func fourPoint(from src: [SIMD2<Double>], to dst: [SIMD2<Double>]) -> simd_double3x3? {
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y, u, v) = (src[i].x, src[i].y, dst[i].x, dst[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for c in 0..<8 {
            guard let p = (c..<8).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p)
            for r in 0..<8 where r != c {
                let f = a[r][c] / a[c][c]
                for k in c..<9 { a[r][k] -= f * a[c][k] }
            }
        }
        let h = (0..<8).map { a[$0][8] / a[$0][$0] }
        return simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
    }

    static let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    static func render(_ image: CIImage, _ size: CGSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        context.render(image, to: pb)
        return pb
    }

    static func apply(_ h: simd_double3x3, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = h * SIMD3(p.x, p.y, 1)
        return SIMD2(v.x / v.z, v.y / v.z)
    }

    static func area(_ q: [SIMD2<Double>]) -> Double {
        var s = 0.0
        for i in q.indices {
            let a = q[i], b = q[(i + 1) % q.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    static func convex(_ q: [SIMD2<Double>]) -> Bool {
        var sign = 0.0
        for i in q.indices {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross == 0 { continue }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }
}
