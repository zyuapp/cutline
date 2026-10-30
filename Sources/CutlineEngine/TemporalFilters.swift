import CoreImage
import CoreVideo
import CutlineCore
import Foundation
import VideoToolbox
import simd

/// An RGB picture in 0…1, rows from the top, channels interleaved.
struct Plane {
    let width: Int
    let height: Int
    var data: [Float]

    init(width: Int, height: Int, data: [Float]? = nil) {
        self.width = width
        self.height = height
        self.data = data ?? [Float](repeating: 0, count: width * height * 3)
    }

    /// The picture of a 32BGRA buffer.
    init(_ pb: CVPixelBuffer) {
        let view = PixelView(pb)
        defer { view.unlock() }
        self.init(width: view.width, height: view.height)
        let w = width
        data.withUnsafeMutableBufferPointer { out in
            let dst = out.baseAddress!
            parallelRows(view.height) { rows in
                for y in rows {
                    let row = view.base + y * view.rowBytes
                    for x in 0..<w {
                        let p = row + x * 4, o = (y * w + x) * 3
                        dst[o] = Float(p[2]) / 255
                        dst[o + 1] = Float(p[1]) / 255
                        dst[o + 2] = Float(p[0]) / 255
                    }
                }
            }
        }
    }

    /// Writes the picture into a 32BGRA buffer of the same size, opaque.
    func write(to pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let w = min(width, CVPixelBufferGetWidth(pb)), h = min(height, CVPixelBufferGetHeight(pb))
        let stride = width
        data.withUnsafeBufferPointer { src in
            let s = src.baseAddress!
            parallelRows(h) { rows in
                for y in rows {
                    let row = base + y * rowBytes
                    for x in 0..<w {
                        let o = (y * stride + x) * 3, p = row + x * 4
                        p[0] = Plane.byte(s[o + 2])
                        p[1] = Plane.byte(s[o + 1])
                        p[2] = Plane.byte(s[o])
                        p[3] = 255
                    }
                }
            }
        }
    }

    @inline(__always) static func byte(_ v: Float) -> UInt8 { UInt8(min(255, max(0, v * 255 + 0.5))) }
}

/// Read access to a locked 32BGRA buffer.
struct PixelView {
    let buffer: CVPixelBuffer
    let base: UnsafePointer<UInt8>
    let rowBytes: Int
    let width: Int
    let height: Int

