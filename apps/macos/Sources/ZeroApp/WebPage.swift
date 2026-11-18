import AppKit
import PDFKit
import SwiftUI
import ZeroBrowserHost
import ZeroCore

/// Chromium for the panel: Zero Browser, its own app in Contents/Helpers, which zerod starts and owns (agents use it
/// through zerod too). Asked for at the first page that needs it, one process for every tab. Zero.app quitting closes
/// its tabs; zerod quitting (restarting for an update) stops it cleanly, and Zero.app asks the next zerod for it.
@MainActor
enum ChromiumEngine {
    static let app = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Zero Browser.app")
    static var available: Bool { FileManager.default.fileExists(atPath: app.path) }
    static let engine: ZBEngine = {
        let engine = ZBEngine(browserApp: app.path)
        // Stopped as asked (zerod restarting): back as soon as zerod is, its tabs where they were.
        engine.stopped = { MainActor.assumeIsolated { ensureRunning(retrying: 60) } }
        // An agent's tab (browser_select "zero", then its tools): in its task's panel, not shown until picked, so the
        // user's view stays theirs; picked, they watch it work.
        engine.agentTab = { host, session in
            MainActor.assumeIsolated {
                let id = "agent-\(host.number)"
                agentTasks[id] = session
                WebPages.adopt(id, host)
                Panels.shared.change(session) { tabs in
                    if !tabs.tabs.contains(where: { $0.id == id }) {
                        tabs.tabs.append(PanelTab(id: id, url: host.url, title: host.title, openedBy: session))
                    }
                }
            }
        }
        // Closed by its agent: gone from its task's panel too.
        engine.tabClosed = { host in
            MainActor.assumeIsolated {
                let id = "agent-\(host.number)"
                guard let session = agentTasks.removeValue(forKey: id) else { return }
                WebPages.close(id)
                Panels.shared.change(session) { tabs in
                    tabs.tabs.removeAll { $0.id == id }
                    if tabs.selected == id { tabs.selected = tabs.tabs.last?.id }
                }
            }
        }
        return engine
    }()
    /// Web links that open in their apps when clicked (LinkRoute): Linear's, when its app opens them, and the Slack
    /// workspaces connected. Read as each page opens.
    // ponytail: a change in Linear's or Slack's settings reaches Zero Browser with the next page; push it on change if
    // that's ever too late.
    static var outsidePrefixes: [String] {
        (LinearLinks.inApp ? ["https://linear.app/"] : []) + SlackLinks.teams.map { "https://\($0.team.domain).slack.com/archives/" }
    }
    private static var asking = false
    /// Each agent's tab's task, by panel tab id.
    private static var agentTasks: [String: String] = [:]

    /// zerod asked for it (started if it isn't), and connected to; tried again every half second up to `retrying`
    /// times while zerod isn't there.
    static func ensureRunning(retrying: Int = 0) {
        guard !engine.running, !asking else { return }
        asking = true
        Task { @MainActor in
            let link = try? ZerodLink()
            let answer = try? await link?.call("zeroBrowser") as? [String: Any]
            link?.close()
            asking = false
            if let pid = answer?["pid"] as? Int {
                if !engine.running { engine.connect(toPid: pid_t(pid)) }
            } else if retrying > 0 {
                try? await Task.sleep(for: .milliseconds(500))
                ensureRunning(retrying: retrying - 1)
            }
        }
    }
}

