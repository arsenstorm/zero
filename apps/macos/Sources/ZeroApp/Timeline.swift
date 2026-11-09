import AppKit
import SwiftUI
import ZeroCore

// A conversation read as Codex shows one: your messages, then each turn's work folded into "Worked for 2m 37s ›" with
// only its answer in full. Hovering a message shows when it was sent, a copy button and a menu. A rail on the left
// has a tick for each of your messages, bright for those on screen; hovering one previews it, clicking goes there.

/// One block of the timeline, drawn again only when the block itself (or the folder its links use) changed: the quote
/// and save actions don't count.
struct BlockRow: View, Equatable {
    let block: TimelineBlock
    let cwd: String
    let quote: (String) -> Void
    let save: (String) -> Void
    /// Going back to a message of yours (WorkspaceView's RewindCard).
    var rewind: (ConversationItem) -> Void = { _ in }
    /// Asking the agent to save an answer for later.
    var later: (String) -> Void = { _ in }

    static func == (a: BlockRow, b: BlockRow) -> Bool { a.block == b.block && a.cwd == b.cwd }

    var body: some View {
        switch block {
        case let .user(item):
            if case let .user(text, _) = item.kind {
                if let given = ConversationItem.from(text) {
                    // Not yours: a worker's report, or Zero's word. Read as such, on the left, folded past a few lines.
                    GivenMessage(from: given.from, text: given.text, cwd: cwd)
                } else {
                    MessageBlock(text: text, date: item.date, mine: true, quote: quote, save: save, rewind: { rewind(item) }) { ItemView(item: item, cwd: cwd) }
                }
            }
        case let .answer(item):
            // Zero's ending isn't shown: it's the task's state, in the sidebar, the pane and the board.
            if case let .agent(said, _) = item.kind, case let text = ZeroEnding.split(said).0, !text.isEmpty {
                MessageBlock(text: text, date: item.date, mine: false, quote: quote, save: save, later: later) {
                    // Still being revealed when the turn ended: it carries on at its pace, rather than jumping to the end.
                    if Reveal.unfinished(item.id, of: text) { StreamingText(id: item.id, text: text, cwd: cwd) }
                    else { MarkdownText(text, cwd: cwd, size: 14.5) }
                }
            }
        case let .work(_, items, start, end, live):
            WorkBlock(items: items, start: start, end: end, live: live, cwd: cwd)
        case let .step(item):
            ItemView(item: item, cwd: cwd)
        }
    }
}

/// "2m 37s", "45s", "1h 3m".
func workedFor(_ seconds: TimeInterval) -> String { Took.length(seconds) }

/// A turn's work: open while it goes ("Working for 12s", every step under it), folded once the answer comes ("Worked
/// for 2m 37s ›"), unless you say otherwise. A turn that only thought says "Thinking", then "Thought for 8s", as Codex
/// does; one that did nothing at all says nothing.
struct WorkBlock: View {
    let items: [ConversationItem]
    let start: Date?
    let end: Date?
    let live: Bool
    let cwd: String
    /// Your choice against the default (open while live, folded after); forgotten when the turn ends.
    @State private var toggled = false
    private var open: Bool { live != toggled }
    /// Steps of substance: reading, running, editing. Thought alone isn't work.
    private var worked: Bool { items.contains { if case .reasoning = $0.kind { false } else { true } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if live || !items.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { toggled.toggle() } } label: {
                    HStack(spacing: 6) {
                        if live, !worked {
                            Thinking(text: "Thinking")
                        } else if live {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(start.map { "Working for " + workedFor(context.date.timeIntervalSince($0)) } ?? "Working")
                            }
                        } else {
                            let verb = worked ? "Worked" : "Thought"
                            Text(Took.text(verb, start.flatMap { start in end.map { $0.timeIntervalSince(start) } }))
                        }
                        if !items.isEmpty { NucleoIcon("chevron-down", size: 9).rotationEffect(.degrees(open ? 0 : -90)) }
                    }
                    // Figures of one width: the count ticks without the chevron after it shifting.
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { if worked { Rectangle().fill(Theme.stroke).frame(height: 1).offset(y: 6) } }
                .tip(open ? "Hide the steps" : "Show every step")
            }
            if open, !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    // Each step knows when the next began (a thought's length); the last, when the turn ended.
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        StepOrAsk(item: item, cwd: cwd, until: index + 1 < items.count ? items[index + 1].date : (live ? nil : end))
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
            if live {
                // Open, every step is above, the words being written among them; this is what's still to say.
                if let last = items.last, case let .agent(said, _) = last.kind, case let text = ZeroEnding.split(said).0, !text.isEmpty {
                    // What it's saying, as the words stream in, at Zero's own steady pace.
                    if !open { StreamingText(id: last.id, text: text, cwd: cwd) }
                } else {
                    // Where it is: its latest step, quietly, on one line of fixed height whatever kind of step it is;
                    // under it "Thinking…", always holding its place and shown only between steps (or before the
                    // first). A step starting or ending changes words, never the height, so nothing below jumps.
                    if !open {
                        Group { if let last = items.last { StepLine(item: last) } }
                            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
                            .opacity(0.7).allowsHitTesting(false)
                    }
                    // Through every step, until its words start to stream (before any step, the heading breathes).
                    if worked { Thinking() }
                }
            }
        }
        .padding(.top, 4)
        .onChange(of: live) { toggled = false }
    }
}

