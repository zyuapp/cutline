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
    /// Color space color effects grade in: sRGB for SDR canvases, the canvas's own encoding for HDR.
    let gradeSpace: CGColorSpace
    /// Video transition windows by track id.
    let windows: [String: [TransitionWindow]]
    private let cache = NSCache<NSString, CIImage>()

    init(project: Project, captions: [CaptionSegment], trackIDs: [String: CMPersistentTrackID], orientations: [String: CGImagePropertyOrientation], images: [String: CIImage]) {
        self.project = project
        self.captions = captions
        self.trackIDs = trackIDs
        self.orientations = orientations
        self.images = images
        gradeSpace = project.canvas.colorSpace.isHDR ? ColorManagement.colorSpace(project.canvas.colorSpace) : ColorCubes.space
        windows = Dictionary(grouping: project.transitionWindows.filter(\.transition.hasVideo), by: \.trackId)
        cache.countLimit = 400
    }

    var canvasRect: CGRect { CGRect(x: 0, y: 0, width: project.canvas.width, height: project.canvas.height) }

    /// Shows where one clip effect acts instead of the picture (see `EffectRenderer.matte`).
    public struct MatteView: Sendable {
        public var clip: String
        public var effect: String

        public init(clip: String, effect: String) {
            self.clip = clip
            self.effect = effect
        }
    }

    /// When set, every frame is the matte of this clip effect in white on black, placed like the clip.
    public var matteView: MatteView?

    /// Draws the frame at a timeline time. `source` returns the decoded frame of a clip.
    func render(at t: Seconds, background: Bool = true, source: (String) -> CVPixelBuffer?) -> CIImage {
        if let view = matteView { return matteFrame(view, at: t, source: source) }
        return composite(at: t, background: background, source: source)
    }

    func matteFrame(_ view: MatteView, at t: Seconds, source: (String) -> CVPixelBuffer?) -> CIImage {
        let canvas = canvasRect
        let black = CIImage(color: .black).cropped(to: canvas)
        guard let ti = project.tracks.firstIndex(where: { $0.kind == .video && $0.clips.contains { $0.id == view.clip } }),
              let clip = project.tracks[ti].clip(at: t), clip.id == view.clip else { return black }
        if clip.kind == .adjustment {
            let local = t - clip.start
            let below = composite(at: t, background: true, tracks: ti, source: source)
            let ctx = EffectRenderer.Context(unit: canvas.height, time: t, opaque: true, gradeSpace: gradeSpace)
            let m = EffectRenderer.matte(clip.effects, id: view.effect, to: below, context: ctx) { e, name in clip.anim["fx.\(e.id).\(name)"]?.value(at: local) }
            return (m ?? black).cropped(to: canvas)
        }
        return (layer(clip, at: t, source: source) ?? black).composited(over: black).cropped(to: canvas)
    }

    /// The frame from the first `tracks` video tracks (all by default).
    func composite(at t: Seconds, background: Bool = true, tracks limit: Int = .max, source: (String) -> CVPixelBuffer?) -> CIImage {
        let canvas = canvasRect
        let unit = canvas.height
        var out = CIImage(color: background ? CIColor(cgColor: project.canvas.background.cgColor) : .clear).cropped(to: canvas)
        // Where pictures lie, so adjustment layers leave a black background (letterbox bars) black.
        let bg = project.canvas.background
        var cover = background && max(bg.r, bg.g, bg.b) > 0.02 ? out : CIImage(color: .clear).cropped(to: canvas)
        for (ti, track) in project.tracks.enumerated() where ti < limit && track.kind == .video && !track.hidden {
            if let w = windows[track.id]?.first(where: { $0.contains(t) }) {
                let a = w.transition.from.flatMap { project.clip($0) }
                let b = w.transition.to.flatMap { project.clip($0) }
                let p = w.progress(at: t)
                var combined = TransitionRenderer.render(w.transition, a: a.flatMap { layer($0, at: t, source: source) }, b: b.flatMap { layer($0, at: t, source: source) }, p: p, canvas: canvas, frame: Int((t * project.canvas.fps).rounded()))
                if !track.effects.isEmpty {
                    combined = EffectRenderer.apply(track.effects, to: combined, context: EffectRenderer.Context(unit: unit, time: t, opaque: false, gradeSpace: gradeSpace)) { _, _ in nil }
                }
                let mode = (p < 0.5 ? a ?? b : b ?? a)?.blend ?? .normal
                out = EffectRenderer.blend(combined, over: out, mode: mode).cropped(to: canvas)
                cover = combined.composited(over: cover)
                continue
            }
            guard let clip = track.clip(at: t) else { continue }
            if clip.kind == .adjustment {
                let local = t - clip.start
                let opacity = clip.resolvedTransform(at: local).opacity
                guard opacity > 0.001 else { continue }
                let ctx = EffectRenderer.Context(unit: unit, time: t, opaque: true, gradeSpace: gradeSpace)
                var adjusted = EffectRenderer.apply(clip.effects, to: out, context: ctx) { e, name in clip.anim["fx.\(e.id).\(name)"]?.value(at: local) }
                adjusted = EffectRenderer.apply(track.effects, to: adjusted, context: ctx) { _, _ in nil }
                adjusted = EffectRenderer.confine(adjusted, to: cover)
                if opacity < 0.999 { adjusted = alpha(adjusted, opacity) }
                out = adjusted.composited(over: out).cropped(to: canvas)
                continue
            }
            guard var placed = blurredLayer(clip, at: t, source: source) else { continue }
            if let fx = clip.effects.first(where: { $0.type == "mask.matte" && $0.enabled }) {
                placed = matte(placed, fx, at: t, source: source)
            }
            if !track.effects.isEmpty {
                placed = EffectRenderer.apply(track.effects, to: placed, context: EffectRenderer.Context(unit: unit, time: t, opaque: false, gradeSpace: gradeSpace)) { _, _ in nil }
            }
            out = EffectRenderer.blend(placed, over: out, mode: clip.blend).cropped(to: canvas)
            cover = placed.composited(over: cover)
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
                let orientation = orientations[clip.id] ?? orientations[mid] ?? .up
                let media = project.mediaAsset(mid)
                // Proxies are scaled, so their fields are already mixed.
                let fields = media.flatMap { $0.deinterlaces && CVPixelBufferGetHeight(pb) == $0.height ? $0.fieldOrder : nil }
                if let media, let log = media.log {
                    img = ColorManagement.applyInput(Deinterlace.apply(ColorManagement.rawImage(pb), order: fields), log: log, target: project.canvas.colorSpace, tone: clip.inputTone ?? .aces, exposure: Float(clip.inputExposure ?? 0), recordedIn: media.signalRange ?? .video).oriented(orientation)
                } else {
                    img = Deinterlace.apply(CIImage(cvPixelBuffer: pb), order: fields).oriented(orientation)
                }
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
            case .fit, .fill:
                // Whole-pixel sizes keep the picture's edges hard, with no half-covered rows next to letterbox bars.
                let s = xf.fit == .fit ? min(canvas.width / e.width, canvas.height / e.height) : max(canvas.width / e.width, canvas.height / e.height)
                let sx = max(1, (e.width * s).rounded()) / e.width, sy = max(1, (e.height * s).rounded()) / e.height
                img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy), highQualityDownsample: s < 1)
            case .stretch:
                img = img.transformed(by: CGAffineTransform(scaleX: canvas.width / e.width, y: canvas.height / e.height))
            }
            layer = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            if opaque {
                // Decoded frames count as opaque everywhere, so color kernels can leave unpremultiplied color
                // outside the picture (graded or smeared letterbox bars); an explicit transparent surround prevents that.
                layer = layer!.composited(over: CIImage(color: .clear).cropped(to: layer!.extent))
            }
            if let fx = clip.effects.first(where: { $0.type == "distort.stabilize" && $0.enabled }), let m = project.mediaAsset(mid), let path = stabilization(clip, m, smoothing: fx.params["smoothing"]?.number ?? 1) {
                let strength = fx.params["strength"]?.number ?? 1
                let extra = fx.params["zoom"]?.number ?? 0
                let zoom = extra > 0 ? 1 + extra : Stabilizer.requiredZoom(path, strength: strength)
                let c = path.correction(at: clip.sourceTime(atTimeline: t), strength: strength)
                let e = layer!.extent
                let move = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                    .concatenating(CGAffineTransform(rotationAngle: -c.angle * .pi / 180))
                    .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                    .concatenating(CGAffineTransform(translationX: e.midX + c.dx * e.width * zoom, y: e.midY - c.dy * e.height * zoom))
                layer = layer!.clampedToExtent().transformed(by: move).cropped(to: e)
            }
        case .solid:
            let color = clip.value("color", at: local)?.color ?? clip.color ?? .black
            layer = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: canvas)
            opaque = true
        case .text:
            guard let spec = clip.resolvedText(at: local) else { return nil }
            let anim = TextPresetAnimator.state(spec: spec, local: min(max(local, 0), clip.duration), duration: clip.duration)
            xf.opacity *= anim.opacity
            xf.scale *= anim.scale
            center = CGPoint(x: canvas.width * (spec.x + xf.x), y: canvas.height * (1 - spec.y - xf.y - anim.yOffset))
            if let animator = spec.animator {
                layer = animatedText(spec, animator, local: local, duration: clip.duration)
            } else {
                layer = textImage(spec, reveal: anim.reveal)
            }
        case .adjustment:
            return nil
        case .generator:
            guard let gen = clip.effects.first(where: { GeneratorCatalog.type($0.type) != nil }) else { return nil }
            let value: (String) -> ParamValue = { name in
                clip.anim["fx.\(gen.id).\(name)"]?.value(at: local) ?? gen.params[name] ?? GeneratorCatalog.type(gen.type)?.spec(name)?.defaultValue ?? .number(0)
            }
            guard let cg = GeneratorRenderer.render(type: gen.type, value: value, canvas: canvas.size) else { return nil }
            layer = CIImage(cgImage: cg)
        case .sequence:
            guard let child = child(for: clip) else { return nil }
            layer = child.render(at: clip.sourceIn + local, background: false) { inner in source("\(clip.id)/\(inner)") }
            center = CGPoint(x: canvas.midX + xf.x * canvas.width, y: canvas.midY - xf.y * canvas.height)
        }
        guard var layer else { return nil }
        // Effects run before the clip is scaled, so lengths are divided by the scale to stay in final frame units.
        var ctx = EffectRenderer.Context(unit: unit / max(CGFloat(xf.scale), 0.01), time: t, opaque: opaque, gradeSpace: gradeSpace)
        if clip.kind == .media, let mid = clip.mediaId { ctx.source = MaskCache.Key(mediaId: mid, time: images[mid] != nil ? 0 : clip.sourceTime(atTimeline: t)) }
        if let view = matteView, view.clip == clip.id {
            guard let m = EffectRenderer.matte(clip.effects, id: view.effect, to: layer, context: ctx, param: param) else { return nil }
            layer = m
            xf.opacity = 1
        } else if !clip.effects.isEmpty {
            layer = EffectRenderer.apply(clip.effects, to: layer, context: ctx, param: param)
        }
        return place(layer, center: center, xf: xf)
    }

    private var paths: [String: StabilizationPath?] = [:]

    /// The smoothed camera path for a stabilized clip, when its motion has been analyzed.
    func stabilization(_ clip: Clip, _ media: MediaAsset, smoothing: Seconds) -> StabilizationPath? {
        let range = Stabilizer.window(clip, media: media)
        let key = "\(media.path)|\(range.start)|\(range.end)|\(smoothing)"
        return childLock.withLock {
            if let hit = paths[key] { return hit }
            let p = Stabilizer.cached(media: media.url, range: range).map { Stabilizer.path($0, smoothing: smoothing) }
            paths[key] = p
            return p
        }
    }

    private var children: [String: RenderScene] = [:]
    private let childLock = NSLock()

    /// The scene inside a sequence clip, sharing this scene's frames and images.
    func child(for clip: Clip) -> RenderScene? {
        guard let seq = clip.mediaId.flatMap({ project.sequence($0) }) else { return nil }
        return childLock.withLock {
            if let c = children[clip.id] { return c }
            let prefix = clip.id + "/"
            var inner = orientations
            for (k, v) in orientations where k.hasPrefix(prefix) { inner[String(k.dropFirst(prefix.count))] = v }
            let c = RenderScene(project: project.inside(seq), captions: [], trackIDs: [:], orientations: inner, images: images)
            children[clip.id] = c
            return c
        }
    }

    /// Text whose words, letters or lines animate one by one.
    func animatedText(_ spec: TextSpec, _ animator: CutlineCore.TextAnimator, local: Seconds, duration: Seconds) -> CIImage? {
        let w = Double(project.canvas.width), h = Double(project.canvas.height)
        guard let layout = AnimatedText.layout(spec, canvasHeight: h, canvasWidth: w, unit: animator.unit) else { return nil }
        let states = layout.units.indices.map { i in
            let spoken = spec.unitTimes.flatMap { $0.indices.contains(i) ? $0[i] : nil }
            return CutlineCore.TextAnimator.state(animator, unitIndex: i, unitStart: animator.start(ofUnit: i, spoken: spoken), local: local, clipDuration: duration)
        }
        return AnimatedText.render(layout, states: states, spec: spec).map { CIImage(cgImage: $0) }
    }

    /// Keeps a layer only where another track's picture is, by its alpha or brightness.
    func matte(_ picture: CIImage, _ fx: Effect, at t: Seconds, source: (String) -> CVPixelBuffer?) -> CIImage {
        guard let tid = fx.params["track"]?.string, let track = project.tracks.first(where: { $0.id == tid }),
              let c = track.clip(at: t), c.kind != .adjustment, var m = layer(c, at: t, source: source) else {
            return (fx.params["invert"]?.bool ?? false) ? picture : CIImage.empty()
        }
        m = m.cropped(to: canvasRect)
        if fx.params["mode"]?.string == "luma" {
            m = m.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        } else {
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        m = m.composited(over: CIImage(color: .black).cropped(to: canvasRect))
        if fx.params["invert"]?.bool ?? false { m = m.applyingFilter("CIColorInvert") }
        return picture.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
    }

    func alpha(_ img: CIImage, _ a: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    /// Places a clip's picture: the anchor point pivots scale, rotation and 3D tilt, and lands at `center`
    /// offset by its distance from the picture's center (so the default anchor keeps the picture centered).
    func place(_ img: CIImage, center: CGPoint, xf: Transform) -> CIImage {
        guard xf.is3D || xf.anchorX != 0.5 || xf.anchorY != 0.5 else {
            return place(img, center: center, scale: xf.scale, rotation: xf.rotation, opacity: xf.opacity)
        }
        let e = img.extent
        let a = CGPoint(x: e.minX + xf.anchorX * e.width, y: e.maxY - xf.anchorY * e.height)
        let shift = CGPoint(x: center.x + (a.x - e.midX), y: center.y + (a.y - e.midY))
        let f = max(0.3, xf.perspective) * canvasRect.height
        let rx = xf.rotateX * .pi / 180, ry = xf.rotateY * .pi / 180, rz = -xf.rotation * .pi / 180
        func project(_ p: CGPoint) -> CGPoint {
            var x = (p.x - a.x) * xf.scale, y = (p.y - a.y) * xf.scale, z = 0.0
            (y, z) = (y * cos(rx), y * sin(rx))
            (x, z) = (x * cos(ry), z + x * sin(ry))
            (x, y) = (x * cos(rz) - y * sin(rz), x * sin(rz) + y * cos(rz))
            let k = f / max(f + z, f * 0.05)
            return CGPoint(x: x * k + shift.x, y: y * k + shift.y)
        }
        var out: CIImage
        if xf.is3D {
            out = img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: project(CGPoint(x: e.minX, y: e.maxY))),
                "inputTopRight": CIVector(cgPoint: project(CGPoint(x: e.maxX, y: e.maxY))),
                "inputBottomRight": CIVector(cgPoint: project(CGPoint(x: e.maxX, y: e.minY))),
                "inputBottomLeft": CIVector(cgPoint: project(CGPoint(x: e.minX, y: e.minY))),
            ])
        } else {
            var t = CGAffineTransform(translationX: -a.x, y: -a.y)
            t = t.concatenating(CGAffineTransform(scaleX: xf.scale, y: xf.scale))
            if xf.rotation != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: rz)) }
            t = t.concatenating(CGAffineTransform(translationX: shift.x, y: shift.y))
            out = img.transformed(by: t, highQualityDownsample: xf.scale < 1)
        }
        if xf.opacity < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: xf.opacity)])
        }
        return out
    }

    /// A clip's placed picture averaged over the shutter interval when it has motion blur and moves.
    func blurredLayer(_ clip: Clip, at t: Seconds, source: (String) -> CVPixelBuffer?) -> CIImage? {
        let shutter = clip.number("transform.motion_blur", at: t - clip.start, default: clip.transform.motionBlur)
        let moves = clip.anim.keys.contains { $0.hasPrefix("transform.") && $0 != "transform.opacity" }
        guard shutter > 0, moves else { return layer(clip, at: t, source: source) }
        let span = shutter / 360 / project.canvas.fps
        let n = 8
        var acc: CIImage?
        for i in 0..<n {
            let dt = span * (Double(i) / Double(n - 1) - 0.5)
            guard var l = layer(clip, at: t + dt, source: source) else { continue }
            l = l.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 / CGFloat(n), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 / CGFloat(n), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 / CGFloat(n), w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 / CGFloat(n)),
            ])
            acc = acc.map { l.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? l
        }
        return acc
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
        let font = TextRenderer.font(spec.font, size: spec.size * h, weight: spec.weight)
        let runs = TextRenderer.runs(spec, font: font, visible: reveal)
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

