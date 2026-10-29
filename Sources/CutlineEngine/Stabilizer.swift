import CoreImage
import CryptoKit
import CutlineCore
import Foundation
import Vision

/// Camera shake analysis and the corrections that remove it.
public enum Stabilizer {
    /// Where the picture content has moved since the first sample, per sample at `start + i / fps`.
    /// Translation is in fractions of the frame (+x right, +y down); rotation in degrees, clockwise.
    public struct Motion: Codable, Hashable, Sendable {
        public var fps: Double
        /// Source seconds of sample 0.
        public var start: Seconds
        /// Width over height of the analysed picture.
        public var aspect: Double
        public var dx: [Double]
        public var dy: [Double]
        public var angle: [Double]

        public init(fps: Double, start: Seconds, aspect: Double, dx: [Double], dy: [Double], angle: [Double]) {
            self.fps = fps
            self.start = start
            self.aspect = aspect
            self.dx = dx
            self.dy = dy
            self.angle = angle
        }

        public var count: Int { dx.count }
        public var end: Seconds { start + Double(max(0, count - 1)) / fps }
    }

    static let analysisSize = CGSize(width: 480, height: 480)

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/motion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func cacheURL(media url: URL, range: TimeRange) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\(attrs?[.size] as? Int ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(fmt(range.start))|\(fmt(range.end))|v1"
        let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return directory.appendingPathComponent("\(key).json")
    }

    public static func cached(media url: URL, range: TimeRange) -> Motion? {
        guard let data = try? Data(contentsOf: cacheURL(media: url, range: range)) else { return nil }
        return try? JSONDecoder().decode(Motion.self, from: data)
    }

    /// Registers consecutive downscaled frames (≤ 30 per second) over a source range and accumulates the camera path.
    public static func analyze(media url: URL, range: TimeRange, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Motion {
        if let m = cached(media: url, range: range) { return m }
        let frames = try await SourceFrames.open(url: url, maxSize: analysisSize, from: range.start)
        let fps = min(30, frames.fps.rounded() > 0 ? frames.fps : 30)
        let n = max(1, Int((max(0, range.duration) * fps + 1e-6).rounded(.down)) + 1)
        let w = Double(frames.size.width), h = Double(frames.size.height)
        let (dx, dy, angle) = try await runBlocking { cancelled -> ([Double], [Double], [Double]) in
            var dx = [0.0], dy = [0.0], angle = [0.0]
            dx.reserveCapacity(n)
            var prev = try frames.frame(near: range.start)
            for i in 1..<max(n, 1) {
                if cancelled() { throw CancellationError() }
                let cur = try frames.frame(near: range.start + Double(i) / fps)
                let step = cur.time == prev.time ? (0, 0, 0) : register(from: prev.buffer, to: cur.buffer, width: w, height: h)
                dx.append(dx[i - 1] + step.0 / w)
                dy.append(dy[i - 1] + step.1 / h)
                angle.append(angle[i - 1] + step.2)
                prev = cur
                if i % 10 == 0 { progress?(Double(i) / Double(n)) }
            }
            return (dx, dy, angle)
        }
        let m = Motion(fps: fps, start: range.start, aspect: w / h, dx: dx, dy: dy, angle: angle)
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: cacheURL(media: url, range: range), options: .atomic) }
        progress?(1)
        return m
    }

    /// Content motion from `a` to `b`: pixels (+x right, +y down) and degrees clockwise.
    static func register(from a: CVPixelBuffer, to b: CVPixelBuffer, width w: Double, height h: Double) -> (Double, Double, Double) {
        let handler = VNImageRequestHandler(cvPixelBuffer: b, options: [:])
        let homography = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: a, options: [:])
        if (try? handler.perform([homography])) != nil, let m = (homography.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform {
            // Vision maps the targeted frame onto the reference in pixels with a bottom-left origin.
            let c = SIMD3<Float>(Float(w / 2), Float(h / 2), 1)
            let p = m * c
            if abs(p.z) > 1e-6 {
                let tx = Double(p.x / p.z) - w / 2, ty = Double(p.y / p.z) - h / 2
                let rot = atan2(Double(m[0][1]), Double(m[0][0])) * 180 / .pi
                if abs(tx) < w / 4, abs(ty) < h / 4, abs(rot) < 10 { return (tx, -ty, -rot) }
            }
        }
        let translation = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: a, options: [:])
        if (try? handler.perform([translation])) != nil, let t = (translation.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform {
            return (Double(t.tx), -Double(t.ty), 0)
        }
        return (0, 0, 0)
    }

    nonisolated(unsafe) static var paths: [PathKey: StabilizationPath] = [:]
    static let lock = NSLock()

    struct PathKey: Hashable {
        var motion: Motion
        var smoothing: Double
    }

    /// The memoized smoothed path for a motion and smoothing.
    public static func path(_ m: Motion, smoothing: Seconds) -> StabilizationPath {
        let key = PathKey(motion: m, smoothing: smoothing)
        if let p = lock.withLock({ paths[key] }) { return p }
        let p = StabilizationPath(m, smoothing: smoothing)
        lock.withLock {
            if paths.count >= 16 { paths.removeAll() }
            paths[key] = p
        }
        return p
    }

    /// Smoothed path minus raw path at a source time, times strength: the translation (fractions, +x right, +y down)
    /// and clockwise rotation (degrees, about the center) that move the picture onto the smooth path.
    /// `smoothing` is the Gaussian sigma of the smoothed path in seconds.
    public static func correction(_ m: Motion, at sourceTime: Seconds, smoothing: Seconds, strength: Double) -> (dx: Double, dy: Double, angle: Double) {
        path(m, smoothing: smoothing).correction(at: sourceTime, strength: strength)
    }

    /// The smallest scale (≥ 1, about the center) that keeps the frame edges hidden under every correction.
    public static func requiredZoom(_ path: StabilizationPath, strength: Double) -> Double {
        let m = path.motion
        let w = max(m.aspect, 1e-3), h = 1.0
        var zoom = 1.0
        for i in 0..<m.count {
            let c = path.correction(index: i, strength: strength)
            let tx = c.dx * w, ty = c.dy * h
            let r = -c.angle * .pi / 180
            let cs = cos(r), sn = sin(r)
            for (px, py) in [(-w / 2, -h / 2), (w / 2, -h / 2), (-w / 2, h / 2), (w / 2, h / 2)] {
                let x = px - tx, y = py - ty
                let qx = cs * x - sn * y, qy = sn * x + cs * y
                zoom = max(zoom, abs(qx) / (w / 2), abs(qy) / (h / 2))
            }
        }
        return zoom
    }
}