/// A step, or, when it was the agent asking you through Zero (zero run, ask, approve), that ask's card in its place:
/// what the step is, answered there as in the inbox. Reads the inbox itself, so the card keeps up with the answer.
struct StepOrAsk: View {
    let item: ConversationItem
    let cwd: String
    let until: Date?
    @Environment(\.askInbox) private var inbox
    @Environment(\.askSession) private var session

    var body: some View {
        if let inbox, let session, let ask = AgentAskCard.made(by: item, in: inbox.store.asks, session: session) {
            // A line: its card, to answer it by, is above the composer.
            AgentAskCard(ask: ask, inbox: inbox, compact: true)
        } else {
            ItemView(item: item, cwd: cwd, until: until)
        }
    }
}

/// Other tasks by their ids: a message from one names it, and opens it. Always equal: its closures read the workspace
/// and navigation, which don't change, and a new one each time the task page redrew redrew every message reading it.
struct TaskLink: Equatable {
    let name: (String) -> String?
    let open: (String) -> Void
    static func == (a: TaskLink, b: TaskLink) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var taskLink: TaskLink? = nil
    /// The inbox, and the session whose chat this is: what a step that asked shows its card from.
    @Entry var askInbox: InboxController? = nil
    @Entry var askSession: String? = nil
}

/// "Thinking…", breathing, while the agent works with nothing new to show: never mistaken for stuck.
struct Thinking: View {
    var text = "Thinking…"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The pulse runs in Core Animation, as the spinner does: a SwiftUI animation that never ends has the window's
    // whole layout worked out again every frame, the conversation with it, for as long as the agent thinks.
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            .overlay { if !reduceMotion { PulseLayer() } }
            .compositingGroup()
    }
}

/// Fades what's under it in and out, forever, on the render server: nothing of SwiftUI's runs per frame.
private struct PulseLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> PulseView { PulseView() }
    func updateNSView(_ view: PulseView, context: Context) {}
}

final class PulseView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer, layer.animation(forKey: "pulse") == nil else { return }
        // A veil in the card's colour, coming and going over the words: the words seem to dim and brighten.
        layer.backgroundColor = Theme.cardColor.cgColor
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0
        pulse.toValue = 0.65
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(pulse, forKey: "pulse")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.cardColor.cgColor }
    }
}

/// Words Zero gave the session, not yours: a worker's report to its lead ("Worker ENG-9790 finished: …"), or a watched
/// command's end. One quiet line, as a step is drawn: the icon and the report's first line; a click opens the whole
/// of it under, and closes it again. The report's closing note on how to reply (zerod's, for the agent) stays folded.
/// Turns Zero started that changed nothing for the user (TimelineRow.quiet): one row, opened in place to read them.
struct QuietTurns<Content: View>: View {
    let turns: Int
    @Binding var open: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    NucleoIcon("stack", size: 14).foregroundStyle(.secondary).frame(width: 14, height: 16)
                    Text(turns == 1 ? "An update that needed nothing from you" : "\(turns) updates that needed nothing from you").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            if open { content() }
        }
    }
}

