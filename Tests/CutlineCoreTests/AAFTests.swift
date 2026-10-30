import Foundation
import Testing
@testable import CutlineCore

// Sample AAFs from Avid Media Composer (the OpenTimelineIO AAF adapter's test data) and pyaaf2's 512-byte-sector
// test file, compressed with LZFSE. Expected values follow the adapter's tests. AAF_SAMPLES=<dir> also checks
// every .aaf in a folder.

private func sample(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name + ".aaf", withExtension: "lzfse", subdirectory: "Fixtures/aaf"))
    return try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
}

private let samples = ["simple", "trims", "transitions", "timecode_test", "2997fps-DFTC", "one_audio_clip", "utf8", "multitrack",
                       "preflattened", "test_muted_clip", "marker-over-audio", "sector_size_512"]

private func extraSamples() -> [URL] {
    guard let dir = ProcessInfo.processInfo.environment["AAF_SAMPLES"] else { return [] }
    return ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "aaf" }.sorted { $0.path < $1.path }
}

private func importSample(_ name: String) throws -> ImportResult { try Importer.aaf(try sample(name), relativeTo: nil) }

private func frames(_ t: Seconds, _ fps: Double = 24) -> Int { Int((t * fps).rounded()) }

/// "start+duration@source" in frames, the source counted from the media's timecode as OTIO counts it.
private func timing(_ p: Project, _ t: Track) -> [String] {
    let fps = p.canvas.fps
    return t.clips.map { c in
        let tc = c.mediaId.flatMap(p.mediaAsset)?.timecodeStart ?? 0
        return "\(frames(c.start, fps))+\(frames(c.duration, fps))@\(frames(c.sourceIn + tc, fps))"
    }
}

/// Names a pid's storage after the file's own property definitions, for re-encoding real files.
private func propertyNames(_ doc: AAFDocument) -> (UInt16) -> String {
    var names = AAFMetaModel.shared.names
    for c in doc.metaDictionary?.objects(0x0003) ?? [] {
        for p in c.objects(0x0009) { if let pid = p.uint(0x000d), let n = p.string(0x0006) { names[UInt16(pid)] = n } }
    }
    return { names[$0] ?? "Property" }
}

// MARK: Compound file

@Test(arguments: samples) func everySampleParsesAsAValidCompoundFile(name: String) throws {
    let data = try sample(name)
    let layout = try CompoundFile.layout(data)
    #expect(layout.treeProblems().isEmpty, "\(name): \(layout.treeProblems().prefix(3))")
    #expect(layout.sectorProblems().isEmpty, "\(name): \(layout.sectorProblems().prefix(3))")
    #expect(layout.miniStreamCutoff == 4096 && layout.miniSectorShift == 6)
    // pyaaf2's test file and Media Composer's 29.97 DF export use 512-byte sectors, the rest 4096.
    #expect(["sector_size_512", "2997fps-DFTC"].contains(name) ? (layout.majorVersion == 3 && layout.sectorShift == 9 && layout.directorySectorCount == 0)
        : (layout.majorVersion == 4 && layout.sectorShift == 12))
    let cf = try CompoundFile(data: data)
    #expect(AUID(bytes: cf.root.clsid) == AAFDocument.rootClass)
    #expect(AAFDocument.isAAF(data))
    #expect(cf.root.child("Header-2") != nil && cf.root.child("MetaDictionary-1") != nil && cf.root.child("referenced properties") != nil)
}

@Test(arguments: samples) func compoundFilesRewriteToTheSameTree(name: String) throws {
    let original = try CompoundFile(data: try sample(name))
    for version: UInt16 in [3, 4] {
        var copy = original
        copy.majorVersion = version
        let bytes = copy.data()
        let layout = try CompoundFile.layout(bytes)
        #expect(layout.majorVersion == version && layout.sectorShift == (version == 4 ? 12 : 9))
        #expect(layout.treeProblems().isEmpty, "\(name) v\(version): \(layout.treeProblems().prefix(3))")
        #expect(layout.sectorProblems().isEmpty, "\(name) v\(version): \(layout.sectorProblems().prefix(3))")
        #expect(bytes.count % (version == 4 ? 4096 : 512) == 0)
        let back = try CompoundFile(data: bytes)
        #expect(back.root == original.root, "\(name) v\(version)")
        #expect(back.headerCLSID == original.headerCLSID)
    }
}

