import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static let playbackArgs: [String: JSON] = [
        "playback": Schema.string("What the preview plays: auto (default; proxies of heavy footage once made), proxy (proxies of every video, made by media_analyze proxy:true) or original. Export always reads originals", values: PlaybackMode.allCases.map(\.rawValue)),
        "proxy_size": Schema.string("Proxy picture size: half (default), quarter, 1080 or 720", values: ProxySize.allCases.map(\.rawValue)),
    ]

    /// Applies playback and proxy_size; nil when neither is given.
    static func applyPlayback(_ p: inout Project, _ args: Args) throws -> String? {
        guard args.has("playback") || args.has("proxy_size") else { return nil }
        var pb = p.playbackSettings
        if let m = try args.enumValue("playback", PlaybackMode.self) { pb.mode = m }
        if let raw = args.optString("proxy_size") ?? args.optInt("proxy_size").map(String.init) {
            guard let s = ProxySize(rawValue: raw.replacingOccurrences(of: "p", with: "")) else { throw EditError("proxy_size is half, quarter, 1080 or 720") }
            pb.proxySize = s
        }
        p.playback = pb == Playback() ? nil : pb
        let missing = p.media.filter { p.wantsProxy($0, heavy: false) && Proxies.preview($0, in: p) == nil }.map(\.id)
        return "Preview plays " + (pb.mode == .original ? "originals" : "\(pb.mode == .proxy ? "proxies of every video" : "proxies where made (heavy footage)") at \(pb.proxySize.rawValue) size") + "; export always reads originals"
            + (missing.isEmpty || pb.mode != .proxy ? "" : ". Not made yet: \(missing.joined(separator: ", ")); media_analyze media_id:\"all\" proxy:true makes them")
    }

    /// The proxy column of media_list.
    static func proxyStatus(_ m: MediaAsset, _ p: Project) -> String {
        guard m.hasVideo, !m.isImage else { return "–" }
        if m.proxy == .never { return "never (original)" }
        if p.playbackSettings.mode == .original { return "off (playback original)" }
        let size = p.playbackSettings.proxySize.rawValue
        if Proxies.preview(m, in: p) != nil { return "\(size) ready" + (m.proxy == .always ? " (always)" : "") }
        return p.wantsProxy(m, heavy: max(m.width, m.height) > 2560 || m.fps > 60.5) ? "\(size) not made" : "original (light footage)"
    }

    /// media_analyze proxy:true: (re)makes each video's proxy at the project's proxy size.
    func rebuildProxies(_ ids: [String], _ p: Project) async throws -> [String] {
        var lines: [String] = []
        let quality = Proxies.Quality(p.playbackSettings.proxySize)
        for id in ids {
            guard let m = p.mediaAsset(id) else { throw EditError("No media \(id)") }
            guard m.hasVideo, !m.isImage else { lines.append("\(id): no video to proxy"); continue }
            if m.proxy == .never || p.playbackSettings.mode == .original { lines.append("\(id): made anyway, but the preview plays the original (\(m.proxy == .never ? "media_organize proxy:never" : "canvas_set playback:original"))") }
            try? FileManager.default.removeItem(at: Proxies.url(for: m, quality: quality))
            let made = try await Proxies.transcode(m, quality: quality)
            lines.append("\(id): proxy \(Int(made.size.width))×\(Int(made.size.height)) ProRes Proxy (\(String(format: "%.1f", made.realtimeFactor))× realtime); export uses the original")
        }
        try? session.sendPreview(["action": "rebuild"])
        return lines
    }
}
