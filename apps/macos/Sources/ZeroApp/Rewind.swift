import AppKit
import SwiftUI
import ZeroCore

/// Where to rewind to: your messages, latest first, picked with the arrows and Return (or a click); Esc closes it.
/// The pick opens RewindCard for the how.
struct RewindPicker: View {
    let messages: [ConversationItem]
    let close: () -> Void
    let pick: (ConversationItem) -> Void
    @State private var index = 0
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rewind to").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(messages.count) message\(messages.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { i, item in
                                Button { pick(item) } label: {
                                    HStack(spacing: 12) {
                                        Text(Self.gist(item)).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                                        if let date = item.date {
                                            Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                                                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        NucleoIcon("chevron-right", size: 11).foregroundStyle(.tertiary).opacity(i == index ? 1 : 0)
                                    }
                                    .padding(.horizontal, 10).frame(height: 32)
                                    .background(i == index ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in if inside { index = i } }
                                .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .thinScrollbar(outset: 2)
                    .scrollIndicators(.never)
                    // As tall as its rows, up to nine: no room left under a short list.
                    .frame(height: 12 + 33 * CGFloat(min(messages.count, 9)) - 1)
                    .onChange(of: index) { if index < messages.count { proxy.scrollTo(messages[index].id) } }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 14) {
                    key("↑↓", "Choose")
                    key("↩", "Pick")
                    key("esc", "Close")
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .frame(width: 460, alignment: .leading)
            .card()
            .compositingGroup()
            .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
        }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: index = min(index + 1, messages.count - 1); return nil // ↓
                case 126: index = max(index - 1, 0); return nil // ↑
                case 36, 76: if index < messages.count { pick(messages[index]) }; return nil // Return
                case 53: close(); return nil
                default: return event
                }
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    /// A key and what it does, as the footer of a menu names them.
    private func key(_ cap: String, _ does: String) -> some View {
        HStack(spacing: 5) {
            Text(cap).font(.system(size: 10.5, weight: .medium)).monospacedDigit().padding(.horizontal, 5).frame(height: 17)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
            Text(does).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    /// The message's first line, its image tokens read as words ("an image", "2 images").
    private static func gist(_ item: ConversationItem) -> String {
        guard case let .user(text, images) = item.kind else { return "" }
        let words = ConversationItem.from(text)?.text ?? text
        let line = words.replacingOccurrences(of: #"\s*\[Image #\d+\]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let pictures = images.isEmpty ? "" : (images.count == 1 ? "an image" : "\(images.count) images")
        return line.isEmpty ? (pictures.isEmpty ? words : pictures.prefix(1).uppercased() + pictures.dropFirst()) : (pictures.isEmpty ? line : "\(line) · \(pictures)")
    }
}

struct RewindCard: View {
    let workspace: Workspace
    let task: String
    let item: ConversationItem
    let close: () -> Void
    let rewound: (Rewound, Bool) -> Void
    let branched: (String) -> Void
    @State private var preview: RewindPreview?
    @State private var busy = false
    @State private var hovered: String?

    private var text: String { if case let .user(text, _) = item.kind { text } else { "" } }
    private var kept: Bool { preview?.snapshot == true }

    var body: some View {
        ZStack {
            // Outside the card: never mind.
            Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 4) {
                Text("Rewind").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.top, 6)
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 10)
                Text(folder).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 6)
                row("both", "Restore conversation and code", "Back to before this message, files and all", enabled: kept) { go(conversation: true, code: true) }
                row("conversation", "Restore conversation", "The files stay as they are now") { go(conversation: true, code: false) }
                row("code", "Restore code", "The conversation carries on as it is", enabled: kept) { go(conversation: false, code: true) }
                row("branch", "Branch from here", "A new task from before this message; this one stays") { branch() }
                Button("Never mind", action: close).keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
            }
            .padding(8)
            .frame(width: 440, alignment: .leading)
            .card()
            .compositingGroup()
            .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
            .disabled(busy)
        }
        .task { preview = await workspace.rewindPreview(task, message: item.id) }
    }

    /// What restoring the code would undo, or why it can't.
    private var folder: String {
        guard let preview else { return "Looking at the folder…" }
        guard preview.snapshot else { return "Zero didn't keep the folder for this message, so only the conversation can go back." }
        let files = preview.files ?? 0
        if files == 0 { return "The folder hasn't changed since this message." }
        return "Since this message: \(files) file\(files == 1 ? "" : "s") changed, +\(preview.insertions ?? 0) −\(preview.deletions ?? 0)."
    }

    private func go(conversation: Bool, code: Bool) {
        busy = true
        Task {
            if let back = await workspace.rewind(task, message: item.id, conversation: conversation, code: code) { rewound(back, conversation) }
            busy = false
            close()
        }
    }

    private func branch() {
        busy = true
        Task {
            let made = await workspace.branch(task, message: item.id)
            busy = false
            close()
            if let id = made?.session { branched(id) }
        }
    }

    private func row(_ id: String, _ title: String, _ detail: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered == id && enabled ? Theme.row : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { inside in if inside { hovered = id } else if hovered == id { hovered = nil } }
    }
}
