import AppKit
import Observation
import SwiftUI
import ZeroCore

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
