import AVFoundation
import AudioToolbox
import CutlineCore
import Foundation

/// An installed Audio Unit effect.
public struct PluginInfo: Sendable, Codable, Equatable {
    /// `au.<manufacturer>.<subtype>.<type>` four-character codes, e.g. `au.appl.dely.aufx`. Codes with
    /// characters outside printable ASCII (or a dot) are written as `0x` and eight hex digits.
    public var id: String
    public var name: String
    public var manufacturer: String
    /// `effect` or `music_effect`.
    public var type: String
    public var version: String
    /// Made by Apple and installed with macOS.
    public var apple: Bool
}

/// One parameter of a plug-in.
public struct PluginParam: Codable, Sendable, Equatable {
    /// Key path in the parameter tree; the key `makeUnit` expects.
    public var id: String
    public var identifier: String
    public var address: UInt64
    public var name: String
    public var unit: String
    public var min: Double
    public var max: Double
    /// The value right after the plug-in loads.
    public var defaultValue: Double
    /// Step names of an indexed parameter, for values `min`, `min + 1`, …
    public var values: [String]?
    public var writable: Bool
}

/// Finds, loads, configures and renders third-party (and Apple) Audio Unit effects.
public enum AudioUnitHost {
    static let types: [(OSType, String)] = [(kAudioUnitType_Effect, "effect"), (kAudioUnitType_MusicEffect, "music_effect")]

