import Foundation

/// Cutline's registration with Claude Code, read from ~/.claude.json and written through the claude CLI.
enum ClaudeCode {
    /// The MCP server inside this app, or the installed one when running a development build.
    static var helper: String {
        Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cutline-mcp").path
            : "/Applications/Cutline.app/Contents/MacOS/cutline-mcp"
    }

    /// True when the user-scope MCP config in ~/.claude.json has a cutline server.
    static var isConnected: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any]
        else { return false }
        return servers["cutline"] != nil
    }

    /// The claude CLI: the usual install locations, then whatever an interactive login shell finds on PATH.
    static func cli() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let hit = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: hit) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Registers `server` as the user-scope cutline MCP server. Returns an error message on failure.
    static func connect(server: String) async -> String? {
        await Task.detached {
            guard let claude = cli() else { return "Claude Code wasn't found. Install it, then click Connect again, or run the command in Terminal." }
            // npm installs are `#!/usr/bin/env node` scripts; a login shell's PATH finds node where the app's doesn't.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-ilc", "\"$0\" mcp add -s user cutline -- \"$1\"", claude.path, server]
            p.standardInput = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = [claude.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            p.environment = env
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return nil }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "claude exited with status \(p.terminationStatus)" : text
        }.value
    }
}
