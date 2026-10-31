import AVFoundation
import AppKit
import CutlineCore
import CutlineEngine
import Observation

/// The open `.cutline` bundle as the preview sees it. The agent writes the files; this
/// watches them and rebuilds playback. The preview writes comments, and recorded takes under media/recordings.
@MainActor
@Observable
final class ProjectDocument {
    let url: URL
    let bundle: ProjectBundle
    let player = PlayerController()
    let thumbnails = Thumbnails()

    private(set) var project: Project
    private(set) var history = History()
    private(set) var comments: [Comment] = []
    private(set) var transcripts: [String: Transcript] = [:]
    private(set) var audio: [String: AudioAnalysis] = [:]
    private(set) var captions: [CaptionSegment] = []
    /// Caption blocks in their original case, for the timeline lane.
    private(set) var laneCaptions: [CaptionSegment] = []
    private(set) var buildError: String?
    /// Set briefly when an agent edit lands, for the tally light.
    private(set) var lastEditAt: Date?
    /// Analysis the MCP server is running in the background, e.g. "Analyzing shots of lake-tahoe 40%".
    private(set) var analysisStatus: String?
    private(set) var exportState: ExportState?
    /// The MCP server's note on whether Claude is waiting for the human's notes.
    private(set) var presence: AgentPresence?
    /// Clips added or changed by the latest edit, for a brief highlight on the timeline.
    private(set) var changedClips: Set<String> = []
    private(set) var changedAt: Date?
    /// The voice-over recording in progress, if the agent asked for one.
    var recording: VoiceOverController?

    struct ExportState: Equatable {
        var progress: Double
        var finishedPath: String?
        var failed = false
    }

    @ObservationIgnored private let library = MediaLibrary(proxyQuality: .half)
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var lastProjectData = Data()
    @ObservationIgnored private var lastCommentsData = Data()
    @ObservationIgnored private var lastHistoryData = Data()
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var controlObserver: NSObjectProtocol?
    @ObservationIgnored private var stateWrite: DispatchWorkItem?
    @ObservationIgnored private var presenceBeat: Timer?

