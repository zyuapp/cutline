import CoreImage
import CutlineCore
import Foundation

/// 3D layers: flat pictures placed in world space and projected through the scene camera.
extension RenderScene {
    /// The camera at timeline time `t`: the topmost visible camera clip playing then, or the default front camera.
    func camera(at t: Seconds) -> SceneCamera {
        let w = Double(canvasRect.width), h = Double(canvasRect.height)
        for track in project.tracks.reversed() where track.kind == .video && !track.hidden {
            guard let c = track.clip(at: t), c.kind == .generator, c.effects.contains(where: { $0.type == "camera" && $0.enabled }) else { continue }
            let local = t - c.start
            return SceneCamera(width: w, height: h) { c.generatorValue($0, at: local)?.number }
        }
        return SceneCamera(width: w, height: h)
    }

    /// Camera-space depth of a 3D clip's anchor, for drawing far layers first.
    func depth3D(_ clip: Clip, at t: Seconds, camera: SceneCamera) -> Double {
        let local = t - clip.start
        let xf = clip.resolvedTransform(at: local)
        let w = Double(canvasRect.width), h = Double(canvasRect.height)
        var p = Vec3(w / 2 + xf.x * w, h / 2 + xf.y * h, xf.z * h)
        if clip.kind == .text, let spec = clip.resolvedText(at: local) {
            let anim = TextPresetAnimator.state(spec: spec, local: min(max(local, 0), clip.duration), duration: clip.duration)
            p.x = w * (spec.x + xf.x)
            p.y = h * (spec.y + xf.y + anim.yOffset)
        }
        return camera.view(p).z
    }

    /// Projects a picture whose anchor would sit at `center` (Core Image coordinates) in 2D onto its plane in 3D.
    /// A layer reaching behind the camera keeps only an axis-aligned part in front of it; nil when none is.
    /// `depth` moves the picture that many pixels behind the layer's plane, along its normal.
    func place3D(_ full: CIImage, center: CGPoint, xf: Transform, camera: SceneCamera, depth: Double = 0) -> CIImage? {
        let whole = full.extent
        guard !whole.isInfinite, whole.width > 0, whole.height > 0 else { return nil }
        let H = canvasRect.height
        let a = CGPoint(x: whole.minX + xf.anchorX * whole.width, y: whole.maxY - xf.anchorY * whole.height)
        let shift = CGPoint(x: center.x + (a.x - whole.midX), y: center.y + (a.y - whole.midY))
        var plane = LayerPlacement3D(anchor: Vec3(shift.x, H - shift.y, xf.z * H), scale: xf.scale, rotateX: xf.rotateX, rotateY: xf.rotateY, rotateZ: xf.rotation)
        if depth != 0 { plane.anchor = plane.world(0, 0, depth) }
        guard let e = inFront(whole, anchor: a, plane: plane, camera: camera) else { return nil }
        let img = e == whole ? full : full.cropped(to: e)
        func corner(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
            guard let s = camera.project(plane.world(x - a.x, a.y - y)) else { return nil }
            return CGPoint(x: s.x, y: H - s.y)
        }
        guard let tl = corner(e.minX, e.maxY), let tr = corner(e.maxX, e.maxY), let br = corner(e.maxX, e.minY), let bl = corner(e.minX, e.minY) else { return nil }
        var out: CIImage
        let square = abs(xf.rotateX) < 1e-9 && abs(xf.rotateY) < 1e-9 && abs(camera.forward.z - 1) < 1e-12
        if square {
            // Facing the camera square on: a similarity transform, sharper than a perspective warp.
            let sx = (tr.x - tl.x) / e.width, sy = (tr.y - tl.y) / e.width
            let m = CGAffineTransform(a: sx, b: sy, c: -sy, d: sx, tx: 0, ty: 0)
            let o = CGPoint(x: e.minX, y: e.maxY).applying(m)
            out = img.transformed(by: m.concatenating(CGAffineTransform(translationX: tl.x - o.x, y: tl.y - o.y)), highQualityDownsample: hypot(sx, sy) < 1)
        } else {
            out = img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: tl), "inputTopRight": CIVector(cgPoint: tr),
                "inputBottomRight": CIVector(cgPoint: br), "inputBottomLeft": CIVector(cgPoint: bl),
            ])
        }
        let depth = camera.view(plane.world(e.midX - a.x, a.y - e.midY)).z
        let r = camera.blurRadius(depth: depth)
        if r > 0.3 {
            out = out.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: out.extent.insetBy(dx: -r * 3, dy: -r * 3))
        }
        if xf.opacity < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: xf.opacity)])
        }
        return out
    }

    /// The largest strip of `e`, cut along x or y, whose every point is in front of the lens.
    func inFront(_ e: CGRect, anchor a: CGPoint, plane: LayerPlacement3D, camera: SceneCamera) -> CGRect? {
        // Depth is linear across the layer's plane.
        func depth(_ x: CGFloat, _ y: CGFloat) -> Double { camera.view(plane.world(x - a.x, a.y - y)).z }
        let d0 = depth(e.minX, e.minY)
        let gx = (depth(e.maxX, e.minY) - d0) / e.width, gy = (depth(e.minX, e.maxY) - d0) / e.height
        let limit = camera.near * 1.5
        if [d0, d0 + gx * e.width, d0 + gy * e.height, d0 + gx * e.width + gy * e.height].allSatisfy({ $0 > limit }) { return e }
        func strip(_ g: Double, _ other: Double, length: CGFloat) -> (CGFloat, CGFloat)? {
            let need = limit - d0 - min(0, other)
            guard abs(g) > 1e-12 else { return need < 0 ? (0, length) : nil }
            let edge = CGFloat(need / g)
            let range = g > 0 ? (max(0, edge), length) : (0, min(length, edge))
            return range.1 - range.0 > 1 ? range : nil
        }
        let byX = strip(gx, gy * e.height, length: e.width).map { CGRect(x: e.minX + $0.0, y: e.minY, width: $0.1 - $0.0, height: e.height) }
        let byY = strip(gy, gx * e.width, length: e.height).map { CGRect(x: e.minX, y: e.minY + $0.0, width: e.width, height: $0.1 - $0.0) }
        return [byX, byY].compactMap { $0 }.max { $0.width * $0.height < $1.width * $1.height }
    }
}
