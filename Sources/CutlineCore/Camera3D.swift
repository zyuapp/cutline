import Foundation

public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { sqrt(dot(self)) }
    public var normalized: Vec3 { let l = length; return l > 0 ? self * (1 / l) : self }
}

/// A pinhole camera over the canvas. World space is in canvas pixels, y down, z away from the viewer;
/// the default camera sees the z = 0 plane exactly as the 2D canvas.
public struct SceneCamera: Equatable, Sendable {
    public var position: Vec3
    public var right: Vec3
    public var down: Vec3
    public var forward: Vec3
    /// Focal length in pixels.
    public var focal: Double
    public var width: Double
    public var height: Double
    /// Camera-space depth in focus, in pixels, and the blur radius in pixels of layers far out of focus.
    public var focus: Double
    public var blur: Double

    /// Depth below which a layer is behind the lens and hidden.
    public var near: Double { height * 0.02 }

    /// Builds the camera from `camera` generator parameters; missing ones take their defaults.
    public init(width: Double, height: Double, value: (String) -> Double? = { _ in nil }) {
        func v(_ k: String) -> Double { value(k) ?? GeneratorCatalog.type("camera")?.spec(k)?.defaultValue.number ?? 0 }
        self.width = width
        self.height = height
        let fov = min(max(v("fov"), 1), 179) * .pi / 180
        let lens = (height / 2) / tan(fov / 2)
        focal = lens * max(v("zoom"), 0.01)
        let target = Vec3(width / 2 + v("target_x") * width, height / 2 + v("target_y") * height, v("target_z") * height)
        let dist = v("distance") > 0 ? v("distance") * height : lens
        let orbit = v("orbit") * .pi / 180, tilt = min(max(v("tilt"), -89.9), 89.9) * .pi / 180
        let toCamera = Vec3(sin(orbit) * cos(tilt), -sin(tilt), -cos(orbit) * cos(tilt))
        position = target + toCamera * dist
        let f = (target - position).normalized
        var r = Vec3(0, 1, 0).cross(f).normalized
        var d = f.cross(r)
        let roll = v("roll") * .pi / 180
        if roll != 0 {
            let (c, s) = (cos(roll), sin(roll))
            (r, d) = (r * c - d * s, d * c + r * s)
        }
        right = r
        down = d
        forward = f
        let fd = v("focus_distance")
        focus = fd > 0 ? fd * height : dist
        blur = v("blur") * height
    }

    /// Camera-space coordinates: x right, y down, z depth along the view.
    public func view(_ p: Vec3) -> Vec3 {
        let q = p - position
        return Vec3(q.dot(right), q.dot(down), q.dot(forward))
    }

    /// Screen position in canvas pixels (y down) of a camera-space point in front of the lens.
    public func screen(_ c: Vec3) -> (x: Double, y: Double)? {
        guard c.z > near else { return nil }
        return (width / 2 + focal * c.x / c.z, height / 2 + focal * c.y / c.z)
    }

    public func project(_ p: Vec3) -> (x: Double, y: Double)? { screen(view(p)) }

    /// Depth-of-field blur radius in pixels at a camera-space depth.
    public func blurRadius(depth: Double) -> Double {
        guard blur > 0, depth > 0, focus > 0 else { return 0 }
        return blur * min(abs(1 - focus / depth), 1)
    }
}

/// Where a flat layer sits in 3D: its anchor point in world space and its rotations.
public struct LayerPlacement3D: Sendable {
    /// World position of the anchor (pixels, y down, z away).
    public var anchor: Vec3
    public var scale: Double
    /// Degrees: tilt with the top away, turn with the right side away, clockwise roll in the layer's plane.
    public var rotateX: Double
    public var rotateY: Double
    public var rotateZ: Double

    public init(anchor: Vec3, scale: Double, rotateX: Double, rotateY: Double, rotateZ: Double) {
        self.anchor = anchor
        self.scale = scale
        self.rotateX = rotateX
        self.rotateY = rotateY
        self.rotateZ = rotateZ
    }

    /// World position of a point offset (dx, dy) pixels from the anchor in the layer's own plane (y down).
    /// The roll applies in the layer's plane first, then the turn, then the tilt.
    public func world(_ dx: Double, _ dy: Double) -> Vec3 {
        var x = dx * scale, y = dy * scale, z = 0.0
        let rz = rotateZ * .pi / 180, ry = rotateY * .pi / 180, rx = rotateX * .pi / 180
        (x, y) = (x * cos(rz) - y * sin(rz), x * sin(rz) + y * cos(rz))
        (x, z) = (x * cos(ry) - z * sin(ry), x * sin(ry) + z * cos(ry))
        (y, z) = (y * cos(rx) + z * sin(rx), -y * sin(rx) + z * cos(rx))
        return anchor + Vec3(x, y, z)
    }
}
