import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CutlineCore
import Foundation

/// Broadcast leader before the program: SMPTE color bars with 1 kHz tone at −20 dBFS, a slate card,
/// then black with a one-frame 2-pop two seconds before the program. Lengths are whole seconds of
/// nominal frames, so the program lands on a whole timecode second.
public struct Leader: Sendable {
    public var barsSeconds: Int
    public var slateSeconds: Int
    public var blackSeconds: Int
    public var pop: Bool
    public var title: String
    /// Label and value rows printed on the slate.
    public var slate: [SlateLine]

    public struct SlateLine: Sendable {
        public var label: String
        public var value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public static let toneHz = 1000.0
    public static let toneDbfs = -20.0

    public init(barsSeconds: Int = 10, slateSeconds: Int = 10, blackSeconds: Int = 10, pop: Bool = true, title: String = "", slate: [SlateLine] = []) {
        self.barsSeconds = barsSeconds
        self.slateSeconds = slateSeconds
        self.blackSeconds = blackSeconds
        self.pop = pop
        self.title = title
        self.slate = slate
    }

    public var totalSeconds: Int { barsSeconds + slateSeconds + blackSeconds }

    public func frames(_ tc: TimecodeFormat) -> Int { totalSeconds * tc.nominal }

    /// Frame index of the 2-pop, nil when off or the black is shorter than two seconds.
    func popFrame(_ tc: TimecodeFormat) -> Int? {
        guard pop, blackSeconds >= 2 else { return nil }
        return frames(tc) - 2 * tc.nominal
    }

    // MARK: Pictures

    /// SMPTE EG 1 color bars in full-range RGB: 75% bars, reverse castellations, then −I, 100% white, +Q
    /// and a PLUGE (black, black, +4%).
    public static func bars(width: Int, height: Int) -> CGImage? {
        draw(width: width, height: height) { ctx in
            let w = Double(width), h = Double(height)
            let v = 191.0 / 255
            let top: [(Double, Double, Double)] = [(v, v, v), (v, v, 0), (0, v, v), (0, v, 0), (v, 0, v), (v, 0, 0), (0, 0, v)]
            let mid: [(Double, Double, Double)] = [(0, 0, v), (0, 0, 0), (v, 0, v), (0, 0, 0), (0, v, v), (0, 0, 0), (v, v, v)]
            let bar = w / 7
            // CG's origin is the bottom left: the bottom band is y 0…h/4.
            let bottomH = h * 0.25, midH = h * 0.08, topH = h - bottomH - midH
            func fill(_ c: (Double, Double, Double), _ r: CGRect) {
                ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
                ctx.fill(r.integral)
            }
            for i in 0..<7 {
                fill(top[i], CGRect(x: Double(i) * bar, y: bottomH + midH, width: bar + 1, height: topH))
                fill(mid[i], CGRect(x: Double(i) * bar, y: bottomH, width: bar + 1, height: midH))
            }
            let wide = bar * 5 / 4
            let bottom: [(Double, Double, Double)] = [(0, 33.0 / 255, 76.0 / 255), (1, 1, 1), (50.0 / 255, 0, 106.0 / 255), (0, 0, 0)]
            for (i, c) in bottom.enumerated() { fill(c, CGRect(x: Double(i) * wide, y: 0, width: wide + 1, height: bottomH)) }
            let pluge: [Double] = [0, 0, 10.0 / 255]
            for (i, l) in pluge.enumerated() { fill((l, l, l), CGRect(x: 5 * bar + Double(i) * bar / 3, y: 0, width: bar / 3 + 1, height: bottomH)) }
            fill((0, 0, 0), CGRect(x: 6 * bar, y: 0, width: bar + 1, height: bottomH))
        }
    }