    init(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        buffer = pb
        base = UnsafePointer(CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self))
        rowBytes = CVPixelBufferGetBytesPerRow(pb)
        width = CVPixelBufferGetWidth(pb)
        height = CVPixelBufferGetHeight(pb)
    }

    func unlock() { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    /// Bilinear RGB in 0…1 at pixel coordinates (pixel centers at integers), clamped to the edge, into `out[0...2]`.
    @inline(__always) func sample(_ x: Float, _ y: Float, into out: UnsafeMutablePointer<Float>) {
        let cx = min(max(x, 0), Float(width - 1)), cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let a = base + y0 * rowBytes + x0 * 4, b = base + y0 * rowBytes + x1 * 4
        let c = base + y1 * rowBytes + x0 * 4, d = base + y1 * rowBytes + x1 * 4
        let wa = (1 - fx) * (1 - fy) / 255, wb = fx * (1 - fy) / 255, wc = (1 - fx) * fy / 255, wd = fx * fy / 255
        out[0] = wa * Float(a[2]) + wb * Float(b[2]) + wc * Float(c[2]) + wd * Float(d[2])
        out[1] = wa * Float(a[1]) + wb * Float(b[1]) + wc * Float(c[1]) + wd * Float(d[1])
        out[2] = wa * Float(a[0]) + wb * Float(b[0]) + wc * Float(c[0]) + wd * Float(d[0])
    }

    /// Bilinear luma-like gray (mean of the channels) at pixel coordinates, clamped to the edge.
    @inline(__always) func gray(_ x: Float, _ y: Float) -> Float {
        let cx = min(max(x, 0), Float(width - 1)), cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        @inline(__always) func g(_ p: UnsafePointer<UInt8>) -> Float { Float(Int(p[0]) + Int(p[1]) + Int(p[2])) }
        let a = g(base + y0 * rowBytes + x0 * 4), b = g(base + y0 * rowBytes + x1 * 4)
        let c = g(base + y1 * rowBytes + x0 * 4), d = g(base + y1 * rowBytes + x1 * 4)
        return ((a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy) / 765
    }

    /// Bilinear RGB at pixel coordinates (pixel centers at integers), clamped to the edge.
    @inline(__always) func sample(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let cx = min(max(x, 0), Float(width - 1)), cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let r0 = base + y0 * rowBytes, r1 = base + y1 * rowBytes
        @inline(__always) func px(_ r: UnsafePointer<UInt8>, _ x: Int) -> SIMD3<Float> {
            let p = r + x * 4
            return SIMD3(Float(p[2]), Float(p[1]), Float(p[0]))
        }
        let top = px(r0, x0) + (px(r0, x1) - px(r0, x0)) * fx
        let bottom = px(r1, x0) + (px(r1, x1) - px(r1, x0)) * fx
        return (top + (bottom - top) * fy) / 255
    }
}

/// Splits `count` rows into chunks run concurrently.
func parallelRows(_ count: Int, _ body: (Range<Int>) -> Void) {
    guard count > 0 else { return }
    let chunks = min(count, ProcessInfo.processInfo.activeProcessorCount * 3)
    DispatchQueue.concurrentPerform(iterations: chunks) { k in
        body(count * k / chunks..<count * (k + 1) / chunks)
    }
}

/// Per-pixel motion from one frame to another, stored on a coarse grid in full-resolution pixels.
struct FlowField {
    let width: Int
    let height: Int
    /// Full-resolution pixels per grid cell.
    let cellX: Float
    let cellY: Float
    /// dx, dy per cell (+x right, +y down): the content at p in the first frame is at p + flow in the second.
    let data: [Float]

    static func uniform(_ dx: Float, _ dy: Float) -> FlowField {
        FlowField(width: 1, height: 1, cellX: 1, cellY: 1, data: [dx, dy])
    }

    /// Bilinear flow at a full-resolution pixel.
    func at(_ x: Float, _ y: Float) -> (Float, Float) {
        if width == 1 && height == 1 { return (data[0], data[1]) }
        let gx = min(max((x + 0.5) / cellX - 0.5, 0), Float(width - 1)), gy = min(max((y + 0.5) / cellY - 0.5, 0), Float(height - 1))
        let x0 = Int(gx), y0 = Int(gy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = gx - Float(x0), fy = gy - Float(y0)
        let a = (y0 * width + x0) * 2, b = (y0 * width + x1) * 2, c = (y1 * width + x0) * 2, d = (y1 * width + x1) * 2
        let wa = (1 - fx) * (1 - fy), wb = fx * (1 - fy), wc = (1 - fx) * fy, wd = fx * fy
        return (wa * data[a] + wb * data[b] + wc * data[c] + wd * data[d], wa * data[a + 1] + wb * data[b + 1] + wc * data[c + 1] + wd * data[d + 1])
    }

    /// Motion from this flow's first frame to `next`'s second: this flow, then `next` from where it lands.
    func then(_ next: FlowField) -> FlowField {
        if width == 1 && height == 1 && next.width == 1 && next.height == 1 { return .uniform(data[0] + next.data[0], data[1] + next.data[1]) }
        let grid = width * height > next.width * next.height ? self : next
        var out = [Float](repeating: 0, count: grid.width * grid.height * 2)
        for gy in 0..<grid.height {
            for gx in 0..<grid.width {
                let x = (Float(gx) + 0.5) * grid.cellX - 0.5, y = (Float(gy) + 0.5) * grid.cellY - 0.5
                let (dx, dy) = at(x, y)
                let (ex, ey) = next.at(x + dx, y + dy)
                out[(gy * grid.width + gx) * 2] = dx + ex
                out[(gy * grid.width + gx) * 2 + 1] = dy + ey
            }
        }
        return FlowField(width: grid.width, height: grid.height, cellX: grid.cellX, cellY: grid.cellY, data: out)
    }

    /// Bilinear flow along full-resolution row `y`, `count` pixels wide, into `dx` and `dy`.
    func row(_ y: Int, count: Int, dx: UnsafeMutablePointer<Float>, dy: UnsafeMutablePointer<Float>) {
        data.withUnsafeBufferPointer { buf in
            let f = buf.baseAddress!
            if width == 1 && height == 1 {
                for x in 0..<count { dx[x] = f[0]; dy[x] = f[1] }
                return
            }
            let gy = min(max((Float(y) + 0.5) / cellY - 0.5, 0), Float(height - 1))
            let y0 = Int(gy), y1 = min(y0 + 1, height - 1), fy = gy - Float(y0)
            let r0 = f + y0 * width * 2, r1 = f + y1 * width * 2
            for x in 0..<count {
                let gx = min(max((Float(x) + 0.5) / cellX - 0.5, 0), Float(width - 1))
                let x0 = Int(gx), x1 = min(x0 + 1, width - 1), fx = gx - Float(x0)
                let wa = (1 - fx) * (1 - fy), wb = fx * (1 - fy), wc = (1 - fx) * fy, wd = fx * fy
                dx[x] = wa * r0[x0 * 2] + wb * r0[x1 * 2] + wc * r1[x0 * 2] + wd * r1[x1 * 2]
                dy[x] = wa * r0[x0 * 2 + 1] + wb * r0[x1 * 2 + 1] + wc * r1[x0 * 2 + 1] + wd * r1[x1 * 2 + 1]
            }
        }
    }
}

/// Dense optical flow from VideoToolbox, both directions per pair of frames. Blocks the calling thread.
final class OpticalFlow {
    let processor = VTFrameProcessor()
    let width: Int
    let height: Int
    let context: CIContext
    let sourcePool: CVPixelBufferPool
    let destinationPool: CVPixelBufferPool
    private var converted: [Int: VTFrameProcessorFrame] = [:]

    init(width: Int, height: Int, context: CIContext) throws {
        guard VTOpticalFlowConfiguration.isSupported,
              let config = VTOpticalFlowConfiguration(frameWidth: width, frameHeight: height, qualityPrioritization: .normal, revision: VTOpticalFlowConfiguration.defaultRevision)
        else { throw EditError("Optical flow is not available") }
        self.width = width
        self.height = height
        self.context = context
        sourcePool = try FlowInterpolator.pool(config.sourcePixelBufferAttributes)
        destinationPool = try FlowInterpolator.pool(config.destinationPixelBufferAttributes)
        try processor.startSession(configuration: config)
    }

    deinit { processor.endSession() }

    private func buffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { throw EditError("Cannot allocate an optical-flow frame") }
        return pb
    }

    private func frame(_ index: Int, _ pb: CVPixelBuffer) throws -> VTFrameProcessorFrame {
        if let hit = converted[index] { return hit }
        let out = try buffer(sourcePool)
        context.render(CIImage(cvPixelBuffer: pb), to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        guard let f = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 600)) else { throw EditError("Cannot wrap an optical-flow frame") }
        converted[index] = f
        return f
    }

    /// Drops converted frames outside `keep`.
    func retain(_ keep: (Int) -> Bool) {
        converted = converted.filter { keep($0.key) }
    }

    /// Flow from frame `a` to frame `b` and back; `a` comes before `b`.
    func flows(_ a: Int, _ pa: CVPixelBuffer, _ b: Int, _ pb: CVPixelBuffer) throws -> (forward: FlowField, backward: FlowField) {
        let fa = try frame(a, pa), fb = try frame(b, pb)
        guard let flow = VTFrameProcessorOpticalFlow(forwardFlow: try buffer(destinationPool), backwardFlow: try buffer(destinationPool)),
              let params = VTOpticalFlowParameters(sourceFrame: fa, nextFrame: fb, submissionMode: .random, destinationOpticalFlow: flow)
        else { throw EditError("Cannot set up optical flow") }
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        processor.process(parameters: params) { _, error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
        return (field(flow.forwardFlow), field(flow.backwardFlow))
    }

    private func field(_ pb: CVPixelBuffer) -> FlowField {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        let cellX = Float(width) / Float(w), cellY = Float(height) / Float(h)
        var data = [Float](repeating: 0, count: w * h * 2)
        let half = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_TwoComponent16Half
        for y in 0..<h {
            let row = base + y * rowBytes
            for x in 0..<w {
                let dx: Float, dy: Float
                if half {
                    let p = row.assumingMemoryBound(to: Float16.self) + x * 2
                    (dx, dy) = (Float(p[0]), Float(p[1]))
                } else {
                    let p = row.assumingMemoryBound(to: Float.self) + x * 2
                    (dx, dy) = (p[0], p[1])
                }
                data[(y * w + x) * 2] = dx * cellX
                data[(y * w + x) * 2 + 1] = dy * cellY
            }
        }
        return FlowField(width: w, height: h, cellX: cellX, cellY: cellY, data: data)
    }
}

/// Global content motion between two frames from Vision's translation registration on small copies.
enum Registration {
    static let side: CGFloat = 480

    /// A copy no larger than `side` on its long edge, for registration.
    static func small(_ pb: CVPixelBuffer, context: CIContext) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let s = min(1, side / CGFloat(max(w, h)))
        if s >= 1 { return pb }
        let sw = max(2, Int(CGFloat(w) * s)), sh = max(2, Int(CGFloat(h) * s))
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, sw, sh, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        guard let out else { return nil }
        let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: CGFloat(sw) / CGFloat(w), y: CGFloat(sh) / CGFloat(h)))
        context.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: sw, height: sh), colorSpace: nil)
        return out
    }

    /// Content motion from `a` to `b` in `b`'s full-resolution pixels (+x right, +y down); `a` and `b` are small copies
    /// of frames `fullWidth` wide.
    static func translation(_ a: CVPixelBuffer, _ b: CVPixelBuffer, fullWidth: Int) -> SIMD2<Double> {
        let w = Double(CVPixelBufferGetWidth(b)), h = Double(CVPixelBufferGetHeight(b))
        let step = Stabilizer.register(from: a, to: b, width: w, height: h)
        let k = Double(fullWidth) / w
        return SIMD2(step.0 * k, step.1 * k)
    }
}

