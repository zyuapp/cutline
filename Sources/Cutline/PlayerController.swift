import AVFoundation
import CoreImage
import Observation

/// Wraps AVPlayer with frame-accurate scrubbing and range playback.
@MainActor
@Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    var duration: Double = 0
    var fps: Double = 30
    var loop = false

    private var observer: Any?
    private var stopAt: Double?
    private var chaseTarget: CMTime?
    private var seeking = false
    @ObservationIgnored var onPause: (() -> Void)?

    /// A tiny, softened copy of the current frame that lights the room around the picture.
    private(set) var ambient: CGImage?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var ambientTimer: Timer?
    @ObservationIgnored private let ambientContext = CIContext(options: [.cacheIntermediates: false])

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        ambientTimer = Timer.scheduledTimer(withTimeInterval: 1 / 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleAmbient() }
        }
    }

    private func sampleAmbient() {
        guard let output, let item = player.currentItem else { return }
        let t = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
        else { return }
        let frame = CIImage(cvPixelBuffer: pb)
        guard frame.extent.width > 0 else { return }
        let w: CGFloat = 40
        let scale = w / frame.extent.width
        let h = (frame.extent.height * scale).rounded()
        let small = frame
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 2.4)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.72])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        ambient = ambientContext.createCGImage(small, from: small.extent)
    }

    private func tick(_ t: Double) {
        guard !seeking else { return }
        time = t
        let playing = player.rate != 0
        if let stop = stopAt, t >= stop {
            pause()
            stopAt = nil
            return
        }
        if playing, t >= duration - 0.5 / fps {
            if loop {
                seek(0)
            } else {
                pause()
            }
            return
        }
        if isPlaying != playing {
            isPlaying = playing
            if !playing { onPause?() }
        }
    }

    func replaceItem(_ item: AVPlayerItem, duration: Double, fps: Double) {
        let keep = min(time, max(0, duration - 1 / fps))
        let wasPlaying = isPlaying
        self.duration = duration
        self.fps = fps
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        output = out
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTime(seconds: keep, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        time = keep
        if wasPlaying { player.play() }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        if time >= duration - 1 / fps { seek(0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        onPause?()
    }

    func play(from start: Double, to end: Double?) {
        seek(start)
        stopAt = end
        player.play()
        isPlaying = true
    }

    // MARK: Recording

    /// Paused exactly on `t` and prerolled, so `roll(atHost:)` starts on time.
    func cue(_ t: Double, muted: Bool) async {
        pause()
        stopAt = nil
        player.isMuted = muted
        let target = CMTime(seconds: max(0, t), preferredTimescale: 60_000)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        time = target.seconds
        _ = await player.preroll(atRate: 1)
    }

    /// Starts the cued item when the host clock reaches `host` and returns its clock read back from the item's
    /// timebase shortly after.
    func roll(atHost host: Double) async -> (host: Double, timeline: Double, requested: Double) {
        let from = player.currentTime()
        player.setRate(1, time: from, atHostTime: CMClockMakeHostTimeFromSystemUnits(AVAudioTime.hostTime(forSeconds: host)))
        isPlaying = true
        let settle = host + 0.05 - AVAudioTime.seconds(forHostTime: mach_absolute_time())
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1e9)) }
        guard let timebase = player.currentItem?.timebase else { return (host, from.seconds, from.seconds) }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let t = CMTimebaseGetTime(timebase).seconds
        return (now, t, from.seconds + (now - host))
    }

    func endRecording() {
        pause()
        player.isMuted = false
    }

    func shuttle(_ rate: Float) {
        player.rate = rate
        isPlaying = rate != 0
    }

    func step(frames: Int) {
        pause()
        seek(time + Double(frames) / fps)
    }

    /// Chases the latest requested time so dragging stays responsive.
    func seek(_ t: Double) {
        let clamped = min(max(0, t), max(0, duration - 1 / fps))
        time = clamped
        chaseTarget = CMTime(seconds: clamped, preferredTimescale: 60_000)
        if !seeking { chase() }
    }

    private func chase() {
        guard let target = chaseTarget else { return }
        seeking = true
        chaseTarget = nil
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.chaseTarget != nil {
                    self.chase()
                } else {
                    self.seeking = false
                    if !self.isPlaying { self.onPause?() }
                }
            }
        }
    }
}
