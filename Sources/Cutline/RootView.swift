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
                LibraryView(model: model)
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
        min(max(TimelineTrackView.idealHeight(doc.project), 140), 400)
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
                        Tally(doc: doc, entry: doc.history.current)
                            .modifier(PictureWidth(picture: picture))
                            .frame(height: 36)
                        ViewerView(doc: doc, pinning: $model.pinning, draft: $model.draft, selected: model.selectedComment)
                            .padding(.horizontal, 24)
                            .padding(.top, 4)
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
            SidePanel(doc: doc, tab: $model.tab, selected: $model.selectedComment, draft: $model.draft)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .navigationTitle(doc.project.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.closeProject() } label: {
                    Label("Library", systemImage: "square.grid.2x2")
                }
                .help("Back to the library (⇧⌘L)")
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

/// Lights up while Claude is changing the edit, like a camera's on-air tally, and says what Claude is doing
/// about your notes and the export.
struct Tally: View {
    let doc: ProjectDocument
    let entry: HistoryEntry?

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let age = doc.lastEditAt.map { ctx.date.timeIntervalSince($0) } ?? .infinity
            let working = doc.presence?.workingNotes(now: ctx.date).count ?? 0
            let live = age < 8 || working > 0
            let listening = !live && doc.presence?.isLive == true
            HStack(spacing: 12) {
                Button(action: doc.jumpToLastChange) {
                    HStack(spacing: 8) {
                        LiveDot(live: live, listening: listening)
                        Text(age < 8 ? "Claude is editing" : working > 0 ? (working == 1 ? "Claude is working on your note" : "Claude is working on \(working) notes") : listening ? "Claude is watching for notes" : entry == nil ? "No edits yet" : "Last edit")
                            .foregroundStyle(live || listening ? .primary : .secondary)
                            .fixedSize()
                        if let entry, age < 8 || (working == 0 && !listening) {
                            Text(entry.label)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(ctx.date.timeIntervalSince(entry.createdAt) < 10 ? "just now" : entry.createdAt.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if let status = doc.analysisStatus {
                            Text(status)
                                .foregroundStyle(Theme.claude)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 14)
                    .frame(height: 32)
                    .contentShape(.capsule)
                    .glassEffect(.regular.tint(live || listening ? Theme.claude.opacity(0.12) : .clear).interactive(), in: .capsule)
                    .animation(.easeOut(duration: 0.5), value: live)
                }
                .buttonStyle(.plain)
                .help("Go to this change (⌥⌘L)")
                .disabled(entry == nil)
                if !live, !listening, !doc.awaitingReply.isEmpty {
                    Label("Claude reads new notes the next time you message it.", systemImage: "moon.zzz")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ExportStatus(doc: doc)
                        if listening || working > 0 {
                            Button("Done") { doc.finishReview(export: false) }
                                .buttonStyle(.glass)
                                .help("Tell Claude you're done for now")
                            if doc.exportState?.finishedPath == nil {
                                Button("Export") { doc.finishReview(export: true) }
                                    .buttonStyle(.glassProminent)
                                    .tint(Theme.claudeFill)
                                    .help("Tell Claude to export the video")
                            }
                        }
                    }
                }
                .controlSize(.large)
            }
            .font(Typeface.font(13))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Export progress, then the finished file.
struct ExportStatus: View {
    let doc: ProjectDocument

    var body: some View {
        if let e = doc.exportState {
            if let path = e.finishedPath {
                let url = URL(fileURLWithPath: path)
                HStack(spacing: 10) {
                    Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                    Divider().frame(height: 14)
                    Button("Play", systemImage: "play.fill") { NSWorkspace.shared.open(url) }
                        .labelStyle(.iconOnly).buttonStyle(.plain).help("Play the export")
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .labelStyle(.iconOnly).buttonStyle(.plain).help("Show in Finder")
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .glassEffect(.regular, in: .capsule)
            } else if e.failed {
                Label("Export failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.tally)
                    .padding(.horizontal, 14).frame(height: 32).glassEffect(.regular, in: .capsule)
            } else {
                HStack(spacing: 8) {
                    Text("Exporting").foregroundStyle(.secondary)
                    ProgressView(value: e.progress).frame(width: 90)
                    Text("\(Int(e.progress * 100))%").monospacedDigit().foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).frame(height: 32).glassEffect(.regular, in: .capsule)
            }
        }
    }
}

/// Keeps a row as wide as the picture, so its edges line up with the frame and the transport.
struct PictureWidth: ViewModifier {
    let picture: CGRect

    func body(content: Content) -> some View {
        if picture.width >= 600 {
            content.frame(width: picture.width).frame(maxWidth: .infinity)
        } else {
            content.padding(.horizontal, 24)
        }
    }
}

/// Breathes while Claude is editing, glows steadily while it waits for notes, and rests as a small grey dot otherwise.
struct LiveDot: View {
    let live: Bool
    var listening = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.claude.opacity(live ? (pulse ? 0 : 0.7) : 0), lineWidth: 1.2)
                .frame(width: pulse ? 16 : 7, height: pulse ? 16 : 7)
            Circle()
                .fill(live || listening ? Theme.claude : Theme.ink3)
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
        HStack(spacing: 0) {
            Timecode(time: doc.player.time, fps: doc.project.canvas.fps)
                .frame(maxWidth: .infinity, alignment: .leading)
            controls
            noteButton.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .modifier(PictureWidth(picture: picture))
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

// MARK: Mark

extension VerticalAlignment {
    private enum CapTop: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.top] }
    }

    /// The top of capital letters, so headings of different sizes line up.
    static let capTop = VerticalAlignment(CapTop.self)
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