/// Decoded frames by index, read forward once, keeping only the ones the filters still need.
final class FrameWindow {
    typealias Next = () throws -> (time: Seconds, buffer: CVPixelBuffer)?

    private let next: Next
    private var frames: [Int: CVPixelBuffer] = [:]
    private(set) var times: [Seconds] = []
    private(set) var exhausted = false
    /// Frames to hold on to; consulted as each frame is decoded and on `retain`.
    var keep: (Int) -> Bool = { _ in true }
    /// Called for each decoded frame with the frame before it.
    var onDecode: ((Int, CVPixelBuffer, CVPixelBuffer?) throws -> Void)?
    private var last: CVPixelBuffer?
    /// Shots of the decoded frames; filters never take pixels from another shot.
    let shots: ShotSplitter

    /// `cuts` are scene cuts from analysis, in source seconds; cuts are also detected as frames decode.
    init(cuts: [Seconds] = [], frameDuration: Seconds = 1.0 / 30, _ next: @escaping Next) {
        self.next = next
        shots = ShotSplitter(cuts: cuts, frameDuration: frameDuration)
    }

    var decoded: Int { times.count }

    /// Frame `i`, decoding forward to it; nil past the end or once dropped.
    func frame(_ i: Int) throws -> CVPixelBuffer? {
        guard i >= 0 else { return nil }
        while decoded <= i, !exhausted { try decodeOne() }
        return frames[i]
    }

    private func decodeOne() throws {
        guard let f = try next() else {
            exhausted = true
            shots.finish()
            return
        }
        let index = decoded
        times.append(f.time)
        shots.feed(f.buffer, time: f.time)
        try onDecode?(index, f.buffer, last)
        last = f.buffer
        if keep(index) { frames[index] = f.buffer }
    }

    /// Whether decoded frames `i` and `j` belong to the same shot, decoding ahead until that is settled.
    func sameShot(_ i: Int, _ j: Int) throws -> Bool {
        let hi = max(i, j)
        _ = try frame(hi)
        guard hi < decoded else { return false }
        while !exhausted, !(min(i, j)...hi).allSatisfy(shots.isFinal) { try decodeOne() }
        return shots.sameShot(i, j)
    }

    func time(_ i: Int) -> Seconds? { times.indices.contains(i) ? times[i] : nil }

    func retain() {
        frames = frames.filter { keep($0.key) }
    }
}

/// One temporal filter over the frame sequence.
protocol TemporalStage: AnyObject {
    /// Replaces `current` (frame `i` as the earlier stages left it) with this stage's result.
    func apply(_ i: Int, _ current: inout Plane, _ window: FrameWindow) throws
    /// Whether frame `j` is still needed for frames from `i` on.
    func needs(_ j: Int, from i: Int) -> Bool
    func decoded(_ index: Int, _ buffer: CVPixelBuffer, previous: CVPixelBuffer?) throws
}

extension TemporalStage {
    func decoded(_ index: Int, _ buffer: CVPixelBuffer, previous: CVPixelBuffer?) throws {}
}

/// A clean plate at the frame size: an image file, or the frame of the clip at `time` with the object's `box` in it.
struct CleanPlate {
    var buffer: CVPixelBuffer
    var box: NormRect?
    var time: Seconds?
}

/// Runs temporal stages over every frame of a window in order.
final class PictureProcessor {
    let stages: [TemporalStage]

    init(stages: [TemporalStage]) {
        self.stages = stages
    }

    /// Builds the stages for the enabled `video.*` effects of a clip, for frames `width`×`height` at `fps`.
    /// `plates` are the clean plates of object removals by effect id, at the frame size, with the object's box in each.
    static func stages(_ effects: [Effect], width: Int, height: Int, fps: Double, context: CIContext, plates: [String: CleanPlate] = [:], cuts: [Seconds] = []) -> [TemporalStage] {
        var flow: OpticalFlow?
        var triedFlow = false
        return effects.compactMap { e -> TemporalStage? in
            let n = { (name: String) in e.params[name]?.number ?? EffectCatalog.type(e.type)?.spec(name)?.defaultValue.number ?? 0 }
            switch e.type {
            case "video.denoise":
                if !triedFlow {
                    triedFlow = true
                    flow = try? OpticalFlow(width: width, height: height, context: context)
                }
                let s = Denoiser.Settings(radius: Int(n("temporal_frames").rounded()), strength: Float(n("strength")), threshold: Float(n("motion_threshold")), spatial: Float(n("spatial")), mix: Float(e.mix))
                return Denoiser(s, flow: flow, context: context)
            case "video.rolling_shutter":
                let s = RollingShutterCorrector.Settings(readout: Float(n("readout")), bottomUp: e.params["direction"]?.string == "bottom_up", bands: Int(n("bands").rounded()), strength: Float(n("strength")), mix: Float(e.mix))
                return RollingShutterCorrector(s, flow: try? OpticalFlow(width: width, height: height, context: context), context: context)
            case "video.remove_object":
                let samples = ObjectTrack.decodeBoxes(e.params["boxes"]?.string ?? "")
                guard !samples.isEmpty else { return nil }
                var s = ObjectRemover.Settings(samples: samples, padding: Float(n("padding")), window: n("window"), feather: Float(n("feather")), mix: Float(e.mix))
                s.patchFill = (e.params["fill"]?.string ?? "patch") != "smooth"
                if let p = plates[e.id] {
                    let box = p.box
                    s.plate = p.buffer
                    s.plateTime = p.time
                    s.plateCuts = cuts
                    let pad = s.padding * Float(height)
                    s.plateHole = box.map { SIMD4(Float($0.x) * Float(width) - pad, Float($0.y) * Float(height) - pad, Float($0.x + $0.width) * Float(width) + pad, Float($0.y + $0.height) * Float(height) + pad) }
                }
                return ObjectRemover(s, fps: fps, context: context)
            default:
                return nil
            }
        }
    }

    /// Filters each frame of `window` and hands it to `emit` with its index and source time.
    func run(_ window: FrameWindow, cancelled: () -> Bool, emit: (Int, Seconds, Plane) throws -> Void) throws {
        var i = 0
        window.onDecode = { [stages] index, buffer, previous in
            for s in stages { try s.decoded(index, buffer, previous: previous) }
        }
        // Frames ahead are all kept: each becomes the current frame later.
        window.keep = { j in j >= 0 }
        while let buffer = try window.frame(i) {
            if cancelled() { throw CancellationError() }
            var plane = Plane(buffer)
            for s in stages { try s.apply(i, &plane, window) }
            try emit(i, window.time(i) ?? 0, plane)
            let next = i + 1
            window.keep = { [stages] j in j >= next || stages.contains { $0.needs(j, from: next) } }
            window.retain()
            i += 1
        }
    }
}

