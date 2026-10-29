import AVFoundation
import CoreImage
import CutlineCore
import Foundation
import Metal

/// Everything the compositor needs to draw any frame of one timeline version.
public final class RenderScene: @unchecked Sendable {
    public let project: Project
    public let captions: [CaptionSegment]
    /// Composition track of each clip's picture, by clip id.
    let trackIDs: [String: CMPersistentTrackID]
    let orientations: [String: CGImagePropertyOrientation]
    let images: [String: CIImage]
    /// Video transition windows by track id.
    let windows: [String: [TransitionWindow]]
    private let cache = NSCache<NSString, CIImage>()

    init(project: Project, captions: [CaptionSegment], trackIDs: [String: CMPersistentTrackID], orientations: [String: CGImagePropertyOrientation], images: [String: CIImage]) {
        self.project = project
        self.captions = captions
        self.trackIDs = trackIDs
        self.orientations = orientations
        self.images = images
        windows = Dictionary(grouping: project.transitionWindows.filter(\.transition.hasVideo), by: \.trackId)
        cache.countLimit = 400
    }

    var canvasRect: CGRect { CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height) }

    /// Draws the frame at a timeline time. `source` returns the decoded frame of a clip.
    func render(at t: Seconds, source: (String) -> CVPixelBuffer?) -> CIImage {
        let canvas = canvasRect
        let unit = canvas.height
        var out = CIImage(color: CIColor(cgColor: project.canvas.background.cgColor)).cropped(to: canvas)
        for track in project.tracks where track.kind == .video && !track.hidden {
            if let w = windows[track.id]?.first(where: { $0.contains(t) }) {
                let a = w.transition.from.flatMap { project.clip($0) }
                let b = w.transition.to.flatMap { project.clip($0) }
                let p = w.progress(at: t)
                var combined = TransitionRenderer.render(w.transition, a: a.flatMap { layer($0, at: t, source: source) }, b: b.flatMap { layer($0, at: t, source: source) }, p: p, canvas: canvas, frame: Int((t * project.canvas.fps).rounded()))
                if !track.effects.isEmpty {
                    combined = EffectRenderer.apply(track.effects, to: combined, context: EffectRenderer.Context(unit: unit, time: t, opaque: false)) { _, _ in nil }
                }
                let mode = (p < 0.5 ? a ?? b : b ?? a)?.blend ?? .normal
                out = EffectRenderer.blend(combined, over: out, mode: mode).cropped(to: canvas)
                continue
            }
            guard let clip = track.clip(at: t) else { continue }
            if clip.kind == .adjustment {
                let local = t - clip.start
                let opacity = clip.resolvedTransform(at: local).opacity
                guard opacity > 0.001 else { continue }
                let ctx = EffectRenderer.Context(unit: unit, time: t, opaque: true)
                var adjusted = EffectRenderer.apply(clip.effects, to: out, context: ctx) { e, name in clip.anim["fx.\(e.id).\(name)"]?.value(at: local) }
                adjusted = EffectRenderer.apply(track.effects, to: adjusted, context: ctx) { _, _ in nil }
                if opacity < 0.999 { adjusted = alpha(adjusted, opacity) }
                out = adjusted.composited(over: out).cropped(to: canvas)
                continue
            }
            guard var placed = layer(clip, at: t, source: source) else { continue }
            if !track.effects.isEmpty {
                placed = EffectRenderer.apply(track.effects, to: placed, context: EffectRenderer.Context(unit: unit, time: t, opaque: false)) { _, _ in nil }
            }
            out = EffectRenderer.blend(placed, over: out, mode: clip.blend).cropped(to: canvas)
        }
        if project.captions.enabled, let caption = captionImage(at: t) {
            out = caption.composited(over: out)
        }
        return out.cropped(to: canvas)
    }

    /// A clip's picture at timeline time `t` with its effects and transform applied, in canvas space.
    /// `t` may fall outside the clip while a transition borrows its handles.
    func layer(_ clip: Clip, at t: Seconds, source: (String) -> CVPixelBuffer?) -> CIImage? {
        let canvas = canvasRect
        let unit = canvas.height
        let local = t - clip.start
        var xf = clip.resolvedTransform(at: local)
        guard xf.opacity > 0.001 else { return nil }
        let param: (Effect, String) -> ParamValue? = { e, name in clip.anim["fx.\(e.id).\(name)"]?.value(at: local) }
        var layer: CIImage?
        var opaque = false
        var center = CGPoint(x: canvas.midX + xf.x * canvas.width, y: canvas.midY - xf.y * canvas.height)
        switch clip.kind {
        case .media:
            guard let mid = clip.mediaId else { return nil }
            var img: CIImage?
            if let still = images[mid] {
                img = still
            } else if let pb = source(clip.id) {
                img = CIImage(cvPixelBuffer: pb).oriented(orientations[clip.id] ?? orientations[mid] ?? .up)
                opaque = true
            }
            guard var img else { return nil }
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            let c = xf.crop
            if !c.isEmpty {
                let e = img.extent
                img = img.cropped(to: CGRect(x: e.width * c.left, y: e.height * c.bottom, width: e.width * max(0.01, 1 - c.left - c.right), height: e.height * max(0.01, 1 - c.top - c.bottom)))
                img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            }
            let e = img.extent
            guard e.width > 0, e.height > 0 else { return nil }
            // Bring the picture to canvas pixel scale first so effect sizes are resolution independent.
            switch xf.fit {
            case .fit:
                let s = min(canvas.width / e.width, canvas.height / e.height)
                img = img.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: s < 1)
            case .fill:
                let s = max(canvas.width / e.width, canvas.height / e.height)
                img = img.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: s < 1)
            case .stretch:
                img = img.transformed(by: CGAffineTransform(scaleX: canvas.width / e.width, y: canvas.height / e.height))
            }
            layer = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        case .solid:
            let color = clip.value("color", at: local)?.color ?? clip.color ?? .black
            layer = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: canvas)
            opaque = true
        case .text:
            guard let spec = clip.resolvedText(at: local) else { return nil }
            let anim = TextAnimator.state(spec: spec, local: min(max(local, 0), clip.duration), duration: clip.duration)
            xf.opacity *= anim.opacity
            xf.scale *= anim.scale
            center = CGPoint(x: canvas.width * (spec.x + xf.x), y: canvas.height * (1 - spec.y - xf.y - anim.yOffset))
            layer = textImage(spec, reveal: anim.reveal)
        case .adjustment:
            return nil
        }
        guard var layer else { return nil }
        // Effects run before the clip is scaled, so lengths are divided by the scale to stay in final frame units.
        let ctx = EffectRenderer.Context(unit: unit / max(CGFloat(xf.scale), 0.01), time: t, opaque: opaque)
        if !clip.effects.isEmpty {
            layer = EffectRenderer.apply(clip.effects, to: layer, context: ctx, param: param)
        }
        return place(layer, center: center, scale: xf.scale, rotation: xf.rotation, opacity: xf.opacity)
    }

    func alpha(_ img: CIImage, _ a: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    func place(_ img: CIImage, center: CGPoint, scale: Double, rotation: Double, opacity: Double) -> CIImage {
        let e = img.extent
        var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        if rotation != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: -rotation * .pi / 180)) }
        t = t.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        var out = img.transformed(by: t, highQualityDownsample: scale < 1)
        if opacity < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        }
        return out
    }

    func textImage(_ spec: TextSpec, reveal: Int?) -> CIImage? {
        let key = "t\(spec.hashValue):\(reveal ?? -1)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let h = Double(min(project.canvas.width, project.canvas.height))
        var runs: [TextRenderer.Run]
        if let reveal {
            let chars = Array(spec.text)
            let n = min(reveal, chars.count)
            runs = [.init(text: String(chars[..<n]), color: spec.color), .init(text: String(chars[n...]), color: spec.color.with(alpha: 0))]
        } else {
            runs = [.init(text: spec.text, color: spec.color)]
        }
        let font = TextRenderer.font(spec.font, size: spec.size * h, weight: spec.weight)
        guard let cg = TextRenderer.render(runs: runs, font: font, align: spec.align, maxWidth: spec.maxWidth * Double(project.canvas.width), background: spec.background, stroke: spec.stroke, strokeWidth: spec.strokeWidth, shadow: spec.shadow, letterSpacing: spec.letterSpacing) else { return nil }
        let img = CIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }

    func captionImage(at t: Seconds) -> CIImage? {
        guard let seg = captions.first(where: { t >= $0.start && t < $0.end }) else { return nil }
        let style = project.captions.style
        let words = seg.words
        let active = words.lastIndex { $0.start <= t + 0.02 } ?? -1
        let mode = style.animation
        let key = "c\(seg.id):\(mode == .none || mode == .pop ? -1 : active)" as NSString
        var img = cache.object(forKey: key)
        if img == nil {
            var runs: [TextRenderer.Run] = []
            var index = 0
            for (li, line) in seg.lines.enumerated() {
                for (wi, w) in line.enumerated() {
                    var color = style.color
                    if mode == .karaoke && index == active { color = style.highlightColor }
                    if mode == .reveal && index > active { color = style.color.with(alpha: 0) }
                    runs.append(.init(text: w.text + (wi < line.count - 1 ? " " : ""), color: color))
                    index += 1
                }
                if li < seg.lines.count - 1 { runs.append(.init(text: "\n", color: style.color)) }
            }
            let h = Double(min(project.canvas.width, project.canvas.height))
            let font = TextRenderer.font(style.font, size: style.size * h, weight: style.weight)
            guard let cg = TextRenderer.render(runs: runs, font: font, align: .center, maxWidth: style.maxWidth * Double(project.canvas.width), background: style.background, stroke: style.stroke, strokeWidth: style.strokeWidth, shadow: style.shadow, letterSpacing: 0) else { return nil }
            img = CIImage(cgImage: cg)
            cache.setObject(img!, forKey: key)
        }
        let canvas = canvasRect
        var scale = 1.0
        let age = t - seg.start
        if mode == .pop || mode == .karaoke, age < 0.16 {
            scale = 0.82 + 0.18 * Easing.easeOut.apply(age / 0.16)
        }
        let fadeOut = min(1, max(0, (seg.end - t) / 0.08))
        return place(img!, center: CGPoint(x: canvas.midX, y: canvas.height * (1 - style.y)), scale: scale, rotation: 0, opacity: fadeOut)
    }
}

