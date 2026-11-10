import AppKit
import SwiftUI
import ZeroCore

/// `Zero --render-pill DIR` writes pill-{resting,hovered,selected}.png and card.png at 4x for pixel checks.
@MainActor
enum Preview {
    /// `Zero --render-text DIR`: Markdown as the conversation draws it, through AppKit (ImageRenderer can't draw the
    /// text view), at 2x: text.png on its own, step.png as an agent's words between steps, block.png in an open work block.
    static func renderText(to dir: String) {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let words = "`SkeletonTurns` is static, and `Bar` only shows while an integration view loads, so both are fine."
        let item = ConversationItem(id: "a1", turn: "t", kind: .agent(text: words, finalAnswer: false), status: .done)
        let command = ConversationItem(
            id: "c1", turn: "t", kind: .command(command: "cd /Users/arsen", cwd: "/", output: "", exitCode: 0, durationMs: 1), status: .done
        )
        func write(_ view: some View, _ name: String) {
            let host = NSHostingView(rootView: view.frame(width: 640).padding(24).background(Theme.card))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        write(MarkdownText(words, size: 14.5), "text.png")
        write(
            VStack(alignment: .leading, spacing: 12) {
                ItemView(item: command, cwd: "/"); ItemView(item: item, cwd: "/")
            }, "step.png")
        write(WorkBlock(items: [command, item], start: Date().addingTimeInterval(-60), end: Date(), live: true, cwd: "/"), "block.png")
        let mine = ConversationItem(id: "u1", turn: "t", kind: .user(text: "`git status` first, then the rest"), status: .done)
        write(ItemView(item: mine, cwd: "/"), "mine.png")
        write(
            MarkdownText("Before.\n\n```swift\nlet a = 1\n```\n\n> A quote, quoted.\n\n---\n\n`code` after a rule.", size: 14.5),
            "blocks.png")
    }

    static func renderPill(to dir: String) {
        let codex = AgentIdentity(name: "codex-12", host: "mac")
        let lead = AgentIdentity(name: "app-lead", host: "mac")
        let store = Store(asks: [
            made(Ask(kind: .note, title: "Update", body: "Scaffolded the checkout page; installing the Stripe SDK next", agent: codex)),
            Ask(
                kind: .choice, title: "Stripe checkout", body: "Allow this command?",
                options: ["Yes", "Yes, and don't ask again", "No, and tell Codex what to do differently…"],
                command: "npm install stripe", agent: codex),
            Ask(
                kind: .run, title: "Production read: Source.count", options: ["Run", "Reject", "Suggest something else…"],
                command: "bin/production console <<< 'puts Source.count'", cwd: "/Users/arsen/x", agent: lead),
            made(Ask(kind: .choice, title: "Deploy", body: "Deploy to staging now?", options: ["Yes", "Not yet…"], agent: lead), chose: 0),
            made(
                Ask(kind: .choice, title: "Lint", body: "Fix the 3 lint warnings too?", options: ["Yes", "Leave them"], agent: codex),
                chose: 0),
            made(
                Ask(kind: .choice, title: "Deploy", body: "Deploy to staging now?", options: ["Yes", "Not yet…"], agent: lead), chose: 0,
                pending: true),
        ])
        let controller = InboxController(store: store)
        let settings = Settings()
        // ZERO_APPEARANCE=light|dark picks the appearance the dynamic colours resolve in.
        let appearance = NSAppearance(named: ProcessInfo.processInfo.environment["ZERO_APPEARANCE"] == "light" ? .aqua : .darkAqua)!
        NSApplication.shared.appearance = appearance
        func write(_ view: some View, _ name: String) {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, appearance.name == .aqua ? .light : .dark))
            renderer.scale = 4
            var image: CGImage?
            appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            guard let cg = image else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let pill = {
            PillView(controller: controller, settings: settings, openInbox: {}, selectAgent: { _ in }, moveHere: {}, previewHovered: $0)
        }
        write(pill(nil), "pill-resting.png")
        controller.agentFilter = "app-lead"
        controller.pinned = true
        write(pill(nil), "pill-selected.png")
        controller.pinned = false
        controller.agentFilter = nil
        write(CardStack(controller: controller).padding(12).background(Color(white: 0.5)), "cards.png")
        // The answer states on their own, with nothing else open, so nothing is dimmed.
        let states = Store(asks: [
            made(
                Ask(kind: .choice, title: "Lint", body: "Fix the 3 lint warnings too?", options: ["Yes", "Leave them"], agent: codex),
                chose: 0),
            made(
                Ask(kind: .choice, title: "Deploy", body: "Deploy to staging now?", options: ["Yes", "Not yet…"], agent: lead), chose: 0,
                pending: true),
        ])
        write(CardStack(controller: InboxController(store: states)).padding(12).background(Color(white: 0.5)), "states.png")
        // A run before and after completion, to compare the terminal's height with the options' space.
        var finished = made(
            Ask(
                kind: .run, title: "Production read", options: ["Run", "Reject", "Suggest something else…"],
                command: "echo one; echo two", cwd: "/tmp", agent: lead), chose: 0)
        finished.output = "one\ntwo\n"
        finished.exitCode = 0
        let runs = Store(asks: [
            finished,
            Ask(
                kind: .run, title: "Production read", options: ["Run", "Reject", "Suggest something else…"],
                command: "echo one; echo two", cwd: "/tmp", agent: lead),
        ])
        write(CardStack(controller: InboxController(store: runs)).padding(12).background(Color(white: 0.5)), "runs.png")
        // The empty inbox: "All quiet." and the new-agent composer, with example choices.
        let empty = InboxController(store: Store())
        empty.spawnTargets = [SpawnChoice(id: "10", name: "acme"), SpawnChoice(id: "13", name: "zero")]
        empty.runtimesByAdapter = ["Zero": [SpawnChoice(id: "6", name: "Claude"), SpawnChoice(id: "7", name: "Codex")]]
        empty.spawnTarget = "10"; empty.spawnRuntime = "6"
        write(ComposerPreview(controller: empty).padding(12).background(Color(white: 0.5)), "composer.png")
        // An agent's conversation: a reply card with Markdown, and a sent message still waiting.
        let claude = AgentIdentity(name: "claude-7", host: "mac", label: "Checkout spec fix")
        func said(_ kind: AskKind, _ body: String, _ status: String) -> Ask {
            var item = made(Ask(kind: kind, title: kind == .message ? "Message" : "Replied", body: body, agent: claude))
            item.status = status
            return item
        }
        let first = said(.message, "fix the flaky checkout spec", "sent")
        let reply = said(
            .note,
            "Found it: the spec raced the mailer.\n\n```ruby\nperform_enqueued_jobs do\n  post :create\nend\n```\n\nPushed as `a1b2c3`.",
            "done")
        let short = said(.note, "Hi. What do you want to work on?", "done")
        let second = said(.message, "and the retry logic?", "sent")
        let talking = InboxController(store: Store(asks: [first, reply]))
        talking.agentFilter = "claude-7"
        write(TimelinePreview(controller: talking).padding(12).background(Color(white: 0.5)), "chat.png")
        let shortly = InboxController(store: Store(asks: [first, reply, short]))
        shortly.agentFilter = "claude-7"
        write(TimelinePreview(controller: shortly).padding(12).background(Color(white: 0.5)), "chat-short.png")
        let waiting = InboxController(store: Store(asks: [first, reply, short, second]))
        waiting.agentFilter = "claude-7"
        write(TimelinePreview(controller: waiting).padding(12).background(Color(white: 0.5)), "chat-waiting.png")
        // The model selector, on real catalogues.
        let selector = SelectorState(kind: .runtime)
        selector.sections = empty.selectorSections(for: .runtime)
        selector.tab = selector.sections.first?.id
        selector.highlighted = selector.sections.first?.rows.first?.id
        write(SelectorView(state: selector).padding(12).background(Color(white: 0.5)), "selector.png")
    }
}

