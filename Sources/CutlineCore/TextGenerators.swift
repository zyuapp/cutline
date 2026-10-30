import Foundation

/// Text on a path and extruded 3D text.
extension GeneratorCatalog {
    static let textType: [ParamSpec] = [
        font,
        num("weight", 700, 100, 900, animatable: false, "100 thin … 900 black"),
        color("color", "#FFFFFF", "Fill color"),
        color("stroke", "#00000000", "Outline color; transparent for none"),
        len("stroke_width", 0, 0.05, "Outline width"),
        num("letter_spacing", 0, -0.5, 2, "Extra space between letters, as a fraction of the size"),
    ]

    static let textGenerators: [EffectType] = [
        EffectType(id: "text.path", category: "generator", summary: "Text on a path, like After Effects' Path Text: letters set along a circle, arc, wave, line or any SVG path (or a shape layer's path, d \"shape:<clip>.<shape id>\"), each turned to follow the curve; animate offset to run the text along it and reveal to type it on", params: [
            text("text", "TEXT ON A PATH • CUTLINE • ", "The words"),
            ParamSpec("path", .choice(["circle", "arc", "wave", "line", "svg"]), .string("circle"), "circle: radius around x,y, starting at the top and running clockwise; arc: the circle from arc_start to arc_end; wave: a sine wave width wide; line: a straight line width wide; svg: the path in d"),
            text("d", "", "SVG path data for path svg, in frame heights around x,y (like a shape layer's path), e.g. \"M -0.4 0 C -0.2 -0.3 0.2 -0.3 0.4 0\"; or \"shape:<clip id>.<shape id>\" to take a shape layer's path, position and transform"),
            pos("x", 0.5, "Path origin (circle center), 0 left to 1 right"),
            pos("y", 0.5, "Path origin, 0 top to 1 bottom"),
            len("radius", 0.3, 5, "Circle and arc radius"),
            num("arc_start", -60, -720, 720, unit: "degrees", "Arc start, clockwise from the top"),
            num("arc_end", 60, -720, 720, unit: "degrees", "Arc end; below arc_start the arc runs counter-clockwise, e.g. 240 → 120 reads left to right along the bottom"),
            len("width", 0.8, 10, "Wave and line length"),
            len("amplitude", 0.06, 2, "Wave height"),
            num("waves", 1.5, 0, 50, "Wave cycles along the width"),
            len("size", 0.06, 1, "Letter size"),
            num("offset", 0, -100, 100, "Moves the text along the path, in path lengths (closed paths wrap); animate for text that runs around"),
            ParamSpec("align", .choice(["start", "center", "end", "spread"]), .string("start"), "Where the text sits on the path before offset; spread spaces the letters out to fill the whole path"),
            len("baseline", 0, 1, "Raises the letters off the path (negative not allowed; use flip to put them on the other side)"),
            ParamSpec("flip", .bool, .bool(false), "Run the path the other way: letters on its inside, reading the other direction (text along the bottom of a circle)"),
            num("reveal", 1, 0, 1, "Share of the letters shown, in reading order; animate 0→1 to type it on"),
        ] + textType),
        EffectType(id: "text.extruded", category: "generator", summary: "Extruded 3D text: solid letters with depth, lit sides and a beveled face. In 2D the depth runs in angle's direction; with transform.3d true the letters are stacked in real depth, so camera moves and rotate_x/y show their sides in perspective", params: [
            text("text", "CUTLINE", "The words"),
            pos("x", 0.5, "Center, 0 left to 1 right"),
            pos("y", 0.5, "Center, 0 top to 1 bottom"),
            len("size", 0.18, 2, "Letter size"),
            color("side_color", "#9A6A00", "Color of the extruded sides"),
            len("depth", 0.04, 1, "Extrusion depth"),
            num("angle", 135, -360, 360, unit: "degrees", "2D: direction the depth runs, CSS style (0 up, 90 right, 135 down-right)"),
            len("bevel", 0.004, 0.05, "Bevel width on the face's edges; 0 for a flat face"),
            num("light", 315, -360, 360, unit: "degrees", "Direction the light comes from, CSS style (315 top left)"),
            num("shading", 0.6, 0, 1, "Strength of lighting on the sides and bevel"),
        ] + textType.map { $0.name == "color" ? color("color", "#FFD60A", "Face color") : $0 }),
    ]
}