/// Motion-compensated temporal noise reduction: neighbours warped onto each frame by optical flow, blended with
/// weights that fall to zero where the aligned neighbour differs from the frame by more than its noise plus a threshold.
final class Denoiser: TemporalStage {
    struct Settings {
        var radius: Int
        var strength: Float
        var threshold: Float
        var spatial: Float
        var mix: Float
    }

    let settings: Settings
    let flow: OpticalFlow?
    let context: CIContext
    private var flows: [Int: [Int: FlowField]] = [:]
    private var small: [Int: CVPixelBuffer] = [:]
    /// Latest per-channel noise estimate of the input, for the spatial pass.
    private(set) var noise: Float = 0

    init(_ settings: Settings, flow: OpticalFlow?, context: CIContext) {
        var s = settings
        s.radius = min(5, max(1, s.radius))
        s.threshold = max(0.002, s.threshold)
        self.settings = s
        self.flow = flow
        self.context = context
    }

    func needs(_ j: Int, from i: Int) -> Bool { j >= i - settings.radius }

    /// Motion from frame `i` to frame `j`: measured between neighbouring frames and chained, so each frame costs
    /// one optical-flow pass whatever the radius.
    func field(_ i: Int, _ j: Int, _ window: FrameWindow) throws -> FlowField {
        if let hit = flows[i]?[j] { return hit }
        if abs(j - i) == 1 {
            guard let pi = try window.frame(i), let pj = try window.frame(j) else { return .uniform(0, 0) }
            return try step(i, pi, j, pj)
        }
        let k = j > i ? j - 1 : j + 1
        let chained = try field(i, k, window).then(try field(k, j, window))
        flows[i, default: [:]][j] = chained
        return chained
    }

    /// Motion between neighbouring frames `i` and `j`, both directions cached.
    private func step(_ i: Int, _ pi: CVPixelBuffer, _ j: Int, _ pj: CVPixelBuffer) throws -> FlowField {
        let (a, b) = i < j ? (i, j) : (j, i)
        let (pa, pb) = i < j ? (pi, pj) : (pj, pi)
        if let flow, let pair = try? flow.flows(a, pa, b, pb) {
            flows[a, default: [:]][b] = pair.forward
            flows[b, default: [:]][a] = pair.backward
        } else {
            guard let sa = small[a] ?? Registration.small(pa, context: context), let sb = small[b] ?? Registration.small(pb, context: context) else { return .uniform(0, 0) }
            small[a] = sa
            small[b] = sb
            let t = Registration.translation(sa, sb, fullWidth: CVPixelBufferGetWidth(pa))
            flows[a, default: [:]][b] = .uniform(Float(t.x), Float(t.y))
            flows[b, default: [:]][a] = .uniform(Float(-t.x), Float(-t.y))
        }
        return flows[i]![j]!
    }

    func apply(_ i: Int, _ current: inout Plane, _ window: FrameWindow) throws {
        guard try window.frame(i) != nil else { return }
        let w = current.width, h = current.height, n = w * h
        let base = current.data
        var acc = base
        var wsum = [Float](repeating: 1, count: n)
        var floors: [Float] = []
        let order = (1...settings.radius).flatMap { [i - $0, i + $0] }
        for j in order {
            guard let there = try window.frame(j), try window.sameShot(i, j) else { continue }
            let f = try field(i, j, window)
            var warped = [Float](repeating: 0, count: n * 3)
            var diff = [Float](repeating: 0, count: n)
            let view = PixelView(there)
            base.withUnsafeBufferPointer { cb in
                warped.withUnsafeMutableBufferPointer { wb in
                    diff.withUnsafeMutableBufferPointer { db in
                        let c = cb.baseAddress!, wp = wb.baseAddress!, d = db.baseAddress!
                        parallelRows(h) { rows in
                            let mx = UnsafeMutablePointer<Float>.allocate(capacity: w), my = UnsafeMutablePointer<Float>.allocate(capacity: w)
                            defer { mx.deallocate(); my.deallocate() }
                            for y in rows {
                                f.row(y, count: w, dx: mx, dy: my)
                                for x in 0..<w {
                                    let sx = Float(x) + mx[x], sy = Float(y) + my[x]
                                    let o = y * w + x
                                    // Neighbour pixels that came from outside its frame have nothing to offer.
                                    if sx < -1 || sy < -1 || sx > Float(w) || sy > Float(h) {
                                        d[o] = .infinity
                                        continue
                                    }
                                    let v = wp + o * 3, here = c + o * 3
                                    view.sample(sx, sy, into: v)
                                    d[o] = (abs(v[0] - here[0]) + abs(v[1] - here[1]) + abs(v[2] - here[2])) / 3
                                }
                            }
                        }
                    }
                }
            }
            view.unlock()
            let smooth = Denoiser.box3(diff, w, h)
            // Most of a frame is aligned well, so a low quantile of the difference measures the noise alone.
            let floor = min(0.12, 1.8 * Denoiser.quantile(smooth, 0.3))
            floors.append(floor)
            let t = settings.threshold
            smooth.withUnsafeBufferPointer { sb in
                warped.withUnsafeBufferPointer { wb in
                    acc.withUnsafeMutableBufferPointer { ab in
                        wsum.withUnsafeMutableBufferPointer { ws in
                            let s = sb.baseAddress!, wp = wb.baseAddress!, a = ab.baseAddress!, sum = ws.baseAddress!
                            parallelRows(h) { rows in
                                for o in rows.lowerBound * w..<rows.upperBound * w {
                                    let weight = min(1, max(0, (floor + t - s[o]) / t))
                                    guard weight > 0 else { continue }
                                    a[o * 3] += weight * wp[o * 3]
                                    a[o * 3 + 1] += weight * wp[o * 3 + 1]
                                    a[o * 3 + 2] += weight * wp[o * 3 + 2]
                                    sum[o] += weight
                                }
                            }
                        }
                    }
                }
            }
        }
        // A per-channel sigma: the mean absolute difference of two noisy frames is about 1.13 sigma.
        noise = floors.isEmpty ? 0.02 : floors.sorted()[floors.count / 2] / 1.8 / 1.13
        let k = settings.strength * settings.mix
        var meanWeight: Float = 0
        var out = base
        out.withUnsafeMutableBufferPointer { ob in
            acc.withUnsafeBufferPointer { ab in
                wsum.withUnsafeBufferPointer { ws in
                    let o = ob.baseAddress!, a = ab.baseAddress!, sum = ws.baseAddress!
                    for p in 0..<n {
                        let inv = 1 / sum[p]
                        for c in 0..<3 {
                            let avg = a[p * 3 + c] * inv
                            o[p * 3 + c] += k * (avg - o[p * 3 + c])
                        }
                    }
                }
            }
        }
        wsum.withUnsafeBufferPointer { meanWeight = $0.reduce(0, +) / Float(max(1, n)) }
        if settings.spatial > 0.001 {
            let residual = noise / max(1, meanWeight).squareRoot()
            out = Denoiser.bilateral(Plane(width: w, height: h, data: out), sigma: max(0.008, 2.5 * residual) * (0.5 + settings.spatial), amount: settings.spatial * settings.mix).data
        }
        current.data = out
        flows = flows.filter { $0.key >= i + 1 - settings.radius }.mapValues { $0.filter { $0.key >= i + 1 - settings.radius } }
        small = small.filter { $0.key >= i + 1 - settings.radius }
        flow?.retain { $0 >= i + 1 - settings.radius }
    }

