import AppKit
import CutlineCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@main
struct CutlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Open Project…") { AppModel.shared.showOpenPanel() }.keyboardShortcut("o")
                }
                CommandGroup(after: .sidebar) {
                    Button(AppModel.shared.showPanel ? "Hide Notes and History" : "Show Notes and History") { AppModel.shared.showPanel.toggle() }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(AppModel.shared.doc == nil)
                }
                CommandMenu("Playback") {
                    Button("Play/Pause") { AppModel.shared.doc?.player.togglePlay() }
                    Button("Add Note") { AppModel.shared.startNote() }
                    Button("Zoom Timeline to Fit") { AppModel.shared.fitRequest += 1 }.keyboardShortcut("0")
                    Button("Go to Last Change") { AppModel.shared.doc?.jumpToLastChange() }.keyboardShortcut("l", modifiers: [.command, .option])
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        showMainWindow()
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if AppModel.shared.doc == nil, let path = args.first {
            AppModel.shared.open(URL(fileURLWithPath: path))
        }
        AppModel.shared.installKeyMonitor()
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppModel.shared.open(url) }
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.toolbarStyle = .unified
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            w.title = "Cutline"
            w.minSize = NSSize(width: 960, height: 620)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: RootView(model: AppModel.shared).preferredColorScheme(.dark))
            host.sceneBridgingOptions = [.toolbars, .title]
            w.contentView = host
            w.setFrameAutosaveName("CutlineMain")
            if !w.setFrameUsingName("CutlineMain") { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var doc: ProjectDocument?
    var error: String?
    var pinning = false
    var draft: DraftNote?
    var tab: PanelTab = .notes
    var showPanel = true
    var selectedComment: String?
    var fitRequest = 0
    @ObservationIgnored private var monitor: Any?

    var recent: [String] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/recent.json")
        let paths = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
        return paths.filter { ProjectBundle.isBundle(URL(fileURLWithPath: $0)) }
    }

    func open(_ url: URL) {
        guard doc?.url.standardizedFileURL != url.standardizedFileURL else { return }
        guard ProjectBundle.isBundle(url) else {
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            let media = UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
            error = media
                ? "\(url.lastPathComponent) is a video, not a Cutline project. Ask Claude to edit it, for example: “Make a 60-second cut of \(path) with captions.”"
                : "\(url.lastPathComponent) is not a Cutline project. Open a .cutline folder that Claude created."
            return
        }
        do {
            doc?.close()
            doc = try ProjectDocument(url: url)
            error = nil
            draft = nil
            pinning = false
            selectedComment = nil
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            self.error = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .cutline project"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func startNote() {
        guard let doc else { return }
        doc.player.pause()
        tab = .notes
        showPanel = true
        draft = nil
        pinning = true
    }

    /// Transport keys work everywhere except while typing.
    func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let doc = self.doc else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if doc.recording != nil {
                guard event.keyCode == 53 else { return event }
                doc.closeRecording()
                return nil
            }
            let shift = event.modifierFlags.contains(.shift)
            if event.modifierFlags.contains(.command) { return event }
            switch event.keyCode {
            case 49: doc.player.togglePlay()
            case 123: doc.player.step(frames: shift ? -Int(doc.player.fps) : -1)
            case 124: doc.player.step(frames: shift ? Int(doc.player.fps) : 1)
            case 115: doc.player.pause(); doc.player.seek(0)
            case 119: doc.player.pause(); doc.player.seek(doc.player.duration)
            case 36, 76:
                if self.pinning {
                    self.draft = DraftNote(time: doc.player.time)
                    self.pinning = false
                } else { return event }
            case 53:
                if self.pinning { self.pinning = false } else if self.draft != nil { self.draft = nil } else { return event }
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": self.startNote()
                case "j": doc.player.shuttle(doc.player.player.rate < 0 ? doc.player.player.rate * 2 : -1)
                case "k": doc.player.pause()
                case "l": doc.player.shuttle(doc.player.player.rate > 0 ? min(doc.player.player.rate * 2, 8) : 1)
                default: return event
                }
            }
            return nil
        }
    }
}
