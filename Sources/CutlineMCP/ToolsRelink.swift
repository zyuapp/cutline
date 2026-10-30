import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerRelinkTool() {
        add(Tool(name: "media_relink", description: "Relink every offline media item at once from a folder searched recursively: by file name (the same name, then the same name with another extension), and by reel and timecode (candidates are probed; one whose reel is the media's and whose timecode covers the source time its clips play). Matched files are probed and replace the offline items in one undoable step, clips keeping their source timecode; the report lists each match, how it matched, and what is still missing.", schema: Schema.object([
            "folder": Schema.string("Folder to search, recursively"),
            "match": Schema.string("name, reel_tc, or both (default: by name first, then reel and timecode for the rest)", values: ["name", "reel_tc", "both"]),
        ], required: ["folder"])) { [unowned self] args in
            _ = try session.requireBundle()
            let folder = session.resolve(try args.string("folder"))
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw EditError("No folder at \(folder.path)") }
            let mode = args.optString("match") ?? "both"
            guard ["name", "reel_tc", "both"].contains(mode) else { throw EditError("match is name, reel_tc or both") }
            let before = try session.project()
            let missing = before.missingMedia { FileManager.default.fileExists(atPath: $0) }
            guard !missing.isEmpty else { return .text("No offline media; nothing to relink.") }
            let files = Project.files(under: [folder]).filter { Toolbox.mediaExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }

            var found: [(old: MediaAsset, path: String, probed: MediaAsset?, how: String)] = []
            var left = missing
            if mode != "reel_tc" {
                let index = RelinkIndex(files)
                for m in left {
                    guard let path = index.match(m) else { continue }
                    found.append((m, path, await Toolbox.probeForRelink(path, id: m.id), "file name"))
                }
                left.removeAll { m in found.contains { $0.old.id == m.id } }
            }
            var probedCount = 0
            if mode != "name", left.contains(where: { $0.timecodeStart != nil }) {
                var candidates: [MediaAsset] = []
                for (i, path) in files.enumerated() where !found.contains(where: { $0.path == path }) {
                    if let c = await Toolbox.probeForRelink(path, id: "candidate\(i)"), c.timecodeStart != nil, c.reel != nil { candidates.append(c) }
                }
                probedCount = files.count
                for m in left {
                    guard let c = before.reelTimecodeMatch(m, candidates: candidates) else { continue }
                    var probed = c
                    probed.id = m.id
                    found.append((m, c.path, probed, "reel \(c.reel ?? "") timecode \(c.timecodeString() ?? "")"))
                }
                left.removeAll { m in found.contains { $0.old.id == m.id } }
            }
            guard !found.isEmpty else {
                return .text("Nothing relinked: \(files.count) media file(s) under \(folder.path), none matching" + (mode == "name" ? " by file name" : mode == "reel_tc" ? " by reel and timecode" : " by file name, or by reel and timecode") + ".\nStill offline: " + left.map { Toolbox.offlineLabel($0) }.joined(separator: ", "))
            }
            let p = try session.edit(found.count == 1 ? "Relink \(found[0].old.id)" : "Relink \(found.count) media") { p in
                for f in found {
                    if let probed = f.probed, let old = p.mediaAsset(f.old.id) {
                        p.replaceMediaKeepingTimecode(Session.relinked(old, to: probed))
                    } else {
                        p.relink(mediaId: f.old.id, to: f.path)
                    }
                }
            }
            let transcodes = try await transcodeRelinked(found.map(\.old.id))
            var lines = ["Relinked \(found.count) of \(missing.count) offline media from \(folder.path)" + (probedCount > 0 ? " (\(probedCount) file(s) probed for reel and timecode)" : "") + ":"]
            for f in found {
                let moved = p.mediaAsset(f.old.id).flatMap { new in f.old.timecodeStart.flatMap { a in new.timecodeStart.map { b in a - b } } }.flatMap { abs($0) > 1e-6 ? $0 : nil }
                lines.append("  \(f.old.id) → \(f.path) (by \(f.how)" + (moved.map { ", clips moved \(fmt2($0))s in the file to keep their source timecode" } ?? "") + ")")
            }
            if !left.isEmpty { lines.append("Still offline (\(left.count)): " + left.map { Toolbox.offlineLabel($0) }.joined(separator: ", ")) }
            return .text(lines.joined(separator: "\n") + transcodes.map { "\n" + $0 }.joined() + "\n" + footer(p))
        })
    }

    /// "a001 (A001C003.mov, reel A001, TC 10:00:00:00)".
    static func offlineLabel(_ m: MediaAsset) -> String {
        var parts = [URL(fileURLWithPath: m.conformPath).lastPathComponent]
        if let r = m.reel { parts.append("reel \(r)") }
        if let tc = m.timecodeString() { parts.append("TC \(tc)") }
        return "\(m.id) (\(parts.joined(separator: ", ")))"
    }

    /// The file as import would read it: AVFoundation, else ffprobe for files macOS can't play. Nil when neither can.
    /// A timecoded file whose reel AVFoundation doesn't see takes ffprobe's (container or stream reel_name tags).
    static func probeForRelink(_ path: String, id: String) async -> MediaAsset? {
        let url = URL(fileURLWithPath: path)
        let ffprobe = FFmpeg.tools()?.ffprobe
        if var m = try? await MediaProbe.probe(url, id: id) {
            if m.reel == nil, m.timecodeStart != nil, let ffprobe, let info = try? await FFmpeg.probe(url, ffprobe: ffprobe) { m.reel = info.reel }
            return m
        }
        guard let ffprobe, let info = try? await FFmpeg.probe(url, ffprobe: ffprobe) else { return nil }
        return MediaIngest.placeholder(url, id: id, info: info)
    }
}
