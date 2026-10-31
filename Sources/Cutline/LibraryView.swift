import AppKit
import CutlineCore
import CutlineEngine
import Observation
import SwiftUI

/// What the library shows about a project, read from its bundle.
struct ProjectSummary: Identifiable, Equatable {
    let url: URL
    var name: String
    var duration: Double
    var canvas: String
    var editedAt: Date?
    var openNotes: Int

    var id: String { url.path }

    init?(url: URL) {
        let bundle = ProjectBundle(url: url)
        guard let p = try? bundle.loadProject() else { return nil }
        self.url = url
        name = p.name
        duration = p.duration
        canvas = "\(p.canvas.width) × \(p.canvas.height)  \(Int(p.canvas.fps.rounded())) fps"
        let history = bundle.loadHistory()
        editedAt = history.current?.createdAt
        openNotes = bundle.loadComments().comments.filter { $0.status == .open }.count
    }
}

/// Recent projects and their poster frames.
@MainActor
@Observable
final class ProjectLibrary {
    static let shared = ProjectLibrary()

    private(set) var projects: [ProjectSummary] = []
    private(set) var posters: [String: CGImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    static var recentURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline/recent.json")
    }

    /// Recent project paths with symlinks resolved, so /tmp and /private/tmp count once.
    static var recentPaths: [String] {
        let raw = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: recentURL))) ?? []
        var seen = Set<String>()
        return raw.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.filter { seen.insert($0).inserted }
    }

    func refresh() {
        projects = Self.recentPaths.compactMap { ProjectSummary(url: URL(fileURLWithPath: $0)) }
        for p in projects { loadPoster(p) }
    }

    /// Puts `url` first in the recent list the MCP server also writes.
    func noteOpened(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        var paths = Self.recentPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        write(Array(paths.prefix(20)))
    }

    func remove(_ p: ProjectSummary) {
        write(Self.recentPaths.filter { $0 != p.url.path })
        refresh()
    }

    private func write(_ paths: [String]) {
        try? FileManager.default.createDirectory(at: Self.recentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(paths).write(to: Self.recentURL)
    }

    private func loadPoster(_ s: ProjectSummary) {
        guard posters[s.id] == nil, !loading.contains(s.id), s.duration > 0 else { return }
        loading.insert(s.id)
        let url = s.url
        Task {
            let bundle = ProjectBundle(url: url)
            guard let p = try? bundle.loadProject(),
                  let built = try? await TimelineBuilder.build(p, transcripts: bundle.transcripts(for: p), library: MediaLibrary(), renderScale: 0.35),
                  let frame = try? await Frames.timeline(built, times: [min(1.5, p.duration / 2)], maxSize: CGSize(width: 640, height: 640)).first
            else { return }
            posters[s.id] = frame.image
        }
    }
}

struct LibraryView: View {
    let model: AppModel
    @State private var library = ProjectLibrary.shared
    @State private var connected = ClaudeCode.isConnected
    @State private var dropTarget = false

    var body: some View {
        Group {
            if library.projects.isEmpty {
                EmptyLibrary(connected: connected)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !connected { ConnectBanner { connected = ClaudeCode.isConnected } }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 24, alignment: .top)], alignment: .leading, spacing: 28) {
                            ForEach(library.projects) { p in
                                ProjectCard(project: p, poster: library.posters[p.id]) { model.open(p.url) }
                                    .contextMenu {
                                        Button("Open") { model.open(p.url) }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                                        Divider()
                                        Button("Remove from List") { library.remove(p) }
                                    }
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Projects")
        .onAppear { library.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refresh()
            connected = ClaudeCode.isConnected
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.claude, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10)
                    .overlay(Label("Open", systemImage: "film").font(.title2.weight(.semibold)).padding(18).glassEffect(.regular, in: .capsule))
                    .allowsHitTesting(false)
            }
        }
        .alert("Can’t Open", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }
}

/// The poster frame, or a quiet placeholder while it renders.
struct Poster: View {
    let image: CGImage?

    var body: some View {
        Color(nsColor: .quaternarySystemFill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .clipped()
    }
}

struct ProjectCard: View {
    let project: ProjectSummary
    let poster: CGImage?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Poster(image: poster)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.25 : 0.06)))
                    .overlay(alignment: .topTrailing) {
                        if project.openNotes > 0 {
                            Label("\(project.openNotes)", systemImage: "mappin")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(Theme.desk)
                                .background(Theme.wax, in: .capsule)
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(Theme.short(project.duration))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: .rect(cornerRadius: 5))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.015 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.headline).lineLimit(1)
                    Text(project.editedAt.map { "Edited \($0.formatted(.relative(presentation: .named)))" } ?? project.canvas)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.smooth(duration: 0.2)) { hovering = h } }
        .help(project.url.path)
    }
}

/// Shown until Claude Code has Cutline as an MCP server.
struct ConnectBanner: View {
    let done: () -> Void
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.wax)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code isn’t connected")
                if let error { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            Button(connecting ? "Connecting…" : "Connect") {
                connecting = true
                Task {
                    error = await ClaudeCode.connect(server: ClaudeCode.helper)
                    connecting = false
                    done()
                }
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.claudeFill)
            .disabled(connecting)
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

struct EmptyLibrary: View {
    let connected: Bool

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("No Projects", systemImage: "film.stack")
            } description: {
                Text("Ask Claude to edit a video. It opens here.")
            }
            .fixedSize()
            if !connected { ConnectBanner {}.frame(maxWidth: 420) }
        }
    }
}