@Test func largeStreamsNeedDIFATSectorsAndReadBack() throws {
    // 9 MB in 512-byte sectors needs more FAT sectors than the header's 109 DIFAT slots.
    let big = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let small = Data("tiny".utf8)
    var root = CompoundFile.Entry(storage: "Root Entry")
    var folder = CompoundFile.Entry(storage: "folder", clsid: AUID("01234567-89ab-cdef-0123-456789abcdef").bytes)
    folder.children = (0..<40).map { CompoundFile.Entry(stream: "s\($0)", data: Data(repeating: UInt8($0), count: $0 * 97)) }
    root.children = [CompoundFile.Entry(stream: "big", data: big), CompoundFile.Entry(stream: "small", data: small), folder]
    for version: UInt16 in [3, 4] {
        let bytes = CompoundFile(root: root, majorVersion: version).data()
        let layout = try CompoundFile.layout(bytes)
        #expect(version == 3 ? layout.difatSectorCount > 0 : layout.difatSectorCount == 0)
        #expect(layout.fatSectorCount == UInt32(layout.difat.filter { $0 <= 0xFFFF_FFFA }.count))
        #expect(layout.treeProblems().isEmpty)
        #expect(layout.sectorProblems().isEmpty, "\(layout.sectorProblems().prefix(3))")
        let back = try CompoundFile(data: bytes)
        #expect(back.root.child("big")?.data == big && back.root.child("small")?.data == small)
        #expect(back.root.child("folder") == folder, "v\(version)")
    }
}

@Test func directoryOrderIsShorterNamesFirstThenCaseInsensitive() {
    #expect(CompoundFile.nameLess("Zz", "aaa"))
    #expect(CompoundFile.nameLess("abc", "ABD"))
    #expect(!CompoundFile.nameLess("ABC", "abc") && !CompoundFile.nameLess("abc", "ABC"))
}

// MARK: AAF objects

@Test(arguments: samples) func aafObjectTreesReencodeExactly(name: String) throws {
    let doc = try AAFDocument(data: try sample(name))
    let again = try AAFDocument(data: doc.data(names: propertyNames(doc)))
    #expect(again == doc, "\(name)")
}

@Test func weakReferencesInRealFilesResolve() throws {
    for name in ["simple", "transitions", "trims"] {
        let doc = try AAFDocument(data: try sample(name))
        var unresolved = 0, total = 0
        doc.root.walk { o in
            for p in o.properties {
                if case .weak(let w) = p.value { total += 1; if doc.resolve(w) == nil { unresolved += 1 } }
            }
        }
        #expect(total > 100 && unresolved == 0, "\(name): \(unresolved) of \(total)")
    }
}

@Test func extraSamplesAllParse() throws {
    for url in extraSamples() {
        let data = try Data(contentsOf: url)
        let layout = try CompoundFile.layout(data)
        #expect(layout.treeProblems().isEmpty, "\(url.lastPathComponent)")
        #expect(layout.sectorProblems().isEmpty, "\(url.lastPathComponent): \(layout.sectorProblems().prefix(3))")
        let doc = try AAFDocument(data: data)
        #expect(try AAFDocument(data: doc.data(names: propertyNames(doc))) == doc, "\(url.lastPathComponent)")
        #expect(try CompoundFile(data: CompoundFile(data: data).data()).root == CompoundFile(data: data).root, "\(url.lastPathComponent)")
        if doc.header?.strong(0x3b03)?.objects(0x1901).isEmpty == false { _ = try Importer.aaf(data, relativeTo: nil) }
    }
}

// MARK: Reading Media Composer AAFs

@Test func simpleSequenceReadsAsTheAdapterReadsIt() throws {
    let r = try importSample("simple")
    let p = r.project
    #expect(p.name == "OTIO TEST 1.Exported.01" && p.canvas.fps == 24)
    let v = p.tracks.filter { $0.kind == .video }
    #expect(v.count == 1)
    #expect(v[0].clips.map { $0.name ?? "" } == ["tech.fux (loop)-HD.mp4", "t-hawk (loop)-HD.mp4", "out-b (loop)-HD.mp4", "KOLL-HD.mp4", "brokchrd (loop)-HD.mp4"])
    // Source ranges start at 01:00:00:00 and last 30:00, 20:00, 30:02, 26:16 and 30:00.
    #expect(timing(p, v[0]) == ["0+720@86400", "720+480@86400", "1200+722@86400", "1922+640@86400", "2562+720@86400"])
    #expect(frames(p.duration) == 3282)
    // The two sound tracks play each picture's own sound in sync, so it rides with the picture.
    #expect(v[0].clips.allSatisfy { $0.volume == 1 } && p.tracks.filter { $0.kind == .audio }.isEmpty)
    #expect(p.media.allSatisfy { $0.timecodeLabel == "01:00:00:00" || $0.name == "KOLL-HD.mp4" })
    try p.validate()
}