/// One tab's page, and the only place the panel meets Zero Browser: it loads an address and says where it is, what
/// it's called, whether it's loading, and whether it can go back or forward.
@MainActor @Observable
final class WebPage {
    private(set) var url = ""
    private(set) var title = ""
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Why the page went (its renderer or the browser app), until Reload.
    private(set) var crashed: String?
    /// An element of the page fullscreen (a video's): the panel gives the page its whole column, address bar and all.
    private(set) var fullscreen = false
    /// Chrome's own dialog for the page (a passkey's) shows, centred on it by the browser app over its panel's column,
    /// which the browser app dims and keeps to the dialog (`modalArea`).
    private(set) var dialog = false {
        didSet {
            guard dialog, !oldValue else { return }
            dialogs += 1
            followView(dialog: dialogs)
        }
    }
    @ObservationIgnored private var dialogs = 0
    /// Whether its tab is the one in view (its task shown, its panel open, it selected), as WebPages says.
    @ObservationIgnored var inView: () -> Bool = { true } {
        didSet { chromium.inView = { [inView] in MainActor.assumeIsolated { inView() } } }
    }

    /// While its dialog shows: placed again whenever what's in view changes (another task, the panel closed, another tab).
    private func followView(dialog: Int) {
        guard self.dialog, dialog == dialogs else { return }
        withObservationTracking {
            _ = inView()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.chromium.placeDialog()
                self?.followView(dialog: dialog)
            }
        }
    }

    /// The side panel's column this page is in, in its window: from the panel's foot to the window's top (its tabs sit
    /// in the title bar above it).
    private func panelColumn(in window: NSWindow) -> NSRect? {
        let page = view.convert(view.bounds, to: nil)
        guard
            let panel = BrowserKeys.anchors.allObjects.lazy.filter({ $0.window === window }).map({ $0.convert($0.bounds, to: nil) })
                .first(where: { $0.contains(NSPoint(x: page.midX, y: page.midY)) })
        else { return nil }
        return NSRect(x: panel.minX, y: panel.minY, width: panel.width, height: window.frame.height - panel.minY)
    }
    /// What the page asks the user (a dialog, a permission), drawn over it, the first in front; the rest wait.
    private(set) var questions: [PageQuestion] = []
    /// Told whenever the address or title changes, so the tab keeps them.
    @ObservationIgnored var changed: (_ url: String, _ title: String) -> Void = { _, _ in }
    /// Asked about a link clicked in the page: true when it opened outside (in an app), and the page stays put.
    @ObservationIgnored var outside: (URL) -> Bool = { _ in false }

    @ObservationIgnored let view: NSView
    @ObservationIgnored let chromium: ZBHost

    /// A Chromium tab's page: a new one, or an agent's already open.
    init(chromium host: ZBHost) {
        chromium = host
        view = host.view
        url = host.url
        title = host.title
        host.changed = { [weak self] url, title, loading, back, forward in
            MainActor.assumeIsolated { self?.read(url: url, title: title, loading: loading, back: back, forward: forward) }
        }
        host.crashed = { [weak self] why in MainActor.assumeIsolated { self?.crashed = why } }
        // A link meant for a new window (target=_blank, window.open after a click): in this tab, unless it's an app's.
        host.opened = { [weak self] request in
            MainActor.assumeIsolated {
                guard let self, request["gesture"] as? Bool == true, let address = request["url"] as? String,
                    let url = URL(string: address), !self.outside(url)
                else { return }
                self.load(address)
            }
        }
        // What the page asks: Zero answers (its menu, a file, a dialog, a permission, where a download goes).
        host.asked = { [weak self] question, answer in
            MainActor.assumeIsolated {
                guard let self else { return answer([:]) }
                PageQuestions.answer(question, on: self, answer)
            }
        }
        host.downloaded = { progress in
            guard progress["complete"] as? Bool == true, let path = progress["path"] as? String else { return }
            PageQuestions.downloaded(path)
        }
        // An app's link clicked in the page: to its app (the browser app kept the page where it was).
        host.printAsked = { [weak self] in MainActor.assumeIsolated { self?.print() } }
        host.fullscreen = { [weak self] on in MainActor.assumeIsolated { self?.fullscreen = on } }
        host.outside = { [weak self] address in
            MainActor.assumeIsolated {
                if let url = URL(string: address) { _ = self?.outside(url) }
            }
        }
        host.dialogShown = { [weak self] shown in MainActor.assumeIsolated { self?.dialog = shown } }
        host.modalArea = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.view.window else { return .zero }
                return self.panelColumn(in: window) ?? .zero
            }
        }
        ChromiumEngine.engine.setOutside(ChromiumEngine.outsidePrefixes)
        ChromiumEngine.ensureRunning()
    }

    convenience init() {
        self.init(chromium: ChromiumEngine.engine.openTab("about:blank", isolated: false))
        // No fallback: a build without Zero Browser says so where the page would be.
        if !ChromiumEngine.available { crashed = "This build of Zero has no Zero Browser (Contents/Helpers)." }
    }

    func load(_ address: String) {
        guard URL(string: address) != nil else { return }
        asked = (address, self.url)
        self.url = address
        // The tab shows the address at once, as a browser's does, and keeps it if the page can't load.
        changed(address, title)
        chromium.load(address)
    }

    /// Printed: the page to a PDF (its print styles, on the paper the Mac prints on), then the Mac's print panel for it
    /// as a sheet on Zero's window (a printer, Save as PDF, Open in Preview). Zero Dev hands the PDF to its checks.
    func print() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Zero print \(UUID().uuidString).pdf")
        let info = NSPrintInfo.shared
        let paper = NSSize(width: info.paperSize.width / 72, height: info.paperSize.height / 72)
        chromium.print(toPDF: url.path, paper: paper) { [weak self] ok in
            MainActor.assumeIsolated {
                guard ok, let self else { return }
                #if ZERO_DEV
                    PageQuestions.devPrinted.append(url)
                #else
                    guard let window = self.view.window, let document = PDFDocument(url: url),
                        let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true)
                    else { return }
                    operation.jobTitle = self.title.isEmpty ? url.deletingPathExtension().lastPathComponent : self.title
                    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
                #endif
            }
        }
    }

    func back() {
        asked = nil
        chromium.command("back")
    }

    func forward() {
        asked = nil
        chromium.command("forward")
    }

    func reload() {
        if crashed != nil {
            crashed = nil
            // The browser app gone: starting it again reopens every tab where it was.
            if !ChromiumEngine.engine.running { ChromiumEngine.ensureRunning() } else { chromium.command("reload") }
        } else {
            chromium.command(loading ? "stop" : "reload")
        }
    }

    /// A text field in the page has the keyboard: ⌘Z undoes typing there rather than reopening a tab.
    var editing: Bool { chromium.editing }

    /// Shown or not: a hidden tab neither paints nor runs its timers at full rate.
    func shown(_ on: Bool) { chromium.setHidden(!on) }

    func close() {
        for question in questions { question.answered(question.options.count - 1, "") }
        questions = []
        dialog = false
        chromium.close()
    }

    func ask(_ question: PageQuestion) { questions.append(question) }

    func answer(_ question: PageQuestion, _ choice: Int, text: String = "") {
        guard questions.contains(where: { $0.id == question.id }) else { return }
        questions.removeAll { $0.id == question.id }
        question.answered(choice, text)
    }

    /// The address last loaded and the one before it, until the page reports a third: reports of the page before (or of
    /// a new tab's about:blank) are from before the load, and don't take its address back (a page that can't load keeps
    /// it, to be fixed).
    @ObservationIgnored private var asked: (address: String, from: String)?

    private func read(url: String, title: String, loading: Bool, back: Bool, forward: Bool) {
        let url = asked.map { url == "about:blank" || url == $0.from ? $0.address : url } ?? url
        if url != asked?.address { asked = nil }
        if self.url != url { self.url = url }
        if self.title != title { self.title = title }
        if self.loading != loading { self.loading = loading }
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
        if crashed != nil, loading { crashed = nil }
        changed(url, title)
    }
}

