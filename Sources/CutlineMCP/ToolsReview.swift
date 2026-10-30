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
            let comments = b.loadComments().comments
                .filter { status == "all" || $0.status.rawValue == status }
                .sorted { $0.time < $1.time }
            guard !comments.isEmpty else { return .text("No \(status == "all" ? "" : status + " ")comments.") }
            let history = b.loadHistory()
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
            if args.bool("frames", default: true) {
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
        })

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
