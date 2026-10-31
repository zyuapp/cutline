import AppKit
import CutlineCore
import CutlineEngine
import Observation
import SwiftUI

/// Rolls the preview's player for a recording.
final class PlayerTransport: ProgramTransport {
    let player: PlayerController

    init(_ player: PlayerController) { self.player = player }

    func cue(_ timeline: Seconds, muted: Bool) async throws {
        await player.cue(timeline, muted: muted)
    }

    func start(atHost host: Double) async throws -> ProgramAnchor {
        let measured = await player.roll(atHost: host)
        return ProgramAnchor(host: measured.host, timeline: measured.timeline, syncError: measured.timeline - measured.requested)
    }

    func stop() async {
        await player.endRecording()
    }

    var outputLatency: Seconds? { AudioDevices.defaultDevice(input: false).flatMap { AudioDevices.latency($0, input: false) } }
}

/// One voiceover_record request in the preview: the session and what the panel shows.
@MainActor
@Observable
final class VoiceOverController {
    let request: VoiceOverRequest
    private(set) var state: VoiceOverSession.State
    @ObservationIgnored let session: VoiceOverSession?
    /// Peak hold for the meter, dBFS.
    private(set) var hold: Double = -120
    @ObservationIgnored private var holdAt = Date.distantPast
    @ObservationIgnored private var levelAt = Date()

    init(request: VoiceOverRequest, session: VoiceOverSession?, failure: String? = nil) {
        self.request = request
        self.session = session
        state = VoiceOverSession.State(phase: failure.map { .failed($0) } ?? .countdown(request.countdown), take: 1, level: -120, timeline: nil, progress: 0, recorded: 0)
    }

    func update(_ s: VoiceOverSession.State) {
        // The meter falls back at 30 dB/s so short peaks stay readable.
        let fallen = state.level - 30 * Date().timeIntervalSince(levelAt)
        levelAt = Date()
        var next = s
        next.level = max(s.level, fallen)
        state = next
        if s.level >= hold || Date().timeIntervalSince(holdAt) > 1.2 {
            hold = s.level
            holdAt = Date()
        }
    }

    func fail(_ message: String) {
        state.phase = .failed(message)
    }

    var finished: Bool {
        switch state.phase {
        case .done, .failed: true
        default: false
        }
    }
}

extension ProjectDocument {
    /// Records the request at `requestURL` into its folder. Only audio files and `result.json` are written; the
    /// agent imports and places the takes.
    func startRecording(_ requestURL: URL) {
        let dir = requestURL.deletingLastPathComponent()
        guard let request = VoiceOver.read(VoiceOverRequest.self, from: requestURL) else { return }
        if recording.map({ !$0.finished }) ?? false {
            try? VoiceOver.write(VoiceOverResult(id: request.id, status: .failed, error: "The preview is already recording \(recording!.request.id); wait for it to finish."), to: VoiceOver.resultURL(dir))
            return
        }
        let env = ProcessInfo.processInfo.environment
        let session = VoiceOverSession(request: request, directory: dir, transport: PlayerTransport(player), environment: env)
        let controller = VoiceOverController(request: request, session: session)
        session.onState = { [weak controller] s in
            DispatchQueue.main.async { controller?.update(s) }
        }
        recording = controller
        NSApp.activate()
        Task { @MainActor in
            if VoiceOverSession.testInput(request, environment: env) == nil {
                try? VoiceOver.write(VoiceOverResult(id: request.id, status: .recording, currentTake: 1), to: VoiceOver.resultURL(dir))
                guard await VoiceOverSession.microphoneAccess() else {
                    try? VoiceOver.write(VoiceOverResult(id: request.id, status: .failed, error: VoiceOver.permissionMessage), to: VoiceOver.resultURL(dir))
                    controller.fail("Cutline can't use the microphone. Turn it on in System Settings › Privacy & Security › Microphone, then ask Claude to record again.")
                    return
                }
            }
            let result = await Task.detached { await session.run() }.value
            guard result.status == .done || result.status == .cancelled else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.recording === controller { self.recording = nil }
        }
    }

    func closeRecording() {
        if let r = recording, !r.finished { r.session?.stop() } else { recording = nil }
    }
}

// MARK: Panel

/// The recording card over the stage: what is being recorded, the countdown, the teleprompter, the input level
/// and the take controls. Red is reserved for the moment the line is live.
struct RecordingPanel: View {
    let doc: ProjectDocument
    let rec: VoiceOverController