/// A page's question for the user: a dialog (alert, confirm, prompt, leaving the page) or a site's permission. Its
/// options in order, the first what Return picks, the last what Esc does; a prompt's text with it.
struct PageQuestion: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let options: [String]
    /// A prompt's field and what's in it at first; nil for the others.
    let text: String?
    let answered: (_ choice: Int, _ text: String) -> Void
}

/// What pages ask: dialogs and permissions as Zero's card over the page (PageQuestionCard), a file to upload in the
/// open panel, downloads into Downloads, and Chromium's menu as Zero's own.
@MainActor
enum PageQuestions {
    /// alert, confirm, prompt or beforeunload: `done` gets OK (or Leave) and a prompt's text.
    static func dialog(_ type: String, message: String, origin: String, text: String?, done: @escaping (Bool, String) -> Void)
        -> PageQuestion
    {
        let leaving = type == "beforeunload"
        return PageQuestion(
            title: leaving ? "Leave this page?" : message, detail: leaving ? "Changes you made may not be saved." : origin,
            options: leaving ? ["Leave", "Stay"] : type == "alert" ? ["OK"] : ["OK", "Cancel"], text: type == "prompt" ? text ?? "" : nil
        ) { choice, text in done(choice == 0, text) }
    }

    static func permission(origin: String, wants: String, done: @escaping (Bool) -> Void) -> PageQuestion {
        PageQuestion(title: "Allow \(origin) to use \(wants)?", detail: "", options: ["Allow", "Don't Allow"], text: nil) { choice, _ in
            done(choice == 0)
        }
    }

