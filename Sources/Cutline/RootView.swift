import AppKit
import CutlineCore
import CutlineEngine
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            Theme.room.ignoresSafeArea()
            if let doc = model.doc {
                EditorView(model: model, doc: doc)
            } else {
                WelcomeView(model: model)
                    .navigationTitle("Cutline")
                    .toolbar(removing: .title)
            }
        }
        .onOpenURL { model.open($0) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
    }
}

// MARK: Editor

struct EditorView: View {
    @Bindable var model: AppModel
    let doc: ProjectDocument
    @State private var picture: CGRect = .zero
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var timelineHeight: CGFloat {
        min(max(TimelineTrackView.idealHeight(doc.project, hasNotes: !doc.comments.isEmpty), 140), 400)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { stage in
                ZStack(alignment: .topLeading) {
                    if picture.width > 0, !reduceTransparency {
                        let glow = glowRect(in: stage.size)
                        AmbientGlow(image: doc.player.ambient, strength: 0.22)
                            .frame(width: glow.width, height: glow.height)
                            .position(x: glow.midX, y: glow.midY)
                            .allowsHitTesting(false)
                    }
                    VStack(spacing: 0) {
                        ViewerView(doc: doc, pinning: $model.pinning, draft: $model.draft, selected: model.selectedComment)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .frame(minHeight: 240)
                        TransportBar(doc: doc, picture: picture) { model.startNote() }
                    }
                }
            }
            .coordinateSpace(.named("stage"))
            .onPreferenceChange(PictureFrameKey.self) { picture = $0 }
            .overlay(alignment: .bottom) {
                if let rec = doc.recording {
                    RecordingPanel(doc: doc, rec: rec)
                        .padding(.bottom, 92)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: doc.recording == nil)
            TimelineTrackView(doc: doc, selectedComment: model.selectedComment) { id in
                model.selectedComment = id
                model.tab = .notes
                model.showPanel = true
            }
            .id(model.fitRequest)
            .padding(.top, 6)
            .frame(height: timelineHeight)
            .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Divider() }
        }
        .frame(minWidth: 680)
        .background {
            Theme.room
                .backgroundExtensionEffect()
                .ignoresSafeArea()
        }
        .inspector(isPresented: $model.showPanel) {
            SidePanel(doc: doc, tab: $model.tab, selected: $model.selectedComment, draft: $model.draft) { model.startNote() }
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .navigationTitle(doc.project.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            if let entry = doc.history.current {
                ToolbarItem(placement: .principal) {
                    Tally(doc: doc, entry: entry)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showPanel.toggle()
                } label: {
                    Label(model.showPanel ? "Hide Notes and History" : "Show Notes and History", systemImage: "sidebar.trailing")
                }
                .help(model.showPanel ? "Hide notes and history (⌥⌘I)" : "Show notes and history (⌥⌘I)")
            }
        }
        .onChange(of: model.draft) { _, d in if d != nil { model.showPanel = true } }
    }

    private var subtitle: String {
        let c = doc.project.canvas
        return "\(c.width) × \(c.height)   \(Int(c.fps.rounded())) fps   \(Theme.short(doc.project.duration))"
    }

    /// The glow fades out before the stage edges so it never meets them as a hard line.
    private func glowRect(in stage: CGSize) -> CGRect {
        let spread = max(picture.width, picture.height) * 0.5
        let left = min(spread, picture.minX), right = min(spread, stage.width - picture.maxX)
        let side = min(left, right)
        let top = min(spread, picture.minY), bottom = min(spread, stage.height - picture.maxY)
        let vertical = min(top, bottom)
        return picture.insetBy(dx: -side, dy: -vertical)
    }
}

/// Lights up while Claude is changing the edit, like a camera's on-air tally.
struct Tally: View {
    let doc: ProjectDocument
    let entry: HistoryEntry

    var body: some View {
        Button(action: doc.jumpToLastChange) {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let age = doc.lastEditAt.map { ctx.date.timeIntervalSince($0) } ?? .infinity
                let live = age < 8
                HStack(spacing: 10) {
                    LiveDot(live: live)
                    Text(live ? "Claude is editing" : "Last edit")
                        .foregroundStyle(live ? .primary : .secondary)
                        .fixedSize()
                    Text(entry.label)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ctx.date.timeIntervalSince(entry.createdAt) < 10 ? "just now" : entry.createdAt.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                    if let status = doc.analysisStatus {
                        Text(status)
                            .foregroundStyle(Theme.claude)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 6)
                .frame(minWidth: 300)
                .animation(.easeOut(duration: 0.5), value: live)
            }
        }
        .help("Go to this change (⌥⌘L)")
    }
}

/// Breathes while Claude is editing; rests as a small grey dot otherwise.
struct LiveDot: View {
    let live: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.claude.opacity(live ? (pulse ? 0 : 0.7) : 0), lineWidth: 1.2)
                .frame(width: pulse ? 16 : 7, height: pulse ? 16 : 7)
            Circle()
                .fill(live ? Theme.claude : Theme.ink3)
                .frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
        .onAppear { animate() }
        .onChange(of: live) { _, _ in animate() }
    }

    private func animate() {
        pulse = false
        guard live, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
    }
}

