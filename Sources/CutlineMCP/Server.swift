import AppKit
import CutlineCore
import CutlineUpdate
import Foundation

/// MCP over stdio: newline-delimited JSON-RPC 2.0.
public final class MCPServer {
    public static let version = "0.1.0"
    let toolbox = Toolbox()

    static let instructions = """
    Cutline is a video editor you drive entirely through these tools; a human watches the result in the Cutline preview app and leaves notes pinned to frames.

    Workflow:
    1. project_create (or project_open). The preview app opens automatically.
    2. media_import the files. Analysis gives word-level transcripts, pauses and scene cuts.
    3. Read before cutting: media_transcript (source time, with word ids) and media_frames to look at footage.
    4. Structure the edit: assemble the best takes, cut_silences, source_cut flubs, clip_add b-roll (track "new"), text_add titles, captions_set.
    5. Shape the look and sound with three general tools: param_set sets or animates any parameter by path (transform.scale, audio.volume, text.color, fx.<id>.<param>…); effect_add stacks effects (blur, color, glow, vignette, grain, masks, shadows…) on clips, tracks or adjustment layers; blend modes via param_set blend. catalog lists every effect, parameter, ease and anchor; catalog tool=<name> gives a tool's full manual.
    6. Verify every change: timeline_frames to see it, timeline_transcript for cuts, project_status (target=<clip> for its parameters). Use dry_run:true to preview risky edits and batch to make one undoable step. preview_seek shows the human what changed (it opens the preview if it's closed).
    7. Review loop: after each round of changes, preview_seek to the change, then call comments_wait. The human reviews in the preview and pins notes; comments_wait returns the notes waiting for your reply, with frames. Address each, comment_reply to resolve it, and call comments_wait again (also after a timeout) until the human clicks Done or Export, closes the preview, or asks you for something else. New notes are also appended to any tool result. Never ask the human to come back to the terminal to relay notes.
    8. export when the human is happy.

    Times are seconds or anchors that survive later edits: "<media>.w12" (a transcript word), "<clip>.end", "marker:<label>", "start", "end", each with optional +/- seconds. Arguments that are positions inside a media file (source_in, assemble segments, source_cut ranges) take word anchors in source time, or the media's own source timecode as "<media>@01:00:12:10" (media_list shows each file's TC and reel). Lengths are fractions of the frame height. Positions (text_x/text_y, text.x/y, generator x/y, transform.pos_x/pos_y) are fractions of the frame from the top left; transform.x/y are offsets of the clip's center from the frame center in frame widths/heights (0 centered, 0.5 on the right edge), so a corner logo is transform.pos_x 0.85, pos_y 0.15 (= transform.x 0.35, y -0.35).
    """

    public init() {}

    /// `runsJobsInWorker` runs background analysis in detached `<this executable> --worker <bundle>` processes,
    /// which outlive the server.
    public convenience init(runsJobsInWorker: Bool) {
        self.init()
        guard runsJobsInWorker else { return }
        JobBoard.workerExecutable = Bundle.main.executableURL.map(Self.pinnedWorker)
        Session.opensPreviewOnDemand = true
        toolbox.session.callerHoldsGate = true
        updatesApp = true
    }