    /// A file (or files, or a folder) to upload: nil when cancelled, or the page isn't in a window.
    static func chooseFiles(in view: NSView, multiple: Bool, folders: Bool, done: @escaping ([URL]?) -> Void) {
        #if ZERO_DEV
            // Zero Dev shows no open panel: its harness picks (DevE2E), else it's cancelled.
            devTrace.append("files asked")
            done(devFiles)
        #else
            guard let window = view.window else { return done(nil) }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = multiple
            panel.canChooseDirectories = folders
            panel.canChooseFiles = !folders
            panel.beginSheetModal(for: window) { result in done(result == .OK ? panel.urls : nil) }
        #endif
    }

    /// Zero Browser's questions (ZBHost.asked).
    static func answer(_ q: [AnyHashable: Any], on page: WebPage, _ answer: @escaping ([AnyHashable: Any]) -> Void) {
        let kind = q["kind"] as? String
        let origin = q["origin"] as? String ?? ""
        switch kind {
        case "download":
            answer(["path": downloadPath(q["name"] as? String)])
        case "menu":
            let at = CGPoint(x: q["x"] as? Double ?? 0, y: q["y"] as? Double ?? 0)
            menu(q["items"] as? [[String: Any]] ?? [], on: page, at: at) { answer($0.map { ["command": $0] } ?? [:]) }
        case "file":
            let mode = q["mode"] as? String
            chooseFiles(in: page.view, multiple: mode == "openMultiple", folders: mode == "openFolder") { urls in
                answer(urls.map { ["paths": $0.map(\.path)] } ?? [:])
            }
        case "dialog":
            page.ask(
                dialog(
                    q["type"] as? String ?? "alert", message: q["message"] as? String ?? "", origin: origin, text: q["default"] as? String
                ) {
                    answer(["ok": $0, "text": $1])
                })
        case "media", "permission":
            page.ask(
                permission(origin: origin.isEmpty ? "this site" : origin, wants: wants(q)) { allow in
                    answer(kind == "media" ? ["allowed": allow ? (q["wanted"] ?? 0) : 0] : ["result": allow ? "accept" : "deny"])
                })
        default:
            answer([:])
        }
    }

    /// CEF's View Page Source (MENU_ID_VIEW_SOURCE): it writes the source to a file and opens it in another app, so
    /// Zero's menu leaves it out.
    private static let viewSource = 132