struct GivenMessage: View {
    let from: String
    let text: String
    let cwd: String
    @State private var open = false
    @Environment(\.taskLink) private var link

    /// Another task's message, not a worker's report (which says whose it is): the task's name, opening it.
    private var sender: String? {
        guard from != "zero", !text.hasPrefix("Worker "), let link else { return nil }
        return link.name(from)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                NucleoIcon(from == "zero" ? "circle-info" : "robot", size: 14).foregroundStyle(.secondary).frame(width: 14, height: 16)
                if let sender, let link {
                    Button(sender) { link.open(from) }.buttonStyle(.plain).fontWeight(.medium).lineLimit(1).fixedSize()
                        .tip("Open \(sender)")
                }
                Button { open.toggle() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(first).foregroundStyle(.secondary).lineLimit(open ? nil : 1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        if !rest.isEmpty { NucleoIcon("chevron-down", size: 11).rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // Opened, what follows its heading: the heading itself is the row above, said once. Events on what's
            // followed as cards of their own (their text is written for the agent).
            if open, !rest.isEmpty {
                let followed = from == "zero" ? FollowEvents.parse(report) : []
                Group {
                    if followed.isEmpty { MarkdownText(rest, cwd: cwd, size: 13.5, compact: true) } else { FollowedEvents(groups: followed) }
                }
                .padding(.leading, 22)
            }
        }
        .font(.callout)
    }

    /// Its first line, as words: the heading of the folded row. Without a closing colon: folded, it read as if the
    /// line after it were what it introduces.
    private var first: String {
        if from == "zero", let headline = NoticeText.headline(text) { return headline }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let words = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return words.hasSuffix(":") ? String(words.dropLast()) : words
    }

    /// The report after its first line, which heads the folded row.
    private var rest: String {
        guard let end = report.firstIndex(where: \.isNewline) else { return "" }
        return report[end...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The report without its closing note to the agent on how to reply.
    private var report: String {
        guard let note = text.range(of: "\n\n(It is session ") else { return text }
        return String(text[..<note.lowerBound])
    }
}

/// Events on what a task follows, opened: a card a thing (its short name, its title opening it), its events under it,
/// each with its words and a link to it.
private struct FollowedEvents: View {
    let groups: [FollowEvents.Group]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups.indices, id: \.self) { i in card(groups[i]) }
        }
    }

    private func card(_ group: FollowEvents.Group) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                if !group.title.isEmpty { opening(group.title, group.url) }
                Spacer(minLength: 0)
            }
            ForEach(group.events.indices, id: \.self) { i in
                let event = group.events[i]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.secondary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3.5 }
                        Text(event.summary).lineLimit(2)
                        if event.mine { Text("Possibly yours").foregroundStyle(.secondary).lineLimit(1).fixedSize() }
                        Spacer(minLength: 8)
                        if let url = event.url { opening("View", url) }
                    }
                    if !event.body.isEmpty {
                        Text(event.body).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled).padding(.leading, 13)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.choice, in: RoundedRectangle(cornerRadius: 10))
    }

    /// What opens, as properties have it: medium weight on a dashed underline.
    @ViewBuilder private func opening(_ text: String, _ link: String?) -> some View {
        if let link, let url = URL(string: link) {
            Button { NSWorkspace.shared.open(url) } label: { TaskDetails.linked(text) }.buttonStyle(.plain).tip("Open " + link)
        } else {
            Text(text).fontWeight(.medium).lineLimit(1)
        }
    }
}

