import AppKit
import SwiftUI
import ZeroCore

// A task's right side as a panel with tabs, as Codex's: the conversation narrows to a column on the left, the panel
// takes the rest. Its first tab is the task's details, always there; then the task's browser tabs, and + for a new
// one. Opened from the title bar's right end (⌥⌘B); its tabs sit in the title bar's row, above it.

// MARK: - Tabs, in the title bar

/// Details, the task's browser tabs, +: from the panel's left edge, in the title bar's row.
struct PanelTabStrip: View {
    let task: String

    var body: some View {
        let tabs = Panels.shared.tabs(task)
        let compact = PanelWidth.compactTabs(strip: Panels.shared.shown - 40, tabs: tabs.tabs.count)
        HStack(spacing: 2) {
            PanelTabButton(title: "Details", icon: "circle-info", selected: tabs.selected == nil, fixed: true) {
                Panels.shared.change(task) { $0.selected = nil }
            }
            ForEach(tabs.tabs) { tab in
                PanelTabButton(
                    title: tab.isNew ? "New tab" : tab.title.isEmpty ? SidePanel.shown(tab.url) : tab.title, icon: "globe",
                    agent: tab.openedBy != nil, selected: tabs.selected == tab.id, iconOnly: compact && tabs.selected != tab.id,
                    close: { SidePanel.close(tab.id, in: task) }
                ) {
                    Panels.shared.change(task) { $0.selected = tab.id }
                }
            }
            Button {
                Panels.shared.change(task) { $0.newTab() }
            } label: {
                NucleoIcon("plus", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(Hovering(radius: 7)).tip("New tab", shortcut: "⌘T").fixedSize()
            Spacer(minLength: 0)
        }
        .frame(height: 28)
    }
}

/// A tab: its icon, its title cut short, and on a browser tab its ×, on the one shown or under the pointer. Browser
/// tabs share the row, 72 to 168 wide each (Safari's way); Details keeps its words.
private struct PanelTabButton: View {
    let title: String
    let icon: String
    /// Opened by an agent: its pixel mark in place of the globe.
    var agent = false
    let selected: Bool
    var fixed = false
    /// No room for a readable title: its icon alone, its title on hover.
    var iconOnly = false
    var close: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        if iconOnly {
            Button(action: action) {
                Group {
                    if agent { PixelIcon("px-robot", height: 12) } else { NucleoIcon(icon, size: 13) }
                }
                .foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(Hovering(radius: 7, fill: Theme.railHover, hover: Theme.railHover)).tip(title)
        } else {
            titled
        }
    }

    private var titled: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if agent {
                    PixelIcon("px-robot", height: 12).foregroundStyle(.secondary)
                } else {
                    NucleoIcon(icon, size: 13).foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 12.5, weight: selected ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected ? .primary : .secondary)
                if !fixed { Spacer(minLength: 0) }
                if let close {
                    Button(action: close) {
                        NucleoIcon("xmark", size: 10).foregroundStyle(.secondary).frame(width: 16, height: 16)
                    }
                    .buttonStyle(Hovering(radius: 4)).opacity(selected || hovered ? 1 : 0).tip("Close tab")
                }
            }
            .padding(.leading, 9).padding(.trailing, fixed ? 10 : 5)
            .frame(minWidth: fixed ? nil : 72, maxWidth: fixed ? nil : 168, minHeight: 28, maxHeight: 28)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.card).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
                } else if hovered {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.railHover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .fixedSize(horizontal: fixed, vertical: false)
        .tip(agent ? "Opened by its agent" : "")
    }
}

// MARK: - The panel

/// What the panel shows under its tabs: the details, or a tab's page under its address bar.
struct SidePanel: View {
    let workspace: Workspace
    let inbox: InboxController
    let navigation: Navigation
    /// The task the tabs belong to: the lead, whichever of its workers is shown.
    let task: String
    let row: BoardRow?
    let conversation: Conversation