    /// Chromium's menu for what was right-clicked, as Zero's own at the pointer: a line where Chromium has a separator,
    /// what can't be done left out. `done` gets the command picked, or nil once it closes without one.
    private static func menu(_ items: [[String: Any]], on page: WebPage, at point: CGPoint, done: @escaping (Int?) -> Void) {
        let view = page.view
        var groups: [[MenuItem]] = [[]]
        var finished = false
        let finish = { (command: Int?) in
            if !finished {
                finished = true
                done(command)
            }
        }
        for item in items {
            if item["separator"] != nil {
                groups.append([])
            } else if item["enabled"] as? Bool ?? true, let command = item["id"] as? Int, command != viewSource {
                groups[groups.count - 1].append(MenuItem(item["label"] as? String ?? "") { finish(command) })
            }
        }
        groups = groups.filter { !$0.isEmpty }
        guard view.window != nil, !groups.isEmpty else { return finish(nil) }
        #if ZERO_DEV
            // Zero Dev opens no menu (it would show over the user's apps): its harness picks from the items by name.
            let all = groups.flatMap { $0 }
            if let pick = devMenuPick(all.map(\.title)), let item = all.first(where: { $0.title == pick }) {
                item.action()
            } else {
                finish(nil)
            }
            return
        #endif
        ZeroContextMenu.open("page", at: (view, point)) { groups }
        // Closed without a pick: Chromium is told, or it waits for an answer.
        func watch() {
            withObservationTracking {
                _ = WorkspaceSelector.shared.open
            } onChange: {
                DispatchQueue.main.async {
                    if WorkspaceSelector.shared.open == "menu-page" { watch() } else { finish(nil) }
                }
            }
        }
        if WorkspaceSelector.shared.open == "menu-page" { watch() } else { finish(nil) }
    }

    #if ZERO_DEV
        static var devFiles: [URL]?
        /// The page menu's items in order, to the harness: the one it names is picked, nil closes it.
        static var devMenuPick: ([String]) -> String? = { _ in nil }
        /// What was asked, for the harness's evidence.
        static var devTrace: [String] = []
        /// The PDFs a print made, in place of the print panel.
        static var devPrinted: [URL] = []
    #endif