    /// 3×3 box mean, edges clamped; infinities stay infinite.
    static func box3(_ v: [Float], _ w: Int, _ h: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: v.count)
        var out = [Float](repeating: 0, count: v.count)
        v.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { tb in
                let s = src.baseAddress!, t = tb.baseAddress!
                parallelRows(h) { rows in
                    for y in rows {
                        let r = y * w
                        for x in 0..<w {
                            t[r + x] = s[r + max(0, x - 1)] + s[r + x] + s[r + min(w - 1, x + 1)]
                        }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { tb in
            out.withUnsafeMutableBufferPointer { ob in
                let t = tb.baseAddress!, o = ob.baseAddress!
                parallelRows(h) { rows in
                    for y in rows {
                        let up = max(0, y - 1) * w, mid = y * w, down = min(h - 1, y + 1) * w
                        for x in 0..<w { o[mid + x] = (t[up + x] + t[mid + x] + t[down + x]) / 9 }
                    }
                }
            }
        }
        return out
    }

    /// The `q` quantile of the finite values, from a subsample.
    static func quantile(_ v: [Float], _ q: Float) -> Float {
        let step = max(1, v.count / 20000)
        var sample: [Float] = []
        sample.reserveCapacity(v.count / step + 1)
        var i = 0
        while i < v.count {
            if v[i].isFinite { sample.append(v[i]) }
            i += step
        }
        guard !sample.isEmpty else { return 0 }
        sample.sort()
        return sample[min(sample.count - 1, Int(Float(sample.count) * q))]
    }

    /// 5×5 bilateral filter: neighbours count by distance and by how close their color is, within `sigma`.
    static func bilateral(_ p: Plane, sigma: Float, amount: Float) -> Plane {
        let w = p.width, h = p.height
        var out = p.data
        var spatial = [Float](repeating: 0, count: 25)
        for dy in -2...2 { for dx in -2...2 { spatial[(dy + 2) * 5 + dx + 2] = exp(-Float(dx * dx + dy * dy) / (2 * 1.5 * 1.5)) } }
        let inv = 1 / (2 * sigma * sigma)
        p.data.withUnsafeBufferPointer { sb in
            out.withUnsafeMutableBufferPointer { ob in
                let s = sb.baseAddress!, o = ob.baseAddress!
                parallelRows(h) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let c = (y * w + x) * 3
                            let r0 = s[c], g0 = s[c + 1], b0 = s[c + 2]
                            var sr: Float = 0, sg: Float = 0, sbl: Float = 0, sw: Float = 0
                            for dy in -2...2 {
                                let yy = min(h - 1, max(0, y + dy))
                                for dx in -2...2 {
                                    let xx = min(w - 1, max(0, x + dx))
                                    let q = (yy * w + xx) * 3
                                    let d = (abs(s[q] - r0) + abs(s[q + 1] - g0) + abs(s[q + 2] - b0)) / 3
                                    let k = spatial[(dy + 2) * 5 + dx + 2] * exp(-d * d * inv)
                                    sr += k * s[q]
                                    sg += k * s[q + 1]
                                    sbl += k * s[q + 2]
                                    sw += k
                                }
                            }
                            o[c] = r0 + amount * (sr / sw - r0)
                            o[c + 1] = g0 + amount * (sg / sw - g0)
                            o[c + 2] = b0 + amount * (sbl / sw - b0)
                        }
                    }
                }
            }
        }
        return Plane(width: w, height: h, data: out)
    }
}

/// Paints a tracked object out: each pixel of its padded box takes the temporal median of the frames around it, aligned
/// by the camera's motion, where those frames show the background; what no frame shows is filled by diffusion.
final class ObjectRemover: TemporalStage {
    struct Settings {
        var samples: [TrackSample]
        /// Fraction of the frame height added around the box.
        var padding: Float
        var window: Seconds
        var feather: Float
        var mix: Float
        /// What fills pixels no frame shows: patches from around the hole (`patch`) or a smooth membrane.
        var patchFill = true
        /// A picture of the background to take it from first, with the object's box in it (pixels) if it shows.
        var plate: CVPixelBuffer?
        var plateHole: SIMD4<Float>?
        /// Source time of a plate taken from a frame of the clip; nil for an image file.
        var plateTime: Seconds?
        /// Scene cuts from analysis, for telling whether the plate's frame is in the current shot.
        var plateCuts: [Seconds] = []
    }

    let settings: Settings
    let context: CIContext
    /// The previous frame's completed region, guiding this one so the fill holds still.
    private var previous: (index: Int, origin: SIMD2<Int>, width: Int, height: Int, rgb: [Float], has: [Bool], nnf: [Int32])?
    private var plateSmall: CVPixelBuffer?
    private var plateSignature: FrameSignature?
    /// Frames each side searched for the background.
    let reach: Int
    /// Only every `step`th frame is kept and searched.
    let step: Int
    static let samplesPerPixel = 7
    /// Cumulative content displacement of each decoded frame from the first, in pixels.
    private var path: [SIMD2<Double>] = []
    private var previousSmall: CVPixelBuffer?

    init(_ settings: Settings, fps: Double, context: CIContext) {
        self.settings = settings
        self.context = context
        reach = max(2, Int((settings.window * max(1, fps)).rounded()))
        step = max(1, reach / 12)
        if let plate = settings.plate {
            plateSmall = Registration.small(plate, context: context)
            if settings.plateTime != nil { plateSignature = FrameSignature(plate) }
        }
    }

    func needs(_ j: Int, from i: Int) -> Bool { j >= i - reach && j % step == 0 }

    func decoded(_ index: Int, _ buffer: CVPixelBuffer, previous: CVPixelBuffer?) throws {
        let small = Registration.small(buffer, context: context)
        if index == 0 || previousSmall == nil || small == nil {
            path.append(path.last ?? .zero)
        } else {
            path.append(path[index - 1] + Registration.translation(previousSmall!, small!, fullWidth: CVPixelBufferGetWidth(buffer)))
        }
        previousSmall = small
    }