extension ShapePath {
    /// Point and unit tangent at arc length `s` along the contours in order; closed contours include their closing line.
    public func point(at s: Double) -> (PathPoint, PathPoint)? {
        var acc = 0.0
        var lastItem: (Measured, Double)?
        for c in contours {
            for item in ShapePath.measure(c) where item.length > 0 {
                lastItem = (item, acc)
                if s <= acc + item.length {
                    return ShapePath.locate(item, s - acc)
                }
                acc += item.length
            }
        }
        guard let (item, start) = lastItem else { return nil }
        return ShapePath.locate(item, s - start)
    }

    static func locate(_ item: Measured, _ u: Double) -> (PathPoint, PathPoint) {
        switch item.seg {
        case .line(let p):
            let d = p - item.from, l = max(d.length, 1e-12)
            return (item.from.lerp(p, u / l), d * (1 / l))
        case .cubic(let a, let b, let p):
            let t = parameter(item.table!, at: u)
            let q = cubicPoint(item.from, a, b, p, t)
            let m = 1 - t
            var d = (a - item.from) * (3 * m * m) + (b - a) * (6 * m * t) + (p - b) * (3 * t * t)
            if d.length < 1e-12 { d = p - item.from }
            return (q, d * (1 / max(d.length, 1e-12)))
        }
    }

    public var isClosed: Bool { contours.count == 1 && contours[0].closed }

    /// The contours run backwards.
    public var reversed: ShapePath {
        ShapePath(contours.reversed().map { c in
            var segments = c.segments
            var pts: [PathPoint] = [c.start] + segments.map(\.end)
            // An explicit closing line, so the reversed contour starts where the original does.
            if c.closed, (pts.last! - c.start).length > 1e-9 {
                segments.append(.line(c.start))
                pts.append(c.start)
            }
            var segs: [Segment] = []
            for (k, s) in segments.enumerated().reversed() {
                switch s {
                case .line: segs.append(.line(pts[k]))
                case .cubic(let a, let b, _): segs.append(.cubic(b, a, pts[k]))
                }
            }
            return Contour(start: pts.last!, segments: segs, closed: c.closed)
        })
    }

    /// SVG path data for the contours.
    public var svg: String {
        func f(_ v: Double) -> String { String(format: "%.6g", v) }
        return contours.map { c in
            "M \(f(c.start.x)) \(f(c.start.y)) " + c.segments.map { s -> String in
                switch s {
                case .line(let p): return "L \(f(p.x)) \(f(p.y))"
                case .cubic(let a, let b, let p): return "C \(f(a.x)) \(f(a.y)) \(f(b.x)) \(f(b.y)) \(f(p.x)) \(f(p.y))"
                }
            }.joined(separator: " ") + (c.closed ? " Z" : "")
        }.joined(separator: " ")
    }

    /// The text.path generator's path in frame heights around its origin.
    public static func textPath(kind: String, radius r: Double, arcStart: Double, arcEnd: Double, width: Double, amplitude: Double, waves: Double, d: String) -> ShapePath? {
        switch kind {
        case "circle":
            return .ellipse(width: 2 * r, height: 2 * r)
        case "arc":
            let a0 = arcStart * .pi / 180, a1 = arcEnd * .pi / 180
            let n = max(2, Int((abs(a1 - a0) / (.pi / 2)).rounded(.up)) * 4)
            let pts = (0...n).map { k -> PathPoint in
                let a = a0 + (a1 - a0) * Double(k) / Double(n)
                return PathPoint(r * sin(a), -r * cos(a))
            }
            return cubicThrough(pts)
        case "wave":
            let n = max(8, Int((waves * 16).rounded(.up)))
            let pts = (0...n).map { k -> PathPoint in
                let f = Double(k) / Double(n)
                return PathPoint(-width / 2 + width * f, -amplitude * sin(2 * .pi * waves * f))
            }
            return cubicThrough(pts)
        case "line":
            return ShapePath([Contour(start: PathPoint(-width / 2, 0), segments: [.line(PathPoint(width / 2, 0))])])
        default:
            guard !d.isEmpty, let p = try? ShapePath.svg(d), !p.isEmpty else { return nil }
            return p
        }
    }

    /// A smooth open curve through points (Catmull-Rom as cubics).
    static func cubicThrough(_ p: [PathPoint]) -> ShapePath {
        var segs: [Segment] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            segs.append(.cubic(p1 + (p2 - p0) * (1.0 / 6), p2 - (p3 - p1) * (1.0 / 6), p2))
        }
        return ShapePath([Contour(start: p[0], segments: segs)])
    }
}