/// An ask as zerod would have it after a while: a note or message as made, a choice answered (or still in its take-back
/// window when `pending`).
@MainActor
private func made(_ ask: Ask, chose option: Int? = nil, pending: Bool = false) -> Ask {
    var ask = ask
    if ask.kind == .note || ask.kind == .message { ask.state = .answered; ask.answeredAt = ask.createdAt }
    if let option {
        ask.state = pending ? .pending : .answered
        ask.choice = option
        ask.answer = ask.options[option]
        ask.answeredAt = Date()
    }
    return ask
}

private struct TimelinePreview: View {
    @Bindable var controller: InboxController
    @FocusState private var focus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { AgentTimeline(controller: controller, focus: $focus) }.frame(width: 380)
    }
}

private struct ComposerPreview: View {
    @Bindable var controller: InboxController
    @FocusState private var focus: String?
    var body: some View {
        ComposerCard(controller: controller, focus: $focus, mode: .newAgent).frame(width: 380)
    }
}

private struct CardStack: View {
    @Bindable var controller: InboxController
    @FocusState private var focus: String?
    var body: some View {
        VStack(spacing: 10) {
            ForEach(controller.store.asks.reversed()) { ask in CardView(ask: ask, controller: controller, focus: $focus) }
        }
        .frame(width: 380)
    }
}
