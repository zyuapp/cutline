import CryptoKit
import Foundation
import Security

/// Downloads newer Cutline releases next to the installed app and swaps them in while the app is closed.
/// The preview app and the MCP server share this, so whichever runs first fetches the update and the swap
/// happens at a moment nobody watches: when the app quits, or before the server launches it.
public enum ReleaseUpdate {
    public static let repository = "zyuapp/cutline"
    public static let bundleIdentifier = "com.zyuapp.cutline"

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// The app bundle that contains `executable`, when it is a signed app that may update itself.
    public static func installedApp(containing executable: URL) -> URL? {
        var url = executable.resolvingSymlinksInPath()
        for _ in 0..<4 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return team(of: url) == nil ? nil : url }
        }
        return nil
    }

    public static func version(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// The newest release tag on GitHub, without its leading "v".
    public static func latest() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Release: Decodable { let tag_name: String }
        return try JSONDecoder().decode(Release.self, from: data).tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }

    static func stagingRoot(for app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(".cutline-update", isDirectory: true)
    }

    /// A verified download waiting to replace `app`, when it is newer than what is installed.
    public static func staged(for app: URL) -> (version: String, url: URL)? {
        let installed = version(of: app) ?? "0"
        let root = stagingRoot(for: app)
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return versions
            .filter { $0.first?.isNumber == true && isNewer($0, than: installed) }
            .sorted { isNewer($0, than: $1) }
            .first
            .map { ($0, root.appendingPathComponent($0).appendingPathComponent("Cutline.app")) }
            .flatMap { FileManager.default.fileExists(atPath: $0.1.path) ? $0 : nil }
    }

    /// Checks GitHub and downloads a newer release beside `app`. Returns the version ready to install, if any.
    @discardableResult
    public static func fetch(for app: URL) async throws -> String? {
        let latest = try await latest()
        guard isNewer(latest, than: version(of: app) ?? "0") else { return nil }
        if let ready = staged(for: app), ready.version == latest { return latest }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw Failure("Cutline can't update itself in \(app.deletingLastPathComponent().path). Run the install script again.")
        }
        let base = URL(string: "https://github.com/\(repository)/releases/download/v\(latest)/")!
        let (zip, _) = try await URLSession.shared.download(from: base.appendingPathComponent("Cutline.zip"))
        defer { try? FileManager.default.removeItem(at: zip) }
        let (sumData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("Cutline.zip.sha256"))
        let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure("The download did not match its checksum.") }

        let root = stagingRoot(for: app)
        let tmp = root.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path])
        guard let signer = team(of: app), team(of: tmp.appendingPathComponent("Cutline.app")) == signer else {
            throw Failure("The update is not signed by the same developer.")
        }
        // The rename publishes the download whole; a concurrent fetch that lost the race keeps the winner's copy.
        let dest = root.appendingPathComponent(latest, isDirectory: true)
        let moved = try withLock(app) { (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil }
        if moved != true, staged(for: app)?.version != latest { throw Failure("The update could not be staged.") }
        return latest
    }

    /// Replaces `app` with the staged update now. Call only while neither the app nor another server from it runs.
    /// Returns nil when nothing is staged or another process is installing.
    @discardableResult
    public static func install(into app: URL) throws -> String? {
        guard staged(for: app) != nil else { return nil }
        return try withLock(app) { () throws -> String? in
            guard let ready = staged(for: app) else { return nil }
            let fm = FileManager.default
            let backup = stagingRoot(for: app).appendingPathComponent("previous-\(UUID().uuidString).app")
            try fm.moveItem(at: app, to: backup)
            do {
                try fm.moveItem(at: ready.url, to: app)
            } catch {
                try? fm.moveItem(at: backup, to: app)
                throw error
            }
            try? fm.removeItem(at: ready.url.deletingLastPathComponent())
            try? fm.removeItem(at: backup)
            return ready.version
        } ?? nil
    }

    /// Runs `body` holding the staging lock, or returns nil when another process holds it.
    static func withLock<T>(_ app: URL, _ body: () throws -> T) throws -> T? {
        let root = stagingRoot(for: app)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return try body()
    }

    /// True when a process other than this one runs an executable inside `app`, such as another Claude session's server.
    public static func othersRunning(from app: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", app.appendingPathComponent("Contents/MacOS/").path]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return true }
        p.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        return pids.contains { $0 != me }
    }

    public enum Relaunch {
        case none
        /// Opens the app in front, on `project` when given.
        case foreground(project: URL?)
        /// Opens the app on `project` behind other windows, passing `--quiet`.
        case background(project: URL?)
    }

    /// Installs the staged update once process `pid` exits, then reopens the app as `relaunch` says.
    public static func installAfterExit(of pid: Int32, into app: URL, relaunch: Relaunch) throws {
        guard let ready = staged(for: app) else { return }
        let backup = stagingRoot(for: app).appendingPathComponent("previous-\(UUID().uuidString).app")
        let project: URL?
        let reopen: String
        switch relaunch {
        case .none: project = nil; reopen = ""
        case .foreground(let p): project = p; reopen = p == nil ? "open \"$1\"" : "open -a \"$1\" \"$5\""
        case .background(let p): project = p; reopen = p == nil ? "open -g \"$1\" --args --quiet" : "open -g -a \"$1\" \"$5\" --args --quiet"
        }
        // lockf takes the same staging lock as `install` and `fetch`, so the swap never overlaps theirs.
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /usr/bin/lockf -k -t 60 "$6" /bin/sh -c 'if mv "$1" "$3" && mv "$2" "$1"; then rm -rf "$4" "$3"; else [ -e "$1" ] || mv "$3" "$1"; fi' sh "$1" "$2" "$3" "$4"
        \(reopen)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", app.path, ready.url.path, backup.path, ready.url.deletingLastPathComponent().path, project?.path ?? "", stagingRoot(for: app).appendingPathComponent(".lock").path]
        try p.run()
    }

    /// The Team ID of a valid signature, or nil for unsigned and ad-hoc code.
    public static func team(of url: URL) -> String? {
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

    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("The update could not be unpacked.") }
    }
}