/// A message of yours or an answer, with what shows under it on hover: copy, a menu, and when it was sent.
struct MessageBlock<Content: View>: View {
    let text: String
    let date: Date?
    /// Yours: on the right, as your bubble is.
    let mine: Bool
    let quote: (String) -> Void
    let save: (String) -> Void
    /// Yours: back to just before it.
    var rewind: (() -> Void)? = nil
    /// The agent's: it's asked to save this for later.
    var later: ((String) -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            content()
            HStack(spacing: 4) {
                CopyButton(text: text)
                Menu {
                    Button("Copy") { copy() }
                    Button("Quote in reply") { quote(text) }
                    Button("Save to a scratchpad") { save(text) }
                    if let later { Button("Save for later") { later(text) } }
                    if let rewind {
                        Divider()
                        Button("Rewind…", action: rewind)
                    }
                } label: {
                    NucleoIcon("dots", size: 13).foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22, height: 22)
                if let date { Text(Self.stamp(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.leading, 4) }
            }
            // Always laid out, shown on hover: nothing moves as the pointer passes.
            .opacity(hovered ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "5:39 PM" today, "Oct 7, 5:39 PM" before, with the year when it isn't this one.
    static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.month(.abbreviated).day().year().hour().minute())
    }
}

/// A tick for each message of yours, down the left, as Codex has them: brighter for those on screen. Hovering grows the
/// tick under the pointer and, a little, its neighbours, dims the rest, and shows that message with the start of its
/// answer; a click goes there.
struct MessageRail: View, Equatable {
    typealias Mark = OutlineMark
    let marks: [Mark]
    let tracker: ScrollTracker
    /// Room at the left, between the page's edge and the ticks, that answers the pointer as the ticks do: the pointer
    /// can drift to the edge without leaving the rail.
    var inset: CGFloat = 0
    let go: (String) -> Void
    @State private var hovered: Int?
    /// The message under the pointer, by its index in `marks`: a tick standing for several is scrubbed through by
    /// moving within its zone.
    @State private var scrubbed: Int?
    /// The pointer is on the card: it stays, so its links can be clicked.
    @State private var onCard = false

    /// The same marks at the same inset draw the same rail: what's on screen is read from the tracker, inside.
    nonisolated static func == (a: MessageRail, b: MessageRail) -> Bool { a.marks == b.marks && a.inset == b.inset }

    /// How long a tick is, by how far it is from the one hovered.
    private static let lengths: [CGFloat] = [24, 17, 13]
    private static let rest: CGFloat = 10

