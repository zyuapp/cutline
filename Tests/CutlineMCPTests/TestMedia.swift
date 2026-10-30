import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A 64×36 flat PNG.
func writePNG(_ url: URL) throws {
    let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

/// Three seconds of a 440 Hz tone, mono.
func writeTone(_ url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)!
    buffer.frameLength = 144_000
    for i in 0..<144_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
    try file.write(from: buffer)
}
