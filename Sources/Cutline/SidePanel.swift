import CutlineCore
import SwiftUI

enum PanelTab: String, CaseIterable {
    case notes = "Notes"
    case history = "History"
}

struct SidePanel: View {
    let doc: ProjectDocument
    @Binding var tab: PanelTab
    @Binding var selected: String?
    @Binding var draft: DraftNote?

    var body: some View {
        Group {
            switch tab {
            case .notes: notes
            case .history: HistoryList(doc: doc)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaBar(edge: .top) {
            Picker("Panel", selection: $tab) {
                Text(notesLabel).tag(PanelTab.notes).help("Notes pinned to frames")
                Text(PanelTab.history.rawValue).tag(PanelTab.history).help("Claude's edits, newest first")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .tint(Theme.segment)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var notesLabel: String {
        let n = doc.openComments.count
        return n > 0 ? "Notes \(n)" : "Notes"
    }

    // MARK: Notes

    private var notes: some View {
        VStack(spacing: 0) {
            if let d = draft {
                NoteComposer(time: d.time, pinned: d.x != nil, fps: doc.project.canvas.fps) { text in
                    doc.addComment(text: text, time: d.time, x: d.x, y: d.y)
                    draft = nil
                } cancel: { draft = nil }
                Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.horizontal, 20)
            }
            if doc.comments.isEmpty {
                if draft == nil { emptyNotes }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(doc.comments.enumerated()), id: \.element.id) { i, c in
                                if i > 0 {
                                    Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.horizontal, 24)
                                }
                                NoteEntry(comment: c, fps: doc.project.canvas.fps, selected: c.id == selected, doc: doc) {
                                    selected = c.id
                                    doc.player.pause()
                                    doc.player.seek(c.time)
                                }
                                .id(c.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selected) { _, id in
                        if let id { withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    private var emptyNotes: some View {
        ContentUnavailableView("No Notes", systemImage: "mappin.and.ellipse", description: Text("Press C to pin a note on the frame."))
            .padding(.top, 24)
    }
}

/// One note: when, who, what, and the conversation under it.
struct NoteEntry: View {
    let comment: Comment
    let fps: Double
    let selected: Bool
    let doc: ProjectDocument
    let select: () -> Void
    @State private var hovering = false
    @State private var replying = false
    @State private var reply = ""

    var body: some View {
        let resolved = comment.status == .resolved
        let human = comment.author == .human
        let collapsed = resolved && !selected
        VStack(alignment: .leading, spacing: collapsed ? 6 : 9) {
            HStack(spacing: 8) {
                Monogram(human: human)
                    .opacity(resolved ? 0.55 : 1)
                Text(human ? "You" : "Claude")
                    .font(Typeface.font(12.5, .semibold))
                    .foregroundStyle(resolved ? .secondary : .primary)
                Text(Theme.compact(comment.time, fps: fps))
                    .font(Typeface.font(12).monospacedDigit())
                    .foregroundStyle(human && !resolved ? Theme.wax : Theme.ink3)
                Spacer(minLength: 4)
                if !resolved, doc.presence?.workingNotes().contains(comment.id) == true, !(hovering || selected) {
                    Label("Claude is on it", systemImage: "sparkle")
                        .labelStyle(.titleAndIcon)
                        .font(Typeface.font(12))
                        .foregroundStyle(Theme.claude)
                } else if hovering || selected {
                    actions(resolved: resolved)
                        .transition(.opacity)
                } else if resolved {
                    Label("Resolved", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(Typeface.font(12))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 22)
            Typeface.text(comment.text, 14)
                .foregroundStyle(resolved ? Theme.settled : Theme.ink)
                .lineSpacing(3)
                .lineLimit(collapsed ? 1 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
            if !comment.replies.isEmpty && !collapsed {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(comment.replies) { r in
                        let agent = r.author == .agent
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent ? "Claude" : "You")
                                .font(Typeface.font(12, .semibold))
                                .foregroundStyle(agent ? Theme.claude : Theme.wax)
                            Typeface.text(r.text, 14)
                                .foregroundStyle(resolved ? Theme.settled : Theme.ink.opacity(0.84))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Capsule().fill((agent ? Theme.claude : Theme.wax).opacity(resolved ? 0.25 : 0.5)).frame(width: 2)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
            if replying {
                TextField("Reply to Claude", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typeface.font(14))
                    .foregroundStyle(.primary)
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
                    .onSubmit {
                        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { doc.reply(comment.id, text: t) }
                        reply = ""
                        replying = false
                    }
                    .onExitCommand { replying = false }
                    .padding(.leading, 24)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, collapsed ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.ink.opacity(selected ? 0.08 : hovering ? 0.04 : 0))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private func actions(resolved: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                doc.setStatus(comment.id, resolved ? .open : .resolved)
            } label: {
                Label(resolved ? "Reopen" : "Resolve", systemImage: resolved ? "arrow.uturn.backward" : "checkmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            Button("Reply") { replying = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
            Menu {
                Button("Delete Note", role: .destructive) { doc.deleteComment(comment.id) }
            } label: {
                Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

struct NoteComposer: View {
    let time: Double
    let pinned: Bool
    let fps: Double
    var save: (String) -> Void
    var cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(Theme.compact(time, fps: fps))
                    .font(Typeface.font(12, .medium).monospacedDigit())
                    .foregroundStyle(Theme.wax)
                Text(pinned ? "Pinned to the frame" : "Whole frame")
                    .font(Typeface.font(12.5, .medium))
                    .foregroundStyle(.tertiary)
            }
            TextField("What should change here?", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .font(Typeface.font(14.5))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.wax.opacity(focused ? 0.6 : 0.25), lineWidth: 1))
                .focused($focused)
                .onSubmit(submit)
            HStack(spacing: 6) {
                Text("Return to add").font(Typeface.font(12)).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).buttonStyle(QuietButtonStyle())
                Button("Add Note", action: submit).buttonStyle(QuietButtonStyle(prominent: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .onAppear { focused = true }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        save(t)
    }
}

/// Claude's edits as a sequence, newest first, grouped by when they happened. Undone edits
/// stay listed until a new edit replaces them.
struct HistoryList: View {
    let doc: ProjectDocument

    struct Row {
        var entry: HistoryEntry
        var indices: [Int]
    }

    /// Consecutive edits with the same label read as one row with a count.
    private func collapsed() -> [Row] {
        var rows: [Row] = []
        for (i, e) in doc.history.entries.enumerated().reversed() {
            if let last = rows.last, last.entry.label == e.label, (last.indices.last ?? 0) == i + 1 {
                rows[rows.count - 1].indices.append(i)
            } else {
                rows.append(Row(entry: e, indices: [i]))
            }
        }
        return rows
    }

    private func bucket(_ d: Date, now: Date) -> String {
        let age = now.timeIntervalSince(d)
        if age < 120 { return "Just Now" }
        if age < 900 { return "Last 15 Minutes" }
        if age < 3600 { return "Last Hour" }
        if Calendar.current.isDate(d, inSameDayAs: now) { return "Earlier Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        let rows = collapsed()
        ScrollView {
            SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let groups = Dictionary(grouping: rows.indices, by: { bucket(rows[$0].entry.createdAt, now: ctx.date) })
                let order = rows.indices.map { bucket(rows[$0].entry.createdAt, now: ctx.date) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(order, id: \.self) { name in
                        Text(name)
                            .font(Typeface.font(12, .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 24)
                            .padding(.top, name == order.first ? 4 : 18)
                            .padding(.bottom, 6)
                        ForEach(groups[name] ?? [], id: \.self) { r in
                            row(rows[r], first: r == 0, last: r == rows.count - 1)
                        }
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .scrollIndicators(.never)
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
            }
        }
    }

    private func row(_ item: Row, first: Bool, last: Bool) -> some View {
        let current = item.indices.contains(doc.history.cursor)
        let undone = item.indices.allSatisfy { $0 > doc.history.cursor }
        return HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(current ? Theme.claude : undone ? Color.clear : Theme.ink3)
                .overlay(Circle().strokeBorder(undone ? Theme.ink3 : .clear, lineWidth: 1))
                .frame(width: current ? 10 : 7, height: current ? 10 : 7)
                .frame(width: 10, height: 20)
            HStack(spacing: 6) {
                Typeface.text(item.entry.label, 14, current ? .semibold : .regular)
                    .foregroundStyle(undone ? .tertiary : current ? .primary : .secondary)
                    .strikethrough(undone, color: Theme.ink3)
                if item.indices.count > 1 {
                    Text("×\(item.indices.count)")
                        .font(Typeface.font(12, .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if undone {
                    Text("Undone").font(Typeface.font(12)).foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 20)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.rule)
                .frame(width: 1)
                .padding(.top, first ? 18 : 0)
                .frame(maxHeight: last ? 18 : .infinity, alignment: .top)
                .padding(.leading, 4.5)
        }
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.ink.opacity(current ? 0.05 : 0))
                .padding(.horizontal, 12)
        )
    }
}
