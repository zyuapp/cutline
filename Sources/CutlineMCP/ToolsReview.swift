import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerReviewTools() {
        add(Tool(name: "comments_list", description: "Read the human's feedback from the preview app. Each comment is pinned to a timeline time and sometimes a point on the frame (shown as a red ring on the attached frames). Check this at the start of every turn and after the human says they left notes. Resolve each one with comment_reply once handled.", schema: Schema.object([
            "status": Schema.string("open (default), resolved or all", values: ["open", "resolved", "all"]),
            "frames": Schema.bool("Attach the current frame at each comment, default true"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let status = args.optString("status") ?? "open"
            let file = b.loadComments()
            session.seenNotes.formUnion(file.humanMarks.map(\.key))
            session.deliveredNotes.formUnion(file.humanMarks.map(\.key))
            let comments = file.comments
                .filter { status == "all" || $0.status.rawValue == status }
                .sorted { $0.time < $1.time }
            guard !comments.isEmpty else { return .text("No \(status == "all" ? "" : status + " ")comments.") }
            return try await describeComments(comments, frames: args.bool("frames", default: true))
        })

        add(Tool(name: "comments_wait", description: "Wait for the human's next note in the preview, so they keep reviewing without going back to Claude Code. The preview shows them Claude is watching. Returns notes still waiting for your reply (with frames, like comments_list) as soon as there are any, when the human closes the preview, or at the timeout; then call it again. Call it after each round of changes and preview_seek, until the human clicks Done or Export in the preview (\"\(ReviewDone.text)\" / \"\(ReviewDone.exportText)\").", schema: Schema.object([
            "timeout": Schema.number("Seconds to wait, default 90, at most 3600"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let timeout = args.optDouble("timeout") ?? 90
            guard timeout > 0, timeout <= 3600 else { throw EditError("timeout is 1…3600 seconds") }
            let watchesPreview = Session.opensPreviewOnDemand
            let projectURL = b.url
            func previewGone() -> Bool { watchesPreview && !Session.previewShows(projectURL) }
            // Other tool calls may run while this polls; the gate comes back before touching the session again.
            let yields = session.callerHoldsGate
            if yields { await session.gate.release() }
            // A preview that project_create or preview_seek just launched gets a moment to load.
            let grace = Date().addingTimeInterval(10)
            while previewGone(), Date() < grace, !Task.isCancelled { try? await Task.sleep(nanoseconds: 250_000_000) }
            if previewGone() {
                if yields { await session.gate.acquire() }
                return .text("The preview is closed, so the human isn't reviewing. Stop waiting; preview_seek reopens it when you have something new to show.")
            }
            let me = ProcessInfo.processInfo.processIdentifier
            let deadline = Date().addingTimeInterval(timeout)
            var refreshed = Date()
            b.writePresence(AgentPresence(pid: me, listening: true))
            var notes: [Comment] = []
            var closed = false
            var away = false
            while Date() < deadline, !Task.isCancelled {
                if previewGone() { closed = true; break }
                if !b.loadComments().awaitingReply.isEmpty {
                    // A short settle so a note typed in two quick parts arrives together.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    notes = b.loadComments().awaitingReply
                    break
                }
                if watchesPreview, Toolbox.humanIdle(projectURL) > Toolbox.awayAfter { away = true; break }
                if Date().timeIntervalSince(refreshed) > 30 {
                    refreshed = Date()
                    b.writePresence(AgentPresence(pid: me, listening: true))
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if yields { await session.gate.acquire() }
            if !notes.isEmpty {
                let marks = b.loadComments().humanMarks.map(\.key)
                session.seenNotes.formUnion(marks)
                session.deliveredNotes.formUnion(marks)
            }
            guard !notes.isEmpty else {
                if closed || Task.isCancelled { b.writePresence(nil) }
                if closed { return .text("The human closed the preview. Stop waiting; preview_seek reopens it when you have something new to show.") }
                if away {
                    b.writePresence(nil)
                    return .text("The human hasn't touched the preview in \(Int(Toolbox.awayAfter / 60)) minutes. Stop waiting; the preview tells them to say \"check my notes\" when they're back.")
                }
                if Task.isCancelled { return .text("Stopped waiting because Claude Code cancelled the call.") }
                // Presence stays up briefly so the preview keeps saying Claude is watching between calls.
                return .text("No new notes yet. Call comments_wait again to keep watching, unless the human asked you for something else.")
            }
            b.writePresence(AgentPresence(pid: me, listening: false, working: notes.map(\.id)))
            let last = Set(notes.map { $0.replies.last?.text ?? $0.text })
            var result = try await describeComments(notes, frames: true)
            let head: String
            if last.contains(ReviewDone.exportText) {
                head = "The human approved the cut and wants it exported. Address any other notes below, then export the deliverable the human asked for at the start (or a high-quality H.264 MP4 of the timeline into the project's exports folder) without asking, comment_reply to their note with the file name, and stop waiting. The preview shows the export with Play and Show in Finder.\n"
            } else if last.contains(ReviewDone.text) {
                head = "The human is done reviewing for now. Address any other notes below, comment_reply to their note with a one-line summary of the session, and stop waiting. Don't ask follow-up questions in the terminal unless something blocks you.\n"
            } else {
                head = "\(notes.count) note(s) waiting for your reply. Address each, comment_reply to resolve it, preview_seek to the change, then comments_wait again:\n"
            }
            result.content[0] = ["type": "text", "text": .string(head + (result.content[0]["text"]?.string ?? ""))]
            return result
        })
        registerCommentReplyTools()
    }

    /// Seconds without the human pausing, scrubbing or writing a note, after which comments_wait stops.
    nonisolated(unsafe) static var awayAfter: Double = 1800

    /// Seconds since the human last paused or moved the preview playhead, or wrote a note or reply.
    static func humanIdle(_ project: URL) -> Double {
        var last = Date.distantPast
        if let data = try? Data(contentsOf: project.appendingPathComponent("preview.json")),
           let j = try? JSONDecoder().decode(JSON.self, from: data),
           let t = j["updatedAt"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }) { last = t }
        for c in ProjectBundle(url: project).loadComments().comments {
            if c.author == .human { last = max(last, c.createdAt) }
            for r in c.replies where r.author == .human { last = max(last, r.createdAt) }
        }
        return Date().timeIntervalSince(last)
    }

    /// Comment threads as text, with the frame at each note when `frames`.
    func describeComments(_ comments: [Comment], frames: Bool) async throws -> ToolResult {
        let history = try session.requireBundle().loadHistory()
        var lines: [String] = []
        for c in comments {
            var line = "\(c.id) @ \(fmt2(c.time))s"
            if let x = c.x, let y = c.y { line += " point (\(fmt2(x)), \(fmt2(y)))" }
            line += " [\(c.status.rawValue)] \(c.author.rawValue): \(c.text)"
            if let h = c.historyId, h != history.current?.id { line += "  (made on \(h); timeline changed since)" }
            lines.append(line)
            for r in c.replies { lines.append("    ↳ \(r.author.rawValue): \(r.text)") }
        }
        var result = ToolResult.text(lines.joined(separator: "\n"))
        if frames {
            let built = try await session.timeline()
            let p = built.scene.project
            if p.duration > 0 {
                let shown = Array(comments.prefix(12))
                let cell = Toolbox.cellWidth(width: p.canvas.width, height: p.canvas.height, count: shown.count)
                var frames = try await Frames.timeline(built, times: shown.map(\.time), maxSize: CGSize(width: cell * 1.5, height: cell * 1.5))
                for (i, c) in shown.enumerated() where i < frames.count {
                    frames[i].label = "\(c.id) \(fmt2(c.time))s"
                    if let x = c.x, let y = c.y, let marked = Toolbox.ring(on: frames[i].image, x: x, y: y) { frames[i].image = marked }
                }
                if let jpeg = Frames.contactSheet(frames, cellWidth: cell) { result.addImage(jpeg) }
            }
        }
        return result
    }

    func registerCommentReplyTools() {
        add(Tool(name: "comment_reply", description: "Reply to a comment in the preview app, typically saying what you changed, and resolve it.", schema: Schema.object([
            "comment_id": Schema.string("Comment id"),
            "text": Schema.string("Reply shown to the human"),
            "resolve": Schema.bool("Mark resolved, default true"),
        ], required: ["comment_id", "text"])) { [unowned self] args in
            let b = try session.requireBundle()
            let id = try args.string("comment_id")
            let text = try args.string("text")
            let resolve = args.bool("resolve", default: true)
            try b.updateComments { f in
                guard let i = f.comments.firstIndex(where: { $0.id == id }) else { throw EditError("No comment \(id)") }
                f.comments[i].replies.append(CommentReply(author: .agent, text: text))
                if resolve { f.comments[i].status = .resolved }
            }
            if var presence = b.loadPresence(), presence.working.contains(id) {
                presence.working.removeAll { $0 == id }
                b.writePresence(presence.working.isEmpty && !presence.listening ? nil : presence)
            }
            return .text("Replied to \(id)" + (resolve ? " and resolved it" : ""))
        })

        add(Tool(name: "comment_add", description: "Leave a note for the human at a timeline time, e.g. a question about a cut or a choice you want them to review.", schema: Schema.object([
            "at": Schema.time("Timeline time"),
            "text": Schema.string("Note"),
        ], required: ["at", "text"])) { [unowned self] args in
            let b = try session.requireBundle()
            let c = Comment(time: try args.time("at"), text: try args.string("text"), author: .agent, historyId: b.loadHistory().current?.id)
            try b.updateComments { $0.comments.append(c) }
            return .text("Added \(c.id)")
        })
    }

    static func ring(on image: CGImage, x: Double, y: Double) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let r = Double(min(w, h)) * 0.07
        let center = CGPoint(x: x * Double(w), y: (1 - y) * Double(h))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1))
        ctx.setLineWidth(max(3, r * 0.18))
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        return ctx.makeImage()
    }
}