@Test func trimsReadAsTheAdapterReadsThem() throws {
    let p = try importSample("trims").project
    let v = try #require(p.tracks.first { $0.kind == .video })
    #expect(p.name == "OTIO TEST 1.Exported.01 - trims.Exported.02")
    #expect(timing(p, v) == ["0+720@86400", "720+359@86521", "1079+400@86523", "1479+559@0", "2146+651@86469"])
    #expect(frames(p.duration) == 2797)
}

@Test func transitionsReadAsDissolvesFadesAndADip() throws {
    let r = try importSample("transitions")
    let p = r.project
    let v = try #require(p.tracks.first { $0.kind == .video })
    #expect(v.clips.map { $0.name ?? "" } == ["tech.fux (loop)-HD.mp4", "t-hawk (loop)-HD.mp4", "KOLL-HD.mp4", "brokchrd (loop)-HD.mp4"])
    // The adapter cuts clips at each transition's cut point; fades against filler run over the clip they fade, so
    // t-hawk keeps the 12 frames past its cut and KOLL the 24 before its own.
    #expect(timing(p, v) == ["0+117@86400", "117+89@86523", "223+168@31", "391+130@86400"])
    #expect(frames(p.duration) == 521)
    let ids = v.clips.map(\.id)
    let tr = p.transitions.map { "\($0.type) \($0.from.map { ids.firstIndex(of: $0)! }.map(String.init) ?? "-")>\($0.to.map { ids.firstIndex(of: $0)! }.map(String.init) ?? "-") \(frames($0.duration)) \($0.align)" }
    #expect(tr == ["dissolve ->0 12 start", "dissolve 0>1 48 end", "dissolve 1>- 24 end", "dip ->2 48 start", "dissolve 3>- 48 end"], "\(tr)")
    for t in p.transitions { try p.checkTransition(t) }
}

@Test func sourceTimecodeComesFromTheTapeMob() throws {
    let p = try importSample("timecode_test").project
    let v = try #require(p.tracks.first { $0.kind == .video })
    let starts = timing(p, v).map { $0.split(separator: "@").last! }
    #expect(starts == ["24", "86424"])
}

@Test func dropFrameProgramTimecode() throws {
    let p = try importSample("2997fps-DFTC").project
    #expect(p.canvas.fps == 29.97 && p.canvas.timecodeStart == "05:00:00;00")
}

@Test func unicodeNamesSurvive() throws {
    let p = try importSample("utf8").project
    #expect(p.name == "Sequence_ABCXYZñçêœ•∑´®†¥¨ˆøπ“‘åß∂ƒ©˙∆˚¬…æΩ≈ç√∫˜µ≤≥÷.Exported.01")
    #expect(p.tracks[0].clips.first?.name == "Clip_ABCXYZñçêœ•∑´®†¥¨ˆøπ“‘åß∂ƒ©˙∆˚¬…æΩ≈ç√∫˜µ≤≥÷")
}

@Test func collapsedVideoTracksFlattenToThePreflattenedSequence() throws {
    let multi = try importSample("multitrack").project
    let flat = try importSample("preflattened").project
    #expect(multi.tracks.filter { $0.kind == .video }.count == 3)
    /// What shows at each frame: the top video track's clip, as "name@source".
    func shown(_ p: Project) -> [String] {
        let tracks = p.tracks.filter { $0.kind == .video }
        return (0..<frames(p.duration)).map { f in
            let t = (Double(f) + 0.5) / 24
            for track in tracks.reversed() {
                if let c = track.clips.first(where: { $0.start <= t && t < $0.end }) { return "\(c.name ?? "")@\(frames(c.sourceIn + t - c.start))" }
            }
            return "-"
        }
    }
    let a = shown(multi), b = shown(flat)
    #expect(a.count == b.count && a == b, "first difference at \(a.indices.first { $0 < b.count && a[$0] != b[$0] } ?? -1)")
}