    /// In Downloads, under a name not taken yet ("name 2.ext"); Zero Dev's in ~/.zero-dev/downloads, never the user's.
    static func downloadPath(_ name: String?) -> String {
        let folder =
            DevBuild.on
            ? Paths.dir.appendingPathComponent("downloads") : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (name?.isEmpty == false ? name! : "download") as NSString
        var url = folder.appendingPathComponent(name as String)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let ext = name.pathExtension
            url = folder.appendingPathComponent("\(name.deletingPathExtension) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return url.path
    }

    /// A download done: the Dock's Downloads stack bounces, as for Safari's.
    static func downloaded(_ path: String) {
        if DevBuild.on { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
    }

    /// What a site asks to use, in words: Chromium's media and permission bits.
    private static func wants(_ q: [AnyHashable: Any]) -> String {
        let wanted = q["wanted"] as? Int ?? 0
        let names: [(Int, String)] =
            q["kind"] as? String == "media"
            ? [(1 << 0, "your microphone"), (1 << 1, "your camera"), (1 << 2, "your Mac's audio"), (1 << 3, "your screen")]
            : [
                (1 << 8, "your location"), (1 << 15, "notifications"), (1 << 4, "the clipboard"), (1 << 7, "your fonts"),
                (1 << 23, "window management"), (1 << 17, "the pointer"), (1 << 16, "the keyboard"),
            ]
        let words = names.filter { wanted & $0.0 != 0 }.map(\.1).joined(separator: " and ")
        return words.isEmpty ? "this" : words
    }
}

/// A page's question over it, in the ask cards' look: what it asks, the site, its options with their keys (Return the
/// first, Esc the last), a prompt's field above them.
private struct PageQuestionCard: View {
    let question: PageQuestion
    let page: WebPage
    @State private var text = ""
    @FocusState private var fieldFocused: Bool
    @FocusState private var cardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if !question.title.isEmpty {
                    Text(question.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        .lineLimit(12).textSelection(.enabled)
                }
                if !question.detail.isEmpty { Text(question.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
            if question.text != nil {
                TextField("", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.choice).clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($fieldFocused).onSubmit { choose(0) }
            }
            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        choose(index)
                    } label: {
                        row(index, option)
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 380, alignment: .leading)
        .card()
        .compositingGroup().floatingShadow()
        .focusable(question.text == nil).focusEffectDisabled().focused($cardFocused)
        .onKeyPress(action: key)
        .onAppear {
            text = question.text ?? ""
            // The keys are the card's while it's up, not the page's under it.
            page.view.window?.makeFirstResponder(nil)
            if question.text == nil { cardFocused = true } else { fieldFocused = true }
        }
    }

    private func choose(_ index: Int) { page.answer(question, index, text: text) }

    /// Esc the last option; without a field to type in, Return the first and a number its option.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            choose(question.options.count - 1)
        } else if question.text != nil {
            return .ignored
        } else if press.key == .return {
            choose(0)
        } else if let n = Int(press.characters), question.options.indices.contains(n - 1) {
            choose(n - 1)
        } else {
            return .ignored
        }
        return .handled
    }

    private func row(_ index: Int, _ option: String) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                .background(Theme.choiceCap).clipShape(RoundedRectangle(cornerRadius: 5))
            Text(option).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.choice).clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

/// Every open tab's page by tab, made the first time it's shown and kept until it's closed, so going back to a tab
/// finds its page as it was (scroll, form and all) rather than loading it again.
@MainActor
enum WebPages {
    // ponytail: every shown tab's page stays alive until closed; evict the least recent if memory says so.
    private static var pages: [String: WebPage] = [:]

    /// The tab's page, telling the tab where it is and what it's called (an agent's, adopted, as well as the user's).
    static func page(for tab: PanelTab, in task: String, outside: @escaping (URL) -> Bool) -> WebPage {
        let made = pages[tab.id]
        let page = made ?? WebPage()
        page.changed = { [id = tab.id] url, title in Panels.shared.change(task) { $0.visited(id, url: url, title: title) } }
        page.inView = { [id = tab.id] in BrowserKeys.visible() == task && Panels.shared.tabs(task).selected == id }
        if made == nil {
            page.outside = outside
            pages[tab.id] = page
            page.load(tab.url)
        }
        return page
    }

    static func existing(_ id: String) -> WebPage? { pages[id] }

    /// The page this view is, or is inside.
    static func holding(_ view: NSView?) -> WebPage? {
        var view = view
        while let next = view {
            if let page = pages.values.first(where: { $0.view === next }) { return page }
            view = next.superview
        }
        return nil
    }

    /// An agent's tab, already open in Zero Browser, as the page of panel tab `id`.
    static func adopt(_ id: String, _ host: ZBHost) {
        if pages[id]?.chromium === host { return }
        pages[id] = WebPage(chromium: host)
    }

    static func close(_ id: String) {
        pages[id]?.close()
        pages[id] = nil
    }
}

/// Where a page draws, and what shows instead when its browser crashed.
struct WebPageView: View {
    let page: WebPage

    var body: some View {
        ZStack {
            PageBox(page: page)
            if let crashed = page.crashed {
                VStack(spacing: 8) {
                    Text("The browser crashed").font(.system(size: 13, weight: .medium))
                    Text(crashed).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Reload") { page.reload() }.keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.card)
            }
            if let question = page.questions.first {
                // The page waits under it, as under a browser's own dialog.
                Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture {}
                PageQuestionCard(question: question, page: page).id(question.id).agentProof()
                    .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { page.shown(true) }
        .onDisappear { page.shown(false) }
    }
}

private struct PageBox: NSViewRepresentable {
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
