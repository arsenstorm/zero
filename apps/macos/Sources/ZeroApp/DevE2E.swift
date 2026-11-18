#if ZERO_DEV
    import AppKit
    import PDFKit
    import SwiftUI
    import ZeroBrowserHost
    import ZeroCore

    /// Zero Dev's end-to-end checks (`--e2e <folder>`, dev builds only): Zero Dev drives its own workspace window, on a
    /// task its own zerod takes in (offline and paused: no agent runs), with events posted to itself (never the user's
    /// mouse or keyboard) and without becoming the active app. Pages are read back through the DevTools protocol. Links leave for nowhere (LinearLinks.left), the open panel is answered
    /// here (PageQuestions.devFiles), downloads land in ~/.zero-dev/downloads. Results: <folder>/results.md and
    /// results.json, the log as it goes in log.txt; then Zero Dev quits.
    @MainActor
    final class DevE2E {
        let app: AppDelegate
        let out: URL
        var task = ""
        var results: [(name: String, ok: Bool, how: String, evidence: String)] = []

        init(_ app: AppDelegate, out: URL) {
            self.app = app
            self.out = out
        }

        static func run(_ app: AppDelegate) {
            let args = CommandLine.arguments
            let folder = args.firstIndex(of: "--e2e").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            let e2e = DevE2E(app, out: URL(fileURLWithPath: folder ?? Paths.dir.appendingPathComponent("e2e").path))
            Task { @MainActor in await e2e.run() }
        }

        // MARK: Results

        /// `how`: "event" when posted events drove it through Zero's own handling, "call" when a function was called.
        func check(_ name: String, _ ok: Bool, _ evidence: String, how: String = "event") {
            results.append((name, ok, how, evidence))
            let line = "\(ok ? "PASS" : "FAIL") \(name): \(evidence)\n"
            let log = out.appendingPathComponent("log.txt")
            if let h = try? FileHandle(forWritingTo: log) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: log, atomically: true, encoding: .utf8)
            }
        }

        func finish() {
            let passed = results.filter(\.ok).count
            var md =
                "# Zero Dev end to end\n\n**\(passed) of \(results.count) checks pass.**\n\n| Check | Result | Driven by | Evidence |\n|---|---|---|---|\n"
            for r in results {
                md +=
                    "| \(r.name) | \(r.ok ? "pass" : "**fail**") | \(r.how) | \(r.evidence.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")) |\n"
            }
            try? md.write(to: out.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
            let json: [String: Any] = ["passed": passed, "failed": results.count - passed, "total": results.count]
            if let d = try? JSONSerialization.data(withJSONObject: json) { try? d.write(to: out.appendingPathComponent("results.json")) }
            NSApp.terminate(nil)
        }

        // MARK: Helpers

        func pause(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

        var window: NSWindow? { app.workspaceWindow }
        var tabs: PanelTabs { Panels.shared.tabs(task) }
        var shownPage: WebPage? { tabs.shown.flatMap { WebPages.existing($0.id) } }

        /// The page's value for a script, through the DevTools protocol.
        func js(_ code: String, on page: WebPage? = nil) async -> Any? {
            guard let page = page ?? shownPage else { return nil }
            let json: String = await withCheckedContinuation { c in
                var done = false
                page.chromium.evaluate(code) { _, json in if !done { done = true; c.resume(returning: json) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !done { done = true; c.resume(returning: "{}") } }
            }
            guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                let r = d["result"] as? [String: Any]
            else { return nil }
            return r["value"]
        }

        func until(_ seconds: Double = 5, _ test: () async -> Bool) async -> Bool {
            for _ in 0..<Int(seconds * 10) {
                if await test() { return true }
                await pause(0.1)
            }
            return await test()
        }

        func waitFor(_ what: String, on page: WebPage? = nil, _ seconds: Double = 10) async -> Bool {
            await until(seconds) { (await js(what, on: page) as? Bool) == true }
        }

        /// A key, posted to Zero Dev's own queue: AppKit takes it to the key window and the menu as a typed one.
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) async {
            let chars = flags.contains(.shift) ? chars.uppercased() : chars
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let e = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: code)
                else { continue }
                NSApp.postEvent(e, atStart: false)
            }
            await pause(0.25)
        }

        /// A point in a view from its top left (as pages and text views count), in its window.
        func inWindow(_ view: NSView, _ p: CGPoint) -> NSPoint {
            view.convert(NSPoint(x: p.x, y: view.isFlipped ? p.y : view.bounds.height - p.y), to: nil)
        }

        /// A click (left or right) given to this view, down then up, as a key window gives it the hand's: the window is
        /// on no display, where AppKit passes no click on.
        func click(_ view: NSView, _ p: CGPoint, right: Bool = false, _ flags: NSEvent.ModifierFlags = []) async {
            guard let number = view.window?.windowNumber else { return }
            let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            let events = types.compactMap {
                NSEvent.mouseEvent(
                    with: $0, location: inWindow(view, p), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            guard events.count == 2 else { return }
            if right {
                view.rightMouseDown(with: events[0])
                view.rightMouseUp(with: events[1])
            } else {
                view.mouseDown(with: events[0])
                view.mouseUp(with: events[1])
            }
            await pause(0.3)
        }

        /// Any of Zero Dev's windows seen on a display while the checks ran (sampled every half second).
        var seenOnScreen = Set<String>()
        func watchScreens() {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    for w in NSApp.windows where w.isVisible && NSScreen.screens.contains(where: { $0.frame.intersects(w.frame) }) {
                        self?.seenOnScreen.insert("\(type(of: w)) \(w.title) \(w.frame) after \"\(self?.results.last?.0 ?? "the start")\"")
                    }
                    // Zero Dev Browser's too (its dialogs), from the window server, in its coordinates.
                    var count: UInt32 = 0
                    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
                    CGGetActiveDisplayList(16, &displays, &count)
                    let screens = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
                    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                    for info in all where (info[kCGWindowOwnerPID as String] as? Int32) == ChromiumEngine.engine.pid {
                        guard let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                            screens.contains(where: { $0.intersects(b) })
                        else { continue }
                        let layer = info[kCGWindowLayer as String] as? Int ?? 0
                        self?.seenOnScreen.insert(
                            "Zero Dev Browser window \(b) layer \(layer) after \"\(self?.results.last?.0 ?? "the start")\"")
                    }
                }
            }
        }

        /// A click given to this view itself (its mouseDown, the mouseUp queued for its tracking), past the window's
        /// hit test: SwiftUI's hosting view answers that with itself over the views it embeds.
        func press(_ view: NSView, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = []) async {
            guard let number = view.window?.windowNumber else { return }
            let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap {
                NSEvent.mouseEvent(
                    with: $0, location: inWindow(view, p), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            guard events.count == 2 else { return }
            NSApp.postEvent(events[1], atStart: false)
            view.mouseDown(with: events[0])
            await pause(0.3)
        }

        /// The mouse's back (3) or forward (4) button over a view, posted to Zero Dev alone: a windowed event with the
        /// button number set through its CGEvent (NSEvent can't make one with a number of its own).
        func mouseButton(_ button: Int64, _ view: NSView, _ p: CGPoint) async -> Bool {
            guard let window = view.window,
                let made = NSEvent.mouseEvent(
                    with: .otherMouseDown, location: inWindow(view, p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                let cg = made.cgEvent
            else { return false }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
            guard let e = NSEvent(cgEvent: cg), e.buttonNumber == Int(button) else { return false }
            NSApp.postEvent(e, atStart: false)
            await pause(0.3)
            return true
        }

        /// One browser tool, called through Zero Dev's zerod as an agent of this task calls it: its text and images.
        func agent(_ tool: String, _ args: [String: Any] = [:]) async -> (ok: Bool, text: String, images: Int) {
            guard let link = try? ZerodLink() else { return (false, "no zerod", 0) }
            defer { link.close() }
            do {
                let r = try await link.call("browserCall", ["session": task, "tool": tool, "args": args]) as? [String: Any]
                let content = r?["content"] as? [[String: Any]] ?? []
                return (
                    true, content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                    content.filter { $0["type"] as? String == "image" }.count
                )
            } catch { return (false, "\(error)", 0) }
        }

        /// Every tab closed, its page with it.
        func resetTabs() {
            for tab in tabs.tabs { SidePanel.close(tab.id, in: task) }
            Panels.shared.change(task) { $0 = PanelTabs() }
        }

        func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
            guard let view else { return [] }
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }

        // MARK: Run

        func run() async {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: out.appendingPathComponent("log.txt"))
            // Never against the user's Zero: this bundle and a zerod under ~/.zero-dev, or nothing at all.
            let socket = ZerodLink.socket
            guard Bundle.main.bundleIdentifier == "com.arsen.zero.dev", socket.hasPrefix(Paths.dir.path), DevBuild.on else {
                check(
                    "Zero Dev runs on its own zerod", false, "bundle \(Bundle.main.bundleIdentifier ?? "?"), socket \(socket)", how: "call")
                return finish()
            }
            watchScreens()
            for _ in 0..<100 where app.workspace == nil || window == nil { await pause(0.1) }
            guard let workspace = app.workspace, let window else {
                check("Zero Dev opens its workspace window", false, "workspace \(app.workspace != nil), window \(window != nil)")
                return finish()
            }
            guard let id = await adoptTask(), await until(10, { workspace.conversation(id) != nil }) else {
                check("Its zerod takes in a task for the checks", false, "no task")
                return finish()
            }
            task = id
            await workspace.pause([id])
            UserDefaults.standard.removeObject(forKey: LinksOpenIn.key)
            UserDefaults.standard.removeObject(forKey: LinksOpenIn.hostsKey)
            app.navigation.place = .task(id)
            app.navigation.pane = false
            DevWindow.driven = true
            // Found on a display: failed here at once, named by the check it came after (and put back by DevWindow).
            var sighted = false
            DevWindow.sighted = { [weak self] how in
                guard let self, !sighted else { return }
                sighted = true
                let after = results.last?.0 ?? "the start"
                check("Zero Dev's window stayed off every display", false, "\(how), after \"\(after)\"", how: "event")
            }
            (window as? DevWindow)?.putBack("before the checks")
            await pause(1.5)
            check(
                "The workspace window is key to Zero Dev, which never becomes the active app", window.isKeyWindow && !NSApp.isActive,
                "key \(window.isKeyWindow) (DevWindow), active \(NSApp.isActive)", how: "seam")
            check("Zero Browser is bundled in Zero Dev", ChromiumEngine.available, ChromiumEngine.app.path, how: "call")

            await links(window)
            await chromiumBasics()
            await questions()
            await keys(window)
            await linkGroups(workspace, window)
            bareReferences(workspace)
            await effortSlider()
            await askPaste(window)
            await agentDrives()
            await desktopDrives(window)
            check("Zero Dev never became the active app", !NSApp.isActive, "active \(NSApp.isActive)", how: "call")
            // Nothing of Zero Dev's on any display: its windows, panels and menus.
            let shown = NSApp.windows.filter { w in w.isVisible && NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
            // Stationary too: Mission Control and App Exposé show any other window of the Space on the user's screen.
            let stays = window.collectionBehavior.contains(.stationary)
            check(
                "No Zero Dev window was on any display, and its window stays out of Mission Control",
                shown.isEmpty && seenOnScreen.isEmpty && stays,
                "now: \(shown.map { "\(type(of: $0)) \($0.frame)" }); during: \(seenOnScreen); stationary \(stays)", how: "call")
            resetTabs()
            await workspace.archive(task)
            finish()
        }

        /// A task in Zero Dev's zerod, taken in from a Claude Code session written here: offline, never resumed.
        func adoptTask() async -> String? {
            guard let home = ProcessInfo.processInfo.environment["ZERO_DEV_HOME"] else { return nil }
            let cwd = Paths.dir.appendingPathComponent("e2e-task")
            try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let real = cwd.resolvingSymlinksInPath().path
            let folder = URL(fileURLWithPath: home).appendingPathComponent(
                ".claude/projects/" + String(real.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let thread = UUID().uuidString.lowercased()
            let records: [[String: Any]] = [
                ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "Zero Dev's end-to-end checks"]],
                [
                    "type": "assistant", "uuid": "a1",
                    "message": [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "text",
                                "text":
                                    "Links: [GitHub PR](https://github.com/zero-e2e/repo/pull/1), [Local app](http://localhost:4321/e2e), [Docs page](https://docs.example.org/guide).",
                            ]
                        ],
                    ],
                ],
            ]
            let text = records.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
                .joined(separator: "\n")
            try? text.write(to: folder.appendingPathComponent("\(thread).jsonl"), atomically: true, encoding: .utf8)
            guard let link = try? ZerodLink() else { return nil }
            defer { link.close() }
            let r =
                try? await link.call("adopt", ["thread": thread, "cwd": real, "label": "Zero Dev e2e", "ticket": "ZD-1"]) as? [String: Any]
            return r?["session"] as? String
        }

        // MARK: Links

        /// A message's links, clicked as the user clicks them: where each goes by Settings' "Open links in".
        func links(_ window: NSWindow) async {
            let text = await until(5) { self.linkText(window) != nil } ? linkText(window) : nil
            guard let text else { return check("A message's links are on screen", false, "no text view with the links") }
            let defaults = UserDefaults.standard
            func click(_ words: String, option: Bool = false) async -> (left: URL?, tab: String?) {
                let before = (left: LinearLinks.left.count, tabs: tabs.tabs.map(\.id))
                guard let point = self.point(of: words, in: text) else { return (nil, nil) }
                await self.press(text, point, option ? .option : [])
                await pause(0.4)
                let left = LinearLinks.left.count > before.left ? LinearLinks.left.last : nil
                let tab = tabs.tabs.first { !before.tabs.contains($0.id) }?.url
                return (left, tab)
            }
            func reset() { resetTabs() }

            var r = await click("GitHub PR")
            check(
                "By default, a GitHub link goes to the default browser", r.left?.host == "github.com" && r.tab == nil,
                "left Zero for \(r.left?.absoluteString ?? "nothing"), panel tab \(r.tab ?? "none")", how: "text view event")
            r = await click("Local app")
            check(
                "By default, a localhost link opens in the side panel",
                r.left == nil && r.tab == "http://localhost:4321/e2e" && app.navigation.pane,
                "panel tab \(r.tab ?? "none"), pane open \(app.navigation.pane), left \(r.left?.absoluteString ?? "nothing")",
                how: "text view event")
            reset()
            r = await click("GitHub PR", option: true)
            check(
                "Option-click opens a GitHub link in the panel instead", r.left == nil && r.tab?.hasPrefix("https://github.com/") == true,
                "panel tab \(r.tab ?? "none"), left \(r.left?.absoluteString ?? "nothing")", how: "text view event")
            r = await click("Local app", option: true)
            check(
                "Option-click sends a localhost link to the browser instead", r.left?.host == "localhost" && r.tab == nil,
                "left Zero for \(r.left?.absoluteString ?? "nothing"), panel tab \(r.tab ?? "none")", how: "text view event")
            reset()
            r = await click("Docs page")
            let before = r
            defaults.set(["example.org"], forKey: LinksOpenIn.hostsKey)
            r = await click("Docs page")
            check(
                "A host on the list opens in the panel, its subdomains too",
                before.left != nil && r.tab == "https://docs.example.org/guide",
                "without it: left \(before.left?.absoluteString ?? "nothing"); with example.org: panel tab \(r.tab ?? "none")",
                how: "text view event")
            defaults.removeObject(forKey: LinksOpenIn.hostsKey)
            reset()
            defaults.set(LinksOpenIn.panel.rawValue, forKey: LinksOpenIn.key)
            r = await click("GitHub PR")
            let panel = r
            reset()
            defaults.set(LinksOpenIn.browser.rawValue, forKey: LinksOpenIn.key)
            r = await click("Local app")
            check(
                "\"Side panel\" and \"Default browser\" send every web link there",
                panel.tab != nil && panel.left == nil && r.left != nil && r.tab == nil,
                "Side panel: GitHub to \(panel.tab ?? "nowhere"); Default browser: localhost left for \(r.left?.absoluteString ?? "nothing")",
                how: "text view event")
            defaults.removeObject(forKey: LinksOpenIn.key)
            reset()
            app.navigation.pane = false
        }

        func linkText(_ window: NSWindow) -> RichTextView? {
            views(RichTextView.self, in: window.contentView).first { $0.string.contains("GitHub PR") && $0.window != nil }
        }

        /// The middle of these words in a text view, from its top left.
        func point(of words: String, in text: NSTextView) -> CGPoint? {
            let range = (text.string as NSString).range(of: words)
            guard range.location != NSNotFound, let layout = text.layoutManager, let container = text.textContainer else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let origin = text.textContainerOrigin
            return CGPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
        }

        // MARK: Chromium's tabs

        func chromiumBasics() async {
            app.navigation.pane = true
            Panels.shared.change(task) { $0.open("https://example.com/") }
            await pause(0.8)
            let first = shownPage
            check("Opening a tab makes a Chromium page", first != nil, "page \(first != nil)")
            let loaded = await waitFor("document.readyState==='complete' && location.host==='example.com'", on: first)
            _ = await until(4) { first?.title.isEmpty == false }
            check(
                "It loads, and its title reaches the tab",
                loaded && first?.title == "Example Domain" && tabs.shown?.title == "Example Domain",
                "page \(first?.title ?? "?"), tab \(tabs.shown?.title ?? "?")")
            check(
                "The browser runs out of Zero's process", ChromiumEngine.engine.running && ChromiumEngine.engine.pid != getpid(),
                "browser pid \(ChromiumEngine.engine.pid), Zero Dev \(getpid())", how: "call")

            first?.load("https://example.org/")
            _ = await waitFor("document.readyState==='complete' && location.host==='example.org'", on: first)
            _ = await until(4) { first?.canGoBack == true }
            first?.back()
            let back = await waitFor("location.host==='example.com'", on: first)
            first?.forward()
            let forward = await waitFor("location.host==='example.org'", on: first)
            check("Back and forward", back && forward, "back \(back), forward \(forward)", how: "call")

            guard let page = first else { return }
            let view = page.chromium.view
            _ = await js("document.body.innerHTML='<input id=i style=\"font-size:20px\" value=\"hello world\">';1", on: page)
            await pause(0.3)
            let r =
                await js(
                    "(()=>{const b=document.getElementById('i').getBoundingClientRect();return [b.x+b.width-4,b.y+b.height/2]})()", on: page
                ) as? [Double] ?? [20, 20]
            await click(view, CGPoint(x: r[0], y: r[1]))
            _ = await js("(()=>{const e=document.getElementById('i');e.focus();e.setSelectionRange(11,11);return 1})()", on: page)
            await key(18, "!", .shift)
            let typed = await js("document.getElementById('i').value", on: page) as? String ?? ""
            check("Typing reaches the page", typed == "hello world!", "value \(typed)")
            await key(51, "\u{7f}", .command)
            let cleared = await js("document.getElementById('i').value", on: page) as? String ?? "?"
            check("⌘⌫ deletes to the line's start", cleared.isEmpty, "value \"\(cleared)\"")
            let inField = page.editing
            _ = await js("document.activeElement.blur(); 1", on: page)
            _ = await until(1) { !page.editing }
            check(
                "Zero knows when a field in the page has the keyboard", inField && !page.editing,
                "in it \(inField), after blur \(page.editing)")

            Panels.shared.change(task) { $0.open("https://example.com/?second") }
            await pause(0.6)
            let second = shownPage
            _ = await waitFor("document.readyState==='complete'", on: second)
            await pause(0.4)
            let hidden = await js("document.visibilityState", on: first) as? String ?? "?"
            let shown = await js("document.visibilityState", on: second) as? String ?? "?"
            check(
                "Only the tab shown is visible", hidden == "hidden" && shown == "visible", "first \(hidden), second \(shown)", how: "call")

            // The browser app killed: the panel says so, Zero stays; Reload brings both tabs back.
            kill(ChromiumEngine.engine.pid, SIGKILL)
            _ = await until(3) { second?.crashed != nil }
            check(
                "A crash shows \"The browser crashed\"", second?.crashed != nil && first?.crashed != nil,
                "shown: \(second?.crashed ?? "none"); other: \(first?.crashed ?? "none")", how: "call")
            second?.reload()
            let back1 = await waitFor("document.readyState==='complete'", on: second, 15)
            let back2 = await waitFor("document.readyState==='complete'", on: first, 10)
            check("Reload brings both tabs back", back1 && back2 && second?.crashed == nil, "shown \(back1), other \(back2)", how: "call")
            // A page that can't load (a typo's host): its address stays, to be fixed.
            resetTabs()
            Panels.shared.change(task) { $0.open("https://example.com/?fails") }
            await pause(0.8)
            let failing = shownPage
            _ = await waitFor("document.readyState==='complete'", on: failing, 15)
            failing?.load("https://nowhere.zero-e2e.invalid/page")
            _ = await until(5) { self.tabs.shown?.url == "https://nowhere.zero-e2e.invalid/page" && failing?.loading == false }
            check(
                "A page that fails to load keeps its address", tabs.shown?.url == "https://nowhere.zero-e2e.invalid/page",
                "page \(failing?.url ?? "?"), tab \(tabs.shown?.url ?? "?"), loading \(failing?.loading == true)", how: "call")
            resetTabs()
        }

        // MARK: Page questions

        /// What a page asks: dialogs as Zero's card (Return, Esc), a file to upload, a download, and the right-click
        /// menu as Zero's.
        func questions() async {
            app.navigation.pane = true
            resetTabs()
            Panels.shared.change(task) { $0.open("https://example.com/?questions") }
            await pause(1)
            guard let page = shownPage, await waitFor("document.readyState==='complete'", on: page, 15) else {
                return check("A page for its questions", false, "none loaded")
            }

            func ask(_ script: String) async -> PageQuestion? {
                _ = await js("window.r = 'waiting'; setTimeout(() => { window.r = \(script) }, 50); 1", on: page)
                _ = await until(3) { !page.questions.isEmpty }
                return page.questions.first
            }
            func result() async -> Any? {
                _ = await until(2) { (await js("window.r !== 'waiting'", on: page) as? Bool) == true }
                return await js("window.r === null ? 'null' : window.r", on: page)
            }

            var q = await ask("confirm('Go on?')")
            let card = q.map { "\($0.title) [\($0.options.joined(separator: ", "))]" } ?? "no card"
            await key(36, "\r")
            var answer = await result()
            check(
                "confirm() shows Zero's card; Return answers OK",
                q?.options == ["OK", "Cancel"] && answer as? Bool == true && page.questions.isEmpty,
                "\(card); page got \(answer ?? "nothing")")
            q = await ask("confirm('Again?')")
            await key(53, "\u{1b}")
            answer = await result()
            check(
                "Esc answers Cancel", q != nil && answer as? Bool == false && page.questions.isEmpty,
                "page got \(answer ?? "nothing")")
            q = await ask("prompt('Name?', 'zero')")
            await pause(0.3)
            await key(36, "\r")
            answer = await result()
            check(
                "prompt() takes its text; Return sends it", q?.text == "zero" && answer as? String == "zero",
                "field \(q?.text ?? "none"); page got \(answer ?? "nothing")")
            q = await ask("prompt('Name?', 'zero')")
            await pause(0.3)
            await key(53, "\u{1b}")
            answer = await result()
            check("Esc cancels a prompt", q != nil && answer as? String == "null", "page got \(answer ?? "nothing")")

            // A file to upload: the input clicked, the harness answering for the open panel.
            let file = out.appendingPathComponent("e2e-upload.txt")
            try? "zero".write(to: file, atomically: true, encoding: .utf8)
            PageQuestions.devFiles = [file]
            _ = await js("document.body.innerHTML='<input type=file id=f style=\"width:300px;height:40px\">';1", on: page)
            await pause(0.3)
            let at =
                await js("(()=>{const b=document.getElementById('f').getBoundingClientRect();return [b.x+20,b.y+b.height/2]})()", on: page)
                as? [Double] ?? [20, 20]
            await click(page.view, CGPoint(x: at[0], y: at[1]))
            let uploaded = await until(3) { (await js("document.getElementById('f').files.length === 1", on: page) as? Bool) == true }
            let named = await js("document.getElementById('f').files[0]?.name ?? 'none'", on: page) as? String ?? "?"
            check(
                "an upload gets the file picked", uploaded && named == "e2e-upload.txt",
                "files: \(named); \(PageQuestions.devTrace)", how: "event")
            PageQuestions.devFiles = nil

            // A download, into Zero Dev's own Downloads.
            let target = Paths.dir.appendingPathComponent("downloads/e2e-download.txt")
            try? FileManager.default.removeItem(at: target)
            _ = await js(
                "(()=>{document.body.innerHTML='';const a=document.createElement('a');a.id='d';a.textContent='Download it';a.style.fontSize='24px';a.href=URL.createObjectURL(new Blob(['zero'],{type:'application/octet-stream'}));a.download='e2e-download.txt';document.body.appendChild(a);return 1})()",
                on: page)
            await pause(0.3)
            let spot =
                await js(
                    "(()=>{const b=document.getElementById('d').getBoundingClientRect();return [b.x+b.width/2,b.y+b.height/2]})()", on: page
                ) as? [Double] ?? [20, 20]
            await click(page.view, CGPoint(x: spot[0], y: spot[1]))
            let saved = await until(8) { (try? String(contentsOf: target, encoding: .utf8)) == "zero" }
            check(
                "a download lands in Downloads (Zero Dev's own)", saved, "\(target.path); \(PageQuestions.devTrace)",
                how: "event")
            PageQuestions.devTrace = []

            let view = page.chromium.view
            // The right-click menu, by its model: a right-click asks Zero, the items Zero would show come here (no menu
            // opens: it would show over the user's apps), the one named is picked and its command reaches Chromium.
            func menu(at p: CGPoint, picking name: String?) async -> [String]? {
                var seen: [String]?
                PageQuestions.devMenuPick = { items in
                    seen = items
                    return name
                }
                await click(view, p, right: true)
                _ = await until(3) { seen != nil }
                PageQuestions.devMenuPick = { _ in nil }
                return seen
            }
            _ = await js("document.body.innerHTML='<input id=s style=\"font-size:24px;width:300px\" value=\"pick me\">';1", on: page)
            await pause(0.3)
            let field =
                await js("(()=>{const b=document.getElementById('s').getBoundingClientRect();return [b.x+20,b.y+b.height/2]})()", on: page)
                as? [Double] ?? [20, 20]
            let inField = CGPoint(x: field[0], y: field[1])
            await click(view, inField)
            _ = await js("(()=>{const e=document.getElementById('s');e.focus();e.setSelectionRange(0,0);return 1})()", on: page)
            let closed = await menu(at: inField, picking: nil)
            // A right-click selects the word under it, as in Chrome; no command ran: the value and the rest stay as they were.
            let untouched =
                await js("(()=>{const e=document.getElementById('s');return e.value==='pick me'&&e.selectionEnd<7})()", on: page) as? Bool
                == true
            check(
                "Chromium: a right-click gives Zero its menu's items; closed without a pick, nothing happens",
                closed?.isEmpty == false && untouched, "items \(closed ?? []); page untouched \(untouched)", how: "event, menu by model")
            let items = await menu(at: inField, picking: "Select All")
            let selected = await until(3) {
                (await js("(()=>{const e=document.getElementById('s');return e.selectionStart===0&&e.selectionEnd===7})()", on: page)
                    as? Bool) == true
            }
            check(
                "Chromium: a pick in Zero's menu reaches Chromium (Select All); no View Page Source",
                selected && items?.contains("View Page Source") == false, "items \(items ?? []); selected \(selected)",
                how: "event, menu by model")

            // Printing: never Chrome's own print panel (a window of the browser app's, on the user's screen). The page's
            // window.print(), the File menu's Print… (⌘P) and the page menu's Print… each print the page to a PDF, with
            // its print styles, for the Mac's print panel as a sheet on Zero's window (here handed to the checks).
            _ = await js(
                "document.body.innerHTML='<style>@media print{.screen{display:none}}</style><h1>Zero print check</h1><p class=screen>On screen only</p>';1",
                on: page)
            func printed(_ count: Int) async -> (ok: Bool, why: String) {
                guard await until(10, { PageQuestions.devPrinted.count >= count }), let url = PageQuestions.devPrinted.last,
                    let pdf = PDFDocument(url: url)
                else { return (false, "no PDF (\(PageQuestions.devPrinted.count))") }
                let text = pdf.string ?? ""
                let head = (try? FileHandle(forReadingFrom: url).readData(ofLength: 4)).map { String(decoding: $0, as: UTF8.self) }
                let ok = head == "%PDF" && pdf.pageCount >= 1 && text.contains("Zero print check") && !text.contains("On screen only")
                return (
                    ok,
                    "\(pdf.pageCount) page(s), print styles \(!text.contains("On screen only")), text \(text.prefix(40).debugDescription)"
                )
            }
            PageQuestions.devPrinted = []
            _ = await js("window.print(); 1", on: page)
            let byPage = await printed(1)
            let item = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu?.item(withTitle: "Print…")
            if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            let byMenu = await printed(2)
            let background = CGPoint(x: 200, y: 160)
            let names = await menu(at: background, picking: nil) ?? []
            let printItem = names.first { $0.hasPrefix("Print") }
            if let printItem { _ = await menu(at: background, picking: printItem) }
            let byPageMenu = await printed(3)
            let printFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ChromiumEngine.engine.pid
            check(
                "Printing: window.print(), File › Print… (⌘P) and the page menu's Print… each make the page's PDF for Zero's print sheet",
                byPage.ok && byMenu.ok && item?.keyEquivalent == "p" && byPageMenu.ok && !printFront,
                "window.print(): \(byPage.why); ⌘P item \(item?.keyEquivalent ?? "none"): \(byMenu.why); page menu \(printItem ?? "no Print item in \(names)"): \(byPageMenu.why); browser in front \(printFront)",
                how: "call, menu by model")

            // VoiceOver: the page's tree as VoiceOver reads it, asked of the elements by model (the calls AppKit makes for
            // VoiceOver). The rotor's searches in document order, iframes' documents included; states; a live
            // region's new text and a changed state posted as it changes.
            var posted: [(name: String, info: [AnyHashable: Any]?, element: Any)] = []
            page.chromium.axPosted = { element, name, info in posted.append((name, info, element)) }
            _ = await js(
                "document.body.innerHTML='<main><h1>Head one</h1><h2>Head two</h2><a href=\"#x\">A link</a><button id=btn aria-expanded=false disabled>Btn</button><input id=cb type=checkbox><input required placeholder=Name><div aria-live=polite id=live></div><nav><a href=\"#y\">Nav link</a></nav><iframe srcdoc=\"<h3>In frame</h3><a href=#z>Frame link</a>\"></iframe></main>';document.getElementById('cb').indeterminate=true;1",
                on: page)
            func area() -> NSObject? { page.chromium.view.accessibilityChildren()?.first as? NSObject }
            func search(_ key: String, from start: Any? = nil, back: Bool = false, limit: Int = -1) -> [ZBAXNode] {
                var p: [String: Any] = [
                    "AXSearchKey": key, "AXResultsLimit": limit, "AXDirection": back ? "AXDirectionPrevious" : "AXDirectionNext",
                ]
                if let start { p["AXStartElement"] = start }
                return area()?.accessibilityAttributeValue(.init(rawValue: "AXUIElementsForSearchPredicate"), forParameter: p)
                    as? [ZBAXNode] ?? []
            }
            func labels(_ nodes: [ZBAXNode]) -> [String] { nodes.map { $0.accessibilityLabel() ?? "" } }
            let built = await until(10) { search("AXHeadingSearchKey").count == 3 && search("AXLinkSearchKey").count == 3 }
            let headings = search("AXHeadingSearchKey")
            let levels = headings.compactMap { $0.accessibilityValue() as? Int }
            let links = search("AXLinkSearchKey")
            let next = links.first.map { labels(search("AXLinkSearchKey", from: $0, limit: 1)) } ?? []
            let previous = links.last.map { labels(search("AXLinkSearchKey", from: $0, back: true, limit: 1)) } ?? []
            let landmarks = search("AXLandmarkSearchKey").map { $0.accessibilitySubrole()?.rawValue ?? "" }
            let count =
                area()?.accessibilityAttributeValue(
                    .init(rawValue: "AXUIElementCountForSearchPredicate"), forParameter: ["AXSearchKey": "AXControlSearchKey"]) as? Int
            let button = search("AXButtonSearchKey").first
            let box = search("AXCheckBoxSearchKey").first
            let textField = search("AXTextFieldSearchKey").first
            let frame = search("AXFrameSearchKey").first
            let iframe = frame?.accessibilityParent() as? ZBAXNode
            let inFrame = headings.last.flatMap { h in iframe.map { $0.pageRect().contains(h.pageRect()) } } ?? false
            check(
                "VoiceOver: the rotor finds headings, links, landmarks and controls in order, an iframe's too, placed in the iframe",
                built && labels(headings) == ["Head one", "Head two", "In frame"] && levels == [1, 2, 3]
                    && labels(links) == ["A link", "Nav link", "Frame link"] && next == ["Nav link"] && previous == ["Nav link"]
                    && landmarks == ["AXLandmarkMain", "AXLandmarkNavigation"] && count == 3 && inFrame,
                "headings \(labels(headings)) levels \(levels); links \(labels(links)), next \(next), previous \(previous); landmarks \(landmarks); controls \(count ?? -1); iframe's heading in the iframe \(inFrame)",
                how: "call")
            let enabled = button?.isAccessibilityEnabled()
            let expanded = button?.accessibilityAttributeValue(.expanded) as? Bool
            let mixed = box?.accessibilityValue() as? Int
            let required = textField?.accessibilityAttributeValue(.init(rawValue: "AXRequired")) as? Bool
            check(
                "VoiceOver: states: a disabled, collapsed button; a mixed check box; a required field",
                enabled == false && expanded == false && mixed == 2 && required == true,
                "button enabled \(String(describing: enabled)) expanded \(String(describing: expanded)); check box \(String(describing: mixed)); field required \(String(describing: required))",
                how: "call")
            posted = []
            _ = await js(
                "document.getElementById('live').textContent='Saved';document.getElementById('btn').setAttribute('aria-expanded','true');1",
                on: page)
            let said = await until(5) {
                posted.contains {
                    $0.name == NSAccessibility.Notification.announcementRequested.rawValue
                        && ($0.info?[NSAccessibility.NotificationUserInfoKey.announcement] as? String) == "Saved"
                }
                    && posted.contains { $0.name == "AXExpandedChanged" && ($0.element as? ZBAXNode) === search("AXButtonSearchKey").first }
            }
            let reExpanded = search("AXButtonSearchKey").first?.accessibilityAttributeValue(.expanded) as? Bool
            check(
                "VoiceOver: a live region's new text is announced; a button's expanded state change is posted",
                said && reExpanded == true,
                "posted \(posted.map(\.name)); expanded now \(String(describing: reExpanded))",
                how: "event")
            page.chromium.axPosted = nil

            // Fullscreen: a page's element (a video's) asks for it on a click; it fills the page, and the panel gives
            // the page its address bar's room too. Esc in the page leaves, back as it was.
            _ = await js(
                "document.body.innerHTML='<div id=v style=\"width:120px;height:60px;background:#c00\"></div><button id=b onclick=\"document.getElementById(\\'v\\').requestFullscreen()\" style=\"position:absolute;left:20px;top:100px;width:120px;height:40px\">Full</button>';1",
                on: page)
            await pause(0.3)
            let tall = view.bounds.height
            await click(view, CGPoint(x: 80, y: 120))
            let entered = await until(5) { page.fullscreen && view.bounds.height > tall }
            let fills = await waitFor(
                "(()=>{const e=document.fullscreenElement;if(!e||e.id!=='v')return false;const r=e.getBoundingClientRect();return r.width===innerWidth&&r.height===innerHeight})()",
                on: page, 3)
            let grown = view.bounds.height - tall
            await key(53, "\u{1b}")
            let left = await until(5) { !page.fullscreen && view.bounds.height == tall }
            let out = await waitFor("document.fullscreenElement===null", on: page, 3)
            check(
                "Fullscreen: a page's element fills the page, the address bar makes room; Esc leaves",
                entered && fills && left && out,
                "entered \(entered), page \(Int(grown)) pt taller; element fills the page \(fills); Esc left \(left), none fullscreen \(out)",
                how: "event")

            // Passkeys. No real WebAuthn call here: Chrome's own dialog would show on the user's screen. The page's hook
            // is read back, and its report sent as it would send it: Chrome's dialog then comes from the page itself
            // (no card of Zero's), and with no window of the browser's shown, nothing takes the front.
            let hooked = await js("navigator.credentials.get.toString().includes('zero:passkey-asked')", on: page) as? Bool == true
            _ = await js("console.debug('zero:passkey-asked'); 1", on: page)
            await pause(1)
            let browserFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ChromiumEngine.engine.pid
            check(
                "A page asking for a passkey: its hook reports it, no card shows, and nothing takes the front",
                hooked && page.questions.isEmpty && !browserFront && !NSApp.isActive,
                "hooked \(hooked); cards \(page.questions.count); browser in front \(browserFront); Zero Dev active \(NSApp.isActive)",
                how: "call")
            await dialogWithItsTab(page)
        }

        /// Chrome's dialog (a passkey's) with its tab, by Zero Dev Browser's stand-in for it: a plain window kept off
        /// every display, read back from the window server.
        func dialogWithItsTab(_ page: WebPage) async {
            let host = page.chromium
            guard let window = page.view.window else { return check("Its dialog: the page's window", false, "none") }
            let height = NSScreen.screens.first?.frame.height ?? 0
            /// Zero Dev Browser's windows from the window server: number, frame (Cocoa's) and how opaque.
            func browserWindows() -> [(number: Int, frame: CGRect, alpha: Double)] {
                let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                return all.compactMap { info in
                    guard (info[kCGWindowOwnerPID as String] as? Int32) == ChromiumEngine.engine.pid,
                        let number = info[kCGWindowNumber as String] as? Int,
                        let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
                    else { return nil }
                    return (
                        number, CGRect(x: b.minX, y: height - b.maxY, width: b.width, height: b.height),
                        info[kCGWindowAlpha as String] as? Double ?? 0
                    )
                }
            }
            /// Whether window `number` is directly above window `below`.
            func justAbove(_ number: Int?, _ below: Int?) -> Bool {
                guard let number, let below else { return false }
                let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(below)) as? [[String: Any]] ?? []
                return (above.last?[kCGWindowNumber as String] as? Int) == number
            }
            /// The windows directly above Zero's, nearest first, by number (Zero Dev Browser's with their size), for evidence.
            func order() -> String {
                let above =
                    CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
                let mine = Dictionary(browserWindows().map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
                return "zero \(window.windowNumber) < "
                    + above.reversed().prefix(4).map { info in
                        let n = info[kCGWindowNumber as String] as? Int ?? 0
                        return mine[n].map { "\(n) \(Int($0.frame.width))x\(Int($0.frame.height)) α\($0.alpha)" } ?? "\(n)"
                    }.joined(separator: " < ")
            }
            /// The panel's column on the screen, which the shield covers.
            func column() -> CGRect { window.convertToScreen(host.modalArea?() ?? .zero) }
            /// The shield over the panel's column, just above Zero's window.
            /// Found by its frame (the column's), then by its number: the column goes with the tab's view.
            var shieldNumber: Int?
            func shield() -> (number: Int, frame: CGRect, alpha: Double)? {
                let c = column()
                let all = browserWindows()
                let found =
                    all.first { c.width > 0 && abs($0.frame.width - c.width) <= 1 && abs($0.frame.height - c.height) <= 1 }
                    ?? all.first { $0.number == shieldNumber }
                if let found { shieldNumber = found.number }
                return found
            }
            func shielded() -> Bool {
                guard let s = shield() else { return false }
                let c = column()
                return abs(s.frame.minX - c.minX) <= 1 && abs(s.frame.minY - c.minY) <= 1 && justAbove(s.number, window.windowNumber)
            }
            /// The stand-in: its frame, how opaque, and whether it's just above the shield (above Zero's window).
            func standIn() -> (frame: CGRect, alpha: Double, justAbove: Bool)? {
                guard let d = browserWindows().first(where: { abs($0.frame.width - 300) <= 1 && abs($0.frame.height - 200) <= 1 })
                else { return nil }
                return (d.frame, d.alpha, shielded() && justAbove(d.number, shield()?.number))
            }
            func tabRect() -> CGRect { window.convertToScreen(page.view.convert(page.view.bounds, to: nil)) }
            func centred() -> Bool {
                guard let s = standIn() else { return false }
                return abs(s.frame.midX - tabRect().midX) <= 1 && abs(s.frame.midY - tabRect().midY) <= 1
            }

            host.devDialog(true)
            let placed = await until(5) { page.dialog && centred() && standIn()?.alpha == 1 && standIn()?.justAbove == true }
            let s = standIn()
            check(
                "Chrome's dialog sits centred on its tab, over a shield on the panel's column, both just above Zero's window, "
                    + "and neither activates the browser app when clicked",
                placed && s?.justAbove == true && shield()?.alpha == 1 && host.placed?["visible"] as? Bool == true
                    && host.devKeepsZeroActive,
                "shown \(page.dialog); dialog \(s.map { "\($0.frame)" } ?? "none"), tab \(tabRect()); shield \(shield().map { "\($0.frame)" } ?? "none"), column \(column()); in order \(s?.justAbove ?? false); non-activating \(host.devKeepsZeroActive); \(order())",
                how: "call")

            let before = window.frame
            window.setFrame(
                NSRect(origin: before.origin, size: NSSize(width: before.width + 80, height: before.height + 40)), display: true)
            await pause(0.5)
            let followed = await until(5) { centred() && shielded() }
            check(
                "It and its shield follow their window when that resizes", followed && tabRect() != .zero,
                "dialog \(standIn().map { "\($0.frame)" } ?? "none"), tab \(tabRect())", how: "call")
            window.setFrame(before, display: true)

            // A click in Zero's window raises it (here ordered front, as the window server does for a click): the dialog
            // is above it again once the click is handled. The click lands in the conversation, outside the panel.
            _ = await until(3) { centred() }
            window.orderFront(nil)
            await pause(0.3)
            let covered = standIn()?.justAbove == false
            let spot = page.view.convert(NSPoint(x: -200, y: page.view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let click = NSEvent.mouseEvent(
                    with: type, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    NSApp.postEvent(click, atStart: false)
                }
            }
            let above = await until(3) { standIn()?.justAbove == true }
            check(
                "A click in Zero's window leaves the shield and the dialog directly above it", above,
                "under it after the raise \(covered); above after the click \(above); \(order())", how: "event")

            page.shown(false)
            let gone = await until(5) { standIn()?.alpha == 0 && shield()?.alpha == 0 }
            page.shown(true)
            let back = await until(5) { standIn()?.alpha == 1 && shield()?.alpha == 1 && centred() }
            check(
                "It goes see-through while its tab is hidden, and comes back with it", gone && back, "hidden \(gone), back \(back)",
                how: "call")

            // While Zero is the active app (said so here: Zero Dev never is), a click in its window keeps that window
            // where it is, under the shield and the dialog, rather than bringing it forward over them. A click on the
            // shield gives the dialog the keyboard and leaves it above the shield.
            host.devActive = true
            let kept = host.devKeptUnder
            // Raised as a click raises it, the click's place held back from the browser app: only Zero's own handling of
            // the click can put its window back under the shield.
            window.orderFront(nil)
            await pause(0.3)
            host.devHoldPlace = true
            let spot2 = page.view.convert(NSPoint(x: -200, y: page.view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let click = NSEvent.mouseEvent(
                    with: type, location: spot2, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    NSApp.postEvent(click, atStart: false)
                }
            }
            let keptUnder = await until(3) { host.devKeptUnder == kept + 1 }
            let underAtOnce = await until(1) { justAbove(shield()?.number, window.windowNumber) }
            host.devHoldPlace = false
            host.devActive = false
            let inOrder = await until(3) { standIn()?.justAbove == true }
            host.devClickShield()
            await pause(0.5)
            let dialogOver = await until(3) { standIn()?.justAbove == true }
            check(
                "While Zero is active, a click in its window keeps it under the dialog; a click on the shield keeps the dialog above",
                keptUnder && underAtOnce && inOrder && dialogOver,
                "kept under \(keptUnder), under the shield by Zero alone \(underAtOnce); in order after \(inOrder); dialog above the shield after its click \(dialogOver); \(order())",
                how: "event")

            // Only while its tab is the one in view: another task shown, the panel closed, another tab picked, it hides
            // (the shield with it), and comes back on the way back.
            func away(_ what: String, _ go: () -> Void, _ back: () -> Void) async {
                go()
                let hidden = await until(5) { standIn()?.alpha == 0 && shield()?.alpha == 0 }
                back()
                let shown = await until(5) { standIn()?.alpha == 1 && shield()?.alpha == 1 && centred() }
                check(
                    "It hides with \(what), and comes back with its tab", hidden && shown, "hidden \(hidden), back \(shown); \(order())",
                    how: "call")
            }
            await away("another task shown", { app.navigation.place = .task("e2e-another-task") }, { app.navigation.place = .task(task) })
            await away("the panel closed", { app.navigation.pane = false }, { app.navigation.pane = true })
            let tab = tabs.selected
            await away(
                "another tab picked", { Panels.shared.change(task) { $0.selected = nil } },
                { Panels.shared.change(task) { $0.selected = tab } })

            host.devDialog(false)
            let closed = await until(5) {
                let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                return !page.dialog && host.placed == nil && !onScreen.contains { ($0[kCGWindowNumber as String] as? Int) == shieldNumber }
            }
            let browserFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ChromiumEngine.engine.pid
            check(
                "Closed: the shield went, and nothing took the front", closed && !browserFront && !NSApp.isActive,
                "shown \(page.dialog), placing \(host.placed != nil), browser in front \(browserFront)", how: "call")

            // A dialog its page's hook didn't report (as GitHub's later requests didn't): the browser app sees the window
            // itself and gives it to the tab last clicked. Chrome moves its dialog to where it thinks the tab is: back on
            // the tab at once, with no place from Zero needed.
            await click(page.view, CGPoint(x: 12, y: 12))
            await pause(0.3)
            host.devUnhookedDialog()
            let found = await until(5) { page.dialog && centred() && standIn()?.alpha == 1 && standIn()?.justAbove == true }
            host.devMoveDialog()
            await pause(0.3)
            let backOnTab = centred()
            host.devDialog(false)
            let gone2 = await until(5) { !page.dialog && host.placed == nil }
            check(
                "A dialog its page didn't report goes with the tab last clicked; moved by Chrome, it's back on the tab at once",
                found && backOnTab && gone2, "placed \(found); back after a move \(backOnTab); closed \(gone2); \(order())", how: "call")

            await rounds(
                page, tabRect: tabRect, standIn: standIn, shield: shield,
                dialogNumber: {
                    browserWindows().first { abs($0.frame.width - 300) <= 1 && abs($0.frame.height - 200) <= 1 }?.number
                })
        }

        /// The window list sampled off the main thread, back to back (each answer takes the window server 2-4 ms), for `ms`: samples in
        /// which the dialog was under Zero's window, see-through or gone, and in which it was off the tab.
        nonisolated func sample(ms: Double, zero: Int, dialog: Int, tab: CGRect, height: CGFloat) async -> (n: Int, covered: Int, off: Int)
        {
            await withCheckedContinuation { done in
                Thread.detachNewThread {
                    var n = 0, covered = 0, off = 0
                    let end = Date().addingTimeInterval(ms / 1000)
                    while Date() < end {
                        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                        let numbers = list.map { $0[kCGWindowNumber as String] as? Int ?? 0 }
                        n += 1
                        if let z = numbers.firstIndex(of: zero), let d = numbers.firstIndex(of: dialog),
                            let b = (list[d][kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
                        {
                            if z < d || (list[d][kCGWindowAlpha as String] as? Double ?? 0) < 1 { covered += 1 }
                            let frame = CGRect(x: b.minX, y: height - b.maxY, width: b.width, height: b.height)
                            if abs(frame.midX - tab.midX) > 1 || abs(frame.midY - tab.midY) > 1 { off += 1 }
                        } else {
                            covered += 1
                        }
                    }
                    done.resume(returning: (n, covered, off))
                }
            }
        }

        /// Rounds of a dialog as GitHub's come (reported by the page, then not, as its Retry), each placed and then
        /// clicked around in Zero: the conversation, the composer, the sidebar, the panel's tabs. Off-screen, a posted
        /// click doesn't bring Zero's window forward as the window server does for the user's: what's measured is
        /// Zero's and the browser app's own handling of each click.
        func rounds(
            _ page: WebPage, tabRect: () -> CGRect, standIn: () -> (frame: CGRect, alpha: Double, justAbove: Bool)?,
            shield: () -> (number: Int, frame: CGRect, alpha: Double)?, dialogNumber: () -> Int?
        ) async {
            let host = page.chromium
            guard let window = page.view.window else { return }
            let height = NSScreen.screens.first?.frame.height ?? 0
            let pageRect = page.view.convert(page.view.bounds, to: nil)
            // On the tab shown, by its icon (clear of its ×): the strip is in the title bar's row, where a click beside a
            // tab would start a window drag.
            let tab = PanelTabStrip.devSelected
            let spots: [(String, NSPoint)] = [
                ("conversation", NSPoint(x: pageRect.minX - 200, y: pageRect.midY)),
                ("composer", NSPoint(x: pageRect.minX - 200, y: 40)),
                ("sidebar", NSPoint(x: 40, y: pageRect.midY - 120)),
                ("panel tabs", NSPoint(x: tab.minX + 14, y: (window.contentView?.bounds.height ?? 0) - tab.midY)),
            ]
            var lines: [String] = []
            var allGood = true
            for round in 1...5 {
                let hooked = round % 2 == 1
                if hooked {
                    host.devDialog(true)
                } else {
                    await click(page.view, CGPoint(x: 12, y: 12))
                    await pause(0.2)
                    host.devUnhookedDialog()
                }
                let placed = await until(5) {
                    guard let s = standIn() else { return false }
                    return page.dialog && s.alpha == 1 && s.justAbove && abs(s.frame.midX - tabRect().midX) <= 1
                        && abs(s.frame.midY - tabRect().midY) <= 1
                }
                host.devAskDialogState()
                _ = await until(2) { host.devDialogState != nil }
                let state = host.devDialogState
                let d = state?["dialog"] as? [String: Any], sh = state?["shield"] as? [String: Any]
                let transient =
                    d?["transient"] as? Bool == true && sh?["transient"] as? Bool == true && d?["managed"] as? Bool == false
                    && sh?["managed"] as? Bool == false && d?["level"] as? Int == 0 && sh?["level"] as? Int == 0
                let keeps = d?["keepsZeroActive"] as? Bool == true && sh?["keepsZeroActive"] as? Bool == true
                // Zero Dev's own are stationary instead, out of Mission Control (transient is what Zero's get).
                let stays = d?["stationaryInDev"] as? Bool == true && sh?["stationaryInDev"] as? Bool == true
                var line =
                    "round \(round) (\(hooked ? "reported" : "unreported")): placed \(placed), transient \(transient), non-activating \(keeps), stationary in Zero Dev \(stays)"
                var good = placed && transient && keeps && stays
                for (name, spot) in spots {
                    if name == "panel tabs" && tab.isEmpty {
                        line += "; panel tabs: no tab's place known"
                        good = false
                        continue
                    }
                    let place = app.navigation.place, selected = Panels.shared.tabs(task).selected
                    guard let dialog = dialogNumber() else {
                        line += "; \(name): no dialog"
                        good = false
                        continue
                    }
                    async let samples = sample(ms: 200, zero: window.windowNumber, dialog: dialog, tab: tabRect(), height: height)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(
                            with: type, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                        {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    let r = await samples
                    // A click that took Zero elsewhere (another task, another tab) hides the dialog by design: put back.
                    let moved = app.navigation.place != place || Panels.shared.tabs(task).selected != selected
                    if moved {
                        app.navigation.place = place
                        Panels.shared.change(task) { $0.selected = selected }
                        _ = await until(3) { standIn()?.alpha == 1 }
                    }
                    line += "; \(name): \(r.n) samples, \(r.covered) covered, \(r.off) off\(moved ? " (went elsewhere)" : "")"
                    if !moved && (r.covered > 0 || r.off > 0 || r.n < 40) { good = false }
                }
                host.devDialog(false)
                let closed = await until(5) { !page.dialog && host.placed == nil }
                line += "; closed \(closed)"
                good = good && closed
                allGood = allGood && good
                lines.append(line)
            }
            check(
                "Five rounds of a dialog: placed on its tab, transient, non-activating; no sample covered or off the tab after clicks around Zero",
                allGood, lines.joined(separator: " | ") + " | panel tabs clicked at \(spots[3].1), on the tab shown \(tab)",
                how: "event, window list")
        }

        // MARK: Keys and mouse buttons

        func keys(_ window: NSWindow) async {
            app.navigation.pane = true
            resetTabs()
            Panels.shared.change(task) { $0.open("https://example.com/?one") }
            Panels.shared.change(task) { $0.open("https://example.com/?two") }
            await pause(1)
            guard let page = shownPage else { return check("A page for the keys", false, "none") }
            let view = page.chromium.view
            _ = await waitFor("document.readyState==='complete'", on: page, 15)
            // The keyboard to the panel: a click in its page.
            await click(view, CGPoint(x: 40, y: 40))
            let holding = WebPages.holding(window.firstResponder as? NSView) === page
            check("A click in the page gives it the keyboard", holding, "first responder \(type(of: window.firstResponder as Any))")

            let count = tabs.tabs.count
            await key(13, "w", .command)
            let closedOne = tabs.tabs.count == count - 1
            check(
                "⌘W closes the panel's tab, not the window", closedOne && window.isVisible,
                "\(count) → \(tabs.tabs.count) tabs; window open \(window.isVisible)")
            await key(6, "z", .command)
            check("⌘Z reopens it, outside a text field", closedOne && tabs.tabs.count == count, "\(count - 1) → \(tabs.tabs.count) tabs")
            await key(13, "w", .command)
            let closedTwo = tabs.tabs.count == count - 1
            let kept = tabs.closed.count
            await key(17, "t", [.command, .shift])
            var how = "posted"
            if tabs.tabs.count != count,
                let e = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil,
                    characters: "T", charactersIgnoringModifiers: "T", isARepeat: false, keyCode: 17)
            {
                how =
                    "posted: no; the menu matches it: \(NSApp.mainMenu?.performKeyEquivalent(with: e) == true); the window: \(window.performKeyEquivalent(with: e))"
            }
            check(
                "⌘⇧T reopens it too", closedTwo && tabs.tabs.count == count,
                "closed \(closedTwo) (\(kept) kept), now \(tabs.tabs.count) tabs; \(how)")
            await key(18, "1", .command)
            let details = tabs.selected == nil
            await key(19, "2", .command)
            check(
                "⌘1 shows Details, ⌘2 the first tab", details && tabs.selected == tabs.tabs.first?.id,
                "details \(details), then \(tabs.shown?.url ?? "Details")")
            let before = tabs.tabs.count
            await key(17, "t", .command)
            check(
                "⌘T opens a new tab", tabs.tabs.count == before + 1 && tabs.shown?.isNew == true,
                "\(before) → \(tabs.tabs.count), new \(tabs.shown?.isNew == true)")
            if let blank = tabs.shown { SidePanel.close(blank.id, in: task) }

            // The mouse's back and forward buttons over the page.
            resetTabs()
            Panels.shared.change(task) { $0.open("https://example.com/") }
            await pause(0.8)
            guard let mouse = shownPage else { return }
            let surface = mouse.chromium.view
            _ = await waitFor("document.readyState==='complete'", on: mouse, 15)
            mouse.load("https://example.org/")
            _ = await waitFor("location.host==='example.org' && document.readyState==='complete'", on: mouse, 15)
            _ = await until(4) { mouse.canGoBack }
            let posted = await mouseButton(3, surface, CGPoint(x: 40, y: 40))
            let back = await waitFor("location.host==='example.com'", on: mouse, 5)
            let posted2 = await mouseButton(4, surface, CGPoint(x: 40, y: 40))
            let forward = await waitFor("location.host==='example.org'", on: mouse, 5)
            check(
                "Mouse buttons 4 and 5 go back and forward in the page", posted && posted2 && back && forward,
                "events posted \(posted && posted2), back \(back), forward \(forward)")
            resetTabs()
        }

        // MARK: Details pane

        /// The details pane's links by issue, from follows as zerod lists them (none polled), and a click on one.
        func linkGroups(_ workspace: Workspace, _ window: NSWindow) async {
            func follow(_ topic: String, _ summary: String, name: String?, state: String?, closed: Bool = false) -> [String: Any] {
                var f: [String: Any] = [
                    "session": task, "topic": topic, "at": 0, "summary": summary, "lastPoll": 0, "mine": false, "about": [String](),
                    "new": false,
                    "detail": "",
                ]
                if let name { f["name"] = name }
                if let state { f["state"] = state; f["closed"] = closed }
                return f
            }
            let list: [[String: Any]] = [
                follow(
                    "linear/ZD-1", "ZD-1 Make links go where they should https://linear.app/zero-e2e/issue/ZD-1",
                    name: "Make links go where they should", state: "In Progress"),
                follow(
                    "github/zero-e2e/app/pull/7", "ZD-1: Route links https://github.com/zero-e2e/app/pull/7", name: "ZD-1: Route links",
                    state: "open"),
                follow(
                    "github/zero-e2e/site/pull/9", "ZD-1: Route links https://github.com/zero-e2e/site/pull/9", name: "ZD-1: Route links",
                    state: "open"),
                follow(
                    "github/zero-e2e/app/pull/3", "Unrelated fix https://github.com/zero-e2e/app/pull/3", name: "Unrelated fix",
                    state: "open"),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: list),
                let follows = try? JSONDecoder().decode([ZerodLink.Followed].self, from: data)
            else { return check("Details: follows decode", false, "fixture didn't decode", how: "call") }
            let groups = LinkGroups.of(follows, issues: [("ZD-1", nil)])
            check(
                "Details: the issue groups its PRs, the same change in two repos as one",
                groups.issues.first?.changes.count == 1 && groups.issues.first?.changes.first?.follows.count == 2
                    && groups.other.count == 1,
                "issues \(groups.issues.map(\.ticket)), changes \(groups.issues.first?.changes.map { "\($0.name)×\($0.follows.count)" } ?? []), other \(groups.other.count)",
                how: "call")

            // The pane itself, drawn as the panel draws it, for a person to look at (SwiftUI shows no accessibility tree
            // to a process without an accessibility client, so its words can't be read back here).
            workspace.devFollowed(follows)
            guard let conversation = workspace.conversation(task) else { return }
            var opened: [String] = []
            let pane = TaskDetails(workspace: workspace, inbox: app.inbox, navigation: app.navigation, row: nil, conversation: conversation)
            {
                opened.append($0)
            }
            .frame(width: 380, height: 520).background(Theme.card)
            // In a hosting view, as the window has it (ImageRenderer draws no ScrollView's content), never on a display.
            let host = NSHostingView(rootView: pane)
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
            let holder = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            holder.contentView = host
            holder.setFrameOrigin(DevWindow.away)
            host.layoutSubtreeIfNeeded()
            await pause(0.5)
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
            if let rep { host.cacheDisplay(in: host.bounds, to: rep) }
            let png = rep?.representation(using: .png, properties: [:])
            // Blank (every pixel one colour) means nothing was drawn.
            let first = rep?.colorAt(x: 0, y: 0)
            let drawn =
                rep.map { r in
                    stride(from: 0, to: r.pixelsHigh, by: 4).contains { y in
                        stride(from: 0, to: r.pixelsWide, by: 4).contains { x in r.colorAt(x: x, y: y) != first }
                    }
                } ?? false
            holder.isReleasedWhenClosed = false
            holder.close()
            let file = out.appendingPathComponent("details-links.png")
            try? png?.write(to: file)
            check(
                "Details: the pane draws its links by issue (look at the image)", drawn,
                "\(file.path); follows \(workspace.followed.filter { $0.session == conversation.id }.count) of \(workspace.followed.count)",
                how: "render")
            workspace.devFollowed(nil)
        }

        /// A lead in a folder that is no repository writes a table of pull requests and heads: the ones it follows link
        /// to their repository, each head to its row's; the one it doesn't follow, and its head, stay text.
        func bareReferences(_ workspace: Workspace) {
            let json = ["13963", "13964"].map {
                #"{"session":"\#(task)","topic":"github/zero-e2e/app/\#($0)","at":0,"summary":"","lastPoll":0,"mine":false,"about":[],"new":false,"detail":""}"#
            }
            guard let follows = try? JSONDecoder().decode([ZerodLink.Followed].self, from: Data("[\(json.joined(separator: ","))]".utf8))
            else { return check("Links: bare references' follows decode", false, "fixture didn't decode", how: "call") }
            workspace.devFollowed(follows)
            defer { workspace.devFollowed(nil) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zero-e2e-worktrees-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let text = """
                | PR | Head | Waiting for |
                |---|---|---|
                | #13963 | 87c01f9a1e | You. |
                | #13969 | 8fe807c9eb | Merge it after #13964. |
                """
            let rich = MarkdownText.render(
                text, size: 14.5, compact: false, links: MarkdownText.links(cwd: folder.path, yours: false, task: task))
            var found: [String] = []
            rich.enumerateAttribute(.link, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
                guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                found.append(
                    "\((rich.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)) → \(url.absoluteString)"
                )
            }
            let want = [
                "#13963 → https://github.com/zero-e2e/app/pull/13963", "87c01f9a1e → https://github.com/zero-e2e/app/commit/87c01f9a1e",
                "#13964 → https://github.com/zero-e2e/app/pull/13964",
            ]
            check("Links: a table's followed PRs and their heads link to their repository", found == want, "\(found)", how: "render")
        }

        // MARK: Agents

        /// A desktop_ call of this task's, through zerod to Zero Dev (attached as its desktop): what zerod answers.
        func desktop(_ tool: String, _ args: [String: Any] = [:]) async -> (ok: Bool, text: String) {
            guard let link = try? ZerodLink() else { return (false, "no zerod") }
            defer { link.close() }
            do {
                let r = try await link.call("desktopCall", ["session": task, "tool": tool, "args": args]) as? [String: Any]
                return (true, (r?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n"))
            } catch { return (false, "\(error)") }
        }

        /// The ref of the first line of a desktop_read with all these words.
        func ref(in lines: String, _ words: String...) -> String? {
            guard
                let line = lines.split(separator: "\n").first(where: { line in
                    words.allSatisfy { line.localizedCaseInsensitiveContains($0) }
                }),
                let found = line.range(of: #"\[e\d+\]"#, options: .regularExpression)
            else { return nil }
            return String(line[found].dropFirst().dropLast())
        }

        /// An agent uses Zero Dev's own window through the desktop tools: allowed on the card, it reads the window and
        /// moves around it through accessibility (no permission needed for an app's own tree, so nothing asks the
        /// system); the composer, an ask's card and Settings refuse it. Nothing here posts events or captures the screen.
        func desktopDrives(_ window: NSWindow) async {
            app.navigation.place = .task(task)
            let listed = await desktop("desktop_apps")
            check(
                "Zero Dev is zerod's desktop: desktop_apps answers",
                listed.ok && listed.text.contains("Accessibility:") && listed.text.contains("Screen: unlocked"),
                String(listed.text.prefix(120)), how: "call")
            let started = Date()
            var took = 0
            let reading = Task {
                let read = await self.desktop("desktop_read", ["app": "com.arsen.zero.dev"])
                took = Int(Date().timeIntervalSince(started) * 1000)
                return read
            }
            var card: Ask?
            _ = await until(5) {
                card = self.app.store.open.first { $0.title.contains("use Zero Dev") }
                return card != nil
            }
            if let card, let allow = card.options.firstIndex(of: "Allow for this task") { app.store.choose(card.id, option: allow) }
            let read = await reading.value
            check(
                "The user allows Zero Dev for the task on a card, and desktop_read gives its window's tree",
                card != nil && read.ok && read.text.contains("[e"),
                "card \(card?.title ?? "none"); card to tree \(took) ms, \(read.text.split(separator: "\n").count) lines; \(read.text.prefix(160))",
                how: "call")
            // The composer is the user's voice: agents reach a task with zero send, never by typing as the user.
            let composer = ref(in: read.text, "text area") ?? ref(in: read.text, "text field")
            let typed = await desktop(
                "desktop_type", ["app": "com.arsen.zero.dev", "ref": composer ?? "e0", "text": "typed by the desktop"])
            let landed = views(NSTextView.self, in: window.contentView).contains { $0.string.contains("typed by the desktop") }
            check(
                "An agent can't type into the user's composer", composer != nil && typed.text.contains("act on Zero") && !landed,
                "ref \(composer ?? "none"): \(typed.text.prefix(100)), landed \(landed)", how: "call")
            // Navigation stays the agent's: the sidebar's Scratchpads, pressed through accessibility, opens them.
            let pads = ref(in: read.text, "Scratchpads")
            let went = await desktop("desktop_click", ["app": "com.arsen.zero.dev", "ref": pads ?? "e0"])
            let moved = await until(3) { self.app.navigation.place == .pads }
            check(
                "An agent can still move around Zero: a sidebar link pressed opens its page", pads != nil && went.ok && moved,
                "ref \(pads ?? "none"): \(went.text.prefix(100)), at \(self.app.navigation.place)", how: "call")
            app.navigation.place = .task(task)
            await pause(0.3)
            let asked = try? await ZerodLink().call(
                "agentAsk",
                ["session": task, "args": ["tool": "ask", "question": "Ship the desktop check?", "options": ["Ship it", "Hold"]]])
            _ = await until(5) { self.app.store.open.contains { $0.title == "Ship the desktop check?" } }
            await pause(0.5)
            let again = await desktop("desktop_read", ["app": "com.arsen.zero.dev"])
            let ship = ref(in: again.text, "Ship it")
            let pressed = await desktop("desktop_click", ["app": "com.arsen.zero.dev", "ref": ship ?? "e0"])
            let open = app.store.open.contains { $0.title == "Ship the desktop check?" && $0.state == .waiting }
            check(
                "An agent can't press an ask's own buttons in Zero",
                ship != nil && !pressed.ok && pressed.text.contains("act on Zero") && open,
                "ref \(ship ?? "none"), \(pressed.text.prefix(120)), still open \(open)", how: "call")
            // By where it is, as much as by its ref: x and y on the card refuse too, before any event is made.
            let at = center(in: again.text, "Ship it")
            let clicked = await desktop("desktop_click", ["app": "com.arsen.zero.dev", "x": at?.x ?? 0, "y": at?.y ?? 0])
            check(
                "Nor click it by x and y", at != nil && clicked.text.contains("act on Zero"),
                "at \(String(describing: at)): \(clicked.text.prefix(100))",
                how: "call")
            // Nor drag onto it: both ends are checked before anything moves.
            let dragged = await desktop(
                "desktop_drag", ["app": "com.arsen.zero.dev", "from": ["x": 40, "y": 200], "to": ["x": at?.x ?? 0, "y": at?.y ?? 0]])
            check("Nor drag onto it", at != nil && dragged.text.contains("act on Zero"), String(dragged.text.prefix(100)), how: "call")
            if let id = (asked as? [String: Any])?["id"] as? String { app.store.choose(id, option: 1) }

            // A picture of Zero Dev's own window, drawn by itself (no permission), one pixel per point.
            let shot =
                try? await ZerodLink().call(
                    "desktopCall", ["session": task, "tool": "desktop_screenshot", "args": ["app": "com.arsen.zero.dev"]]) as? [String: Any]
            let parts = shot?["content"] as? [[String: Any]] ?? []
            let image = (parts.first { $0["type"] as? String == "image" }?["data"] as? String).flatMap { Data(base64Encoded: $0) }
                .flatMap(NSBitmapImageRep.init(data:))
            let colours =
                image.map { rep in
                    Set(
                        stride(from: 0, to: rep.pixelsWide, by: 37).flatMap { x in
                            stride(from: 0, to: rep.pixelsHigh, by: 41).compactMap {
                                rep.colorAt(x: x, y: $0)?.usingColorSpace(.deviceRGB)?.redComponent
                            }
                        }
                    ).count
                } ?? 0
            let frame = window.frame.size
            check(
                "desktop_screenshot gives Zero Dev's window as Zero draws it, a pixel a point",
                image?.pixelsWide == Int(frame.width) && image?.pixelsHigh == Int(frame.height) && colours > 3,
                "\(image.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "no image") for a \(Int(frame.width))x\(Int(frame.height)) window, \(colours) shades; \(parts.compactMap { $0["text"] as? String }.joined().prefix(100))",
                how: "call")
            // A film needs Screen Recording, which Zero Dev never has: it says so, and asks the system nothing.
            let film = await desktop("desktop_record", ["app": "com.arsen.zero.dev", "action": "start"])
            check(
                "desktop_record without Screen Recording says to ask the user", film.text.contains("Screen Recording permission"),
                String(film.text.prefix(120)), how: "call")

            // Settings are the user's: read, yes; pressed, no.
            app.navigation.place = .settings
            var settings = (ok: false, text: "")
            var button: String?
            _ = await until(5) {
                settings = await self.desktop("desktop_read", ["app": "com.arsen.zero.dev"])
                button = self.ref(in: settings.text, "button")
                return button != nil
            }
            let inSettings = await desktop("desktop_click", ["app": "com.arsen.zero.dev", "ref": button ?? "e0"])
            check(
                "An agent can't act in Zero's Settings", button != nil && inSettings.text.contains("act on Zero"),
                "ref \(button ?? "none, read: \(settings.text.prefix(300))"): \(inSettings.text.prefix(100))", how: "call")
            app.navigation.place = .task(task)
            await pause(0.3)

            // The control bar's Stop: what drives is shown, Stop takes the desktop back, and the task is told once.
            _ = await desktop("desktop_read", ["app": "com.arsen.zero.dev"])
            let shown = Desktop.shared.driving
            Desktop.shared.stop()
            await pause(0.3)
            let stopped = await desktop("desktop_read", ["app": "com.arsen.zero.dev"])
            check(
                "Stop takes the desktop back from the task", shown?.app == "Zero Dev" && stopped.text.contains("stopped"),
                "driving \(shown.map { "\($0.task) in \($0.app)" } ?? "nothing"): \(stopped.text.prefix(100))", how: "call")
        }

        /// The middle of the first element with these words in a desktop_read, in the window's points.
        func center(in lines: String, _ words: String...) -> (x: Double, y: Double)? {
            guard
                let line = lines.split(separator: "\n").first(where: { line in
                    words.allSatisfy { line.localizedCaseInsensitiveContains($0) }
                }),
                let found = line.range(of: #"(-?\d+),(-?\d+) (\d+)x(\d+)"#, options: .regularExpression)
            else { return nil }
            let n = line[found].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" }).compactMap { Double($0) }
            return n.count == 4 ? (n[0] + n[2] / 2, n[1] + n[3] / 2) : nil
        }

        /// The model selector's effort slider, read from what the selector would show (it never opens here): the level
        /// its chip names, and a level slid to, on the new task page with no model picked and on a task.
        func effortSlider() async {
            let selector = WorkspaceSelector.shared
            func shown(_ chip: String) -> (state: SelectorState, row: SelectorRow)? {
                selector.devShown = nil
                selector.devChips[chip]?()
                guard let state = selector.devShown, let row = state.sections.flatMap(\.rows).first(where: \.selected) else { return nil }
                return (state, row)
            }
            // Levels that aren't the model's default, so the default showing instead fails.
            let first = ComposerRows.catalogue(.claude).first
            let others = (first?.levels ?? []).map(\.id).filter { $0 != first?.defaultLevel }
            guard others.count >= 2 else {
                return check("Claude's first model has effort levels", false, "\(first?.id ?? "none")", how: "call")
            }
            let defaults = UserDefaults.standard
            let provider = defaults.string(forKey: "workspaceProvider"), kept = NewTaskChoice.kept(for: .claude)
            defaults.set("claude", forKey: "workspaceProvider")
            NewTaskChoice.keep(.claude, model: "", effort: others[0])
            app.navigation.place = .home
            await pause(0.8)
            let new = shown("new.agent")
            let opened = new.flatMap { $0.state.level(of: $0.row) }
            new.map { $0.state.slide(to: others[1], on: $0.row) }
            let slid = new.flatMap { $0.state.level(of: $0.row) }
            check(
                "New task, no model picked: the effort slider shows the chip's level and slides",
                opened == others[0] && slid == others[1] && NewTaskChoice.kept(for: .claude).effort == others[1],
                "\(new?.row.id ?? "no selector (chips: \(selector.devChips.keys.sorted()))"): opened at \(opened ?? "nil") (chip \(others[0])), slid to \(slid ?? "nil"), kept \(NewTaskChoice.kept(for: .claude).effort)",
                how: "call")
            NewTaskChoice.keep(.claude, model: kept.model, effort: kept.effort, advisor: kept.advisor)
            if let provider {
                defaults.set(provider, forKey: "workspaceProvider")
            } else {
                defaults.removeObject(forKey: "workspaceProvider")
            }

            app.navigation.place = .task(task)
            await pause(0.8)
            let chip = "task.\(task).agent"
            let open = shown(chip)
            let level = open.flatMap { s in s.row.levels.map(\.id).first { $0 != s.state.level(of: s.row) } }
            if let open, let level { open.state.slide(to: level, on: open.row) }
            let moved = open.flatMap { $0.state.level(of: $0.row) }
            await pause(0.3)
            let again = shown(chip).flatMap { $0.state.level(of: $0.row) }
            check(
                "A task's effort slider moves to the level slid to, and opens on it again",
                level != nil && moved == level && again == level,
                "\(open?.row.id ?? "no selector"): slid to \(level ?? "nil"), shows \(moved ?? "nil"), reopened at \(again ?? "nil")",
                how: "call")
        }

        /// An image pasted (⌘V) into an ask's "Something else…": a tile over the words in the box, not its path; the
        /// answer the agent reads keeps the path. The paste reads a pasteboard of the checks' own, never the user's.
        func askPaste(_ window: NSWindow) async {
            app.navigation.place = .task(task)
            let asked =
                try? await ZerodLink().call(
                    "agentAsk",
                    [
                        "session": task,
                        "args": ["tool": "ask", "question": "Paste a picture?", "options": ["All right", "Something else…"]],
                    ])
                as? [String: Any]
            guard let id = asked?["id"] as? String, await until(5, { self.app.store.ask(id) != nil }) else {
                return check("An ask to paste into", false, "\(String(describing: asked))", how: "call")
            }
            app.inbox.drafts[id] = "broken:"
            app.inbox.choose(1, on: id)
            await pause(0.6)
            let board = NSPasteboard(name: .init("com.arsen.zero.dev.e2e"))
            board.clearContents()
            board.writeObjects([
                NSImage(size: NSSize(width: 8, height: 8), flipped: false) {
                    NSColor.red.setFill(); $0.fill(); return true
                }
            ])
            Attachments.pasteboard = board
            await key(9, "v", .command)
            Attachments.pasteboard = .general
            let draft = app.inbox.drafts[id] ?? ""
            let pasted = PastedImages.split(draft, folder: Attachments.folder.path)
            let fields =
                views(NSTextView.self, in: window.contentView).map(\.string)
                + views(NSTextField.self, in: window.contentView).map(\.stringValue)
            let field = fields.first { $0.contains("broken:") }
            check(
                "An image pasted into an ask's Something else… is a tile, its path not in the field",
                pasted.words == "broken:" && pasted.images.count == 1 && field != nil && field?.contains("/attachments/") == false,
                "draft \(draft); field \(field ?? "not found")", how: "event")
            app.inbox.send(id)
            _ = await until(3) { self.app.store.ask(id)?.answer != nil }
            let answer = app.store.ask(id)?.answer ?? ""
            check(
                "The answer the agent reads keeps the pasted image's path", !pasted.images.isEmpty && answer.contains(pasted.images[0]),
                answer, how: "call")
        }

        /// An agent of this task drives Zero Browser through zerod, and its tab shows in the task's panel.
        func agentDrives() async {
            app.navigation.pane = true
            let picked = await agent("browser_select", ["browser": "zero"])
            check("An agent picks Zero Browser through zerod", picked.ok, String(picked.text.prefix(100)), how: "call")
            let listed = await agent("browser_tabs", ["createIfEmpty": true])
            let tabId =
                listed.text.split(separator: "\n").lazy.compactMap { line -> Int? in
                    guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] else { return nil }
                    return d.first?["tabId"] as? Int
                }.first ?? listed.text.range(of: #"\d{6,}"#, options: .regularExpression).flatMap { Int(listed.text[$0]) }
            check("Its browser_tabs opens a tab of its own", listed.ok && tabId != nil, String(listed.text.prefix(160)), how: "call")
            guard let tabId else { return }
            let went = await agent("browser_navigate", ["url": "https://example.com/", "tabId": tabId])
            let title = await agent("browser_js", ["text": "document.title", "tabId": tabId])
            check(
                "browser_navigate and browser_js work in it", went.ok && title.text.contains("Example Domain"),
                "\(went.text.prefix(60)) / \(title.text.prefix(60))", how: "call")
            let adopted = await until(5) { self.tabs.tabs.contains { $0.openedBy == self.task } }
            check("The agent's tab shows in the task's panel", adopted, "\(tabs.tabs.map(\.url))", how: "call")
            _ = await agent(
                "browser_js", ["text": "setTimeout(() => { window.answered = confirm('Go on?') }, 200); 'set'", "tabId": tabId])
            await pause(0.8)
            let blocked = await agent("browser_js", ["text": "1 + 1", "tabId": tabId])
            let answered = await agent("browser_dialog", ["accept": true, "tabId": tabId])
            let result = await agent("browser_js", ["text": "String(window.answered)", "tabId": tabId])
            check(
                "An agent's page dialog goes to the agent, not the user's card",
                blocked.text.contains("Go on?") && answered.ok && result.text.contains("true"),
                "\(blocked.text.prefix(80)) / \(result.text.suffix(20))", how: "call")
            let closed = await agent("browser_tab_close", ["tabId": tabId])
            let gone = await until(4) { !self.tabs.tabs.contains { $0.openedBy == self.task } }
            check("browser_tab_close closes it, in the panel too", closed.ok && gone, String(closed.text.prefix(80)), how: "call")
        }
    }
#endif