@Test func mutedClipsGoToAHiddenTrack() throws {
    let p = try importSample("test_muted_clip").project
    let hidden = p.tracks.filter(\.hidden)
    #expect(hidden.count == 1 && hidden[0].clips.map { $0.name ?? "" } == ["Frame Debugger 0h.mov"])
}

@Test func aMasterClipWithoutASequenceImportsWithItsMarkers() throws {
    let r = try importSample("marker-over-audio")
    #expect(r.project.markers.map { frames($0.time) } == [50, 103, 166])
    #expect(r.project.tracks.filter { $0.kind == .audio }.flatMap(\.clips).count == 1)
}

@Test func oneSoundClipIsAnAudioTrack() throws {
    let p = try importSample("one_audio_clip").project
    let a = p.tracks.filter { $0.kind == .audio }
    #expect(a.count == 1 && timing(p, a[0]) == ["0+720@86400"] && a[0].clips[0].name == "tech.fux (loop)-HD.mp4")
}

@Test func pyaaf2SmallSectorFileReads() throws {
    let doc = try AAFDocument(data: try sample("sector_size_512"))
    #expect(doc.header?.strong(0x3b03)?.objects(0x1901).isEmpty == false)
    _ = try importSample("sector_size_512")
}

// MARK: Writing

/// Interview with timecode and reel, b-roll without sound, music with fades and a volume ramp, mono voice-over.
func aafProject() throws -> Project {
    var p = Project(name: "Mix handoff", canvas: Canvas(fps: 25, timecodeStart: "10:00:00:00"))
    p.canvasSet = true
    var a = MediaAsset(id: "a", path: "/tmp/aaf-test/Interview A.mov", name: "Interview A", duration: 120, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)
    a.setTimecode(frames: TimecodeFormat(fps: 25).frames("14:03:10:05")!, format: TimecodeFormat(fps: 25))
    a.reel = "A001"
    a.audioChannels = [SourceChannel(track: 1, channel: 1), SourceChannel(track: 1, channel: 2)]
    let b = MediaAsset(id: "b", path: "/tmp/aaf-test/broll.mov", name: "broll", duration: 60, width: 3840, height: 2160, fps: 25, hasVideo: true, hasAudio: false)
    var m = MediaAsset(id: "m", path: "/tmp/aaf-test/music.wav", name: "music", duration: 200, width: 0, height: 0, fps: 25, hasVideo: false, hasAudio: true)
    m.sampleRate = 48000
    var vo = MediaAsset(id: "vo", path: "/tmp/aaf-test/vo take 3.wav", name: "vo take 3", duration: 30, width: 0, height: 0, fps: 25, hasVideo: false, hasAudio: true)
    vo.audioChannels = [SourceChannel(track: 1, channel: 1)]
    p.media = [a, b, m, vo]
    var c1 = Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 10, volume: 0.8)
    c1.audioLag = -0.4
    var c2 = Clip(id: "c2", kind: .media, mediaId: "a", start: 4, duration: 3, sourceIn: 30)
    c2.audioLead = 0.4
    p.tracks[0].clips = [
        c1,
        c2,
        Clip(id: "c3", kind: .media, mediaId: "b", start: 7, duration: 2, sourceIn: 5),
    ]
    p.tracks[1].clips = [Clip(id: "m1", kind: .media, mediaId: "m", start: 0, duration: 9, sourceIn: 20, audioFadeIn: 1, audioFadeOut: 2,
                              anim: ["audio.volume": Curve(keys: [CurveKey(t: 0, v: .number(0.5), ease: .linear), CurveKey(t: 4, v: .number(0.5), ease: .linear), CurveKey(t: 5, v: .number(1), ease: .linear)])])]
    let voTrack = p.addTrack(kind: .audio, name: "VO")
    p.tracks[p.trackIndex(voTrack.id)!].clips = [Clip(id: "vo1", kind: .media, mediaId: "vo", start: 2, duration: 3, sourceIn: 1, volume: 1.2)]
    p.transitions = [
        Transition(id: "x1", from: "c1", to: "c2", type: "dissolve", duration: 1),
        Transition(id: "x0", from: nil, to: "c1", type: "dissolve", duration: 0.5, part: .video),
    ]
    p.markers = [Marker(id: "k1", time: 3, label: "Check sync")]
    try p.validate()
    for t in p.transitions { try p.checkTransition(t) }
    return p
}

