import AppKit
import CutlineCore
import CutlineEngine
import Foundation

public enum PreviewControl {
    public static let notification = Notification.Name("com.zyuapp.cutline.control")
    public static let bundleIdentifier = "com.zyuapp.cutline"
}

/// State shared by tool calls within one MCP connection.
final class Session {
    var bundle: ProjectBundle?
    let library = MediaLibrary()
    private var built: (project: Project, transcripts: Int, timeline: BuiltTimeline)?

    static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent.json")
    }

    static var recentProjects: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: stateURL))) ?? []
    }

    func open(_ url: URL) throws -> ProjectBundle {
        guard ProjectBundle.isBundle(url) else { throw EditError("No Cutline project at \(url.path)") }
        let b = ProjectBundle(url: url)
        bundle = b
        built = nil
        var recent = Session.recentProjects.filter { $0 != url.path }
        recent.insert(url.path, at: 0)
        try? JSONEncoder().encode(Array(recent.prefix(10))).write(to: Session.stateURL)
        return b
    }

    func requireBundle() throws -> ProjectBundle {
        if let bundle { return bundle }
        var hint = "No project is open. Call project_create or project_open first."
        if let last = Session.recentProjects.first { hint += " Most recent project: \(last)" }
        throw EditError(hint)
    }

    func project() throws -> Project {
        try requireBundle().loadProject()
    }

    /// Applies an edit and records it as one history entry.
    @discardableResult
    func edit(_ label: String, _ body: (inout Project) throws -> Void) throws -> Project {
        let b = try requireBundle()
        var p = try b.loadProject()
        let before = p
        try body(&p)
        guard p != before else { return p }
        try b.commit(p, label: label)
        return p
    }

    func stems() throws -> AudioStems {
        AudioStems(directory: try requireBundle().cacheURL.appendingPathComponent("stems", isDirectory: true))
    }

    /// The current timeline with every audio-effect stem rendered, as export will hear it.
    func timeline() async throws -> BuiltTimeline {
        let b = try requireBundle()
        let p = try b.loadProject()
        return try await timeline(for: p)
    }

    func timeline(for p: Project) async throws -> BuiltTimeline {
        let b = try requireBundle()
        let transcripts = b.transcripts(for: p)
        if let built, built.project == p, built.transcripts == transcripts.count, built.timeline.missingStems.isEmpty { return built.timeline }
        let stems = try stems()
        try await stems.renderMissing(p, transcripts: transcripts, library: library)
        let t = try await TimelineBuilder.build(p, transcripts: transcripts, library: library, stems: stems)
        built = (p, transcripts.count, t)
        return t
    }

    func resolve(_ path: String, relativeTo base: URL? = nil) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        let root = base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return root.appendingPathComponent(expanded).standardizedFileURL
    }

    // MARK: Analysis

    func analyze(_ media: MediaAsset, transcript: Bool, audio: Bool, scenes: Bool, language: String) async throws -> String {
        let b = try requireBundle()
        var notes: [String] = []
        if media.hasAudio && (audio || transcript) {
            try FileManager.default.createDirectory(at: b.cacheURL, withIntermediateDirectories: true)
            let pcm = b.cacheURL.appendingPathComponent("\(media.id).caf")
            defer { try? FileManager.default.removeItem(at: pcm) }
            let a = try await AudioAnalyzer.analyze(media: media, pcmURL: transcript ? pcm : nil)
            try b.saveAudioAnalysis(a)
            let long = a.silences.filter { $0.duration >= 0.5 }
            notes.append("audio: loudness \(String(format: "%.1f", a.loudnessDb)) dB, \(long.count) pauses ≥0.5s totaling \(fmt1(long.map(\.duration).reduce(0, +)))s")
            if transcript {
                do {
                    let raw = try await Transcriber.transcribe(pcmURL: pcm, mediaId: media.id, locale: language)
                    let t = Transcriber.tighten(raw, audio: a)
                    try b.saveTranscript(t)
                    let fillers = t.words.filter(\.isFiller).count
                    notes.append("transcript: \(t.words.count) words, \(fillers) fillers")
                } catch {
                    notes.append("transcript failed: \(error.localizedDescription)")
                }
            }
        }
        if scenes && media.hasVideo && !media.isImage {
            let cuts = try await SceneDetector.detect(media)
            try b.saveVisualAnalysis(VisualAnalysis(mediaId: media.id, sceneCuts: cuts))
            notes.append("scenes: \(cuts.count) cuts")
        }
        built = nil
        return notes.joined(separator: "; ")
    }

    // MARK: Preview app

    func appURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["CUTLINE_APP"] { return URL(fileURLWithPath: env) }
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<4 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: PreviewControl.bundleIdentifier)
    }

    func openPreview() throws -> String {
        let b = try requireBundle()
        guard let app = appURL() else { return "Cutline.app was not found; install it to /Applications or set CUTLINE_APP." }
        let p = Process()
        if app.pathExtension == "app" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app.path, b.url.path]
        } else {
            // A bare development build of the preview executable.
            p.executableURL = app
            p.arguments = [b.url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        try p.run()
        if app.pathExtension == "app" {
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw EditError("Could not open \(app.path); macOS refused to launch it. Run Cutline.app once from Finder, or set CUTLINE_APP.") }
        }
        return "Preview opened in \(app.lastPathComponent)."
    }

    func sendPreview(_ info: [String: Any]) throws {
        let b = try requireBundle()
        var payload = info
        payload["project"] = b.url.path
        DistributedNotificationCenter.default().postNotificationName(PreviewControl.notification, object: nil, userInfo: payload, deliverImmediately: true)
    }
}

func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