    var body: some View {
        let visible = Set(tracker.seen.values)
        GeometryReader { space in
            // Ten points apart, down to seven when there are many; past that, each tick stands for a run of messages
            // rather than the ticks packing into a block. Moving within a tick's zone scrubs through its run.
            let room = space.size.height * 0.8
            let stride = max(1, Int((CGFloat(marks.count) * 7 / max(room, 1)).rounded(.up)))
            let groups: [Range<Int>] = Swift.stride(from: 0, to: marks.count, by: stride).map { $0..<min($0 + stride, marks.count) }
            let shown = groups.map { marks[$0.lowerBound] }
            let pitch = max(7, min(10, room / CGFloat(max(shown.count, 1))))
            let top = (space.size.height - pitch * CGFloat(shown.count)) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, mark in
                    let distance = hovered.map { abs($0 - index) }
                    let length = distance.flatMap { $0 < Self.lengths.count ? Self.lengths[$0] : nil } ?? Self.rest
                    let bright = hovered.map { $0 == index } ?? visible.contains(mark.id)
                    Capsule().fill(Color.primary.opacity(bright ? 0.85 : 0.25))
                        .frame(width: length, height: 1.5)
                        .offset(x: inset, y: top + pitch * (CGFloat(index) + 0.5) - 0.75)
                }
            }
            // The ticks ease to their lengths; the card (below) is instant.
            .animation(.easeOut(duration: 0.12), value: hovered)
            .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    let index = Int(((point.y - top) / pitch).rounded(.down))
                    let inside = point.y >= top - pitch && point.y <= top + pitch * CGFloat(shown.count) + pitch
                    hovered = inside ? min(max(index, 0), shown.count - 1) : nil
                    if let hovered {
                        // Where in the tick's zone: which of its run.
                        let group = groups[hovered]
                        let within = min(max((point.y - (top + pitch * CGFloat(hovered))) / pitch, 0), 0.999)
                        scrubbed = group.lowerBound + Int(within * CGFloat(group.count))
                    } else { scrubbed = nil }
                case .ended:
                    // A moment to cross to the card; it stays while the pointer's on it.
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        if !onCard { hovered = nil; scrubbed = nil }
                    }
                }
            }
            .onTapGesture { if let scrubbed, scrubbed < marks.count { go(marks[scrubbed].id) } }
            .overlay {
                if let hovered, hovered < shown.count, let scrubbed, scrubbed < marks.count {
                    // Centred on its tick, kept inside the view near its ends.
                    let y = min(max(top + pitch * (CGFloat(hovered) + 0.5), 60), space.size.height - 60)
                    let mark = marks[scrubbed]
                    preview(mark)
                        .fixedSize()
                        // Links in it open; anywhere else on it goes to the message, as its tick does.
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .onTapGesture { go(mark.id) }
                        .onHover { inside in
                            onCard = inside
                            if !inside { self.hovered = nil; self.scrubbed = nil }
                        }
                        .position(x: inset + 40 + 160, y: y)
                }
            }
        }
        // Past the ticks, the rail reaches to where the card begins: the pointer crosses to it without leaving.
        .frame(width: inset + 40)
    }

    private func preview(_ mark: Mark) -> some View {
        let inline = { (text: String) in (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text) }
        let firstLine = mark.text.split(separator: "\n").first.map(String.init) ?? mark.text
        return VStack(alignment: .leading, spacing: 5) {
            Text(firstLine).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
            if let answer = mark.answer {
                Text(inline(answer.replacingOccurrences(of: "\n", with: " "))).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// Where a conversation is scrolled to and which of its turns are on screen. Its own object, read only by what shows
/// them (the scrollbar, the way down, the rail), so scrolling redraws them and not every message.
@Observable final class ScrollTracker {
    var geometry: ScrollGeometry?
    /// The blocks on screen, by the message of yours each answers to.
    var seen: [String: String] = [:]
    /// The conversation's own height (without the room an answered card keeps): read when a card leaves, never by a
    /// view's body, so its every change redraws nothing.
    var columnHeight: CGFloat = 0
}

/// Back to the latest, once it's well below what's on screen.
struct WayDown: View {
    let tracker: ScrollTracker
    /// Away from the end whatever the scroll says: a window jumped to, the latest not loaded.
    var away = false
    let go: () -> Void

    var body: some View {
        if away || tracker.geometry.map({ $0.contentSize.height + $0.contentInsets.bottom - ($0.contentOffset.y + $0.containerSize.height) > 200 }) == true {
            Button(action: go) {
                NucleoIcon("arrow-up", size: 14).rotationEffect(.degrees(180)).foregroundStyle(.primary)
                    .frame(width: 32, height: 32).background(Theme.card, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.stroke))
            }
            .buttonStyle(.plain).tip("Go to the latest")
            .transition(.opacity)
        }
    }
}

/// A scrollbar as arsenstorm.com has one: a thin rounded thumb on no track, the full height of what scrolls; it
/// widens under the pointer and drags.
struct ThinScrollbar: View {
    let tracker: ScrollTracker
    let scrollTo: (CGFloat) -> Void
    @State private var hovered = false
    @State private var dragFrom: CGFloat?
    /// Shown while scrolling and a moment after, as macOS's overlay scrollbars are; held while it's pointed at or dragged.
    @State private var shown = false
    @State private var hiding: Task<Void, Never>?

    /// rgb(161 161 170 / 70%) light, rgb(113 113 122 / 70%) dark: the site's zinc.
    static let thumb = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 113 / 255, green: 113 / 255, blue: 122 / 255, alpha: 0.7)
            : NSColor(srgbRed: 161 / 255, green: 161 / 255, blue: 170 / 255, alpha: 0.7)
    })

    var body: some View {
        GeometryReader { space in
            if let geometry = tracker.geometry {
                // What's on screen against the whole conversation; past either end (insets, a bounce) counts as the end.
                let total = geometry.contentSize.height
                let visible = min(geometry.visibleRect.height, total)
                if total > visible + 1 {
                    let track = space.size.height - 8
                    let length = max(32, track * visible / total)
                    let room = total - visible
                    let offset = min(max(geometry.visibleRect.minY, 0), room)
                    let y = 4 + (track - length) * offset / room
                    Capsule().fill(Self.thumb)
                        .frame(width: hovered || dragFrom != nil ? 6 : 4, height: length)
                        .opacity(shown || hovered || dragFrom != nil ? 1 : 0)
                        .frame(width: 12, height: length)
                        .contentShape(Rectangle())
                        .position(x: space.size.width - 6, y: y + length / 2)
                        .onHover { inside in
                            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
                            if !inside { reveal() }
                        }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let start = dragFrom ?? offset
                                if dragFrom == nil { dragFrom = start }
                                let moved = drag.translation.height * room / max(track - length, 1)
                                scrollTo(min(max(start + moved, 0), room))
                            }
                            .onEnded { _ in dragFrom = nil; reveal() })
                }
            }
        }
        .frame(width: 12)
        .onChange(of: tracker.geometry?.contentOffset.y) { reveal() }
    }

    /// Shown now, faded out once scrolling has stopped for a moment.
    private func reveal() {
        if !shown { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, !hovered, dragFrom == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { shown = false }
        }
    }
}