@Test func aProjectRoundTripsThroughAAF() throws {
    let p = try aafProject()
    let made = try p.interchange(.aaf)
    let r = try Importer.aaf(made.data, relativeTo: nil)
    let q = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(q.name == p.name && q.canvas.fps == 25 && q.canvas.timecodeStart == "10:00:00:00")
    func media(_ p: Project, _ c: Clip) -> MediaAsset? { c.mediaId.flatMap(p.mediaAsset) }
    let v = try #require(q.tracks.first { $0.kind == .video })
    #expect(v.clips.map { media(q, $0)?.path } == ["/tmp/aaf-test/Interview A.mov", "/tmp/aaf-test/Interview A.mov", "/tmp/aaf-test/broll.mov"])
    #expect(timing(q, v) == timing(p, p.tracks[0]), "\(timing(q, v))")
    #expect(v.clips.map { frames($0.audioLead, 25) } == [0, 10, 0] && v.clips.map { frames($0.audioLag, 25) } == [-10, 0, 0])
    #expect(v.clips.map(\.volume) == [0.8, 1, 1])
    let ia = try #require(media(q, v.clips[0]))
    #expect(ia.timecodeLabel == "14:03:10:05" && ia.reel == "A001" && ia.width == 1920 && ia.hasAudio && ia.hasVideo)
    #expect(media(q, v.clips[2])?.hasAudio == false)
    // Picture dissolve and sound crossfade come back as one transition, the fade from black as picture only.
    let tr = q.transitions.map { "\($0.from ?? "-")>\($0.to ?? "-") \(frames($0.duration, 25)) \($0.align) \($0.part)" }.sorted()
    #expect(tr == ["->\(v.clips[0].id) 13 start video", "\(v.clips[0].id)>\(v.clips[1].id) 25 center both"].sorted(), "\(tr)")

    let audio = q.tracks.filter { $0.kind == .audio }
    #expect(audio.map(\.name) == ["Music", "VO"])
    let music = try #require(audio.first?.clips.first)
    #expect(timing(q, audio[0]) == timing(p, p.tracks[1]))
    #expect(frames(music.audioFadeIn, 25) == 25 && frames(music.audioFadeOut, 25) == 50)
    for t in stride(from: 0.0, through: 9, by: 0.5) {
        #expect(abs(q.heardGain(music, track: audio[0], at: t) - p.heardGain(p.tracks[1].clips[0], track: p.tracks[1], at: t)) < 1e-3, "music at \(t)")
    }
    let voice = try #require(audio.last?.clips.first)
    #expect(abs(voice.volume - 1.2) < 1e-4 && timing(q, audio[1]) == ["50+75@25"] && media(q, voice)?.sampleRate == 48000)
    #expect(q.markers.map { "\(frames($0.time, 25)) \($0.label)" } == ["75 Check sync"])
    for t in q.transitions { try q.checkTransition(t) }
    // The voice-over starts a second into its file, short of a 2 s handle.
    #expect(made.notes == ["Handles: 1 clip(s) have less than 2.00s of media before or after them, so their handles stop at the media's ends: vo1"], "\(made.notes)")
}

@Test func masterClipsReachTwoSecondsPastTheEditAsHandles() throws {
    let p = try aafProject()
    let doc = p.aafDocument()
    let mobs = try #require(doc.header?.strong(0x3b03)?.objects(0x1901))
    let master = try #require(mobs.first { $0.classID == AAFClass.masterMob && $0.string(0x4402) == "Interview A" })
    let clip = try #require(master.objects(0x4403).first?.strong(0x4803))
    // The interview is used from 10 s (c1) to 33 s plus the dissolve's tail; 2 s handles each side at 25 fps.
    #expect(clip.int(0x1201) == 200 && clip.int(0x1201)! + clip.int(0x0202)! == 33 * 25 + 50)
    let noHandles = p.aafDocument(handles: 0)
    let bare = try #require(noHandles.header?.strong(0x3b03)?.objects(0x1901).first { $0.classID == AAFClass.masterMob && $0.string(0x4402) == "Interview A" }?.objects(0x4403).first?.strong(0x4803))
    #expect(bare.int(0x1201) == 250)
    // Composition clips start where their media does, whatever the handles.
    let back = try Importer.aaf(noHandles.data(names: AAFMetaModel.shared.name), relativeTo: nil).project
    #expect(timing(back, back.tracks[0]) == timing(p, p.tracks[0]))
}

