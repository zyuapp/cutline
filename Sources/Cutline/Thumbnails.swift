import AVFoundation
import CutlineCore
import ImageIO
import Observation

/// Small frames of each media file for the timeline filmstrip.
@MainActor
@Observable
final class Thumbnails {
    struct Strip {
        var interval: Double
        var images: [CGImage?]
    }

    private(set) var strips: [String: Strip] = [:]
    /// Bumped as frames arrive so the timeline redraws.
    private(set) var revision = 0
    @ObservationIgnored private var started: Set<String> = []

    func prepare(_ media: [MediaAsset]) {
        for m in media where m.hasVideo && !started.contains(m.path) {
            started.insert(m.path)
            if m.isImage {
                loadImage(m)
            } else {
                generate(m)
            }
        }
    }

    func image(mediaPath: String, at t: Double) -> CGImage? {
        guard let s = strips[mediaPath], !s.images.isEmpty else { return nil }
        let i = min(max(0, Int(t / s.interval)), s.images.count - 1)
        return s.images[i] ?? s.images[..<i].last { $0 != nil } ?? nil
    }

    private func loadImage(_ m: MediaAsset) {
        let url = m.url
        Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { return }
            await MainActor.run {
                self.strips[m.path] = Strip(interval: .infinity, images: [img])
                self.revision += 1
            }
        }
    }

    private func generate(_ m: MediaAsset) {
        let interval = max(0.5, m.duration / 240)
        let count = max(1, Int(m.duration / interval))
        strips[m.path] = Strip(interval: interval, images: Array(repeating: nil, count: count))
        let url = m.url
        let path = m.path
        Task.detached(priority: .utility) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 192, height: 108)
            gen.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)
            let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * interval, preferredTimescale: 600) }
            var batch: [(Int, CGImage)] = []
            var index = 0
            for await result in gen.images(for: times) {
                if let img = try? result.image { batch.append((index, img)) }
                index += 1
                if batch.count >= 12 || index == count {
                    let ready = batch
                    batch.removeAll()
                    await MainActor.run {
                        for (i, img) in ready where i < self.strips[path]?.images.count ?? 0 { self.strips[path]?.images[i] = img }
                        self.revision += 1
                    }
                }
            }
        }
    }
}