enum TextPresetAnimator {
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
        // The black base track only keeps the composition running; its frames are never read, and asking
        // for them makes readers wait on a track stretched over long gaps.
        requiredSourceTrackIDs = Set(scene.trackIDs.filter { $0.key != "__base" }.values).sorted().map { NSNumber(value: $0) }
    }
}

/// Renders frames of a timeline in its working space. AVFoundation creates compositors by class,
/// so each output color space has its own subclass.
public class CutlineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let device = MTLCreateSystemDefaultDevice()
    static let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    class var space: WorkingSpace { .rec709 }

    static func compositorClass(_ w: WorkingSpace) -> AVVideoCompositing.Type {
        switch w {
        case .rec709: CutlineCompositor.self
        case .p3: CutlineCompositorP3.self
        case .rec2020_hlg: CutlineCompositorHLG.self
        case .rec2020_pq: CutlineCompositorPQ.self
        }
    }

    private lazy var output = ColorManagement.colorSpace(Self.space)
    private lazy var context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .outputColorSpace: output]
        if let device = CutlineCompositor.device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
    private let queue = DispatchQueue(label: "cutline.compositor", qos: .userInteractive)
    private var renderContext: AVVideoCompositionRenderContext?

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        // Ten-bit sources keep log and HDR footage from banding; 8-bit SDR stays cheap.
        let formats: [OSType] = Self.space == .rec709
            ? [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
            : [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_64RGBAHalf]
        return [kCVPixelBufferPixelFormatTypeKey as String: formats.map { NSNumber(value: $0) }, kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: ColorManagement.pixelFormat(Self.space)), kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public var supportsHDRSourceFrames: Bool { Self.space.isHDR }
    public var supportsWideColorSourceFrames: Bool { Self.space != .rec709 }

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
                ColorManagement.tag(out, Self.space)
                context.render(fitted, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: output)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {}
}

final class CutlineCompositorP3: CutlineCompositor, @unchecked Sendable {
    override class var space: WorkingSpace { .p3 }
}

final class CutlineCompositorHLG: CutlineCompositor, @unchecked Sendable {
    override class var space: WorkingSpace { .rec2020_hlg }
}

final class CutlineCompositorPQ: CutlineCompositor, @unchecked Sendable {
    override class var space: WorkingSpace { .rec2020_pq }
}
