import AppKit
import SwiftUI
import WebKit
import ZeroCore

/// One tab's page, and the only place the panel meets a browser engine: it loads an address and says where it is,
/// what it's called, whether it's loading, and whether it can go back or forward. WebKit for now; the engine chosen
/// later replaces what's inside, not what's around it.
@MainActor @Observable
final class WebPage {
    private(set) var url = ""
    private(set) var title = ""
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Told whenever the address or title changes, so the tab keeps them.
    @ObservationIgnored var changed: (_ url: String, _ title: String) -> Void = { _, _ in }

    @ObservationIgnored let view: NSView
    @ObservationIgnored private let web: WKWebView
    @ObservationIgnored private var watching: [NSKeyValueObservation] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: configuration)
        web.allowsBackForwardNavigationGestures = true
        view = web
        watching = [
            web.observe(\.url, options: .new) { [weak self] web, _ in MainActor.assumeIsolated { self?.read(web) } },
            web.observe(\.title, options: .new) { [weak self] web, _ in MainActor.assumeIsolated { self?.read(web) } },
            web.observe(\.isLoading, options: .new) { [weak self] web, _ in MainActor.assumeIsolated { self?.read(web) } },
            web.observe(\.canGoBack, options: .new) { [weak self] web, _ in MainActor.assumeIsolated { self?.read(web) } },
            web.observe(\.canGoForward, options: .new) { [weak self] web, _ in MainActor.assumeIsolated { self?.read(web) } },
        ]
    }

    func load(_ address: String) {
        guard let url = URL(string: address) else { return }
        self.url = address
        web.load(URLRequest(url: url))
    }

    func back() { web.goBack() }
    func forward() { web.goForward() }
    func reload() { if loading { web.stopLoading() } else { web.reload() } }

    private func read(_ web: WKWebView) {
        let (url, title) = (web.url?.absoluteString ?? self.url, web.title ?? "")
        if self.url != url { self.url = url }
        if self.title != title { self.title = title }
        if loading != web.isLoading { loading = web.isLoading }
        if canGoBack != web.canGoBack { canGoBack = web.canGoBack }
        if canGoForward != web.canGoForward { canGoForward = web.canGoForward }
        changed(url, title)
    }
}

/// Every open tab's page by tab, made the first time it's shown and kept until it's closed, so going back to a tab
/// finds its page as it was (scroll, form and all) rather than loading it again.
@MainActor
enum WebPages {
    // ponytail: every shown tab's page stays alive until closed; evict the least recent if memory says so.
    private static var pages: [String: WebPage] = [:]

    static func page(for tab: PanelTab) -> WebPage {
        if let page = pages[tab.id] { return page }
        let page = WebPage()
        pages[tab.id] = page
        page.load(tab.url)
        return page
    }

    static func existing(_ id: String) -> WebPage? { pages[id] }
    static func close(_ id: String) { pages[id] = nil }
}

/// Where a page draws.
struct WebPageView: NSViewRepresentable {
    let page: WebPage

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        place(page.view, in: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        if page.view.superview !== box { place(page.view, in: box) }
    }

    private func place(_ view: NSView, in box: NSView) {
        box.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
    }
}
