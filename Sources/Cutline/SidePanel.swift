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
    var startNote: () -> Void
    @Namespace private var tabs

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                tabButton(.notes, count: doc.openComments.count)
                tabButton(.history, count: nil)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 54)
            Rectangle().fill(Theme.rule).frame(height: 0.5)
            switch tab {
            case .notes: notes
            case .history: HistoryList(doc: doc)
            }
        }
        .background(Theme.panel)
    }

    private func tabButton(_ t: PanelTab, count: Int?) -> some View {
        let on = tab == t
        return Button {
            withAnimation(.smooth(duration: 0.25)) { tab = t }
        } label: {
            HStack(spacing: 7) {
                Text(t.rawValue)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Typeface.font(11.5, .semibold).monospacedDigit())
                        .foregroundStyle(on ? Theme.desk : Theme.ink2)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 19, minHeight: 18)
                        .background(Capsule().fill(on ? Theme.wax : Theme.raised))
                }
            }
            .font(Typeface.font(14, .medium))
            .foregroundStyle(on ? Theme.ink : Theme.ink3)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if on {
                    Capsule().fill(Theme.ink).frame(height: 2).matchedGeometryEffect(id: "tab", in: tabs)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Notes

    private var notes: some View {
        VStack(spacing: 0) {
            if let d = draft {
                NoteComposer(time: d.time, pinned: d.x != nil, fps: doc.project.canvas.fps) { text in
                    doc.addComment(text: text, time: d.time, x: d.x, y: d.y)
                    draft = nil
                } cancel: { draft = nil }
                Rectangle().fill(Theme.rule).frame(height: 0.5)
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
                                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 12)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("No notes yet")
                .font(Typeface.font(16, .medium))
                .foregroundStyle(Theme.ink)
            Text("Pause where something should change, press C, and click the spot on the frame. Claude reads every open note.")
                .font(Typeface.font(14))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(3)
            Button(action: startNote) {
                HStack(spacing: 6) {
                    Text("Add note at")
                    Text(Theme.compact(doc.player.time, fps: doc.project.canvas.fps)).monospacedDigit()
                }
            }
            .buttonStyle(QuietButtonStyle(bordered: true))
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 28)
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
                    .foregroundStyle(resolved ? Theme.ink2 : Theme.ink)
                Text(Theme.compact(comment.time, fps: fps))
                    .font(Typeface.font(12).monospacedDigit())
                    .foregroundStyle(human && !resolved ? Theme.wax : Theme.ink3)
                Spacer(minLength: 4)
                if hovering || selected {
                    actions(resolved: resolved)
                        .transition(.opacity)
                } else if resolved {
                    Label("Resolved", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(Typeface.font(12))
                        .foregroundStyle(Theme.ink3)
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
                    .foregroundStyle(Theme.ink)
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
                .fill(Theme.ink.opacity(selected ? 0.06 : hovering ? 0.03 : 0))
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
                HStack(spacing: 5) {
                    Image(systemName: resolved ? "arrow.uturn.backward" : "checkmark").font(.system(size: 10, weight: .bold))
                    Text(resolved ? "Reopen" : "Resolve")
                }
                .font(Typeface.font(12.5, .medium))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Theme.ink.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            Button("Reply") { replying = true }
                .buttonStyle(.plain)
                .font(Typeface.font(12.5, .medium))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .fixedSize()
            Menu {
                Button("Delete note", role: .destructive) { doc.deleteComment(comment.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .foregroundStyle(Theme.ink3)
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
                    .foregroundStyle(Theme.ink3)
            }
            TextField("What should change here?", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .font(Typeface.font(14.5))
                .foregroundStyle(Theme.ink)
                .lineSpacing(4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.wax.opacity(focused ? 0.6 : 0.25), lineWidth: 1))
                .focused($focused)
                .onSubmit(submit)
            HStack(spacing: 6) {
                Text("Return to add").font(Typeface.font(12)).foregroundStyle(Theme.ink3)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).buttonStyle(QuietButtonStyle())
                Button("Add note", action: submit).buttonStyle(QuietButtonStyle(prominent: true))
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
        if age < 120 { return "Just now" }
        if age < 900 { return "Last 15 minutes" }
        if age < 3600 { return "Last hour" }
        if Calendar.current.isDate(d, inSameDayAs: now) { return "Earlier today" }
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
                            .foregroundStyle(Theme.ink3)
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
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Theme.panel.opacity(0), Theme.panel], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .allowsHitTesting(false)
        }
    }

    private func row(_ item: Row, first: Bool, last: Bool) -> some View {
        let current = item.indices.contains(doc.history.cursor)
        let undone = item.indices.allSatisfy { $0 > doc.history.cursor }
        return HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(current ? Theme.claude : undone ? Theme.panel : Theme.ink3)
                .overlay(Circle().strokeBorder(undone ? Theme.ink3 : .clear, lineWidth: 1))
                .frame(width: current ? 10 : 7, height: current ? 10 : 7)
                .frame(width: 10, height: 20)
            HStack(spacing: 6) {
                Typeface.text(item.entry.label, 14, current ? .semibold : .regular)
                    .foregroundStyle(undone ? Theme.ink3 : current ? Theme.ink : Theme.ink2)
                    .strikethrough(undone, color: Theme.ink3)
                if item.indices.count > 1 {
                    Text("×\(item.indices.count)")
                        .font(Typeface.font(12, .medium).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                }
                if undone {
                    Text("Undone").font(Typeface.font(12)).foregroundStyle(Theme.ink3)
                }
            }
            .frame(minHeight: 20)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.16))
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