    /// The padded box at source time `t` in pixels (x0, y0, x1, y1), rows from the top; nil where the track has no box.
    func hole(at t: Seconds, width w: Int, height h: Int) -> SIMD4<Float>? {
        guard let b = ObjectTrack.box(settings.samples, at: t) else { return nil }
        let pad = settings.padding * Float(h)
        return SIMD4(Float(b.x) * Float(w) - pad, Float(b.y) * Float(h) - pad, Float(b.x + b.width) * Float(w) + pad, Float(b.y + b.height) * Float(h) + pad)
    }

    func apply(_ i: Int, _ current: inout Plane, _ window: FrameWindow) throws {
        let w = current.width, h = current.height
        guard let t = window.time(i), let box = hole(at: t, width: w, height: h) else { return }
        let x0 = max(0, Int(box.x.rounded(.down))), y0 = max(0, Int(box.y.rounded(.down)))
        let x1 = min(w - 1, Int(box.z.rounded(.up))), y1 = min(h - 1, Int(box.w.rounded(.up)))
        guard x1 >= x0, y1 >= y0 else { return }
        // Decode the frames ahead first, so their camera motion is known.
        _ = try window.frame(i + reach)
        struct Candidate {
            var view: PixelView
            var offset: SIMD2<Float>
            var hole: SIMD4<Float>
        }
        var candidates: [Candidate] = []
        guard let herePB = try window.frame(i) else { return }
        let here = PixelView(herePB)
        defer { here.unlock() }
        let ring = ObjectRemover.ring(box, width: w, height: h)
        for d in 1...reach {
            for j in [i - d, i + d] where j % step == 0 {
                guard path.indices.contains(j), let tj = window.time(j), let hj = hole(at: tj, width: w, height: h), let pb = try window.frame(j), try window.sameShot(i, j) else { continue }
                let o = path[j] - path[i]
                candidates.append(Candidate(view: PixelView(pb), offset: SIMD2(Float(o.x), Float(o.y)), hole: hj))
            }
        }
        defer { candidates.forEach { $0.view.unlock() } }
        // The camera path drifts and is whole-frame; align each candidate around the hole itself.
        var refined = candidates.map(\.offset)
        refined.withUnsafeMutableBufferPointer { rb in
            let r = rb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: candidates.count) { k in
                let c = candidates[k]
                r[k] = ObjectRemover.refine(c.offset, here: here, there: c.view, ring: ring, hole: box, holeThere: c.hole)
            }
        }
        for k in candidates.indices { candidates[k].offset = refined[k] }
        let rw = x1 - x0 + 1, rh = y1 - y0 + 1
        var fill = [Float](repeating: 0, count: rw * rh * 3)
        var known = [Bool](repeating: false, count: rw * rh)
        let limit = ObjectRemover.samplesPerPixel
        fill.withUnsafeMutableBufferPointer { fb in
            known.withUnsafeMutableBufferPointer { kb in
                let f = fb.baseAddress!, k = kb.baseAddress!
                parallelRows(rh) { rows in
                    var r = [Float](repeating: 0, count: limit), g = r, b = r
                    for ry in rows {
                        for rx in 0..<rw {
                            let px = Float(x0 + rx), py = Float(y0 + ry)
                            var n = 0
                            for c in candidates {
                                let qx = px + c.offset.x, qy = py + c.offset.y
                                guard qx >= 0, qy >= 0, qx <= Float(w - 1), qy <= Float(h - 1) else { continue }
                                if qx >= c.hole.x - 1, qx <= c.hole.z + 1, qy >= c.hole.y - 1, qy <= c.hole.w + 1 { continue }
                                let v = c.view.sample(qx, qy)
                                r[n] = v.x
                                g[n] = v.y
                                b[n] = v.z
                                n += 1
                                if n == limit { break }
                            }
                            guard n > 0 else { continue }
                            let o = ry * rw + rx
                            f[o * 3] = ObjectRemover.median(&r, n)
                            f[o * 3 + 1] = ObjectRemover.median(&g, n)
                            f[o * 3 + 2] = ObjectRemover.median(&b, n)
                            k[o] = true
                        }
                    }
                }
            }
        }
        if let plate = settings.plate, try plateInShot(i, window) {
            usePlate(plate, here: herePB, ring: ring, box: box, origin: SIMD2(x0, y0), width: rw, height: rh, fill: &fill, known: &known)
        }
        if previous?.index == i - 1, try !window.sameShot(i - 1, i) { previous = nil }
        if settings.patchFill, known.contains(false) {
            complete(i, current, box: SIMD4(x0, y0, x1, y1), fill: &fill, known: &known)
        } else {
            previous = nil
        }
        ObjectRemover.diffuse(&fill, &known, rw, rh, border: { x, y in
            let cx = min(w - 1, max(0, x0 + x)), cy = min(h - 1, max(0, y0 + y))
            let o = (cy * w + cx) * 3
            return SIMD3(current.data[o], current.data[o + 1], current.data[o + 2])
        })
        let feather = max(1, settings.feather * Float(h))
        let mix = settings.mix
        current.data.withUnsafeMutableBufferPointer { cb in
            let c = cb.baseAddress!
            for ry in 0..<rh {
                for rx in 0..<rw {
                    let px = Float(x0 + rx), py = Float(y0 + ry)
                    let inside = min(px - box.x, box.z - px, py - box.y, box.w - py)
                    let a = min(1, max(0, inside / feather)) * mix
                    guard a > 0 else { continue }
                    let o = ((y0 + ry) * w + x0 + rx) * 3, s = (ry * rw + rx) * 3
                    for ch in 0..<3 { c[o + ch] += a * (fill[s + ch] - c[o + ch]) }
                }
            }
        }
    }

    /// Whether the clean plate can stand in for frame `i`: always for an image file; for a frame of the clip, only
    /// inside the plate frame's shot.
    func plateInShot(_ i: Int, _ window: FrameWindow) throws -> Bool {
        guard let at = settings.plateTime else { return true }
        guard let t = window.time(i) else { return false }
        let fd = window.decoded > 1 ? (window.times[window.decoded - 1] - window.times[0]) / Double(window.decoded - 1) : 1.0 / 30
        if let k = window.times.firstIndex(where: { abs($0 - at) <= fd / 2 + 1e-6 }) { return try window.sameShot(k, i) }
        let lo = min(at, t), hi = max(at, t)
        if settings.plateCuts.contains(where: { $0 > lo - ShotSplitter.slack && $0 <= hi + fd }) { return false }
        guard let sig = plateSignature, let pb = try window.frame(i) else { return true }
        let d = FrameSignature(pb).distance(sig)
        return !(d.histogram > 0.35 || d.blocks > 0.15)
    }

    /// Takes the box's background from the clean plate where the plate shows it: aligned to this frame around the
    /// hole and matched to its exposure there.
    func usePlate(_ plate: CVPixelBuffer, here herePB: CVPixelBuffer, ring: SIMD4<Float>, box: SIMD4<Float>, origin: SIMD2<Int>, width rw: Int, height rh: Int, fill: inout [Float], known: inout [Bool]) {
        let here = PixelView(herePB), there = PixelView(plate)
        defer { here.unlock(); there.unlock() }
        var start = SIMD2<Float>(0, 0)
        if let a = Registration.small(herePB, context: context), let b = plateSmall {
            let t = Registration.translation(a, b, fullWidth: CVPixelBufferGetWidth(plate))
            start = SIMD2(Float(t.x), Float(t.y))
        }
        let away = SIMD4<Float>(-1e6, -1e6, -1e6, -1e6)
        // The object's box at the plate's time is skipped, unless it covers where the object is now: then the plate
        // was picked as a frame without the object.
        var hole = settings.plateHole ?? away
        let ix = max(0, min(hole.z, box.z) - max(hole.x, box.x)), iy = max(0, min(hole.w, box.w) - max(hole.y, box.y))
        if ix * iy > 0.5 * (box.z - box.x) * (box.w - box.y) { hole = away }
        let offset = ObjectRemover.refine(start, here: here, there: there, ring: ring, hole: box, holeThere: hole, search: 10)
        // Exposure: the mean difference over the ring, outside both holes.
        var diff = SIMD3<Float>(repeating: 0)
        var n: Float = 0
        var y = ring.y
        while y <= ring.w {
            var x = ring.x
            while x <= ring.z {
                let inHole = x >= box.x - 1 && x <= box.z + 1 && y >= box.y - 1 && y <= box.w + 1
                let qx = x + offset.x, qy = y + offset.y
                let inPlateHole = qx >= hole.x - 1 && qx <= hole.z + 1 && qy >= hole.y - 1 && qy <= hole.w + 1
                if !inHole, !inPlateHole, qx >= 0, qy >= 0, qx <= Float(there.width - 1), qy <= Float(there.height - 1) {
                    diff += here.sample(x, y) - there.sample(qx, qy)
                    n += 1
                }
                x += 3
            }
            y += 3
        }
        let gain = n > 20 ? diff / n : .zero
        for ry in 0..<rh {
            for rx in 0..<rw {
                let qx = Float(origin.x + rx) + offset.x, qy = Float(origin.y + ry) + offset.y
                guard qx >= 0, qy >= 0, qx <= Float(there.width - 1), qy <= Float(there.height - 1) else { continue }
                if qx >= hole.x - 1, qx <= hole.z + 1, qy >= hole.y - 1, qy <= hole.w + 1 { continue }
                let v = there.sample(qx, qy) + gain
                let o = ry * rw + rx
                fill[o * 3] = v.x; fill[o * 3 + 1] = v.y; fill[o * 3 + 2] = v.z
                known[o] = true
            }
        }
    }

    /// Fills what no frame (or plate) shows by exemplar inpainting of a region around the box, guided by the
    /// previous frame's fill moved with the camera.
    private func complete(_ i: Int, _ current: Plane, box: SIMD4<Int>, fill: inout [Float], known: inout [Bool]) {
        let w = current.width, h = current.height
        let (x0, y0, x1, y1) = (box.x, box.y, box.z, box.w)
        let rw = x1 - x0 + 1, rh = y1 - y0 + 1
        let margin = min(200, max(24, max(rw, rh)))
        let cx0 = max(0, x0 - margin), cy0 = max(0, y0 - margin), cx1 = min(w - 1, x1 + margin), cy1 = min(h - 1, y1 + margin)
        let cw = cx1 - cx0 + 1, ch = cy1 - cy0 + 1
        var rgb = [Float](repeating: 0, count: cw * ch * 3)
        var hole = [Bool](repeating: false, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                let fx = cx0 + x, fy = cy0 + y, c = (y * cw + x) * 3
                if fx >= x0, fx <= x1, fy >= y0, fy <= y1 {
                    let r = (fy - y0) * rw + fx - x0
                    if known[r] {
                        for k in 0..<3 { rgb[c + k] = fill[r * 3 + k] }
                    } else {
                        hole[y * cw + x] = true
                    }
                } else {
                    let o = (fy * w + fx) * 3
                    for k in 0..<3 { rgb[c + k] = current.data[o + k] }
                }
            }
        }
        let origin = SIMD2(cx0, cy0)
        var guide: Inpainter.Guide?
        if let prev = previous, prev.index == i - 1, path.indices.contains(i), path.indices.contains(i - 1) {
            // Content at p in this frame is at p + shift in the previous one.
            let shift = path[i - 1] - path[i]
            let sx = Float(shift.x), sy = Float(shift.y)
            let ix = Int(shift.x.rounded()), iy = Int(shift.y.rounded())
            var g = Inpainter.Guide(rgb: [Float](repeating: 0, count: cw * ch * 3), has: [Bool](repeating: false, count: cw * ch), nnf: [Int32](repeating: -1, count: cw * ch))
            for y in 0..<ch {
                for x in 0..<cw where hole[y * cw + x] {
                    let px = Float(origin.x + x) + sx - Float(prev.origin.x), py = Float(origin.y + y) + sy - Float(prev.origin.y)
                    let ax = Int(px.rounded(.down)), ay = Int(py.rounded(.down))
                    guard ax >= 0, ay >= 0, ax + 1 < prev.width, ay + 1 < prev.height else { continue }
                    let corners = [ay * prev.width + ax, ay * prev.width + ax + 1, (ay + 1) * prev.width + ax, (ay + 1) * prev.width + ax + 1]
                    guard corners.allSatisfy({ prev.has[$0] }) else { continue }
                    let fx = px - Float(ax), fy = py - Float(ay)
                    let weights = [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]
                    let t = y * cw + x
                    for k in 0..<3 { g.rgb[t * 3 + k] = zip(corners, weights).reduce(0) { $0 + prev.rgb[$1.0 * 3 + k] * $1.1 } }
                    g.has[t] = true
                }
            }
            for y in 0..<ch {
                for x in 0..<cw {
                    let qx = origin.x + x + ix - prev.origin.x, qy = origin.y + y + iy - prev.origin.y
                    guard qx >= 0, qy >= 0, qx < prev.width, qy < prev.height else { continue }
                    let s = prev.nnf[qy * prev.width + qx]
                    guard s >= 0 else { continue }
                    let sx = Int(s) % prev.width + prev.origin.x - ix - origin.x, sy = Int(s) / prev.width + prev.origin.y - iy - origin.y
                    if sx >= 0, sy >= 0, sx < cw, sy < ch { g.nnf[y * cw + x] = Int32(sy * cw + sx) }
                }
            }
            guide = g
        }
        let result = Inpainter.fill(&rgb, width: cw, height: ch, hole: hole, guide: guide)
        for y in y0...y1 {
            for x in x0...x1 {
                let r = (y - y0) * rw + x - x0
                guard !known[r] else { continue }
                let c = ((y - cy0) * cw + x - cx0) * 3
                for k in 0..<3 { fill[r * 3 + k] = rgb[c + k] }
                known[r] = true
            }
        }
        previous = (i, origin, cw, ch, rgb, hole, result.nnf)
    }

    /// The band around a hole whose background registers the frames locally, (x0, y0, x1, y1) in pixels.
    static func ring(_ hole: SIMD4<Float>, width w: Int, height h: Int) -> SIMD4<Float> {
        let m = max(16, 0.6 * max(hole.z - hole.x, hole.w - hole.y))
        return SIMD4(max(1, hole.x - m), max(1, hole.y - m), min(Float(w - 2), hole.z + m), min(Float(h - 2), hole.w + m))
    }

    /// Refines the offset that maps this frame's pixels onto another frame's (`there`) by Gauss-Newton translation
    /// alignment of the band around the hole, skipping both frames' holes; keeps `start` when that doesn't improve.
    /// With `search`, whole-pixel offsets that far around `start` are tried first and the best one is refined.
    static func refine(_ start: SIMD2<Float>, here: PixelView, there: PixelView, ring: SIMD4<Float>, hole: SIMD4<Float>, holeThere: SIMD4<Float>, search: Int = 0) -> SIMD2<Float> {
        let area = max(1, (ring.z - ring.x) * (ring.w - ring.y))
        let stride = max(1, Int((area / 3000).squareRoot().rounded()))
        var points: [(Float, Float, Float)] = []
        var y = Int(ring.y)
        while Float(y) <= ring.w {
            var x = Int(ring.x)
            while Float(x) <= ring.z {
                let px = Float(x), py = Float(y)
                if !(px >= hole.x - 1 && px <= hole.z + 1 && py >= hole.y - 1 && py <= hole.w + 1) { points.append((px, py, here.gray(px, py))) }
                x += stride
            }
            y += stride
        }
        guard points.count > 50 else { return start }
        // A uniform brightness difference between the frames is solved for along with the motion.
        func cost(_ o: SIMD2<Float>) -> (Float, Int) {
            var s: Float = 0, s2: Float = 0, n = 0
            for (px, py, v) in points {
                let qx = px + o.x, qy = py + o.y
                if qx >= holeThere.x - 1 && qx <= holeThere.z + 1 && qy >= holeThere.y - 1 && qy <= holeThere.w + 1 { continue }
                if qx < 1 || qy < 1 || qx > Float(there.width - 2) || qy > Float(there.height - 2) { continue }
                let r = there.gray(qx, qy) - v
                s += r
                s2 += r * r
                n += 1
            }
            guard n > 0 else { return (.infinity, 0) }
            let mean = s / Float(n)
            return (s2 / Float(n) - mean * mean, n)
        }
        var o = start
        var (best, _) = cost(o)
        if search > 0 {
            for dy in -search...search {
                for dx in -search...search where dx != 0 || dy != 0 {
                    let candidate = start + SIMD2(Float(dx), Float(dy))
                    let (c, n) = cost(candidate)
                    if n > points.count / 2, c < best { best = c; o = candidate }
                }
            }
        }
        for spread: Float in [2, 2, 1, 1, 1, 1] {
            var h = simd_float3x3(), g = SIMD3<Float>(repeating: 0)
            var count = 0
            for (px, py, v) in points {
                let qx = px + o.x, qy = py + o.y
                if qx >= holeThere.x - 1 && qx <= holeThere.z + 1 && qy >= holeThere.y - 1 && qy <= holeThere.w + 1 { continue }
                if qx < spread || qy < spread || qx > Float(there.width - 1) - spread || qy > Float(there.height - 1) - spread { continue }
                let gx = (there.gray(qx + spread, qy) - there.gray(qx - spread, qy)) / (2 * spread)
                let gy = (there.gray(qx, qy + spread) - there.gray(qx, qy - spread)) / (2 * spread)
                let r = there.gray(qx, qy) - v
                let j = SIMD3(gx, gy, 1)
                h += simd_float3x3(columns: (j * gx, j * gy, j))
                g += j * r
                count += 1
            }
            guard count > 10, abs(h.determinant) > 1e-9 else { break }
            let solved = -(h.inverse * g)
            let step = SIMD2(solved.x, solved.y)
            guard step.x.isFinite, step.y.isFinite, abs(step.x) < 4, abs(step.y) < 4 else { break }
            let next = o + step
            let (c, n) = cost(next)
            guard n > points.count / 4, c < best else { if spread == 1 { break } else { continue } }
            o = next
            best = c
            if abs(step.x) + abs(step.y) < 0.01 { break }
        }
        return o
    }

    /// Median of the first `n` values (reordered).
    @inline(__always) static func median(_ v: inout [Float], _ n: Int) -> Float {
        for a in 1..<max(1, n) {
            let x = v[a]
            var b = a - 1
            while b >= 0 && v[b] > x {
                v[b + 1] = v[b]
                b -= 1
            }
            v[b + 1] = x
        }
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }

    /// Fills unknown pixels of a region from its known pixels and the picture around it (`border`, by region
    /// coordinates, for pixels just outside): peels inward from known neighbours, then relaxes toward a smooth membrane.
    static func diffuse(_ fill: inout [Float], _ known: inout [Bool], _ w: Int, _ h: Int, border: (Int, Int) -> SIMD3<Float>) {
        var unknown = known.indices.filter { !known[$0] }
        guard !unknown.isEmpty else { return }
        let holes = unknown
        func value(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            if x < 0 || y < 0 || x >= w || y >= h { return border(x, y) }
            let o = y * w + x
            return known[o] ? SIMD3(fill[o * 3], fill[o * 3 + 1], fill[o * 3 + 2]) : nil
        }
        while !unknown.isEmpty {
            var next: [Int] = []
            var set: [(Int, SIMD3<Float>)] = []
            for o in unknown {
                let x = o % w, y = o / w
                var s = SIMD3<Float>(repeating: 0)
                var n: Float = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                    if let v = value(x + dx, y + dy) { s += v; n += 1 }
                }
                if n > 0 { set.append((o, s / n)) } else { next.append(o) }
            }
            if set.isEmpty { break }
            for (o, v) in set {
                fill[o * 3] = v.x
                fill[o * 3 + 1] = v.y
                fill[o * 3 + 2] = v.z
                known[o] = true
            }
            unknown = next
        }
        // Over-relaxed Gauss-Seidel toward the harmonic fill; wide holes need sweeps in proportion to their size.
        let sweeps = min(400, max(40, max(w, h)))
        let omega: Float = 1.85
        fill.withUnsafeMutableBufferPointer { fb in
            let f = fb.baseAddress!
            for _ in 0..<sweeps {
                for o in holes {
                    let x = o % w, y = o / w
                    var s = SIMD3<Float>(repeating: 0)
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { s += border(nx, ny) } else {
                            let q = (ny * w + nx) * 3
                            s += SIMD3(f[q], f[q + 1], f[q + 2])
                        }
                    }
                    let q = o * 3
                    f[q] += omega * (s.x / 4 - f[q])
                    f[q + 1] += omega * (s.y / 4 - f[q + 1])
                    f[q + 2] += omega * (s.z / 4 - f[q + 2])
                }
            }
        }
    }
}