    init(url: URL) throws {
        self.url = url
        bundle = ProjectBundle(url: url)
        project = try bundle.loadProject()
        player.restore(UserDefaults.standard.double(forKey: Self.playheadKey(url)))
        player.onPause = { [weak self] in self?.writePreviewState() }
        reload(force: true)
        watch()
        listen()
        writePreviewState()
        // While the human looks at the app or plays the cut, keep preview.json fresh so Claude knows they're there.
        presenceBeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive || self.player.isPlaying else { return }
                self.writePreviewState()
            }
        }
    }

    static func playheadKey(_ url: URL) -> String { "playhead:" + url.standardizedFileURL.path }

    func close() {
        UserDefaults.standard.set(player.time, forKey: Self.playheadKey(url))
        presenceBeat?.invalidate()
        stateWrite?.cancel()
        try? FileManager.default.removeItem(at: url.appendingPathComponent("preview.json"))
        watchers.forEach { $0.cancel() }
        if let controlObserver { DistributedNotificationCenter.default().removeObserver(controlObserver) }
        player.pause()
    }

    // MARK: Loading

    func reload(force: Bool = false) {
        let projectData = (try? Data(contentsOf: bundle.projectURL)) ?? Data()
        let historyData = (try? Data(contentsOf: bundle.historyURL)) ?? Data()
        let commentsData = (try? Data(contentsOf: bundle.commentsURL)) ?? Data()

        if commentsData != lastCommentsData {
            lastCommentsData = commentsData
            comments = bundle.loadComments().comments.sorted { $0.time < $1.time }
        }
        if historyData != lastHistoryData {
            let first = lastHistoryData.isEmpty
            lastHistoryData = historyData
            history = bundle.loadHistory()
            if !first {
                lastEditAt = Date()
                if exportState?.finishedPath != nil || exportState?.failed == true { exportState = nil }
            }
        }
        analysisStatus = Self.jobsSummary(url.appendingPathComponent("jobs.json"))
        let agent = bundle.loadPresence()
        if agent != presence { presence = agent }
        if exportState == nil || exportState?.finishedPath != nil, let record = bundle.loadExportRecord(), record.isCurrent(history: history) {
            let state = ExportState(progress: record.state == .finished ? 1 : 0, finishedPath: record.state == .finished ? record.path : nil, failed: record.state == .failed)
            if state != exportState, record.state != .started || record.isLive { exportState = state }
        }
        let analysisChanged = loadAnalysis()
        guard force || projectData != lastProjectData || analysisChanged else { return }
        lastProjectData = projectData
        guard let p = try? bundle.loadProject() else { return }
        if !force {
            let before = Dictionary(project.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let changed = Set(p.tracks.flatMap(\.clips).filter { before[$0.id] != $0 }.map(\.id))
            if !changed.isEmpty {
                changedClips = changed
                changedAt = Date()
            }
        }
        project = p
        captions = p.captions.enabled ? p.captionSegments(transcripts: transcripts) : []
        var plain = p
        plain.captions.style.uppercase = false
        laneCaptions = p.captions.enabled ? plain.captionSegments(transcripts: transcripts) : []
        rebuild()
    }

    /// Returns true when transcripts or audio analysis changed.
    private func loadAnalysis() -> Bool {
        var t: [String: Transcript] = [:]
        var a: [String: AudioAnalysis] = [:]
        for m in project.media {
            if let x = transcripts[m.id] ?? bundle.transcript(m.id) { t[m.id] = x }
            if let x = audio[m.id] ?? bundle.audioAnalysis(m.id) { a[m.id] = x }
        }
        let changed = t.count != transcripts.count || a.count != audio.count
        transcripts = t
        audio = a
        return changed
    }

    private func rebuild() {
        buildTask?.cancel()
        let p = project
        let t = transcripts
        let lib = library
        let stems = AudioStems(directory: bundle.cacheURL.appendingPathComponent("stems", isDirectory: true))
        buildTask = Task { [weak self] in
            do {
                let built = try await TimelineBuilder.build(p, transcripts: t, library: lib, stems: stems)
                guard !Task.isCancelled, let self else { return }
                self.buildError = nil
                self.player.replaceItem(built.playerItem(), duration: built.duration, fps: p.canvas.fps)
                self.thumbnails.prepare(p.media)
                // Tracks with audio effects play dry until their processed stem is rendered.
                guard !built.missingStems.isEmpty else { return }
                try await stems.renderMissing(p, transcripts: t, library: lib)
                guard !Task.isCancelled else { return }
                let processed = try await TimelineBuilder.build(p, transcripts: t, library: lib, stems: stems)
                guard !Task.isCancelled else { return }
                self.player.replaceItem(processed.playerItem(), duration: processed.duration, fps: p.canvas.fps)
            } catch {
                self?.buildError = error.localizedDescription
            }
        }
    }

    static func jobsSummary(_ url: URL) -> String? {
        struct Job: Decodable { var mediaId: String; var features: [String]; var status: String; var progress: Double }
        guard let data = try? Data(contentsOf: url), let jobs = try? JSONDecoder().decode([Job].self, from: data) else { return nil }
        guard let job = jobs.first(where: { $0.status == "running" }) ?? jobs.first(where: { $0.status == "queued" }) else { return nil }
        let waiting = jobs.filter { $0.status == "queued" || $0.status == "running" }.count - 1
        return "Analyzing \(job.mediaId) \(Int(job.progress * 100))%" + (waiting > 0 ? " +\(waiting)" : "")
    }

    private func watch() {
        for dir in [url, bundle.analysisURL] {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleReload(analysis: dir != self?.url) }
            src.setCancelHandler { Darwin.close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    private func scheduleReload(analysis: Bool) {
        if analysis {
            transcripts.removeAll()
            audio.removeAll()
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: Agent control

    private func listen() {
        let path = url.path
        controlObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.zyuapp.cutline.control"), object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo, info["project"] as? String == path else { return }
            let action = info["action"] as? String
            let time = info["time"] as? Double
            let play = info["play"] as? Bool ?? false
            let end = info["end"] as? Double
            let state = info["state"] as? String
            let progress = info["progress"] as? Double
            let exportPath = info["path"] as? String
            let request = info["request"] as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                switch action {
                case "rebuild":
                    self.reload(force: true)
                case "reveal":
                    AppModel.shared.reveal()
                case "seek":
                    guard let time else { return }
                    if play { self.player.play(from: time, to: end) } else { self.player.pause(); self.player.seek(time) }
                    AppModel.shared.reveal()
                case "record":
                    guard let request else { return }
                    self.startRecording(URL(fileURLWithPath: request))
                case "export":
                    switch state {
                    case "started": self.exportState = ExportState(progress: 0)
                    case "progress": self.exportState = ExportState(progress: progress ?? 0)
                    case "finished": self.exportState = ExportState(progress: 1, finishedPath: exportPath)
                    case "failed": self.exportState = ExportState(progress: 0, failed: true)
                    default: break
                    }
                default: break
                }
            }
        }
    }

    /// Lets the agent ask where the human is looking.
    func writePreviewState() {
        stateWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let t = self.player.time
            let clips = self.project.tracks.reversed().compactMap { track -> String? in
                track.clip(at: t).map { "\(track.id):\($0.id)" }
            }
            let state: [String: Any] = [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "playhead": (t * 1000).rounded() / 1000,
                "playing": self.player.isPlaying,
                "visibleClips": clips,
                "historyId": self.history.current?.id ?? "",
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.url.appendingPathComponent("preview.json"), options: .atomic)
            }
        }
        stateWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Comments

    /// Moves the playhead to the start of what the last edit changed.
    func jumpToLastChange() {
        let starts = project.tracks.flatMap(\.clips).filter { changedClips.contains($0.id) }.map(\.start)
        guard let t = starts.min() else { return }
        player.pause()
        player.seek(t)
    }

    func addComment(text: String, time: Double, x: Double?, y: Double?) {
        let c = Comment(time: time, x: x, y: y, text: text, author: .human, historyId: history.current?.id)
        try? bundle.updateComments { $0.comments.append(c) }
        reload()
    }

    /// Pins the note that tells Claude the human is done reviewing, and whether to export.
    func finishReview(export: Bool) {
        addComment(text: export ? ReviewDone.exportText : ReviewDone.text, time: player.time, x: nil, y: nil)
    }

    func setStatus(_ id: String, _ status: CommentStatus) {
        try? bundle.updateComments { f in
            if let i = f.comments.firstIndex(where: { $0.id == id }) { f.comments[i].status = status }
        }
        reload()
    }

    func deleteComment(_ id: String) {
        try? bundle.updateComments { $0.comments.removeAll { $0.id == id } }
        reload()
    }

    func reply(_ id: String, text: String) {
        try? bundle.updateComments { f in
            if let i = f.comments.firstIndex(where: { $0.id == id }) {
                f.comments[i].replies.append(CommentReply(author: .human, text: text))
                f.comments[i].status = .open
            }
        }
        reload()
    }

    var openComments: [Comment] { comments.filter { $0.status == .open } }

    /// Open notes where the human spoke last.
    var awaitingReply: [Comment] { CommentsFile(comments: comments).awaitingReply }
}
