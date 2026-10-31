import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// Finds newer releases on GitHub and replaces this app with one, keeping the signing team.
/// Inactive in development builds, which are not app bundles.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case available(String)
        case installing(String)
        case failed(String)
    }

    static let repository = "zyuapp/cutline"

    private(set) var state: State = .idle
    @ObservationIgnored private var timer: Timer?

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let enabled = Bundle.main.bundleURL.pathExtension == "app" && Updater.team(of: Bundle.main.bundleURL) != nil

    var available: String? {
        if case .available(let v) = state { return v }
        return nil
    }

    func start() {
        guard enabled else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    /// Checks GitHub for a newer release. When `interactive`, reports the outcome in an alert.
    func check(interactive: Bool = false) async {
        guard enabled else {
            if interactive { alert("Updates are off in development builds.", detail: "Build with scripts/build-app.sh or install a release.") }
            return
        }
        if case .installing = state { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Release: Decodable { let tag_name: String }
            let latest = try JSONDecoder().decode(Release.self, from: data).tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if Self.isNewer(latest, than: current) {
                state = .available(latest)
                if interactive { promptInstall(latest) }
            } else {
                state = .idle
                if interactive { alert("Cutline \(current) is the latest version.") }
            }
        } catch {
            state = .idle
            if interactive { alert("Could not check for updates.", detail: error.localizedDescription) }
        }
    }

    /// Downloads the release, checks its checksum and signature, then swaps the bundle and relaunches.
    func install(_ version: String) async {
        state = .installing(version)
        do {
            let app = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
                throw UpdateError("Cutline can't replace itself in \(app.deletingLastPathComponent().path). Run the install script again.")
            }
            let base = URL(string: "https://github.com/\(Self.repository)/releases/download/v\(version)/")!
            let (zip, _) = try await URLSession.shared.download(from: base.appendingPathComponent("Cutline.zip"))
            let (sumData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("Cutline.zip.sha256"))
            let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError("The download did not match its checksum.") }

            // Unpack next to the app so the final move is a rename on the same volume.
            let staging = app.deletingLastPathComponent().appendingPathComponent(".cutline-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
            let fresh = staging.appendingPathComponent("Cutline.app")
            guard let team = Self.team(of: app), Self.team(of: fresh) == team else {
                try? FileManager.default.removeItem(at: staging)
                throw UpdateError("The update is not signed by the same developer.")
            }
            relaunch(replacing: app, with: fresh, staging: staging)
        } catch {
            let message = (error as? UpdateError)?.message ?? error.localizedDescription
            state = .failed(message)
            alert("Cutline could not update.", detail: message)
        }
    }

    func promptInstall(_ version: String) {
        let a = NSAlert()
        a.messageText = "Cutline \(version) is available"
        a.informativeText = "You have \(current). Cutline quits, updates and opens again."
        a.addButton(withTitle: "Update and Relaunch")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { Task { await install(version) } }
    }

    /// A shell waits for this process to exit, swaps the bundles, restoring the old one if the move fails, and reopens the app.
    private func relaunch(replacing app: URL, with fresh: URL, staging: URL) {
        let backup = staging.appendingPathComponent("previous.app")
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if mv "$1" "$3" && mv "$2" "$1"; then rm -rf "$4"; else [ -e "$1" ] || mv "$3" "$1"; fi
        open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", app.path, fresh.path, backup.path, staging.path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("The update could not be unpacked.") }
    }

    private func alert(_ message: String, detail: String = "") {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.runModal()
    }

    /// The Team ID of a valid signature, or nil for unsigned and ad-hoc code.
    static func team(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

private struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