// MARK: Transport

struct TransportBar: View {
    let doc: ProjectDocument
    let picture: CGRect
    var addNote: () -> Void

    var body: some View {
        let wide = picture.width >= 600
        Group {
            if wide {
                HStack(spacing: 0) {
                    Timecode(time: doc.player.time, fps: doc.project.canvas.fps)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    controls
                    noteButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: picture.width)
            } else {
                HStack(spacing: 0) {
                    Timecode(time: doc.player.time, fps: doc.project.canvas.fps)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    controls
                    noteButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 78)
    }

    private var controls: some View {
        let p = doc.player
        return GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                transportButton("Go to Start", symbol: "backward.end.fill", help: "Go to start (Home)") { p.pause(); p.seek(0) }
                transportButton("Back One Frame", symbol: "backward.frame.fill", help: "Back one frame (←)") { p.step(frames: -1) }
                Button(action: p.togglePlay) {
                    Label(p.isPlaying ? "Pause" : "Play", systemImage: p.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.desk)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Theme.ink)
                .padding(.horizontal, 6)
                .help(p.isPlaying ? "Pause (Space)" : "Play (Space)")
                transportButton("Forward One Frame", symbol: "forward.frame.fill", help: "Forward one frame (→)") { p.step(frames: 1) }
                transportButton("Go to End", symbol: "forward.end.fill", help: "Go to end (End)") { p.pause(); p.seek(p.duration) }
                Toggle(isOn: Binding(get: { p.loop }, set: { p.loop = $0 })) {
                    Label("Loop Playback", systemImage: "repeat")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(.leading, 6)
                .help(p.loop ? "Loop is on" : "Loop playback")
            }
            .controlSize(.extraLarge)
        }
    }

    private func transportButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
    }

    private var noteButton: some View {
        Button(action: addNote) {
            Label("Add Note", systemImage: "mappin.and.ellipse")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.desk)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(Theme.wax)
        .help("Pin a note to this frame (C)")
    }
}

/// Hours, minutes and seconds in ink; the frame count a step quieter.
struct Timecode: View {
    let time: Double
    let fps: Double

    var body: some View {
        let tc = Theme.timecode(time, fps: fps)
        let hours = tc.hasPrefix("00:") ? tc.index(tc.startIndex, offsetBy: 3) : tc.startIndex
        let frames = tc.index(tc.endIndex, offsetBy: -3)
        HStack(spacing: 0) {
            Text(tc[..<hours]).foregroundStyle(.tertiary)
            Text(tc[hours..<frames]).foregroundStyle(.primary)
            Text(tc[frames...]).foregroundStyle(.tertiary)
        }
        .font(.system(size: 26, weight: .light).monospacedDigit())
        .tracking(-0.2)
        .fixedSize()
    }
}

// MARK: Welcome

extension VerticalAlignment {
    private enum CapTop: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.top] }
    }

    /// The top of capital letters, so headings of different sizes line up.
    static let capTop = VerticalAlignment(CapTop.self)
}

struct WelcomeView: View {
    let model: AppModel
    @State private var copied = false

    /// The helper inside this app bundle, or where an installed copy lives when running a development build.
    private var mcpCommand: String {
        let inBundle = Bundle.main.bundleURL.pathExtension == "app"
        let helper = inBundle
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cutline-mcp").path
            : "/Applications/Cutline.app/Contents/MacOS/cutline-mcp"
        return "claude mcp add -s user cutline -- \"\(helper)\""
    }

    var body: some View {
        content
            .background(Theme.room.ignoresSafeArea())
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 88) {
            VStack(alignment: .leading, spacing: 0) {
                CutlineMark(size: 56)
                    .padding(.bottom, 22)
                Text("Cutline")
                    .font(Typeface.font(46, .medium))
                    .tracking(-0.9)
                    .foregroundStyle(.primary)
                Text("Claude edits your video. You watch, scrub, and leave notes on the frames you want changed.")
                    .font(Typeface.font(18))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .frame(maxWidth: 470, alignment: .leading)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 30) {
                    step(1, "Connect Cutline to Claude Code") {
                        HStack(spacing: 10) {
                            Text(mcpCommand)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(mcpCommand)
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(mcpCommand, forType: .string)
                                copied = true
                                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                            }
                            .buttonStyle(QuietButtonStyle(bordered: true))
                        }
                        .padding(.leading, 18).padding(.trailing, 7)
                        .frame(maxWidth: 520)
                        .frame(height: 44)
                        .background(.quaternary, in: Capsule())
                    }
                    step(2, "Ask Claude for a video") {
                        Text("“Make a 45-second vertical cut of ~/Movies/interview.mov with captions and no long pauses.”")
                            .font(Typeface.font(15))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .frame(maxWidth: 470, alignment: .leading)
                    }
                    step(3, "Watch and leave notes") {
                        Text("The project opens in this window. Press C on any frame to pin a note; Claude reads it and changes the edit.")
                            .font(Typeface.font(15))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .frame(maxWidth: 470, alignment: .leading)
                    }
                }
                .padding(.top, 52)
                if let e = model.error {
                    Text(e).font(Typeface.font(13)).foregroundStyle(Theme.tally).padding(.top, 24)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Recent Projects")
                    .font(Typeface.font(15, .semibold))
                    .foregroundStyle(.primary)
                if model.recent.isEmpty {
                    Text("Projects Claude creates appear here.")
                        .font(Typeface.font(14)).foregroundStyle(.tertiary)
                }
                VStack(spacing: 4) {
                    ForEach(model.recent.prefix(6), id: \.self) { path in
                        RecentRow(path: path) { model.open(URL(fileURLWithPath: path)) }
                    }
                }
                .padding(.horizontal, -10)
                Button("Open a Project…") { model.showOpenPanel() }
                    .buttonStyle(QuietButtonStyle(bordered: true))
                    .padding(.top, 6)
            }
            .padding(24)
            .frame(width: 420, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .padding(.horizontal, 72)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("\(n)")
                .font(Typeface.font(15, .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Typeface.font(16, .medium)).foregroundStyle(.primary)
                content()
            }
        }
    }
}