    /// A copy of this server's binary for analysis workers, so an update that swaps the app bundle doesn't give
    /// this session's workers a different version than the server that queued them.
    static func pinnedWorker(_ exe: URL) -> URL {
        let exe = exe.resolvingSymlinksInPath()
        guard let app = ReleaseUpdate.installedApp(containing: exe), let version = ReleaseUpdate.version(of: app) else { return exe }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ReleaseUpdate.bundleIdentifier).appendingPathComponent("bin").appendingPathComponent(version)
        let copy = dir.appendingPathComponent(exe.lastPathComponent)
        if FileManager.default.isExecutableFile(atPath: copy.path) { return copy }
        let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.copyItem(at: exe, to: tmp)) != nil
        else { return exe }
        if (try? FileManager.default.moveItem(at: tmp, to: copy)) == nil { try? FileManager.default.removeItem(at: tmp) }
        return FileManager.default.isExecutableFile(atPath: copy.path) ? copy : exe
    }

    /// Fetches app updates in the background and installs them while the preview is closed.
    var updatesApp = false
    private let output = NSLock()
    /// A comments_wait call in flight and its request id; a cancel for it, or any other request, ends it.
    private var waiting: Task<Void, Never>?
    private var waitingId: JSON?
    private let waitLock = NSLock()
    private var waitReplied = false
    private var lastWaitEnded: Date?
    private var lastRequest = Date()
    /// Notes already pushed to a Claude Code channel, so each is pushed once.
    private var pushed: Set<String> = []

    private enum Event {
        case line(String)
        case tick
        case end
    }

    public func run() async {
        log("cutline-mcp \(Self.version) ready")
        if updatesApp { Task.detached { await Self.updateInBackground() } }
        let (events, sink) = AsyncStream<Event>.makeStream()
        let reader = Task.detached {
            do {
                for try await line in FileHandle.standardInput.bytes.lines { sink.yield(.line(line)) }
            } catch {
                FileHandle.standardError.write("[cutline] stdin error: \(error)\n".data(using: .utf8)!)
            }
            sink.yield(.end)
        }
        let ticker = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                sink.yield(.tick)
            }
        }
        defer { reader.cancel(); ticker.cancel() }
        for await event in events {
            switch event {
            case .line(let line):
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let msg = line.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) }
                if msg?["method"]?.string == "notifications/cancelled" {
                    if waiting != nil, msg?["params"]?["requestId"] == waitingId { await finishWait() }
                    continue
                }
                if msg?["id"] != nil, msg?["method"]?.string != "ping" { lastRequest = Date() }
                // Other calls run while a wait polls; the session gate keeps them from overlapping its reads.
                await handle(line)
            case .tick:
                if waiting != nil, waitLock.withLock({ waitReplied }) { await finishWait() }
                if waiting == nil {
                    expirePresence()
                    pushNewNotes()
                }
            case .end:
                await finishWait()
                return
            }
        }
    }

    private func finishWait() async {
        guard let w = waiting else { return }
        w.cancel()
        await w.value
        waiting = nil
        waitingId = nil
        lastWaitEnded = Date()
    }

    /// Takes down "watching" soon after the last wait ends without another, and "working on your note" once
    /// Claude has made no calls for five minutes, so the preview never claims Claude is there when it isn't.
    func expirePresence() {
        guard let b = toolbox.session.bundle, var p = b.loadPresence(), p.pid == ProcessInfo.processInfo.processIdentifier else { return }
        let before = p
        if p.listening, Date().timeIntervalSince(lastWaitEnded ?? .distantPast) > 60 { p.listening = false }
        if !p.working.isEmpty, Date().timeIntervalSince(lastRequest) > 300 { p.working = [] }
        guard p != before else { return }
        b.writePresence(p.listening || !p.working.isEmpty ? p : nil)
    }

    /// Sends notes the human pinned while Claude is idle to Claude Code as channel events, which start a turn when
    /// the session runs with `--dangerously-load-development-channels server:cutline`; other clients drop them.
    func pushNewNotes() {
        guard let b = toolbox.session.bundle else { return }
        let file = b.loadComments()
        let owed = Dictionary(file.humanMarks.map { ($0.comment.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        let skip = pushed.union(toolbox.session.deliveredNotes)
        let fresh = file.awaitingReply.filter { owed[$0.id].map { !skip.contains($0) } ?? false }
        guard !fresh.isEmpty else { return }
        pushed.formUnion(fresh.compactMap { owed[$0.id] })
        for c in fresh {
            let said = c.replies.last(where: { $0.author == .human })?.text ?? c.text
            let point = c.x.flatMap { x in c.y.map { " at (\(fmt2(x)), \(fmt2($0)))" } } ?? ""
            send(["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": [
                "content": .string("The human pinned a note in the Cutline preview at \(fmt2(c.time))s\(point): “\(said)”. Look with comments_list, change the edit, comment_reply to resolve it, then comments_wait for the next note."),
                "meta": ["comment_id": .string(c.id), "time": .string(fmt2(c.time)), "project": .string(b.url.lastPathComponent)],
            ]])
        }
    }

    static func updateInBackground() async {
        guard let exe = Bundle.main.executableURL, let app = ReleaseUpdate.installedApp(containing: exe) else { return }
        if !Session.previewRunning, !ReleaseUpdate.othersRunning(from: app) { try? ReleaseUpdate.install(into: app) }
        _ = try? await ReleaseUpdate.fetch(for: app)
    }

    func handle(_ line: String) async {
        guard let data = line.data(using: .utf8), let msg = try? JSONDecoder().decode(JSON.self, from: data) else {
            send(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        if let batch = msg.array {
            for m in batch { await dispatch(m) }
        } else {
            await dispatch(msg)
        }
    }

    func dispatch(_ msg: JSON) async {
        let id = msg["id"]
        let method = msg["method"]?.string ?? ""
        let params = msg["params"]
        guard let id, !id.isNull else { return }
        switch method {
        case "initialize":
            // Claude Code doesn't register channels on servers that negotiate 2026-07-28 or later.
            let requested = params?["protocolVersion"]?.string ?? "2025-06-18"
            let version = requested >= "2026-07-28" ? "2025-11-25" : requested
            reply(id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false], "experimental": ["claude/channel": [:]]],
                "serverInfo": ["name": "cutline", "title": "Cutline", "version": .string(Self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": .array(toolbox.definitions)])
        case "tools/call" where params?["name"]?.string == "comments_wait":
            let args = params?["arguments"]
            await finishWait()
            waitingId = id
            waitLock.withLock { waitReplied = false }
            waiting = Task { [toolbox] in
                let started = Date()
                await toolbox.session.gate.acquire()
                let result = await toolbox.call("comments_wait", args)
                await toolbox.session.gate.release()
                self.log("comments_wait \(result.isError ? "error" : "ok") \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                self.reply(id, result.json)
                self.waitLock.withLock { self.waitReplied = true }
            }
        case "tools/call":
            let name = params?["name"]?.string ?? ""
            let started = Date()
            await toolbox.session.gate.acquire()
            let result = await toolbox.call(name, params?["arguments"])
            await toolbox.session.gate.release()
            log("\(name) \(result.isError ? "error" : "ok") \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            reply(id, result.json)
        case "resources/list":
            reply(id, ["resources": []])
        case "prompts/list":
            reply(id, ["prompts": []])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(method)")]])
        }
    }

    func reply(_ id: JSON, _ result: JSON) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func send(_ msg: JSON) {
        var out = msg.encoded()
        out.append("\n")
        output.withLock { FileHandle.standardOutput.write(out.data(using: .utf8)!) }
    }

    func log(_ s: String) {
        FileHandle.standardError.write("[cutline] \(s)\n".data(using: .utf8)!)
    }
}
