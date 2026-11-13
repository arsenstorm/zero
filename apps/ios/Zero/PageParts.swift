import SwiftUI

// A page's parts, built as Later's list is: white, everything on the title's column (20 pt in), each row an icon then
// its words, a value in grey on the right. Settings and Record are made of them so they read as the app's own pages.
// (Grey cards for every group read as a form re-skinned; the system's grouped form, a grey page of white blocks.)

/// A group of rows under a small grey heading on the page's column, a note under it.
struct PageGroup<Content: View>: View {
    var title: String? = nil
    var note: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4) }
            content()
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

/// A row: its icon, what it is, and its value (or what it leads to) in grey on the right.
struct PageRow: View {
    let title: String
    var value: String? = nil
    var icon: String? = nil
    /// A small mark at the end (an arrow for what opens elsewhere).
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let icon { Image(icon).resizable().frame(width: 20, height: 20) }
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
            if let trailing { Image(trailing).resizable().frame(width: 14, height: 14).foregroundStyle(.secondary) }
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }
}

/// An action, as a row: red when it takes something away.
struct PageAction: View {
    let title: String
    var icon: String? = nil
    var trailing: String? = nil
    var destructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            PageRow(title: title, icon: icon, trailing: trailing)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

/// A page of groups, scrolling: room under the title, and between groups.
struct PageScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content() }.padding(.top, 12)
        }
    }
}

/// A page's action, the page's width: Zero's ink when it's the one to press, glass when it isn't. The app's one
/// button for a page's actions (pairing, Later's, a task that didn't load).
struct WideButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold))
                .foregroundStyle(prominent ? Theme.onKnob : Color.primary)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background { if prominent { Capsule().fill(Theme.knob) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? .identity : .regular.interactive(), in: Capsule())
    }
}

/// A page with nothing on it, the app's one way of saying so (the Mac's empty pages): its icon, a headline, a line on
/// what would show here.
struct EmptyPage: View {
    let icon: String
    let title: String
    let line: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(icon).resizable().frame(width: 28, height: 28).foregroundStyle(.secondary)
            }
        } description: {
            Text(line)
        }
        .allowsHitTesting(false)
    }
}

/// Renaming a task: Zero's own small sheet, as New task's top (close, its name, done) and the Mac's NameSheet.
struct RenameSheet: View {
    @Binding var name: String
    let rename: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    private var ready: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image("xmark-outline").resizable().frame(width: 20, height: 20).frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()).accessibilityLabel("Close")
                Spacer()
                Text("Rename task").font(.headline)
                Spacer()
                SendCircle(ready: ready, sending: false, label: "Rename", action: submit)
            }
            TextField("Name", text: $name).font(.title3).focused($focused).submitLabel(.done).onSubmit(submit)
                .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .padding(16)
        .presentationDetents([.height(150)])
        .onAppear { focused = true }
    }

    private func submit() {
        guard ready else { return }
        rename()
        dismiss()
    }
}

extension View {
    /// The app's one card, as the Mac's card(): a raised surface, its radius, a hairline round it.
    func zeroCard() -> some View {
        background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(.quaternary))
    }
}