enum TextAnimator {
    struct State {
        var opacity = 1.0
        var scale = 1.0
        var yOffset = 0.0
        var reveal: Int?
    }

    static func state(spec: TextSpec, local: Seconds, duration: Seconds) -> State {
        var s = State()
        let inDur = min(0.4, duration / 3)
        let outDur = min(0.3, duration / 3)
        let pIn = inDur > 0 ? min(1, local / inDur) : 1
        let pOut = outDur > 0 ? min(1, max(0, (duration - local) / outDur)) : 1
        switch spec.animationIn {
        case .none: break
        case .fade: s.opacity *= Easing.easeOut.apply(pIn)
        case .pop:
            s.opacity *= min(1, pIn * 2)
            s.scale *= backOut(pIn) * 0.5 + 0.5
        case .slideUp:
            s.opacity *= Easing.easeOut.apply(pIn)
            s.yOffset -= 0.04 * (1 - Easing.easeOut.apply(pIn))
        case .typewriter:
            let total = min(1.6, duration * 0.45)
            let count = spec.text.count
            s.reveal = total > 0 ? Int((Double(count) * min(1, local / total)).rounded(.up)) : count
        }
        switch spec.animationOut {
        case .none, .typewriter: if spec.animationOut == .typewriter { s.opacity *= pOut }
        case .fade: s.opacity *= pOut
        case .pop:
            s.opacity *= pOut
            s.scale *= 0.85 + 0.15 * pOut
        case .slideUp:
            s.opacity *= pOut
            s.yOffset += 0.03 * (1 - pOut)
        }
        return s
    }