    var body: some View {
        let tabs = Panels.shared.tabs(task)
        Group {
            if let tab = tabs.shown {
                VStack(spacing: 0) {
                    BrowserBar(task: task, tab: tab)
                    Hairline()
                    if tab.isNew {
                        NewTabPage(workspace: workspace, row: row, conversation: conversation, closed: tabs.closed) { open($0) }
                    } else {
                        let page = WebPages.page(for: tab)
                        WebPageView(page: page).id(tab.id)
                            .onAppear {
                                page.changed = { [task, id = tab.id] url, title in
                                    Panels.shared.change(task) { $0.visited(id, url: url, title: title) }
                                }
                            }
                    }
                }
            } else {
                TaskDetails(workspace: workspace, inbox: inbox, navigation: navigation, row: row, conversation: conversation) { open($0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        // ⌘T and ⌘L while the panel shows: a new tab; the address bar (a new tab's is focused already).
        .background {
            Button("") { Panels.shared.change(task) { $0.newTab() } }.keyboardShortcut("t", modifiers: .command).hidden()
            Button("") { BrowserBar.focus.value += 1 }.keyboardShortcut("l", modifiers: .command).hidden()
            Button("") { Panels.shared.change(task) { $0.step(1) } }.keyboardShortcut(.tab, modifiers: .control).hidden()
            Button("") { Panels.shared.change(task) { $0.step(-1) } }.keyboardShortcut(.tab, modifiers: [.control, .shift]).hidden()
        }
    }

    private func open(_ url: String) { Panels.shared.change(task) { $0.open(url) } }

    static func close(_ id: String, in task: String) {
        Panels.shared.change(task) { $0.close(id) }
        WebPages.close(id)
    }

    /// An address without its scheme, as Safari shows it.
    static func shown(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

/// Back, forward, reload, the address, and the tab's menu: one row, its controls the title bar's size.
private struct BrowserBar: View {
    let task: String
    let tab: PanelTab
    /// Bumped by ⌘L: the address bar shown takes the keyboard.
    @MainActor static let focus = Bump()
    @State private var typed = ""
    @State private var editing = false
    @FocusState private var focused: Bool
    @State private var menuAnchor = CGRect.zero

    @MainActor @Observable final class Bump { var value = 0 }

    var body: some View {
        let page = tab.isNew ? nil : WebPages.existing(tab.id)
        HStack(spacing: 2) {
            button("arrow-left", "Back", page?.canGoBack == true) { page?.back() }
            button("arrow-right", "Forward", page?.canGoForward == true) { page?.forward() }
            button("arrow-rotate-clockwise", page?.loading == true ? "Stop" : "Reload", page != nil) { page?.reload() }
            address(page).padding(.horizontal, 6)
            Button(action: unlessClicked(menu)) {
                NucleoIcon("dots", size: 15).foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(Hovering(radius: 7)).opensOnPress(menu).tip("More")
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                menuAnchor = $0
            }
        }
        .padding(.horizontal, 6).frame(height: 40)
        .onAppear { if tab.isNew { focused = true } }
        .onChange(of: tab.id) { if tab.isNew { focused = true } }
        .onChange(of: Self.focus.value) { focused = true }
    }

    /// The address as Safari shows it until clicked into; then the whole of it, to type over.
    private func address(_ page: WebPage?) -> some View {
        let url = page?.url ?? tab.url
        return HStack(spacing: 6) {
            if !tab.isNew, url.hasPrefix("https://"), !focused { NucleoIcon("lock", size: 11).foregroundStyle(.tertiary) }
            TextField("Search or enter an address", text: $typed)
                .textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused)
                .foregroundStyle(focused ? .primary : .secondary)
                .onSubmit {
                    guard let url = PanelAddress.url(from: typed) else { return }
                    focused = false
                    if let page { page.load(url) } else { Panels.shared.change(task) { $0.open(url) } }
                }
                .onExitCommand {
                    focused = false; typed = SidePanel.shown(url)
                }
        }
        .padding(.horizontal, 10).frame(height: 28).frame(maxWidth: .infinity)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.selectedStroke : Theme.fieldEdge))
        .onChange(of: focused) { typed = focused ? url : SidePanel.shown(url) }
        .onChange(of: url, initial: true) { if !focused { typed = SidePanel.shown(url) } }
    }

    private func menu() {
        let width = SelectorView.width(.menu)
        let anchor = CGRect(x: menuAnchor.maxX - width, y: menuAnchor.minY, width: width, height: menuAnchor.height)
        let (task, tab) = (task, tab)
        let url = WebPages.existing(tab.id)?.url ?? tab.url
        WorkspaceSelector.shared.toggle("panel-tab", kind: .menu, anchor: anchor) {
            ZeroContextMenu.sections(
                [
                    url.isEmpty
                        ? []
                        : [
                            MenuItem("Open in default browser", "arrow-up-right") {
                                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                            },
                            MenuItem("Copy link", "link") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
                            },
                        ],
                    [MenuItem("Close tab", "xmark") { SidePanel.close(tab.id, in: task) }],
                ].filter { !$0.isEmpty })
        }
    }

    private func button(_ icon: String, _ label: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIcon(icon, size: 15).foregroundStyle(.secondary).frame(width: 28, height: 28).opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(Hovering(radius: 7)).disabled(!enabled).tip(label)
    }
}

// MARK: - The new-tab page

/// A new tab: what the task already points at (its pull request, ticket, followed threads, a server its commands left
/// running) and the tabs last closed, a click away. No tools: Open in and Continue are in Details.
private struct NewTabPage: View {
    let workspace: Workspace
    let row: BoardRow?
    let conversation: Conversation
    let closed: [PanelTab]
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                let links = TaskLinksList.of(conversation, row: row, in: workspace).filter { !$0.url.isEmpty }
                if !links.isEmpty {
                    section("This task") {
                        ForEach(links) { link in
                            NewTabRow(icon: link.icon, title: link.title, detail: link.detail ?? Self.host(link.url)) { open(link.url) }
                        }
                    }
                }
                let servers = (workspace.left[conversation.id]?.things ?? []).compactMap { thing in
                    thing.name.firstMatch(of: #/(localhost|127\.0\.0\.1):\d+/#).map { (String($0.0), thing.name) }
                }
                if !servers.isEmpty {
                    section("Left running") {
                        ForEach(servers, id: \.0) { server in
                            NewTabRow(icon: "server", title: server.0, detail: server.1) { open("http://" + server.0) }
                        }
                    }
                }
                if !closed.isEmpty {
                    section("Recently closed") {
                        ForEach(closed) { tab in
                            NewTabRow(
                                icon: "globe", title: tab.title.isEmpty ? SidePanel.shown(tab.url) : tab.title, detail: Self.host(tab.url)
                            ) {
                                open(tab.url)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 28)
            .frame(maxWidth: .infinity)
        }
        .thinScrollbar()
        .background(Theme.composer)
    }

    static func host(_ url: String) -> String { URL(string: url)?.host() ?? url }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 2)
            VStack(spacing: 0) { rows() }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        }
    }
}

private struct NewTabRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                NucleoIcon(icon, size: 14).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(hovered ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}

// MARK: - The divider

/// The line between the conversation and the panel: dragged, it sets the panel's one width (whole points, within
/// both minimums); the width is kept for every task.
struct PanelDivider: View {
    /// The page's width, for the minimums.
    let page: Double
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let from = start ?? Panels.shared.shown
                                start = from
                                Panels.shared.wanted = PanelWidth.width(page: page, wanted: (from - drag.translation.width).rounded())
                            }
                            .onEnded { _ in start = nil })
            }
    }
}
