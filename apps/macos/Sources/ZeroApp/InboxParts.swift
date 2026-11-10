import AppKit
import Observation
import SwiftUI
import ZeroCore

/// The agent's terminal, in Zero, for the pickers slash commands open: the rendered screen below its
/// separator, keys for the pointer (the keyboard already goes straight through), and a close.
struct ScreenCard: View {
    let agent: String
    let screen: String
    @Bindable var controller: InboxController

    private static let keys: [(String, [UInt8])] = [
        ("↑", [27, 91, 65]), ("↓", [27, 91, 66]), ("←", [27, 91, 68]), ("→", [27, 91, 67]), ("⏎", [13]), ("Esc", [27]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Screen").font(.system(size: 12, weight: .medium))
                Text(controller.store.displayName(of: agent)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                ForEach(Self.keys, id: \.0) { label, bytes in
                    Button {
                        controller.store.press(bytes, on: agent)
                    } label: {
                        Text(label).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .frame(minWidth: 22, minHeight: 20).padding(.horizontal, 4)
                            .background(Theme.keycap).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Button {
                    controller.store.closeScreen(of: agent)
                } label: {
                    NucleoIcon("xmark", size: 13).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).offset(x: 4)
            }
            .frame(height: 20)
            Text(visible.isEmpty ? "Waiting for the agent's screen…" : visible)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .card()
    }

    /// What the agent has open: everything below its last separator line, else the last 20 lines, with the
    /// blank run at the end gone.
    private var visible: String {
        var lines = screen.components(separatedBy: "\n")
        if let separator = lines.lastIndex(where: { $0.hasPrefix("▔▔▔") || $0.hasPrefix("───") }) {
            lines = Array(lines[(separator + 1)...])
        } else {
            lines = Array(lines.suffix(20))
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : $0 }.joined(separator: "\n")
    }
}

/// Chat-bubble width: the content is offered up to `max` points and the view takes exactly what it uses, so a
/// short line gets a short bubble. (A `maxWidth` frame claims the whole cap whenever the column offers it.)
struct BubbleWidth: ViewModifier {
    let hug: Bool
    let max: CGFloat
    func body(content: Content) -> some View {
        if hug { HuggingWidth(max: max) { content } } else { content.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct HuggingWidth: Layout {
    let max: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? max, max)
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        return CGSize(width: min(size.width, width), height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The "/" and "@" suggestions: commands and skills with what they do, files by name with their folder.
struct MentionList: View {
    let state: InboxController.MentionState
    let pick: (Int) -> Void
    let hover: (Int) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                Button {
                    pick(index)
                } label: {
                    HStack(spacing: 8) {
                        NucleoIcon(item.kind == .file ? "file" : item.kind == .loop ? "animation-repeat" : "command", size: 13)
                            .foregroundStyle(.secondary).frame(width: 14)
                        Text(title(item)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let detail = detail(item) {
                            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(item.kind == .file ? .head : .tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(index == state.selected ? Theme.row : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { hover(index) } }
            }
        }
        .padding(6)
        .card()
    }

    private func title(_ item: Mention) -> String {
        item.kind == .file ? "@" + (item.insert.dropFirst() as Substring).split(separator: "/").last.map(String.init)! : item.insert
    }

    private func detail(_ item: Mention) -> String? {
        guard item.kind == .file else { return item.detail }
        let dir = (String(item.insert.dropFirst()) as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }
}

/// Copies a command in one click; a tick and "Copied" for a moment say it did.
struct CopyCommand: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5)); copied = false
            }
        } label: {
            NucleoLabel(copied ? "Copied" : "Copy", icon: copied ? "circle-check" : "copy", size: 12)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).tip("Copy the command")
    }
}
