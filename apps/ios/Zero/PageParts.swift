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