    /// Every installed effect and music effect, Apple's included, sorted by manufacturer and name.
    public static func installedEffects() -> [PluginInfo] {
        let manager = AVAudioUnitComponentManager.shared()
        return types.flatMap { type, label in
            manager.components(matching: AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)).map { c in
                let d = c.audioComponentDescription
                return PluginInfo(id: id(for: d), name: c.name, manufacturer: c.manufacturerName, type: label, version: c.versionString, apple: d.componentManufacturer == kAudioUnitManufacturer_Apple)
            }
        }.sorted { ($0.manufacturer, $0.name, $0.id) < ($1.manufacturer, $1.name, $1.id) }
    }

    public static func id(for d: AudioComponentDescription) -> String {
        "au.\(code(d.componentManufacturer)).\(code(d.componentSubType)).\(code(d.componentType))"
    }

    /// The component description an id names; throws for malformed ids.
    public static func description(for id: String) throws -> AudioComponentDescription {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "au", let m = osType(parts[1]), let s = osType(parts[2]), let t = osType(parts[3]) else {
            throw EditError("\"\(id)\" is not a plug-in id; expected au.<manufacturer>.<subtype>.<type>, as installedEffects lists")
        }
        return AudioComponentDescription(componentType: t, componentSubType: s, componentManufacturer: m, componentFlags: 0, componentFlagsMask: 0)
    }

    static func code(_ v: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ (0x21...0x7E).contains($0) && $0 != UInt8(ascii: ".") }) { return String(decoding: bytes, as: UTF8.self) }
        return String(format: "0x%08x", v)
    }

    static func osType(_ s: String) -> OSType? {
        if s.hasPrefix("0x") { return OSType(s.dropFirst(2), radix: 16) }
        let b = Array(s.utf8)
        guard b.count == 4 else { return nil }
        return b.reduce(0) { $0 << 8 | OSType($1) }
    }

    /// Loads a plug-in. Third-party units load out of process when they support it, so a crash cannot take the
    /// host down; Apple's load in process.
    public static func instantiate(id: String) async throws -> AVAudioUnit {
        let d = try description(for: id)
        guard AVAudioUnitComponentManager.shared().components(matching: d).contains(where: { $0.audioComponentDescription.componentType == d.componentType }) else {
            throw EditError("No installed plug-in \(id); installedEffects lists them")
        }
        if d.componentManufacturer != kAudioUnitManufacturer_Apple, let u = try? await AVAudioUnit.instantiate(with: d, options: .loadOutOfProcess) {
            return u
        }
        return try await AVAudioUnit.instantiate(with: d, options: [])
    }

    public static func parameters(of id: String) async throws -> [PluginParam] {
        let unit = try await instantiate(id: id)
        return (unit.auAudioUnit.parameterTree?.allParameters ?? []).map(describe)
    }

    static func describe(_ p: AUParameter) -> PluginParam {
        var values: [String]?
        if p.unit == .indexed || p.unit == .boolean, let names = p.valueStrings, !names.isEmpty { values = names }
        return PluginParam(
            id: p.keyPath, identifier: p.identifier, address: p.address, name: p.displayName, unit: unitName(p),
            min: Double(p.minValue), max: Double(p.maxValue), defaultValue: Double(p.value), values: values,
            writable: p.flags.contains(.flag_IsWritable)
        )
    }

    static func unitName(_ p: AUParameter) -> String {
        switch p.unit {
        case .decibels: "dB"
        case .hertz: "Hz"
        case .milliseconds: "ms"
        case .seconds: "seconds"
        case .percent: "%"
        case .cents, .absoluteCents: "cents"
        case .relativeSemiTones: "semitones"
        case .octaves: "octaves"
        case .degrees, .phase: "degrees"
        case .boolean: "on/off"
        case .indexed: "choice"
        case .linearGain: "gain"
        case .ratio: "ratio"
        case .rate: "rate"
        case .pan: "pan"
        case .BPM: "BPM"
        case .beats: "beats"
        case .sampleFrames: "samples"
        case .meters: "meters"
        case .midiNoteNumber: "MIDI note"
        case .customUnit: p.unitName ?? ""
        default: ""
        }
    }

    /// Factory preset names.
    public static func presets(of id: String) async throws -> [String] {
        let unit = try await instantiate(id: id)
        return unit.auAudioUnit.factoryPresets?.map(\.name) ?? []
    }

    /// A loaded plug-in with `preset` applied, then `params` (keyed by key path, identifier, address or display
    /// name). Values outside a parameter's range throw. Attach it to one engine at a time.
    public static func makeUnit(id: String, params: [String: Double], preset: String?) async throws -> AVAudioUnit {
        let unit = try await instantiate(id: id)
        try configure(unit, params: params, preset: preset)
        return unit
    }

    public static func configure(_ unit: AVAudioUnit, params: [String: Double], preset: String?) throws {
        let au = unit.auAudioUnit
        if let preset, !preset.isEmpty {
            let all = au.factoryPresets ?? []
            guard let p = all.first(where: { $0.name.caseInsensitiveCompare(preset) == .orderedSame }) else {
                throw EditError("\(unit.name) has no preset \"\(preset)\"; presets: \(all.map(\.name).joined(separator: ", "))")
            }
            au.currentPreset = p
        }
        let tree = au.parameterTree?.allParameters ?? []
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            guard let p = parameter(key, in: tree) else {
                throw EditError("\(unit.name) has no parameter \"\(key)\"; parameters: \(tree.map(\.keyPath).joined(separator: ", "))")
            }
            guard Float(value) >= p.minValue - 1e-4 * abs(p.minValue), Float(value) <= p.maxValue + 1e-4 * abs(p.maxValue) else {
                throw EditError("\(unit.name) \(p.displayName) (\(p.keyPath)) takes \(p.minValue)…\(p.maxValue), not \(value)")
            }
            p.value = Swift.min(Swift.max(Float(value), p.minValue), p.maxValue)
        }
    }

    static func parameter(_ key: String, in tree: [AUParameter]) -> AUParameter? {
        tree.first { $0.keyPath == key } ?? tree.first { $0.identifier == key } ?? tree.first { String($0.address) == key }
            ?? tree.first { $0.displayName.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Renders deinterleaved float (one or two channels) through `units` in order with AVAudioEngine offline
    /// manual rendering. Reported latency is trimmed from the start and `tail` seconds of silence are flushed
    /// through, so the result is `tail` seconds longer than the input and time-aligned with it. Blocks; units
    /// are reset first and detached afterwards, and must not be attached to another engine.
    public static func render(_ x: [[Float]], sampleRate: Double, units: [AVAudioUnit], tail: Double = 1) throws -> [[Float]] {
        let n = x.first?.count ?? 0
        guard n > 0, !units.isEmpty else { return x }
        guard (1...2).contains(x.count), let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(x.count)) else {
            throw EditError("Plug-in rendering takes mono or stereo audio")
        }
        let engine = AVAudioEngine()
        let cursor = Cursor()
        let source = AVAudioSourceNode(format: format) { silence, _, frames, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let start = cursor.position, count = Int(frames)
            let available = Swift.max(0, Swift.min(count, n - start))
            for (c, b) in buffers.enumerated() {
                guard let out = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if available > 0 { x[Swift.min(c, x.count - 1)].withUnsafeBufferPointer { out.update(from: $0.baseAddress! + start, count: available) } }
                if available < count { (out + available).initialize(repeating: 0, count: count - available) }
            }
            if available == 0 { silence.pointee = true }
            cursor.position += count
            return noErr
        }
        engine.attach(source)
        var previous: AVAudioNode = source
        for u in units {
            u.reset()
            engine.attach(u)
            engine.connect(previous, to: u, format: format)
            previous = u
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        defer {
            engine.stop()
            for u in units { engine.detach(u) }
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        let latency = units.map(\.auAudioUnit.latency).reduce(0, +)
        var skip = Int((latency * sampleRate).rounded())
        let wanted = n + Int(Swift.max(tail, 0) * sampleRate)
        var out = [[Float]](repeating: [], count: x.count)
        for c in out.indices { out[c].reserveCapacity(wanted) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw EditError("Cannot allocate a render buffer")
        }
        var stalls = 0
        while out[0].count < wanted {
            let need = wanted - out[0].count + skip
            let status = try engine.renderOffline(AVAudioFrameCount(Swift.min(Int(buffer.frameCapacity), need)), to: buffer)
            Heartbeat.beat()
            switch status {
            case .success: stalls = 0
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalls += 1
                if stalls > 100 { throw EditError("Plug-in rendering stalled") }
                continue
            case .error: throw EditError("Plug-in rendering failed")
            @unknown default: throw EditError("Plug-in rendering failed")
            }
            let got = Int(buffer.frameLength)
            let drop = Swift.min(skip, got)
            skip -= drop
            guard got > drop else { continue }
            let channels = Int(buffer.format.channelCount)
            for c in out.indices {
                let p = buffer.floatChannelData![Swift.min(c, channels - 1)]
                out[c].append(contentsOf: UnsafeBufferPointer(start: p + drop, count: got - drop))
            }
        }
        return out.map { Array($0.prefix(wanted)) }
    }

    final class Cursor: @unchecked Sendable {
        var position = 0
    }
}
