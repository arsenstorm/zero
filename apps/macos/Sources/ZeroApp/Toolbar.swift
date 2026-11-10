import AppKit
import SwiftUI
import ZeroCore

// The workspace window's toolbar: back and forward beside the window's buttons, close together as Codex's are (two
// toolbar items would sit as far apart as AppKit spaces items), then the rest of the row as the page's title bar.
extension AppDelegate: NSToolbarDelegate {
    private static let history = NSToolbarItem.Identifier("history")
    private static let title = NSToolbarItem.Identifier("title")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.history, Self.title] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.history, Self.title] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool)
        -> NSToolbarItem?
    {
        switch id {
        case Self.history: return HistoryItem(identifier: id, navigation: navigation, target: self)
        case Self.title:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = TitleBarHost(workspace: workspace, navigation: navigation)
            item.isBordered = false
            item.label = "Title"
            return item
        default: return nil
        }
    }
}

/// The title bar's SwiftUI, stretched over the rest of the toolbar's row and told where the page starts in it, so the
/// task's name lines up with the page below.
private final class TitleBarHost: NSView {
    private let workspace: Workspace
    private let navigation: Navigation
    private let host: NSHostingView<TitleBar>
    private var inset: CGFloat = 0

    init(workspace: Workspace, navigation: Navigation) {
        self.workspace = workspace
        self.navigation = navigation
        host = NSHostingView(rootView: TitleBar(workspace: workspace, navigation: navigation, inset: 0))
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28), widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        // As wide as the row lets it be.
        let wide = widthAnchor.constraint(equalToConstant: 10_000)
        wide.priority = .defaultLow
        wide.isActive = true
        setContentHuggingPriority(.init(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let start = pageStart - convert(NSPoint.zero, to: nil).x
        if abs(start - inset) > 0.5 {
            inset = start
            host.rootView = TitleBar(workspace: workspace, navigation: navigation, inset: start)
        }
    }
}

private final class HistoryItem: NSToolbarItem {
    private let navigation: Navigation
    private let back: NSButton
    private let forward: NSButton

    init(identifier: NSToolbarItem.Identifier, navigation: Navigation, target: AppDelegate) {
        self.navigation = navigation
        func button(_ icon: String, _ label: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: Nucleo.image(icon, size: 15) ?? NSImage(), target: target, action: action)
            button.setAccessibilityLabel(label)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = label
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            return button
        }
        back = button("arrow-left", "Back", #selector(AppDelegate.goBack))
        forward = button("arrow-right", "Forward", #selector(AppDelegate.goForward))
        super.init(itemIdentifier: identifier)
        let pair = NSStackView(views: [back, forward])
        pair.spacing = 6
        view = pair
        label = "Back and forward"
        isBordered = false // no glass capsule around the pair
    }

    /// AppKit asks as the window updates; the arrows dim where there's nowhere to go.
    override func validate() {
        view?.isHidden = !navigation.ready
        back.isEnabled = navigation.canGoBack
        forward.isEnabled = navigation.canGoForward
    }
}