/// The chat's scrollbar on any scroll view: the system's hidden, this one drawn over the right edge, dragged to scroll.
struct ThinScrollbars: ViewModifier {
    /// How far past the scroll view's right edge the bar sits: a sidebar's runs in its padding, at the sidebar's edge.
    var outset: CGFloat = 0
    /// Where it's scrolled, kept by this name: back there on coming back to it (back and forward, or Zero reopened).
    var remember: String? = nil
    @State private var tracker = ScrollTracker()
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, now in tracker.geometry = now }
            .overlay(alignment: .trailing) { ThinScrollbar(tracker: tracker) { position.scrollTo(y: $0) }.padding(.trailing, 2).offset(x: outset) }
            .onScrollPhaseChange { _, phase in if phase == .idle { keep() } }
            .onDisappear(perform: keep)
            .onAppear {
                guard let remember, let y = ScrollMemory.offsets[remember], y > 0 else { return }
                // Once laid out: before, there's nothing to scroll.
                DispatchQueue.main.async { position.scrollTo(y: y) }
            }
    }

    private func keep() {
        guard let remember, let y = tracker.geometry?.contentOffset.y else { return }
        ScrollMemory.offsets[remember] = max(0, y)
    }
}

extension View {
    /// The one scrollbar Zero has, the chat's, on this scroll view.
    func thinScrollbar(outset: CGFloat = 0, remember: String? = nil) -> some View { modifier(ThinScrollbars(outset: outset, remember: remember)) }
}

/// Where pages and conversations were scrolled to, kept across going back and forward and across Zero reopening.
enum ScrollMemory {
    /// A page's offset, by name.
    static var offsets: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "scrollOffsets") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "scrollOffsets") }
    }

    /// A conversation's place: the block at the top of the screen, and the message of yours it answers (to load back
    /// to when it isn't loaded). None: at its end.
    static func place(in conversation: String) -> (block: String, turn: String)? {
        guard let kept = (UserDefaults.standard.dictionary(forKey: "chatScroll") as? [String: [String]])?[conversation], kept.count == 2 else { return nil }
        return (kept[0], kept[1])
    }

    static func keep(_ place: (block: String, turn: String)?, in conversation: String) {
        var all = UserDefaults.standard.dictionary(forKey: "chatScroll") as? [String: [String]] ?? [:]
        all[conversation] = place.map { [$0.block, $0.turn] }
        UserDefaults.standard.set(all, forKey: "chatScroll")
    }
}

/// The same scrollbar for AppKit's scroll views (a pad's text, a command's output): the thumb only, in the chat's
/// zinc, thin until the pointer is on it.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 12 }
    private var hovered = false

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        let width: CGFloat = hovered ? 6 : 4
        let bar = NSRect(x: knob.maxX - width - 2, y: knob.minY + 4, width: width, height: max(knob.height - 8, 24))
        NSColor(ThinScrollbar.thumb).setFill()
        NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

