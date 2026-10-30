import Foundation

/// SMPTE timecode at a frame rate: labels count nominal frames per second (30 at 29.97) and drop
/// frame numbers at 29.97 and 59.94. EDL, FCPXML and exported timecode tracks all use this choice.
public struct TimecodeFormat: Equatable, Sendable {
    public let nominal: Int
    public let dropFrame: Bool
    /// One frame lasts frameNum/frameDen seconds, e.g. 1001/30000 at 29.97.
    public let frameNum: Int
    public let frameDen: Int

    /// Program start when a project doesn't set one, as in EDL export.
    public static let defaultStart = "01:00:00:00"

    public init(fps: Double) {
        let grid = FrameGrid(fps: fps)
        nominal = max(1, Int(grid.rate.rounded()))
        dropFrame = grid.num == 1001 && EDLTimecode.dropFrames(nominal) > 0
        frameNum = grid.num
        frameDen = grid.den
    }

    /// Frames in 24 hours of labels.
    public var framesPerDay: Int { EDLTimecode.frames(24, 0, 0, 0, nominal: nominal, drop: dropFrame) }

    /// Frame count of "hh:mm:ss:ff" (or "hh:mm:ss;ff"); nil when malformed.
    public func frames(_ s: String) -> Int? {
        let parts = s.split(whereSeparator: { ":;.,".contains($0) }).map { Int($0) }
        guard parts.count == 4, let h = parts[0], let m = parts[1], let sec = parts[2], let f = parts[3],
              (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(sec), (0..<nominal).contains(f) else { return nil }
        return EDLTimecode.frames(h, m, sec, f, nominal: nominal, drop: dropFrame)
    }

    /// The label of a frame count, wrapping at 24 hours; ";" before the frames marks drop frame.
    public func string(_ frames: Int) -> String {
        let day = framesPerDay
        return EDLTimecode.string(((frames % day) + day) % day, nominal: nominal, drop: dropFrame)
    }

    /// Whole frames in `seconds` at this rate.
    public func frameCount(_ seconds: Seconds) -> Int { Int((seconds * Double(frameDen) / Double(frameNum)).rounded()) }

    public func seconds(_ frames: Int) -> Seconds { Double(frames * frameNum) / Double(frameDen) }
}

extension Canvas {
    /// Timecode of the first timeline frame in exports, "01:00:00:00" unless set.
    public var startTimecode: String { timecodeStart ?? TimecodeFormat.defaultStart }
}