/// A motion path with its Gaussian-smoothed version precomputed.
public final class StabilizationPath: Sendable {
    public let motion: Stabilizer.Motion
    /// Gaussian sigma in seconds.
    public let smoothing: Seconds
    public let dx: [Double]
    public let dy: [Double]
    public let angle: [Double]

    public init(_ m: Stabilizer.Motion, smoothing: Seconds) {
        motion = m
        self.smoothing = smoothing
        let sigma = smoothing * m.fps
        dx = StabilizationPath.smooth(m.dx, sigma: sigma)
        dy = StabilizationPath.smooth(m.dy, sigma: sigma)
        angle = StabilizationPath.smooth(m.angle, sigma: sigma)
    }

    /// Smoothed minus raw at a source time, times strength (0…1); clamped to the analysed range.
    public func correction(at sourceTime: Seconds, strength: Double) -> (dx: Double, dy: Double, angle: Double) {
        let n = motion.count
        guard n > 0 else { return (0, 0, 0) }
        let f = min(Double(n - 1), max(0, (sourceTime - motion.start) * motion.fps))
        let i = Int(f.rounded(.down)), j = min(i + 1, n - 1)
        let p = f - Double(i)
        let a = correction(index: i, strength: strength), b = correction(index: j, strength: strength)
        return (a.dx + (b.dx - a.dx) * p, a.dy + (b.dy - a.dy) * p, a.angle + (b.angle - a.angle) * p)
    }

    func correction(index i: Int, strength: Double) -> (dx: Double, dy: Double, angle: Double) {
        ((dx[i] - motion.dx[i]) * strength, (dy[i] - motion.dy[i]) * strength, (angle[i] - motion.angle[i]) * strength)
    }

    /// Gaussian blur with point reflection at the ends, so steady pans pass through unchanged.
    static func smooth(_ x: [Double], sigma: Double) -> [Double] {
        let n = x.count
        guard sigma > 0.01, n > 2 else { return x }
        let r = Int((3 * sigma).rounded(.up))
        let weights = (0...r).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        let total = weights[0] + 2 * weights.dropFirst().reduce(0, +)
        func value(_ j: Int) -> Double {
            if j < 0 { return 2 * x[0] - x[min(-j, n - 1)] }
            if j >= n { return 2 * x[n - 1] - x[max(0, 2 * (n - 1) - j)] }
            return x[j]
        }
        return (0..<n).map { i in
            var s = weights[0] * x[i]
            for k in 1...r { s += weights[k] * (value(i - k) + value(i + k)) }
            return s / total
        }
    }
}

extension Stabilizer {
    /// The source span analyzed for a clip: what it plays plus a second either side for smoothing.
    public static func window(_ clip: Clip, media: MediaAsset) -> TimeRange {
        let lo = min(clip.sourceIn, clip.sourceOut), hi = max(clip.sourceIn, clip.sourceOut)
        return TimeRange(max(0, ((lo - 1) * 10).rounded(.down) / 10), min(media.duration, ((hi + 1) * 10).rounded(.up) / 10))
    }
}
