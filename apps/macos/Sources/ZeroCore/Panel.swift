import Foundation
import Observation

/// A browser tab in a task's side panel: the task's own, kept with it.
public struct PanelTab: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Empty: a new tab, its page the task's links.
    public var url: String
    public var title: String
    /// Who opened it: nil for the user. Kept for when agents open tabs of their own (their session).
    public var openedBy: String?
    /// Where it stood when it was closed, to reopen it there.
    public var place: Int?

    public init(id: String = UUID().uuidString, url: String = "", title: String = "", openedBy: String? = nil) {
        self.id = id; self.url = url; self.title = title; self.openedBy = openedBy
    }

    public var isNew: Bool { url.isEmpty }
}

/// One task's tabs: the browser tabs in order, the one shown (nil is Details), and the few last closed.
public struct PanelTabs: Codable, Equatable, Sendable {
    public var tabs: [PanelTab] = []
    public var selected: String?
    public var closed: [PanelTab] = []
    static let closedKept = 5

    public init() {}

    public var shown: PanelTab? { tabs.first { $0.id == selected } }

    /// A new tab, shown: the blank one already there if there is one, rather than a second.
    public mutating func newTab() {
        if let blank = tabs.first(where: \.isNew) { selected = blank.id; return }
        let tab = PanelTab()
        tabs.append(tab)
        selected = tab.id
    }

    /// A page in a tab, shown: the tab already on it, else the blank one shown, else a new one.
    public mutating func open(_ url: String, title: String = "") {
        if let there = tabs.first(where: { $0.url == url }) { selected = there.id; return }
        if let shown, shown.isNew, let index = tabs.firstIndex(of: shown) {
            tabs[index].url = url; tabs[index].title = title
            return
        }
        let tab = PanelTab(url: url, title: title)
        tabs.append(tab)
        selected = tab.id
    }

    /// Closed, the tab to its right is shown (else the one to its left, else Details); a page is kept to reopen.
    public mutating func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs.remove(at: index)
        tab.place = index
        if !tab.isNew {
            closed.removeAll { $0.url == tab.url }
            closed.insert(tab, at: 0)
            if closed.count > Self.closedKept { closed.removeLast(closed.count - Self.closedKept) }
        }
        guard selected == id else { return }
        selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }

    /// The tab last closed, back in its place and shown (⌘⇧T); false when none is kept.
    public mutating func reopen() -> Bool {
        guard !closed.isEmpty else { return false }
        var tab = closed.removeFirst()
        let place = min(tab.place ?? tabs.count, tabs.count)
        tab.place = nil
        tabs.insert(tab, at: place)
        selected = tab.id
        return true
    }

    /// ⌘1 to ⌘8: the strip's tab at that place, Details first; ⌘9: the last. None at that place: no change.
    public mutating func select(position: Int) {
        let order: [String?] = [nil] + tabs.map(\.id)
        if position == 9 {
            selected = order[order.count - 1]
        } else if order.indices.contains(position - 1) {
            selected = order[position - 1]
        }
    }

    /// The next tab (or one back), Details among them, round from the last to the first: ⌃Tab, ⌃⇧Tab.
    public mutating func step(_ by: Int) {
        let order: [String?] = [nil] + tabs.map(\.id)
        let at = order.firstIndex(of: selected) ?? 0
        selected = order[((at + by) % order.count + order.count) % order.count]
    }

    /// Where a tab's page went, as its engine says.
    public mutating func visited(_ id: String, url: String, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].url != url { tabs[index].url = url }
        if tabs[index].title != title { tabs[index].title = title }
    }
}

/// How wide the panel is: one width for every tab and task, so changing either never moves the conversation.
public enum PanelWidth {
    public static let least: Double = 320
    /// The conversation keeps this much beside it.
    public static let conversationLeast: Double = 400
    static let most: Double = 560
    /// The rail (48), the panel's inset (4), the sidebar and its line, the conversation, the divider, the panel.
    public static func windowLeast(sidebar: Double) -> Double { 48 + 4 + sidebar + 1 + conversationLeast + 1 + least }

    /// Whether the tabs not shown are cut to their icons: when the strip (from the panel's edge to its toggle) leaves
    /// each, after Details, + and the one shown, less than a readable title (100).
    public static func compactTabs(strip: Double, tabs: Int) -> Bool {
        guard tabs > 1 else { return false }
        let room = strip - 90 - 30 - 168
        return room / Double(tabs - 1) < 100
    }

    /// The panel's width on a page this wide: the one dragged to (nil: 46% of the page, at most 560), never narrower
    /// than its least, nor so wide the conversation gets less than its own.
    public static func width(page: Double, wanted: Double?) -> Double {
        let wanted = wanted ?? min(most, (page * 0.46).rounded())
        return max(least, min(wanted, page - 1 - conversationLeast))
    }
}

/// What's typed in a tab's address bar, as a page to load: an address as it is (https:// added; http:// for a local
/// server), anything else a search.
public enum PanelAddress {
    public static func url(from typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return text }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasPrefix("0.0.0.0")
        if local { return "http://" + text }
        if !text.contains(" "), text.contains(".") { return "https://" + text }
        // ponytail: one search engine, a setting if anyone asks for another.
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url?.absoluteString
    }
}

/// Where a link clicked in the panel goes: to an app when Zero would open it in one (Linear's when the user has it
/// open Linear links, Slack's for a connected workspace, Zero's own zero://, mailto: and any other app's scheme), as
/// the conversation's links do; only a web page that would go to the web browser opens in a panel tab instead.
public enum LinkRoute {
    /// The app's link to open, or nil for a web page.
    public static func app(_ url: URL, linearApp: Bool, slack: [Slack.State]) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return url }
        let linear = "https://linear.app/"
        if linearApp, url.absoluteString.hasPrefix(linear) { return URL(string: "linear://" + url.absoluteString.dropFirst(linear.count)) }
        return SlackLinks.url(url, in: slack)
    }
}

/// Every task's panel tabs, kept in the app's defaults by task, and the panel's width.
@MainActor @Observable
public final class Panels {
    public static let shared = Panels()
    static let tabsKey = "panelTabs"
    static let widthKey = "panelWidth"

    private var all: [String: PanelTabs]
    @ObservationIgnored private let defaults: UserDefaults
    /// The width dragged to; nil until the divider is first dragged.
    public var wanted: Double? { didSet { defaults.set(wanted, forKey: Self.widthKey) } }
    /// The width the open panel has now (its wanted one, fitted to the page), for the title bar's tabs above it.
    public var shown: Double = PanelWidth.least

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = defaults.data(forKey: Self.tabsKey).flatMap { try? JSONDecoder().decode([String: PanelTabs].self, from: $0) } ?? [:]
        wanted = defaults.object(forKey: Self.widthKey) as? Double
    }

    public func tabs(_ task: String) -> PanelTabs { all[task] ?? PanelTabs() }

    /// A change to a task's tabs, kept.
    public func change(_ task: String, _ change: (inout PanelTabs) -> Void) {
        var tabs = all[task] ?? PanelTabs()
        change(&tabs)
        guard tabs != all[task] else { return }
        all[task] = tabs
        // ponytail: an archived task's tabs stay in defaults; prune by the roster if they ever add up.
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.tabsKey) }
    }
}
