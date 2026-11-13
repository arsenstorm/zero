#if DEBUG
    import SwiftUI
    import UIKit

    /// A task's page as the app shows it (TaskView), with a conversation of its own, for the UI tests (ZeroUITests):
    /// opened with the launch argument `-composerTest`, no pairing needed. Every frame, what's on screen is written to
    /// Library/frames.log (FrameLog): the keyboard's top, the composer's foot and the page's scroll, as drawn.
    struct TaskTestPage: View {
        let model = PhoneModel.shared
        @State private var session = "test-" + UUID().uuidString.prefix(6)
        @State private var ready = false

        var body: some View {
            NavigationStack {
                if ready { TaskView(model: model, session: session) }
            }
            .background { FrameLog() }
            .task {
                // With `-fixture <path>`: a real conversation as zerod's `recent` sent it (its result), a long one with
                // folded turns and pages before it. With `-fixtureFirst` as well, it's there before the page opens (a
                // task opened from the list, already held), rather than coming a moment after.
                if let at = CommandLine.arguments.firstIndex(of: "-fixture"), at + 1 < CommandLine.arguments.count,
                    let data = FileManager.default.contents(atPath: CommandLine.arguments[at + 1]),
                    let recent = try? jsonDecoder.decode(Recent.self, from: data)
                {
                    var conversation = recent.result.conversation
                    conversation.id = session
                    if CommandLine.arguments.contains("-fixtureFirst") {
                        model.showForTests(conversation, earlier: recent.result.earlier)
                        ready = true
                    } else {
                        ready = true
                        try? await Task.sleep(for: .milliseconds(600))
                        model.showForTests(conversation, earlier: recent.result.earlier)
                    }
                    return
                }
                var conversation = Conversation(id: session, provider: .claude, cwd: "/work")
                // Working, with the launch argument `-working`: the composer shows Stop, and a message sent queues.
                conversation.status = CommandLine.arguments.contains("-working") ? .working : .idle
                let start = Date().addingTimeInterval(-3600)
                for turn in 0..<12 {
                    let at = start.addingTimeInterval(Double(turn) * 120)
                    conversation.items.append(item("u\(turn)", .user(text: "Message \(turn): what's next on this?", images: []), at))
                    conversation.items.append(
                        item(
                            "a\(turn)",
                            .agent(
                                text: "Answer \(turn). A few lines of words, as an agent writes them, long enough to wrap "
                                    + "across the page twice or three times so the page has something to scroll.",
                                finalAnswer: true), at.addingTimeInterval(30)))
                }
                // As a task opens in the app: the page first, its conversation a moment later.
                ready = true
                try? await Task.sleep(for: .milliseconds(600))
                model.showForTests(conversation)
                // An ask of the task's agent, to answer (its inbox, the bar's tray).
                var agent = AgentIdentity(name: "zerod-" + session, host: "test")
                agent.ref = session
                agent.runtime = "zerod"
                model.showForTests(Ask(kind: .choice, title: "Go on with the plan?", options: ["Yes", "No"], agent: agent))
                // With `-endLater`: the turn ends 6 s on with no answer ("Thinking…" goes, nothing comes in its place).
                if CommandLine.arguments.contains("-endLater") {
                    try? await Task.sleep(for: .seconds(6))
                    if var ended = model.conversation(session) {
                        ended.status = .idle
                        model.showForTests(ended)
                    }
                }
                // With `-addLater`: 12 s on, a message of the user's that zerod sends on by itself (one queued), not lifted.
                if CommandLine.arguments.contains("-addLater") {
                    try? await Task.sleep(for: .seconds(12))
                    model.addedForTests("Sent on by zerod", to: session)
                }
            }
        }

        private struct Recent: Decodable {
            struct Result: Decodable {
                let conversation: Conversation
                let earlier: Int
            }
            let result: Result
        }

        private func item(_ id: String, _ kind: ConversationItem.Kind, _ at: Date) -> ConversationItem {
            ConversationItem(id: id, turn: nil, kind: kind, status: .done, at: Int(at.timeIntervalSince1970 * 1000))
        }
    }

    /// Every frame, as drawn (layers' presentation values, mid-animation too): the keyboard's top (its layout guide),
    /// the composer's foot (its box's scroll view), and the page's scroll offset and foot inset.
    struct FrameLog: UIViewRepresentable {
        /// How many of the conversation's items are on screen (ConversationView sets it): a dip is something gone.
        @MainActor static var shown = 0
        /// The composer's fade, as drawn (ComposerFade sets it).
        @MainActor static var fade = 0.0

        func makeUIView(context: Context) -> Logger { Logger() }
        func updateUIView(_ view: Logger, context: Context) {}

        final class Logger: UIView {
            private var link: CADisplayLink?
            private var lines: [String] = []
            private lazy var file: URL = {
                let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("frames.log")
                try? Data().write(to: url)
                return url
            }()
            private lazy var probe: UIView = {
                let probe = UIView()
                probe.isUserInteractionEnabled = false
                probe.translatesAutoresizingMaskIntoConstraints = false
                addSubview(probe)
                NSLayoutConstraint.activate([
                    probe.heightAnchor.constraint(equalToConstant: 1), probe.widthAnchor.constraint(equalToConstant: 1),
                    probe.leadingAnchor.constraint(equalTo: leadingAnchor),
                    probe.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                ])
                return probe
            }()

            override func didMoveToWindow() {
                super.didMoveToWindow()
                isUserInteractionEnabled = false
                guard window != nil, link == nil else { return }
                _ = probe
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                self.link = link
            }

            /// Where a view is drawn on screen this frame: its own and its ancestors' layers as presented.
            private func drawn(_ view: UIView) -> CGRect {
                let own = view.layer.presentation() ?? view.layer
                var rect = CGRect(origin: .zero, size: own.bounds.size)
                var layer: CALayer? = own
                var current: UIView? = view
                while let v = current, let l = layer {
                    rect.origin.x += l.frame.minX - (v.superview?.layer.presentation()?.bounds.minX ?? v.superview?.bounds.minX ?? 0)
                    rect.origin.y += l.frame.minY - (v.superview?.layer.presentation()?.bounds.minY ?? v.superview?.bounds.minY ?? 0)
                    current = v.superview
                    layer = current.map { $0.layer.presentation() ?? $0.layer }
                    if current is UIWindow { break }
                }
                return rect
            }

            private func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
                ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
            }

            /// The keyboard as iOS draws it: its host view in the keyboard's window.
            private func keyboardHost() -> UIView? {
                let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                for window in windows {
                    if let host = all(UIView.self, in: window).first(where: {
                        String(describing: type(of: $0)).contains("InputSetHostView")
                    }) {
                        return host
                    }
                }
                return nil
            }

            @objc private func tick(_ link: CADisplayLink) {
                guard let window else { return }
                let guide = drawn(probe).maxY
                let host = keyboardHost()
                // The host's top, or the screen's foot with no keyboard drawn.
                let keyboard = host.map { drawn($0).minY } ?? window.bounds.maxY
                let scrolls = all(UIScrollView.self, in: window).filter { !($0 is UITextView) }
                let field = all(UITextView.self, in: window).first { $0.accessibilityIdentifier == "composer.field" }
                let page = scrolls.filter { scroll in !(field.map { $0.isDescendant(of: scroll) } ?? false) }
                    .max { $0.contentSize.height < $1.contentSize.height }
                let pageOffset = (page?.layer.presentation() ?? page?.layer)?.bounds.minY ?? 0
                lines.append(
                    String(
                        format: "%.4f keyboard %.1f guide %.1f field %.1f page %.1f inset %.1f height %.1f shown %d fade %.2f",
                        link.timestamp, keyboard, guide,
                        field.map { drawn($0).maxY } ?? -1, pageOffset, page?.adjustedContentInset.bottom ?? -1,
                        page?.contentSize.height ?? -1, FrameLog.shown, FrameLog.fade))
                if lines.count >= 30 { flush() }
            }

            private func flush() {
                guard let handle = try? FileHandle(forWritingTo: file) else { return }
                handle.seekToEndOfFile()
                handle.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
                try? handle.close()
                lines = []
            }
        }
    }
#endif
