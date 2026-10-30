import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// The file sync and level comparison read for `m`: the asked channel(s), else its analysis channel, else for
    /// multichannel files every channel with sound, else the media itself.
    func heard(_ m: MediaAsset, _ channel: String?) async throws -> URL {
        let routing = try channel.map { raw -> ChannelRouting in
            guard let r = ChannelRouting(rawValue: raw) else { throw EditError("channel is \(ChannelRouting.help)") }
            return r
        } ?? m.analysisChannel
        let b = try session.requireBundle()
        return try await SourceChannels.analysisSource(m, channel: routing, cache: b.cacheURL.appendingPathComponent("analysis-audio", isDirectory: true))?.url ?? m.url
    }

    /// Reads the source channels of media an edit names (media_id) when the project doesn't know them yet,
    /// so the edit can store them.
    func primeChannels(_ args: Args, _ p: Project) async {
        guard let id = args.optString("media_id"), let m = p.mediaAsset(id), m.audioChannels == nil, m.hasAudio, !m.isImage, !m.isTranscoding else { return }
        if let chs = await SourceChannels.describe(m.url) { session.probedChannels[id] = chs }
    }

    /// Stores channels read by `primeChannels` on the project's media.
    func fillChannels(_ p: inout Project, _ id: String) {
        guard let i = p.media.firstIndex(where: { $0.id == id }), p.media[i].audioChannels == nil, let chs = session.probedChannels[id] else { return }
        p.media[i].audioChannels = chs
    }
}
