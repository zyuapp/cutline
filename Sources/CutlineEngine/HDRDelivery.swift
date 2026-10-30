import AVFoundation
import CoreImage
import CutlineCore
import Foundation

extension RenderScene {
    /// The composited frame as the compositor writes it: PQ highlights rolled off to the canvas's master peak,
    /// then, for an SDR version, trimmed to Rec. 709.
    func delivered(_ image: CIImage) -> CIImage {
        let canvas = project.canvas
        var img = image
        if let rolloff = canvas.peakRolloff {
            let cube = HDRCubes.cube("peak|\(rolloff.peakNits)|\(rolloff.knee)", size: 65, rolloff.transform)
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": ColorManagement.colorSpace(.rec2020_pq),
            ])
        }
        if let trim = sdrTrim, canvas.colorSpace.isHDR {
            let cube = HDRCubes.cube("sdr|\(canvas.colorSpace.rawValue)|\(trim.method.rawValue)|\(trim.targetNits)|\(trim.sourcePeakNits)", size: 65, trim.transform(from: canvas.colorSpace))
            let encoded = img.matchedFromWorkingSpace(to: ColorManagement.colorSpace(canvas.colorSpace)) ?? img
            let mapped = encoded.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": ColorManagement.passthroughSpace,
            ])
            img = mapped.matchedToWorkingSpace(from: ColorManagement.colorSpace(.rec709)) ?? mapped
        }
        return img
    }
}

enum HDRCubes {
    static func cube(_ key: String, size: Int, _ f: @escaping ColorMath.Transform) -> (size: Int, data: Data) {
        if let hit = ColorManagement.cubes.object(forKey: key as NSString) { return (hit.size, hit.data) }
        let cube = ColorManagement.bake(size: size, f)
        ColorManagement.cubes.setObject(cube, forKey: key as NSString)
        return (cube.size, cube.data)
    }
}

extension BuiltTimeline {
    /// The encoding the compositor writes: Rec. 709 for an SDR version of an HDR canvas, else the canvas's.
    public var outputSpace: WorkingSpace { scene.sdrTrim != nil ? .rec709 : scene.project.canvas.colorSpace }

    /// The same timeline delivered as Rec. 709 SDR through `trim`; nil unless the canvas is HDR.
    public func sdrVersion(_ trim: SDRTrim) -> BuiltTimeline? {
        guard scene.project.canvas.colorSpace.isHDR else { return nil }
        let s = RenderScene(project: scene.project, captions: scene.captions, trackIDs: scene.trackIDs, orientations: scene.orientations, images: scene.images)
        s.sdrTrim = trim
        let vc = videoComposition.mutableCopy() as! AVMutableVideoComposition
        // Source frames stay as decoded (as on the HDR timeline); the compositor converts them.
        vc.customVideoCompositorClass = CutlineCompositorSDRTrim.self
        vc.instructions = vc.instructions.map { i in
            CutlineInstruction(timeRange: i.timeRange, scene: s)
        }
        var built = BuiltTimeline(composition: composition, videoComposition: vc, audioMix: audioMix, scene: s, duration: duration, missingStems: missingStems, layout: layout, surround: surround)
        built.missingPictures = missingPictures
        return built
    }
}