    static func backOut(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

final class CutlineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let scene: RenderScene

    init(timeRange: CMTimeRange, scene: RenderScene) {
        self.timeRange = timeRange
        self.scene = scene
        requiredSourceTrackIDs = Set(scene.trackIDs.values).sorted().map { NSNumber(value: $0) }
    }
}

public final class CutlineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let device = MTLCreateSystemDefaultDevice()
    static let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .outputColorSpace: CutlineCompositor.colorSpace]
        if let device = CutlineCompositor.device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
    private let queue = DispatchQueue(label: "cutline.compositor", qos: .userInteractive)
    private var renderContext: AVVideoCompositionRenderContext?

    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? CutlineInstruction,
                      let out = request.renderContext.newPixelBuffer()
                else {
                    request.finish(with: NSError(domain: "Cutline", code: 1))
                    return
                }
                let scene = instruction.scene
                let image = scene.render(at: request.compositionTime.seconds) { clipId in
                    guard let id = scene.trackIDs[clipId] else { return nil }
                    return request.sourceFrame(byTrackID: id)
                }
                let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
                let canvas = scene.canvasRect
                let fitted = canvas.width == CGFloat(w) && canvas.height == CGFloat(h)
                    ? image
                    : image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / canvas.width, y: CGFloat(h) / canvas.height))
                context.render(fitted, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: Self.colorSpace)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {}
}
