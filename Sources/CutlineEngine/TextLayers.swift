import CoreImage
import CutlineCore
import Foundation

/// Generator values that depend on other clips, and extruded text stacked in 3D.
extension RenderScene {
    /// A generator clip's parameter values at clip-local `local`. A text.path whose d is "shape:<clip>.<shape id>"
    /// takes that shape layer's path (with its scale and rotation) and position at the same timeline time.
    func generatorValues(_ clip: Clip, _ gen: Effect, at local: Seconds) -> (String) -> ParamValue {
        let plain: (String) -> ParamValue = { clip.generatorValue($0, at: local) ?? .number(0) }
        guard gen.type == "text.path", let ref = plain("d").string, ref.hasPrefix("shape:"),
              let resolved = shapeReference(String(ref.dropFirst(6)), at: clip.start + local) else { return plain }
        return { name in
            switch name {
            case "d": return .string(resolved.d)
            case "path": return .string("svg")
            case "x": return .number(resolved.x)
            case "y": return .number(resolved.y)
            default: return plain(name)
            }
        }
    }

    /// "<clip>.<shape id>" (or just "<clip>" for its first shape): the shape's path in frame heights around its position.
    func shapeReference(_ ref: String, at t: Seconds) -> (d: String, x: Double, y: Double)? {
        let parts = ref.split(separator: ".", maxSplits: 1).map(String.init)
        guard let first = parts.first, let source = project.clip(first), source.kind == .generator else { return nil }
        let local = t - source.start
        guard let json = source.generatorValue("shapes", at: local)?.string, let items = try? ShapeLayers.parse(json),
              let item = parts.count > 1 ? items.first(where: { $0.id == parts[1] }) : items.first else { return nil }
        func num(_ prop: String) -> Double { source.generatorValue("\(item.id).\(prop)", at: local)?.number ?? item.value(prop).number ?? 0 }
        guard let path = try? item.path(num) else { return nil }
        let sx = num("scale") * num("scale_x"), sy = num("scale") * num("scale_y")
        let r = num("rotation") * .pi / 180
        let placed = path.mapped { p in
            let x = p.x * sx, y = p.y * sy
            return PathPoint(x * cos(r) - y * sin(r), x * sin(r) + y * cos(r))
        }
        // Shape positions are frame fractions; text.path takes x in frame widths too, so the offset carries over.
        return (placed.svg, num("x"), num("y"))
    }

    /// text.extruded on a 3D layer: side slices stacked behind the face along the layer's normal, darker toward the
    /// back, then the face, all projected through the camera.
    func extruded3D(_ clip: Clip, value: @escaping (String) -> ParamValue, xf: Transform, center: CGPoint, t: Seconds, param: @escaping (Effect, String) -> ParamValue?) -> CIImage? {
        let canvas = canvasRect
        guard let parts = PathText.extrudedParts(value: value, canvas: canvas.size) else { return nil }
        let ctx = EffectRenderer.Context(unit: canvas.height / max(CGFloat(xf.scale), 0.01), time: t, opaque: false, gradeSpace: gradeSpace)
        let effects = clip.effects(atTimeline: t)
        func prepared(_ cg: CGImage) -> CIImage {
            let img = CIImage(cgImage: cg)
            return effects.isEmpty ? img : EffectRenderer.apply(effects, to: img, context: ctx, param: param)
        }
        let face = prepared(parts.face), side = prepared(parts.side)
        let depth = (value("depth").number ?? 0) * Double(canvas.height)
        let shading = min(max(value("shading").number ?? 0.6, 0), 1)
        let cam = camera(at: t)
        var solid = xf
        solid.opacity = 1
        var out = CIImage(color: .clear).cropped(to: canvas)
        if depth > 0.5 {
            let n = min(96, max(2, Int((depth / 1.5).rounded(.up))))
            for k in stride(from: n, through: 1, by: -1) {
                let f = Double(k) / Double(n)
                let shade = CGFloat(1 - 0.5 * shading * f)
                let slice = side.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: shade, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: shade, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: shade, w: 0),
                ])
                if let placed = place3D(slice, center: center, xf: solid, camera: cam, depth: depth * f) { out = placed.composited(over: out) }
            }
        }
        if let placed = place3D(face, center: center, xf: solid, camera: cam) { out = placed.composited(over: out) }
        return xf.opacity < 0.999 ? alpha(out, xf.opacity) : out
    }
}