/// The app mark: a frame split by a cut, with Claude's light in the corner.
struct CutlineMark: View {
    var size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width
            let tile = CGRect(x: 0, y: 0, width: s, height: s)
            ctx.fill(Path(roundedRect: tile, cornerRadius: s * 0.23, style: .continuous), with: .color(Color(hex: 0x2A2B2F)))
            ctx.stroke(Path(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), cornerRadius: s * 0.23, style: .continuous), with: .color(.white.opacity(0.08)), lineWidth: 1)
            let frame = CGRect(x: s * 0.2, y: s * 0.32, width: s * 0.6, height: s * 0.38)
            let shape = Path(roundedRect: frame, cornerRadius: s * 0.04)
            let cutTop = CGPoint(x: frame.midX + s * 0.05, y: frame.minY - s * 0.02)
            let cutBottom = CGPoint(x: frame.midX - s * 0.05, y: frame.maxY + s * 0.02)
            for (side, dx, dy) in [(true, -s * 0.02, -s * 0.013), (false, s * 0.02, s * 0.013)] {
                var mask = Path()
                if side {
                    mask.move(to: .zero); mask.addLine(to: CGPoint(x: cutTop.x, y: 0)); mask.addLine(to: cutTop); mask.addLine(to: cutBottom); mask.addLine(to: CGPoint(x: cutBottom.x, y: s)); mask.addLine(to: CGPoint(x: 0, y: s))
                } else {
                    mask.move(to: CGPoint(x: s, y: 0)); mask.addLine(to: CGPoint(x: cutTop.x, y: 0)); mask.addLine(to: cutTop); mask.addLine(to: cutBottom); mask.addLine(to: CGPoint(x: cutBottom.x, y: s)); mask.addLine(to: CGPoint(x: s, y: s))
                }
                mask.closeSubpath()
                var layer = ctx
                layer.translateBy(x: dx, y: dy)
                layer.clip(to: mask)
                layer.fill(shape, with: .color(Theme.ink))
            }
            let r = s * 0.06
            let dot = CGRect(x: s * 0.74 - r, y: s * 0.2 - r, width: 2 * r, height: 2 * r)
            ctx.addFilter(.shadow(color: Theme.claude.opacity(0.8), radius: s * 0.05))
            ctx.fill(Path(ellipseIn: dot), with: .color(Theme.claude))
        }
        .frame(width: size, height: size)
    }
}

/// A recent project with a frame rendered from its current edit.
struct RecentRow: View {
    let path: String
    let open: () -> Void
    @State private var poster: CGImage?
    @State private var name = ""
    @State private var info = ""
    @State private var edited = ""
    @State private var folder = ""
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                ZStack {
                    Theme.field
                    if let poster {
                        Image(decorative: poster, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 104, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Typeface.text(name.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : name, 15, .medium)
                        .foregroundStyle(.primary)
                    Text(info)
                        .font(Typeface.font(12.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        Text(edited).fixedSize()
                        Text(folder).truncationMode(.middle).foregroundStyle(.tertiary)
                    }
                    .font(Typeface.font(12.5))
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help((path as NSString).abbreviatingWithTildeInPath)
        .task { await load() }
    }

    private func load() async {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: path))
 guard let p = try? bundle.loadProject() else { return }
        name = p.name
        info = "\(Theme.short(p.duration))     \(p.canvas.width) × \(p.canvas.height)"
        let url = URL(fileURLWithPath: path)
        folder = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        edited = ""
        if let date = bundle.loadHistory().current?.createdAt {
            edited = "Edited \(date.formatted(.relative(presentation: .named)))   "
        }
        guard p.duration > 0,
              let built = try? await TimelineBuilder.build(p, transcripts: bundle.transcripts(for: p), library: MediaLibrary(), renderScale: 0.25),
              let frame = try? await Frames.timeline(built, times: [min(1.5, p.duration / 2)], maxSize: CGSize(width: 300, height: 300)).first
        else { return }
        poster = frame.image
    }
}