@Test func ourAAFIsWellFormed() throws {
    let p = try aafProject()
    let data = p.aaf(handles: 2, date: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(AAFDocument.isAAF(data))
    let layout = try CompoundFile.layout(data)
    #expect(layout.majorVersion == 4 && layout.sectorShift == 12 && layout.miniSectorShift == 6 && layout.miniStreamCutoff == 4096)
    #expect(layout.treeProblems().isEmpty, "\(layout.treeProblems())")
    #expect(layout.sectorProblems().isEmpty, "\(layout.sectorProblems().prefix(3))")
    #expect(layout.fatSectorCount == UInt32(layout.difat.filter { $0 <= 0xFFFF_FFFA }.count))
    let cf = try CompoundFile(data: data)
    #expect(cf.headerCLSID == AAFDocument.signature4K && AUID(bytes: cf.root.clsid) == AAFDocument.rootClass)
    // The same top-level layout as Media Composer's files.
    let real = try CompoundFile(data: try sample("simple"))
    #expect(Set(cf.root.children.map(\.name)) == Set(real.root.children.map(\.name)))
    #expect(Set(cf.root.child("Header-2")!.children.map(\.name)).isSubset(of: Set(real.root.child("Header-2")!.children.map(\.name))))

    let doc = try AAFDocument(data: data)
    let model = AAFMetaModel.shared
    // Every object has its class's required properties, its class is declared, and every weak reference resolves.
    let declared = Set(doc.metaDictionary!.objects(0x0003).compactMap { $0.auid(0x0005) })
    let types = Set(doc.metaDictionary!.objects(0x0004).compactMap { $0.auid(0x0005) })
    var missing: [String] = [], undeclared = Set<String>(), dangling = 0, refs = 0
    doc.header!.walk { o in
        let lacks = model.missingRequired(o)
        if !lacks.isEmpty { missing.append("\(model.classes[o.classID]?.name ?? o.classID.description): \(lacks)") }
        if !declared.contains(o.classID) { undeclared.insert(o.classID.description) }
        for prop in o.properties {
            switch prop.value {
            case .weak(let w): refs += 1; if doc.resolve(w) == nil { dangling += 1 }
            case .weakSet(let ws), .weakVector(let ws): for w in ws { refs += 1; if doc.resolve(w) == nil { dangling += 1 } }
            default: break
            }
        }
    }
    doc.metaDictionary!.walk { o in
        for prop in o.properties {
            if case .weak(let w) = prop.value { refs += 1; if doc.resolve(w) == nil { dangling += 1 } }
            if case .weakVector(let ws) = prop.value { for w in ws { refs += 1; if doc.resolve(w) == nil { dangling += 1 } } }
        }
    }
    #expect(missing.isEmpty, "\(missing.prefix(5))")
    #expect(undeclared.isEmpty, "\(undeclared)")
    #expect(refs > 50 && dangling == 0, "\(dangling) of \(refs) weak references dangle")
    for c in doc.metaDictionary!.objects(0x0003) {
        for prop in c.objects(0x0009) { #expect(types.contains(prop.auid(0x000b)!), "\(c.string(0x0006) ?? "") \(prop.string(0x0006) ?? "")") }
    }
    // Locators name the camera originals as file URLs.
    var urls: [String] = []
    doc.header!.walk { o in if o.classID == AAFClass.networkLocator, let u = o.string(0x4001) { urls.append(u) } }
    #expect(Set(urls) == ["file:///tmp/aaf-test/Interview%20A.mov", "file:///tmp/aaf-test/broll.mov", "file:///tmp/aaf-test/music.wav", "file:///tmp/aaf-test/vo%20take%203.wav"])
    // Stereo sound is two mono slots per track; the mono voice-over one.
    let comp = doc.header!.strong(0x3b03)!.objects(0x1901).first { $0.classID == AAFClass.compositionMob }!
    let kinds = comp.objects(0x4403).compactMap { $0.strong(0x4803)?.weak(0x0201).map { AUID(bytes: $0.key) } }
    #expect(kinds.filter { $0 == AAFDef.picture }.count == 1 && kinds.filter { $0 == AAFDef.sound }.count == 5 && kinds.filter { $0 == AAFDef.timecode }.count == 1)
    // Writing is deterministic for a given date.
    #expect(p.aaf(handles: 2, date: Date(timeIntervalSince1970: 1_700_000_000)) == data)
}

@Test(arguments: ["simple", "transitions", "one_audio_clip", "2997fps-DFTC"]) func ourClassDefinitionsMatchMediaComposersBaseline(name: String) throws {
    let ours = try #require(try aafProject().aafDocument().metaDictionary)
    let theirs = try #require(try AAFDocument(data: try sample(name)).metaDictionary)
    func table(_ md: AAFObject) -> [AUID: [UInt16: AUID]] {
        Dictionary(uniqueKeysWithValues: md.objects(0x0003).map { c in
            (c.auid(0x0005)!, Dictionary(c.objects(0x0009).compactMap { p in p.uint(0x000d).flatMap { $0 < 0x8000 ? (UInt16($0), p.auid(0x000b)!) : nil } }, uniquingKeysWith: { a, _ in a }))
        })
    }
    let a = table(ours), b = table(theirs)
    let shared = Set(a.keys).intersection(b.keys)
    #expect(shared.count > 40)
    for id in shared {
        // Same pids with the same types; ours may list properties a newer SDK added.
        for (pid, type) in b[id]! { #expect(a[id]![pid] == type, "\(AAFMetaModel.shared.classes[id]?.name ?? id.description) pid \(String(pid, radix: 16))") }
    }
}

@Test func notesSayWhatAAFDropsAndThatNoDAWHasOpenedIt() throws {
    var p = try aafProject()
    p.tracks[0].clips[2].transform.scale = 1.2
    p.tracks[0].clips[2].transform.anchorX = 0.2
    p.tracks[0].clips[2].effects = [Effect(id: "blur", type: "blur")]
    p.tracks[0].clips[1].reverse = true
    p.transitions.append(Transition(id: "x2", from: "c2", to: "c3", type: "wipe", duration: 0.4))
    let made = try p.interchange(.aaf, options: InterchangeOptions(aafHandles: 5))
    let text = made.notesText(project: p.name, format: .aaf)
    #expect(text.contains("Not yet opened in Pro Tools, Media Composer or Resolve"))
    // Scale and reverse are carried; the anchor and blur aren't.
    #expect(made.notes.contains("c3 → anchor point, effects and grade (blur) not carried"), "\(made.notes)")
    #expect(!made.notes.contains { $0.hasPrefix("c2") })
    #expect(made.notes.contains("Transition x2 wipe → a dissolve"))
    #expect(made.notes.contains { $0.hasPrefix("Handles: 1 clip(s) have less than 5.00s") && $0.hasSuffix(": vo1") })
}

@Test func titlesComeBackFromTheirComments() throws {
    var p = try aafProject()
    let v2 = p.addTrack(kind: .video, name: "Titles")
    p.tracks[p.trackIndex(v2.id)!].clips = [Clip(id: "t1", kind: .text, start: 1, duration: 2, text: TextSpec(text: "Ada Lovelace", size: 0.06, color: RGBA(r: 1, g: 1, b: 1)))]
    let q = try Importer.aaf(try p.interchange(.aaf).data, relativeTo: nil).project
    let title = try #require(q.tracks.flatMap(\.clips).first { $0.kind == .text })
    #expect(title.text?.text == "Ada Lovelace" && frames(title.start, 25) == 25 && frames(title.duration, 25) == 50)
}

@Test func dropFrameAndConstantSpeedRoundTrip() throws {
    var p = Project(name: "DF", canvas: Canvas(fps: 30000.0 / 1001, timecodeStart: "00:59:58;00"))
    p.canvas.dropFrame = true
    p.media = [MediaAsset(id: "a", path: "/tmp/aaf-test/a.mov", name: "a", duration: 100, width: 1280, height: 720, fps: 30000.0 / 1001, hasVideo: true, hasAudio: false)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 2, sourceIn: 3, speed: 2)]
    try p.validate()
    let q = try Importer.aaf(try p.interchange(.aaf).data, relativeTo: nil).project
    #expect(q.canvas.fps == 29.97 && q.canvas.timecodeStart == "00:59:58;00")
    let c = try #require(q.tracks.first?.clips.first)
    #expect(c.speed == 2 && abs(c.sourceIn - 3) < 0.02 && abs(c.duration - 2) < 0.02)
}