/// Rows standing in for older messages while they're fetched: a message of yours and an answer, as bars.
/// The top of a conversation with more above it: nothing while idle, "Loading earlier…" while a page comes in. One
/// height either way, so nothing moves.
struct LoadingEarlier: View {
    let loading: Bool
    var body: some View {
        HStack(spacing: 8) {
            if loading {
                Spinner().frame(width: 12, height: 12)
                Text("Loading earlier…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
    }
}

struct SkeletonTurns: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14).fill(Theme.chip).frame(width: 260, height: 36).frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach([0.92, 0.78, 0.86, 0.45], id: \.self) { fraction in
                        GeometryReader { space in RoundedRectangle(cornerRadius: 4).fill(Theme.chip).frame(width: space.size.width * fraction, height: 10) }
                            .frame(height: 10)
                    }
                }
            }
        }
        .opacity(0.7)
    }
}

/// A step as one line, for the working bar's latest: what it is, not its card (a command's box, cut to a line, was
/// half a box). Running, a spinner; done, a tick; failed, a cross.
struct StepLine: View {
    let item: ConversationItem

    var body: some View {
        HStack(spacing: 7) {
            switch item.status {
            case .running: Spinner().frame(width: 11, height: 11)
            case .done: NucleoIcon("circle-check", fill: "glyph", size: 12).foregroundStyle(.secondary)
            case .failed: NucleoIcon("circle-xmark", fill: "glyph", size: 12).foregroundStyle(.red)
            case .declined: NucleoIcon("ban", size: 12).foregroundStyle(.orange)
            }
            text.lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var text: some View {
        switch item.kind {
        case let .command(command, _, _, _, _): Text("$ " + command.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12, design: .monospaced))
        case let .tool(name, detail): Text(ToolNames.name(name)).fontWeight(.medium) + Text(" " + ToolNames.detail(detail))
        case let .fileChange(changes): Text("Edited " + changes.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))
        case let .agent(text, _), let .reasoning(text), let .plan(text): Text(text.split(separator: "\n").first.map(String.init) ?? "")
        case let .notice(text, _): Text(text)
        case let .table(title, _, rows): Text(title.isEmpty ? "A table of \(rows.count)" : title)
        case let .user(text, _): Text((ConversationItem.from(text)?.text ?? text).split(separator: "\n").first.map(String.init) ?? "")
        }
    }
}

/// How much of each streaming message has been shown, by its item: kept outside the views, so the answer a turn ends
/// with carries on from where the live text was.
@MainActor enum Reveal {
    static var shown: [String: Int] = [:]

    static func unfinished(_ id: String, of text: String) -> Bool { shown[id].map { $0 < text.count } ?? false }
}

/// Words as they stream, shown at Zero's own pace rather than in the bursts they arrive in: fast enough to catch up
/// with what's arrived within a third of a second, never slower than 400 characters a second, so text flows on
/// steadily, ahead of the bursts, instead of jumping.
struct StreamingText: View {
    let id: String
    let text: String
    let cwd: String
    @State private var shown: Int = 0
    @State private var last: Date?

    var body: some View {
        let total = text.count
        TimelineView(.animation(minimumInterval: 1 / 60, paused: shown >= total)) { context in
            MarkdownText(String(text.prefix(shown)), cwd: cwd, size: 14.5).streaming(true)
                .onChange(of: context.date) { _, now in advance(to: now, total: total) }
        }
        .onAppear { shown = min(Reveal.shown[id] ?? 0, total) }
    }

    private func advance(to now: Date, total: Int) {
        let step = min(now.timeIntervalSince(last ?? now.addingTimeInterval(-1 / 60)), 0.1)
        last = now
        let behind = total - shown
        guard behind > 0 else { return }
        let pace = max(400, Double(behind) / 0.33)
        shown = min(total, shown + max(1, Int(pace * step)))
        Reveal.shown[id] = shown
    }
}