    private var fps: Double { doc.project.canvas.fps }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let script = rec.request.script, !script.isEmpty {
                Teleprompter(text: script, progress: rec.state.progress, live: isLive)
            }
            if case .failed(let message) = rec.state.phase {
                Text(message)
                    .font(Typeface.font(14))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LevelMeter(level: rec.state.level, hold: rec.hold)
                progress
            }
            controls
        }
        .padding(20)
        .frame(width: 520)
        .animation(.easeOut(duration: 0.2), value: isLive)
        .glassEffect(.regular.tint(isLive ? Theme.tally.opacity(0.18) : .clear), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var isLive: Bool { rec.state.phase == .recording }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isLive ? Theme.tally : Theme.ink3)
                    .frame(width: 9, height: 9)
                Text(phaseLabel)
                    .font(Typeface.font(14, .semibold))
                    .foregroundStyle(isLive ? .primary : .secondary)
            }
            Text("Take \(rec.state.take) of \(rec.request.takes)")
                .font(Typeface.font(13).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(Theme.compact(rec.request.start, fps: fps)) – \(Theme.compact(rec.request.end, fps: fps))")
                .font(Typeface.font(13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .overlay {
            if case .countdown(let n) = rec.state.phase {
                Text("\(n)")
                    .font(Typeface.font(44, .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: n)
                    .offset(y: -2)
            }
        }
    }

    private var phaseLabel: String {
        switch rec.state.phase {
        case .countdown: "Get ready"
        case .preroll: "Preroll"
        case .recording: "Recording"
        case .saving: "Saving take"
        case .done: rec.state.recorded > 0 ? "Recorded · Claude is placing it" : "Stopped"
        case .failed: "Can't record"
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.field)
                    Capsule()
                        .fill(isLive ? Theme.tally : Theme.ink3)
                        .frame(width: geo.size.width * rec.state.progress)
                }
            }
            .frame(height: 4)
            HStack {
                Text(rec.state.timeline.map { Theme.timecode($0, fps: fps) } ?? " ")
                    .font(Typeface.font(12).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(rec.request.muteProgram ? "Program muted" : "Program on your headphones")
                    .font(Typeface.font(12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Spacer()
            if rec.finished {
                Button("Close") { doc.closeRecording() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Retake") { rec.session?.retake() }
                    .buttonStyle(.bordered)
                    .help("Throw this take away and record it again")
                Button("Stop") { rec.session?.stop() }
                    .buttonStyle(.borderedProminent)
                    .help("Stop recording; the takes so far are kept (Esc)")
            }
        }
    }
}

/// The script; one too long for the box scrolls through as the line plays so the current words sit near the top.
struct Teleprompter: View {
    let text: String
    let progress: Double
    let live: Bool
    @State private var contentHeight: CGFloat = 0
    private let height: CGFloat = 112

    var body: some View {
        let overflows = contentHeight > height
        let travel = overflows ? contentHeight - height * 0.45 : 0
        Typeface.text(text, 22, .medium)
            .foregroundStyle(live ? .primary : .secondary)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .offset(y: -travel * progress)
            .animation(.linear(duration: 0.1), value: progress)
            .frame(height: contentHeight > 0 ? min(height, contentHeight) : height, alignment: .top)
            .clipped()
            .mask(LinearGradient(stops: overflows
                ? [.init(color: progress > 0 ? .clear : .black, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 0.75), .init(color: .clear, location: 1)]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

/// Input level from −60 to 0 dBFS with a peak hold; ink while healthy, wax near the top, red when clipping.
struct LevelMeter: View {
    let level: Double
    let hold: Double

    private func x(_ db: Double) -> Double { min(1, max(0, (db + 60) / 60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.field)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(level > -1 ? Theme.tally : level > -12 ? Theme.wax : Theme.ink2)
                        .frame(width: w * x(level))
                        .animation(.linear(duration: 0.05), value: level)
                    Rectangle()
                        .fill(hold > -1 ? Theme.tally : Theme.ink)
                        .frame(width: 2)
                        .offset(x: max(0, w * x(hold) - 2))
                        .opacity(hold > -60 ? 1 : 0)
                }
            }
            .frame(height: 8)
            GeometryReader { geo in
                ForEach([-48, -36, -24, -12, -6, 0], id: \.self) { db in
                    Text("\(db)")
                        .font(Typeface.font(10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: min(geo.size.width - 6, geo.size.width * x(Double(db))), y: 6)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level.rounded())) dB")
    }
}
