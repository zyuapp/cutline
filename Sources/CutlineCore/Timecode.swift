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

    /// `dropFrame: false` counts NTSC rates non-drop.
    public init(fps: Double, dropFrame allowDrop: Bool? = nil) {
        let grid = FrameGrid(fps: fps)
        nominal = max(1, Int(grid.rate.rounded()))
        dropFrame = grid.num == 1001 && EDLTimecode.dropFrames(nominal) > 0 && allowDrop != false
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

    /// Counting as `label` is written: drop frame when ";" or "." separates the frames, non-drop otherwise.
    public init(fps: Double, label: String) {
        self.init(fps: fps, dropFrame: TimecodeFormat.isDropLabel(label))
    }

    public static func isDropLabel(_ label: String) -> Bool { label.contains(";") || label.contains(".") }

    /// Whole frames in `seconds` at this rate.
    public func frameCount(_ seconds: Seconds) -> Int { Int((seconds * Double(frameDen) / Double(frameNum)).rounded()) }

    public func seconds(_ frames: Int) -> Seconds { Double(frames * frameNum) / Double(frameDen) }

    /// Exact frames per second, e.g. 30000/1001.
    public var rate: Double { Double(frameDen) / Double(frameNum) }

    /// Frame count of a label read at this rate; ";" forces drop frame where the rate has it.
    public func frames(reading label: String) -> Int? {
        TimecodeFormat.isDropLabel(label) && !dropFrame && EDLTimecode.dropFrames(nominal) > 0
            ? TimecodeFormat(fps: rate, dropFrame: true).frames(label) : frames(label)
    }
}

extension Canvas {
    /// Timecode of the first timeline frame in exports, "01:00:00:00" unless set.
    public var startTimecode: String { timecodeStart ?? TimecodeFormat.defaultStart }
}

extension MediaAsset {
    /// How the media's source timecode counts: at its own frame rate (`fallback` without one), drop frame as its
    /// label is written, or as `dropFrame` says (nil: the rate's default) when there is no label.
    public func timecodeFormat(fallback fps: Double = 30, dropFrame: Bool? = nil) -> TimecodeFormat {
        let rate = self.fps > 0 && !isImage ? self.fps : fps
        return timecodeLabel.map { TimecodeFormat(fps: rate, label: $0) } ?? TimecodeFormat(fps: rate, dropFrame: dropFrame)
    }

    /// Frames from midnight to the first frame; nil without source timecode. The label wins when it names the
    /// same frame as `timecodeStart`.
    public func timecodeFrames(fallback fps: Double = 30) -> Int? {
        guard let start = timecodeStart else { return nil }
        let f = timecodeFormat(fallback: fps)
        if let label = timecodeLabel, let n = f.frames(label), abs(f.seconds(n) - start) < 0.5 / f.rate { return n }
        return f.frameCount(start)
    }

    /// The source timecode label of the first frame; nil without one.
    public func timecodeString(fallback fps: Double = 30) -> String? {
        timecodeFrames(fallback: fps).map { timecodeFormat(fallback: fps).string($0) }
    }

    /// Frames from midnight of the source frame at `t` seconds into the media (0 at its first frame).
    public func sourceFrames(at t: Seconds, fallback fps: Double = 30) -> Int {
        (timecodeFrames(fallback: fps) ?? 0) + timecodeFormat(fallback: fps).frameCount(t)
    }

    /// Seconds into the media of a source timecode label; ";" in it counts drop frame. Nil when malformed.
    public func sourceSeconds(timecode label: String, fallback fps: Double = 30) -> Seconds? {
        let f = timecodeFormat(fallback: fps)
        guard let n = f.frames(reading: label) else { return nil }
        return f.seconds(n - (timecodeFrames(fallback: fps) ?? 0))
    }

    /// Sets the source timecode to `frames` from midnight, counted as `format` does.
    public mutating func setTimecode(frames: Int, format: TimecodeFormat) {
        timecodeStart = format.seconds(frames)
        timecodeLabel = format.string(frames)
    }

    /// Keeps `seconds` as the start and labels the nearest frame, counted as `format` does.
    public mutating func setTimecode(seconds: Seconds, format: TimecodeFormat) {
        timecodeStart = seconds
        timecodeLabel = format.string(format.frameCount(seconds))
    }
}
