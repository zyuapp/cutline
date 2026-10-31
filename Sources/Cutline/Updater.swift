import AppKit
import CutlineUpdate
import Foundation
import Observation

/// Fetches newer releases in the background and installs them without asking: when Cutline quits, or by a quiet
/// relaunch onto the same project and playhead once the app has sat unused in the background.
/// Inactive in development builds, which are not signed app bundles.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        /// Downloaded and verified; installs when the app quits.
        case ready(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var idleTimer: Timer?
    /// Says whether the app may restart unnoticed right now.
    @ObservationIgnored var isIdle: () -> Bool = { false }

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let app = Bundle.main.executableURL.flatMap(ReleaseUpdate.installedApp(containing:))
    var enabled: Bool { app != nil }

    var ready: String? {
        if case .ready(let v) = state { return v }
        return nil
    }

    func start() {
        guard let app else { return }
        if let staged = ReleaseUpdate.staged(for: app) { state = .ready(staged.version) }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restartIfIdle() }
        }
    }

    private func restartIfIdle() {
        guard ready != nil, isIdle() else { return }
        installOnQuit(relaunch: .background(project: AppModel.shared.doc?.url))
        state = .idle
        NSApp.terminate(nil)
    }

    /// Fetches a newer release if there is one. When `interactive`, reports the outcome in an alert.
    func check(interactive: Bool = false) async {
        guard let app else {
            if interactive { alert("Updates are off in development builds.", detail: "Build with scripts/build-app.sh or install a release.") }
            return
        }
        if case .checking = state { return }
        let before = state
        state = .checking
        do {
            if let v = try await ReleaseUpdate.fetch(for: app) {
                state = .ready(v)
                if interactive { promptRestart(v) }
            } else {
                state = .idle
                if interactive { alert("Cutline \(current) is the latest version.") }
            }
        } catch {
            state = before
            if interactive { alert("Could not check for updates.", detail: error.localizedDescription) }
        }
    }

    /// Hands a downloaded update to a helper that swaps it in once this process exits.
    func installOnQuit(relaunch: ReleaseUpdate.Relaunch = .none) {
        guard let app, ready != nil else { return }
        try? ReleaseUpdate.installAfterExit(of: ProcessInfo.processInfo.processIdentifier, into: app, relaunch: relaunch)
    }

    private func promptRestart(_ version: String) {
        let a = NSAlert()
        a.messageText = "Cutline \(version) is ready"
        a.informativeText = "It installs the next time Cutline quits. Restart now to use it?"
        a.addButton(withTitle: "Restart Now")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            installOnQuit(relaunch: .foreground(project: AppModel.shared.doc?.url))
            state = .idle
            NSApp.terminate(nil)
        }
    }

    private func alert(_ message: String, detail: String = "") {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.runModal()
    }
}
