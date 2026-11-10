import SwiftUI

/// The phone's way around: a glass pill of the places as icons (Inbox, Tasks, Later) and a ⌃⌄ that opens it, in place,
/// into the menu (the workspace, each place by name, recording, settings); New task a circle of its own beside it.
struct NavBar: View {
    static let height: CGFloat = 62
    @Bindable var model: PhoneModel
    @Binding var open: Bool
    let newTask: () -> Void
    @Namespace private var glass
    @State private var choosingWorkspace = false

    private static let places: [(PhoneModel.Place, String, String)] = [
        (.inbox, "Inbox", "inbox-glyph"), (.tasks, "Tasks", "list-checkbox-glyph"), (.later, "Later", "bookmark-glyph"),
    ]
    /// The pages only the menu leads to; while one is open, the menu's slot shows it, as Linear's does.
    private static let menuPages: [(PhoneModel.Place, String, String)] = [
        (.record, "Record your screen", "record-glyph"), (.settings, "Settings", "gear-outline"),
    ]
    /// What's selected sits on: a lighter capsule, as Linear's (a set colour: a semantic one on glass comes out faint).
    static let here = Color(
        uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.08) })

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .bottom, spacing: 14) {
                // The whole width beside New task; the menu opens at the same width.
                if open { menu } else { pill }
                Button(action: newTask) {
                    Image("plus-outline").resizable().frame(width: 22, height: 22)
                        .frame(width: Self.height, height: Self.height).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("New task")
            }
        }
        .padding(.horizontal, 20)
    }

    private var pill: some View {
        HStack(spacing: 0) {
            ForEach(Self.places, id: \.0) { place, title, image in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.tab = place }
                } label: {
                    Image(image).resizable().frame(width: 22, height: 22)
                        // A dot while something waits on the user; its count is in the menu.
                        .overlay(alignment: .topTrailing) {
                            if place == .inbox && !model.waiting.isEmpty {
                                Circle().fill(.blue).frame(width: 9, height: 9).offset(x: 4, y: -4)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: Self.height - 12)
                        .background { if model.tab == place { Capsule().fill(Self.here).matchedGeometryEffect(id: "here", in: glass) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
            }
            // The menu, or while on a page it leads to, that page: its icon, a small ⌃⌄ beside it, selected.
            let page = Self.menuPages.first { $0.0 == model.tab }
            Button {
                setOpen(true)
            } label: {
                HStack(spacing: 6) {
                    if let page {
                        Image(page.2).resizable().frame(width: 22, height: 22)
                        Image("chevron-expand-y-outline").resizable().frame(width: 12, height: 12).foregroundStyle(.secondary)
                    } else {
                        Image("chevron-expand-y-outline").resizable().frame(width: 22, height: 22)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: Self.height - 12)
                .background { if page != nil { Capsule().fill(Self.here).matchedGeometryEffect(id: "here", in: glass) } }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(page.map { "\($0.1), menu" } ?? "Menu")
        }
        .padding(6)
        .glassEffect(.regular.interactive(), in: Capsule())
        .glassEffectID("nav", in: glass)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            workspace
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            if choosingWorkspace {
                ForEach(model.workspaces) { space in
                    row(Home.title(space), image: nil, selected: space.id == model.currentWorkspace?.id) {
                        model.switchWorkspace(space.id)
                        setOpen(false)
                    }
                }
            } else {
                ForEach(Self.places, id: \.0) { place, title, image in
                    row(title, image: image, selected: model.tab == place, count: place == .inbox ? model.waiting.count : 0) {
                        model.tab = place
                        setOpen(false)
                    }
                }
                ForEach(Self.menuPages, id: \.0) { place, title, image in
                    row(title, image: image, selected: model.tab == place) {
                        model.tab = place
                        setOpen(false)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        // Concentric: the rows' capsules (25) plus the inset (8) make the card's corners.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 33, style: .continuous))
        .glassEffectID("nav", in: glass)
    }

    /// The workspace shown, as the Mac's sidebar heading has it; with others, tapping it lists them here.
    private var workspace: some View {
        Button {
            if model.workspaces.count > 1 { withAnimation(.snappy(duration: 0.25)) { choosingWorkspace.toggle() } }
        } label: {
            HStack(spacing: 12) {
                Logo(size: 26)
                Text(model.currentWorkspace.map(Home.title) ?? "Zero").font(.body.weight(.semibold)).lineLimit(1)
                if model.workspaces.count > 1 {
                    Image("chevron-expand-y-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, image: String?, selected: Bool = false, count: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let image { Image(image).resizable().frame(width: 22, height: 22) }
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                if count > 0 {
                    Text("\(count)").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24).background(.blue, in: Capsule())
                }
                if image == nil && selected {
                    Image("circle-check-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14).frame(height: 50)
            .background { if selected && image != nil { Capsule().fill(Self.here) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func setOpen(_ value: Bool) {
        withAnimation(.bouncy(duration: 0.35)) {
            open = value
            if !value { choosingWorkspace = false }
        }
    }
}
