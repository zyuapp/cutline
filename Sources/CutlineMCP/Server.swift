import CutlineCore
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
    6. Verify every change: timeline_frames to see it, timeline_transcript for cuts, project_status (target=<clip> for its parameters). Use dry_run:true to preview risky edits and batch to make one undoable step. preview_seek shows the human what changed.
    7. comments_list at the start of each turn; address each note, then comment_reply to resolve it.
    8. export when the human is happy.

    Times are seconds or anchors that survive later edits: "<media>.w12" (a transcript word), "<clip>.end", "marker:<label>", "start", "end", each with optional +/- seconds. Arguments that are positions inside a media file (source_in, assemble segments, source_cut ranges) take word anchors in source time, or the media's own source timecode as "<media>@01:00:12:10" (media_list shows each file's TC and reel). Lengths are fractions of the frame height; positions are fractions of the frame from the top left.
    """

    public init() {}

    public func run() async {
        log("cutline-mcp \(Self.version) ready")
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                await handle(line)
            }
        } catch {
            log("stdin error: \(error)")
        }
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
            let requested = params?["protocolVersion"]?.string ?? "2025-06-18"
            reply(id, [
                "protocolVersion": .string(requested),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cutline", "title": "Cutline", "version": .string(Self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": .array(toolbox.definitions)])
        case "tools/call":
            let name = params?["name"]?.string ?? ""
            let started = Date()
            let result = await toolbox.call(name, params?["arguments"])
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
        FileHandle.standardOutput.write(out.data(using: .utf8)!)
    }

    func log(_ s: String) {
        FileHandle.standardError.write("[cutline] \(s)\n".data(using: .utf8)!)
    }
}