    /// The slate card: title, then label/value rows, white on dark gray.
    public func slateImage(width: Int, height: Int) -> CGImage? {
        Leader.draw(width: width, height: height) { ctx in
            let h = Double(height), w = Double(width)
            ctx.setFillColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let left = w * 0.12
            var y = h * 0.78
            Leader.text(title.isEmpty ? "Untitled" : title, size: h * 0.075, bold: true, at: CGPoint(x: left, y: y), ctx)
            y -= h * 0.11
            for line in slate {
                Leader.text(line.label.uppercased(), size: h * 0.032, bold: false, gray: 0.6, at: CGPoint(x: left, y: y), ctx)
                Leader.text(line.value, size: h * 0.04, bold: true, at: CGPoint(x: left + w * 0.22, y: y), ctx)
                y -= h * 0.06
            }
        }
    }

    /// One frame of countdown: a white "2" in a ring.
    public static func popImage(width: Int, height: Int) -> CGImage? {
        draw(width: width, height: height) { ctx in
            let h = Double(height), w = Double(width)
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.setLineWidth(h * 0.012)
            let r = h * 0.3
            ctx.strokeEllipse(in: CGRect(x: w / 2 - r, y: h / 2 - r, width: 2 * r, height: 2 * r))
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, h * 0.4, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, h * 0.4, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "2", attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)]))
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: w / 2 - b.midX, y: h / 2 - b.midY)
            CTLineDraw(line, ctx)
        }
    }

    public static func black(width: Int, height: Int) -> CGImage? {
        draw(width: width, height: height) { ctx in
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func text(_ s: String, size: Double, bold: Bool, gray: Double = 1, at p: CGPoint, _ ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: gray, alpha: 1)]))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        // Device RGB keeps code values exact: 75% bars stay 191.
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        body(ctx)
        return ctx.makeImage()
    }

    // MARK: Samples

    /// Video samples for the whole leader, timed from zero in frames of `tc`.
    func videoSamples(width: Int, height: Int, space: WorkingSpace, tc: TimecodeFormat) throws -> [CMSampleBuffer] {
        let format = ColorManagement.pixelFormat(space)
        func buffer(_ image: CGImage?) throws -> CVPixelBuffer {
            guard let image else { throw EditError("Cannot draw the leader") }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
            guard let pb else { throw EditError("Cannot allocate a leader frame") }
            Leader.ciContext.render(CIImage(cgImage: image), to: pb, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
            ColorManagement.tag(pb, space)
            return pb
        }
        let bars = try buffer(Leader.bars(width: width, height: height))
        let slate = try buffer(slateImage(width: width, height: height))
        let black = try buffer(Leader.black(width: width, height: height))
        let pop = popFrame(tc)
        let popBuffer = pop == nil ? nil : try buffer(Leader.popImage(width: width, height: height))
        let barsEnd = barsSeconds * tc.nominal, slateEnd = barsEnd + slateSeconds * tc.nominal
        var out: [CMSampleBuffer] = []
        for f in 0..<frames(tc) {
            let pb = f < barsEnd ? bars : f < slateEnd ? slate : (f == pop ? popBuffer ?? black : black)
            out.append(try Leader.sample(pb, frame: f, tc))
        }
        return out
    }

    static func sample(_ pb: CVPixelBuffer, frame: Int, _ tc: TimecodeFormat) throws -> CMSampleBuffer {
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { throw EditError("Cannot describe a leader frame") }
        let step = CMTime(value: CMTimeValue(tc.frameNum), timescale: CMTimeScale(tc.frameDen))
        var timing = CMSampleTimingInfo(duration: step, presentationTimeStamp: CMTimeMultiply(step, multiplier: Int32(frame)), decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &out)
        guard let out else { throw EditError("Cannot create a leader frame") }
        return out
    }

    /// Interleaved float PCM at 48 kHz: tone under the bars, silence under the slate and black, and one
    /// frame of tone for the 2-pop. Every channel but LFE carries the tone.
    func audioSamples(layout: AudioLayout, tc: TimecodeFormat) throws -> [CMSampleBuffer] {
        let rate = 48_000.0
        let channels = layout.channelCount
        let total = Int((tc.seconds(frames(tc)) * rate).rounded())
        let barsEnd = Int((tc.seconds(barsSeconds * tc.nominal) * rate).rounded())
        let popRange: Range<Int>? = popFrame(tc).map { f in
            Int((tc.seconds(f) * rate).rounded())..<Int((tc.seconds(f + 1) * rate).rounded())
        }
        let amp = Float(pow(10, Leader.toneDbfs / 20))
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        let layoutData = layout.channelLayoutData
        let status = layoutData.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: layout == .stereo ? 0 : raw.count,
                                           layout: layout == .stereo ? nil : raw.baseAddress?.assumingMemoryBound(to: AudioChannelLayout.self),
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        }
        guard status == noErr, let fd else { throw EditError("Cannot describe the leader tone (\(status))") }
        var out: [CMSampleBuffer] = []
        let chunk = 4800
        var start = 0
        while start < total {
            let n = min(chunk, total - start)
            var pcm = [Float](repeating: 0, count: n * channels)
            for i in 0..<n {
                let s = start + i
                guard s < barsEnd || popRange?.contains(s) == true else { continue }
                let v = amp * Float(sin(2 * Double.pi * Leader.toneHz * Double(s) / rate))
                for c in 0..<channels where c != layout.lfeChannel { pcm[i * channels + c] = v }
            }
            let bytes = pcm.count * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw EditError("Cannot allocate the leader tone") }
            pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: n, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample else { throw EditError("Cannot create the leader tone") }
            out.append(sample)
            start += n
        }
        return out
    }

    nonisolated(unsafe) static let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
}

