import Foundation

/// Per media: whether the preview plays a lightweight proxy instead of the camera file.
public enum ProxyMode: String, Codable, Sendable, CaseIterable {
    /// A proxy is made for heavy footage (over 2560 px, over 60 fps, 10-bit long GOP) and played once made.
    case auto
    /// A proxy is made and played even for light footage.
    case always
    /// The preview always plays the original.
    case never
}

/// Project-wide: what the preview plays.
public enum PlaybackMode: String, Codable, Sendable, CaseIterable {
    /// Each media's `ProxyMode` decides.
    case auto
    /// Every video plays a proxy (made for all of them) unless its media says never.
    case proxy
    /// The preview plays originals, as export does.
    case original
}

/// Proxy picture size.
public enum ProxySize: String, Codable, Sendable, CaseIterable {
    case half, quarter
    /// Fits 1920×1080.
    case hd = "1080"
    /// Fits 1280×720.
    case sd = "720"
}

public struct Playback: Codable, Equatable, Sendable {
    public var mode: PlaybackMode
    public var proxySize: ProxySize

    public init(mode: PlaybackMode = .auto, proxySize: ProxySize = .half) {
        self.mode = mode
        self.proxySize = proxySize
    }
}

extension Project {
    /// The playback settings, defaults when unset.
    public var playbackSettings: Playback { playback ?? Playback() }

    /// Whether the preview plays `m`'s proxy when one is made.
    public func previewUsesProxy(_ m: MediaAsset) -> Bool {
        guard m.hasVideo, !m.isImage, m.proxy != .never else { return false }
        return playbackSettings.mode != .original
    }

    /// Whether a proxy of `m` should be made; `heavy` is whether the footage is hard to play (see `Proxies.shouldProxy`).
    public func wantsProxy(_ m: MediaAsset, heavy: Bool) -> Bool {
        guard previewUsesProxy(m) else { return false }
        return m.proxy == .always || playbackSettings.mode == .proxy || heavy
    }
}