/// A QuickTime timecode track ('tmcd') of one sample.
public enum TimecodeTrack {
    static func formatDescription(_ tc: TimecodeFormat) throws -> CMTimeCodeFormatDescription {
        var fd: CMTimeCodeFormatDescription?
        let flags = (tc.dropFrame ? kCMTimeCodeFlag_DropFrame : 0) | kCMTimeCodeFlag_24HourMax
        let status = CMTimeCodeFormatDescriptionCreate(allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32, frameDuration: CMTime(value: CMTimeValue(tc.frameNum), timescale: CMTimeScale(tc.frameDen)),
                                                       frameQuanta: UInt32(tc.nominal), flags: flags, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else { throw EditError("Cannot describe the timecode track (\(status))") }
        return fd
    }

    /// A big-endian frame number at time zero lasting `duration`.
    static func sample(startFrame: Int, duration: CMTime, _ fd: CMTimeCodeFormatDescription) throws -> CMSampleBuffer {
        var value = Int32(startFrame).bigEndian
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { throw EditError("Cannot allocate a timecode sample") }
        CMBlockBufferReplaceDataBytes(with: &value, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { throw EditError("Cannot create a timecode sample") }
        return sample
    }

    /// The start label of a file's first timecode track, e.g. "01:00:00:00", nil without one.
    public static func read(_ url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .timecode).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        guard reader.startReading() else { return nil }
        let found = try await runBlocking { _ -> (CMBlockBuffer, CMFormatDescription)? in
            var found: (CMBlockBuffer, CMFormatDescription)?
            // Edit-boundary markers come first and carry no data.
            while found == nil, let sample = out.nextSample() {
                if let block = CMSampleBufferGetDataBuffer(sample), let fd = CMSampleBufferGetFormatDescription(sample) { found = (block, fd) }
            }
            reader.cancelReading()
            return found
        }
        guard let (block, fd) = found else { return nil }
        var raw: Int32 = 0
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw)
        let frame = Int(Int32(bigEndian: raw))
        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fd))
        let drop = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fd) & kCMTimeCodeFlag_DropFrame != 0
        let fps = drop ? Double(quanta) * 1000 / 1001 : Double(quanta)
        let format = TimecodeFormat(fps: fps, dropFrame: drop)
        return format.nominal == quanta && format.dropFrame == drop ? format.string(frame) : nil
    }
}
