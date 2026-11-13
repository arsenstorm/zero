import SwiftUI

// A task's conversation on the phone, read as the Mac reads it (ZeroCore's TimelineBlock): your messages, each turn's
// work folded under "Worked for…" with only its answer in full. What waits on you is in the task's own inbox (its
// button in the bar, TaskInbox), not at the conversation's foot, where a few cards took the whole screen.

struct ConversationView: View {
    let model: PhoneModel
    let conversation: Conversation
    /// Your message just sent, lifted to the page's top: from it down, at least this tall (the page's height), so the
    /// answer grows into room already there and the page never has to move for it (TaskView).
    var lift: CGFloat = 0
    /// The message lifted: yours sent (its own id), or what an answer to an ask brought (TaskView).
    var liftAt: String? = nil
    /// Where the conversation's end is and ↓ (TaskView's): told when the conversation moves or changes.
    var end: TaskEnd? = nil
    /// What's on screen, at the Mac's pace (ZeroCore's Playback): answers read out word by word, what came after them
    /// stepping out once they're read. Opened, or back from the background, it's all there at once. Calmer than the
    /// Mac's: an answer that comes whole is read a word at a time (twice the pace at most), not in runs of words.
    @State private var playback: Playback = {
        let playback = Playback()
        playback.fastest = 2
        playback.limit = 60
        return playback
    }()
    @State private var shape = TurnShape()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The lifted group's height as laid out, and what it keeps as its least (a turn's live row gone, see below).
    @State private var height: CGFloat = 0
    @State private var held: CGFloat = 0
    /// The message an About link went to, washed for a moment.
    @State private var washed: String?
    @Environment(\.scenePhase) private var phase

    /// Posted with an item's id (an ask's About, tapped in the task's inbox): the conversation goes to it.
    static let show = Notification.Name("zero.showMessage")

    var body: some View {
        let items = Sending.merge(conversation.items, model.sending[conversation.id] ?? []).filter { item in
            !conversation.approvals.contains { $0.item == item.id }
        }
        // Not live only in the background: Control Center or a Face ID prompt (inactive) showed the rest of an answer at once.
        let _ = playback.update(items, conversation: conversation.id, live: phase != .background, now: Date())
        #if DEBUG
            let _ = FrameLog.shown = playback.count
        #endif
        let working = playback.working(conversation.status == .working || conversation.status == .waiting)
        let blocks = shape.blocks(Array(items.prefix(playback.count)), working: working)
        ScrollViewReader { proxy in
            // Not lazy: a lazy stack under a bottom anchor drew nothing until scrolled, and the phone holds one page only.
            VStack(alignment: .leading, spacing: 0) {
                let earlier = model.earlier(conversation.id) > 0
                // From your latest message down, in a group of its own: what's lifted (always the same group, so a
                // send moves nothing into or out of it but the messages around it).
                // From the message lifted (yours sent, by its own id or zerod's copy of it keeping that id as `sent`;
                // or what an answer to an ask brought), or from the end until it shows; with nothing lifted, from your
                // latest message. Always the latest of yours, the room moved on to a message never lifted.
                let split =
                    liftAt.map { at in
                        blocks.firstIndex { block in
                            if case let .user(item) = block { return item.id == at || item.sent == at }
                            return block.id == at
                        } ?? blocks.endIndex
                    }
                    ?? blocks.lastIndex { if case let .user(item) = $0 { item.isYours } else { false } } ?? blocks.endIndex
                VStack(alignment: .leading, spacing: 24) {
                    if earlier {
                        Button("Earlier messages") { Task { await model.loadEarlier(conversation.id) } }
                            .font(.footnote).frame(maxWidth: .infinity)
                    }
                    ForEach(blocks[..<split]) { row($0) }
                }
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(blocks[split...]) { row($0) }
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    height = $0
                }
                .overlay(alignment: .bottom) {
                    EndMarker(end: end).frame(height: 1)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.frame(in: .global).maxY
                        } action: { _ in
                            end?.recount()
                        }
                }
                .frame(minHeight: max(lift, held), alignment: .top)
                // The gap between blocks above it is the group's own: a lift scrolls to it, so a lifted message has
                // that gap below the bar, not against its edge.
                .padding(.top, earlier || split > 0 ? Self.liftGap : 0)
                .id(Self.lifted)
            }
            // A turn ending with nothing in its live row's place: the row's space kept until the next item takes it,
            // so the page at its end doesn't drop by it.
            .onChange(of: working) { was, now in if was && !now { held = height } }
            .onChange(of: items.count) { held = 0 }
            .onChange(of: liftAt) { held = 0 }
            .environment(\.showMessage) { show($0, proxy) }
            .environment(\.playback, playback)
            .environment(\.taskEnd, end)
            .onReceive(NotificationCenter.default.publisher(for: Self.show)) { note in
                if let item = note.object as? String { show(item, proxy) }
            }
        }
        .background { PlaybackClock(playback: playback) }
    }

    /// The id of the group from your latest message down: where a message just sent is lifted to (TaskView).
    static let lifted = "lifted"
    /// A lifted message's gap below the bar: the conversation's own between blocks.
    static let liftGap: CGFloat = 24

    @ViewBuilder private func row(_ block: TimelineBlock) -> some View {
        switch block {
        case let .user(item): UserMessage(item: item).id(item.id).washed(washed == item.id)
        case let .work(id, items, start, end, live):
            WorkBlock(
                model: model, session: conversation.id, items: items, start: start, end: end, live: live,
                answered: shape.answered.contains(id), followed: shape.followed.contains(id), washed: washed)
        // An answer that was only its ending (an event or a worker's report taken in, "[zero: waiting]") has no words
        // to show: nothing, not its copy and menu under an empty reply.
        case let .answer(item):
            if case let .agent(text, _) = item.kind, case let words = ZeroEnding.split(text).0,
                !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let readout = playback.readout(item.id)
                Answer(text: words, date: item.date, readout: readout, stamped: (readout?.done ?? true) && item.status != .running)
                    .id(item.id).washed(washed == item.id)
            }
        case let .step(item): StepView(model: model, session: conversation.id, item: item)
        }
    }

    /// To a message, its turn opened if it's folded there (WorkBlock), then washed a moment.
    private func show(_ item: String, _ proxy: ScrollViewProxy) {
        NotificationCenter.default.post(name: WorkBlock.unfold, object: item)
        Task {
            // Once an opened turn has laid out its steps.
            try? await Task.sleep(for: .milliseconds(50))
            // A jump under Reduce Motion; the wash still fades.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { proxy.scrollTo(item, anchor: .center) }
            washed = item
            try? await Task.sleep(for: .seconds(1.6))
            if washed == item { withAnimation(.easeOut(duration: 0.6)) { washed = nil } }
        }
    }
}

/// The conversation's blocks as the Mac's TimelineShape makes them: of the items playback has reached, and which
/// turns have their answer under them (they fold) or a message after them.
@MainActor final class TurnShape {
    private(set) var answered: Set<String> = []
    private(set) var followed: Set<String> = []
    /// Answers whose words began under their turn's live heading: they keep it as the turn ends.
    private var spoken: Set<String> = []

    func blocks(_ items: [ConversationItem], working: Bool) -> [TimelineBlock] {
        var blocks = TimelineBlock.of(items, working: working)
        for case let .work(_, work, _, _, true) in blocks where work.count == 1 {
            if case .agent = work[0].kind { spoken.insert(work[0].id) }
        }
        // An answer that had nothing else in its turn's work: its heading ("Thought for…") stays as the turn ends, the
        // same block it was (gone, the answer moved up by its height at once).
        for index in blocks.indices.reversed() where index > 0 {
            guard case let .answer(answer) = blocks[index], spoken.contains(answer.id), case let .user(asked) = blocks[index - 1]
            else { continue }
            blocks.insert(.work(id: "work-" + answer.id, items: [], start: asked.date, end: answer.date, live: false), at: index)
        }
        answered = []
        followed = []
        var work: [String] = []
        for (index, block) in blocks.enumerated() {
            switch block {
            case let .work(id, _, _, _, _):
                work.append(id)
                if index + 1 < blocks.count, case .answer = blocks[index + 1] { answered.insert(id) }
            case .user: followed.formUnion(work); work = []
            default: break
            }
        }
        return blocks
    }
}

/// Playback's clock: the display's, at most 60 times a second while something is read out or fading, not at all
/// otherwise. Its own view, so a tick redraws only what reads what it changed (the words being read).
private struct PlaybackClock: UIViewRepresentable {
    let playback: Playback

    func makeUIView(context: Context) -> Ticker { Ticker() }

    func updateUIView(_ ticker: Ticker, context: Context) {
        ticker.tick = { [playback] in playback.advance(to: $0) }
        ticker.paused = !playback.playing
    }

    static func dismantleUIView(_ ticker: Ticker, coordinator: ()) { ticker.end() }

    final class Ticker: UIView {
        var tick: ((Date) -> Void)?
        var paused = true { didSet { run() } }
        private var link: CADisplayLink?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { end() } else { run() }
        }

        private func run() {
            if link == nil, window != nil, !paused {
                let link = CADisplayLink(target: self, selector: #selector(fire))
                // Sixty a second: a tick at the steady pace is then a word or less. A tick only draws (RevealRenderer).
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            link?.isPaused = paused
        }

        /// The link holds this view: let go of it when the view leaves.
        func end() {
            link?.invalidate()
            link = nil
        }

        @objc private func fire(_ link: CADisplayLink) { tick?(Date()) }
    }
}

extension EnvironmentValues {
    /// The task page's end (TaskEnd): where a read-out under way has got to is told to it (ReadingMarker).
    @Entry var taskEnd: TaskEnd? = nil
    /// Goes to a message of the conversation on screen (an ask's About); nil where there's none.
    @Entry var showMessage: ((String) -> Void)? = nil
}

extension View {
    /// A message an About link went to: a soft wash behind it, fading.
    func washed(_ on: Bool) -> some View {
        background(Theme.knob.opacity(on ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 12).inset(by: -6))
    }
}

extension PhoneModel {
    /// A task's asks still open: what its inbox holds, with its questions and approvals.
    func openAsks(_ session: String) -> [Ask] { asks.filter { $0.isAgents(in: session) && !$0.state.isFinal } }

    func waitingCount(_ conversation: Conversation) -> Int {
        conversation.questions.count + conversation.approvals.count + openAsks(conversation.id).count
    }
}

/// What a task opens its inbox with, from a step in its conversation that asked you something.
extension EnvironmentValues {
    @Entry var openTaskInbox: () -> Void = {}
}

/// A task's inbox: its questions, approvals and asks, each answered where it stands, in a sheet from the bar's button.
/// Closed once nothing is left.
struct TaskInbox: View {
    let model: PhoneModel
    let session: String
    @Environment(\.dismiss) private var dismiss
    private static let fade = AnyTransition.opacity.animation(.easeOut(duration: 0.2))

    var body: some View {
        let conversation = model.conversation(session)
        let waiting = conversation.map(model.waitingCount) ?? 0
        NavigationStack {
            Group {
                if waiting == 0 {
                    // Nothing to answer: said in a few words in the middle, in a sheet only as tall as that.
                    EmptyPage(icon: "inbox-glyph", title: "Nothing waiting on you", line: "This task's questions and approvals come here.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let conversation {
                                ForEach(conversation.questions) { question in
                                    QuestionCard(model: model, session: session, question: question).transition(Self.fade)
                                }
                                ForEach(conversation.approvals) { approval in
                                    ApprovalCard(model: model, session: session, approval: approval).transition(Self.fade)
                                }
                            }
                            ForEach(model.openAsks(session)) { ask in AskCard(model: model, ask: ask).transition(Self.fade) }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Waiting on you")
            .navigationBarTitleDisplayMode(.inline)
            // An ask's About: the sheet goes, and the conversation under it goes to the message.
            .environment(\.showMessage) { item in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: ConversationView.show, object: item)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onChange(of: waiting) { old, now in if now == 0 && old > 0 { dismiss() } }
        .presentationDetents(waiting == 0 ? [.height(230)] : [.medium, .large])
    }
}

/// The bar's way into a task's inbox: the tray, white as the ⋯ beside it, and with something waiting, a small blue dot
/// at its corner, clear of the tray (a count over it crowded it; one beside it in blue sat apart from the bar). How
/// many is the sheet's to say.
struct TaskInboxButton: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image("inbox-glyph")
                .overlay(alignment: .topTrailing) {
                    if count > 0 { Circle().fill(.blue).frame(width: 7, height: 7).offset(x: 3, y: -1) }
                }
        }
        .accessibilityLabel(count > 0 ? "\(count) waiting on you" : "Nothing waiting on you")
    }
}

/// A step that asks you something still open: its question in a line, the card itself in the task's inbox.
struct OpenAskRow: View {
    let ask: Ask
    @Environment(\.openTaskInbox) private var openInbox

    var body: some View {
        Button(action: openInbox) {
            HStack(spacing: 8) {
                Image("inbox-glyph").resizable().frame(width: 16, height: 16).foregroundStyle(.blue)
                Text(ask.title).lineLimit(1)
                Spacer(minLength: 0)
                Text("Answer").foregroundStyle(.blue)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An answer: its Markdown, and under it a copy button and the way to pick out part of it (as ChatGPT's): SwiftUI's
/// text on the phone copies a whole paragraph or nothing.
struct Answer: View {
    let text: String
    var date: Date? = nil
    /// Being read out (Playback), or its last words fading.
    var readout: Readout? = nil
    /// Its row shows: not while its words are still being read out (the row keeps its place).
    var stamped = true
    @State private var selecting = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let readout { StreamingText(readout: readout, text: text) } else { MarkdownView(text: text) }
            }
            .contextMenu { CopyActions(text: text, select: { selecting = true }) }
            // As the Mac's: when it came, by the words' edge, then copy, then more, evenly and closely spaced, each
            // icon's touch area wider than it looks.
            HStack(spacing: 14) {
                if let date { Text(MessageStamp.text(date)).font(.footnote).foregroundStyle(.tertiary) }
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5)); copied = false
                    }
                } label: {
                    Image(copied ? "circle-check-outline" : "copy-outline").resizable().frame(width: 16, height: 16)
                        .foregroundStyle(.secondary).contentShape(Rectangle().inset(by: -10))
                }
                .accessibilityLabel("Copy")
                Menu {
                    CopyActions(text: text, select: { selecting = true })
                } label: {
                    Image("dots-outline").resizable().frame(width: 16, height: 16).foregroundStyle(.secondary)
                        .contentShape(Rectangle().inset(by: -10))
                }
                .accessibilityLabel("More")
            }
            .buttonStyle(.plain)
            .frame(height: 32)
            // Under words still being read out, nothing yet: its place kept, where it'll be once they're read; then in,
            // faded (it popped in, late, with the turn's end).
            .opacity(stamped ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: stamped)
            .allowsHitTesting(stamped)
        }
        .sheet(isPresented: $selecting) { SelectText(text: text) }
    }
}

/// "5:39 PM" today, "Oct 7, 5:39 PM" before, with the year when it isn't this one (the Mac's MessageBlock.stamp).
enum MessageStamp {
    static func text(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(
            sameYear ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.month(.abbreviated).day().year().hour().minute())
    }
}

/// Words as they're read out, at Playback's pace: whole words, each run the clock passes fading in from nothing over
/// 700 ms, so the newest words are an even gradient. Laid out whole as its words arrive and revealed in place (Reveal):
/// a tick only draws again, nothing is laid out, and nothing below it moves as it reads. Read and faded in, it's the
/// answer's plain text.
struct StreamingText: View {
    let readout: Readout
    let text: String
    @State private var drawn = DrawnCount()

    var body: some View {
        if readout.done {
            MarkdownView(text: text)
        } else {
            // Read here so the clock's tick redraws this, and only this.
            let now = readout.now
            let reveal = Reveal(
                visible: drawn.of(text, readout.shown),
                runs: readout.fadingSoFar.map { (at: drawn.of(text, $0.at), since: $0.since) },
                now: now)
            MarkdownView(blocks: MarkdownCache.blocks(text), reveal: reveal)
        }
    }
}

/// How many characters as drawn the first `n` characters of an answer's Markdown make (its marks aren't drawn).
/// Worked out a paragraph at a time: the paragraphs before the one `n` is in are counted once per arrival (each parse
/// kept by MarkdownCache), and only the start of that one is parsed again, not the whole answer up to it for every
/// word. Kept by `n`: the run starts are asked for on every tick.
@MainActor final class DrawnCount {
    private var known: [Int: Int] = [:]
    private var bytes = 0
    /// Each paragraph's start (in characters) and the characters drawn before it.
    private var paragraphs: [(start: Int, before: Int, text: Substring)] = []

    func of(_ text: String, _ n: Int) -> Int {
        let size = text.utf8.count
        if size != bytes {
            // Shrunk or changed: what was known may not hold. Grown: it does (a start doesn't depend on what follows).
            if size < bytes { known = [:] }
            bytes = size
            split(text)
        }
        if let count = known[n] { return count }
        guard let index = paragraphs.lastIndex(where: { $0.start <= n }) else { return 0 }
        let paragraph = paragraphs[index]
        let count = paragraph.before + MarkdownView.length(MarkdownBlock.parse(String(paragraph.text.prefix(n - paragraph.start))))
        known[n] = count
        return count
    }

    private func split(_ text: String) {
        paragraphs = []
        var start = 0, before = 0
        for part in text.split(separator: "\n\n", omittingEmptySubsequences: false) {
            paragraphs.append((start, before, part))
            before += MarkdownView.length(MarkdownCache.blocks(String(part)))
            start += part.count + 2
        }
    }
}

/// What of an answer is drawn: the characters (as drawn) shown so far, the runs still fading in, and the clock's time.
struct Reveal {
    let visible: Int
    let runs: [(at: Int, since: Date)]
    let now: Date
    /// Where the words still fading begin: before it, plain.
    var fading: Int { runs.first?.at ?? visible }

    func alpha(_ i: Int) -> Double {
        guard i < visible else { return 0 }
        guard let run = runs.last(where: { $0.at <= i }) else { return 1 }
        return min(1, max(0, now.timeIntervalSince(run.since) / Playback.fade))
    }
}

/// One text of an answer being read out, `start` characters into it: its glyphs up to what's shown, the newest fading.
/// A character or two off where a line's glyphs and characters differ (a soft break), which no eye sees in a fade.
struct RevealRenderer: TextRenderer {
    let start: Int
    let reveal: Reveal

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let fading = reveal.runs.first?.at ?? reveal.visible
        var index = start
        for line in layout {
            guard index < reveal.visible else { return }
            let count = line.reduce(0) { $0 + $1.count }
            // Read before the fading words: drawn whole.
            if index + count <= min(fading, reveal.visible) {
                context.draw(line)
                index += count
                continue
            }
            for run in line {
                for glyph in run {
                    let alpha = reveal.alpha(index)
                    index += 1
                    guard alpha > 0 else { continue }
                    var faded = context
                    faded.opacity = alpha
                    faded.draw(glyph)
                }
            }
        }
    }
}

/// Zero's link underline: dashed, just under the baseline (the system's sits too far below the words).
struct DashedRule: View {
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path {
                $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
    var body: some View { Line().stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 1) }
}

/// Copy, and pick out part of it.
struct CopyActions: View {
    let text: String
    var select: (() -> Void)?
    var body: some View {
        Button("Copy") { UIPasteboard.general.string = text }
        if let select { Button("Select text", action: select) }
    }
}

/// The text to select from, as much or as little as wanted: its words without Markdown's marks, in iOS's own text
/// view, which selects with handles.
struct SelectText: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(
                text: (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map {
                    String($0.characters)
                } ?? text
            )
            .padding(.horizontal, 12)
            .navigationTitle("Select text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 10
        view.attributedText = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label, .paragraphStyle: style])
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}

/// Yours, on the right; another task's or Zero's words (a worker's report) as a quiet line.
struct UserMessage: View {
    let item: ConversationItem
    @State private var open = false

    /// A video's line for the agent (the Mac's composer adds it): its number, and the stills cut from it.
    private static let videoLine = try! NSRegularExpression(
        pattern: #"\n*\[Video #(\d+): (.+?)(?:, \d+:\d|\. It's a video)[^\n]*\]$"#, options: [.anchorsMatchLines])
    private static let token = try! NSRegularExpression(pattern: #"\[(?:Image|Video) #\d+\]"#)

    /// The tiles a message of yours shows and its words: a video once, by its first still; the images that aren't
    /// a video's stills; the words without the tokens or the video's line.
    static func shown(_ text: String, images: [String]) -> (tiles: [(path: String, video: Bool)], words: String) {
        let whole = text as NSString
        var stills = Set<Int>(), videos: [(path: String, video: Bool)] = []
        for match in videoLine.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            let line = whole.substring(with: match.range) as NSString
            let numbers = (try! NSRegularExpression(pattern: #"\[Image #(\d+)\]"#)).matches(
                in: line as String, range: NSRange(location: 0, length: line.length)
            )
            .compactMap { Int(line.substring(with: $0.range(at: 1))) }
            stills.formUnion(numbers)
            if let first = numbers.first, images.indices.contains(first - 1) { videos.append((images[first - 1], true)) }
        }
        let tiles = videos + images.enumerated().filter { !stills.contains($0.offset + 1) }.map { ($0.element, false) }
        var words = videoLine.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: whole.length), withTemplate: "")
        words = token.stringByReplacingMatches(in: words, range: NSRange(location: 0, length: (words as NSString).length), withTemplate: "")
        return (tiles, words.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        if case let .user(text, images) = item.kind {
            if let given = ConversationItem.from(text) {
                Button {
                    open.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(given.text.split(separator: "\n").first.map(String.init) ?? "").lineLimit(open ? nil : 1)
                        if open { MarkdownView(text: given.text) }
                    }
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                // As the Mac shows yours: the images above the words, as tiles (a video as one, its first still, not the
                // stills cut from it for the agent); the words without their tokens or the video's line for the agent.
                let (tiles, words) = Self.shown(text, images: images)
                VStack(alignment: .trailing, spacing: 6) {
                    if !tiles.isEmpty { MessageImages(tiles: tiles) }
                    if !words.isEmpty {
                        // Solid, as the Mac's: Zero's ink, the words in the opposite.
                        Text(words).foregroundStyle(Theme.onKnob).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.knob, in: RoundedRectangle(cornerRadius: 18))
                            .contextMenu { CopyActions(text: words) }
                    }
                    // When it was sent, always, by the bubble's edge (its copy is a long press away).
                    if let date = item.date {
                        Text(MessageStamp.text(date)).font(.footnote).foregroundStyle(.tertiary).padding(.trailing, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
            }
        }
    }
}

/// A turn's work, as the Mac's: folded unless you open it. Folded while it works, only what the agent has said shows,
/// each message staying, and one line under them for the step running now; its answer, once it's writing it, takes
/// the messages' place under the heading. Opened, every step and message is listed and the answer comes in below
/// them. Over: "Worked for 2m 37s" with the answer under it.
struct WorkBlock: View {
    /// Posted with an item's id as an About link goes to it: the work holding it opens.
    static let unfold = Notification.Name("zero.unfoldWork")
    let model: PhoneModel
    let session: String
    let items: [ConversationItem]
    let start: Date?
    let end: Date?
    let live: Bool
    /// Its answer is on screen under it (being read out, from its first words).
    var answered = false
    /// A message has come after it.
    var followed = false
    /// The message an About link went to.
    var washed: String? = nil
    /// Opened by you, and only by you: a turn going live again as Zero restarts opened it by itself, when its
    /// openness followed its state. Your next message folds it.
    @State private var expanded = false
    /// Its words have been the last thing long enough to be its answer, not a message between steps: its messages
    /// fold away and the answer reads on from the heading.
    @State private var answering = false
    @Environment(\.playback) private var playback

    /// Steps of substance: reading, running, editing. Thought alone isn't work, nor its words.
    private var worked: Bool {
        items.contains { if case .reasoning = $0.kind { false } else if case .agent = $0.kind { false } else { true } }
    }
    /// Answering with no steps, its words streaming in: the heading it ends with ("Thought for…") already.
    private var speaking: Bool { live && !worked && items.last.map { if case .agent = $0.kind { true } else { false } } == true }
    /// The words the agent is writing now, the last of its items.
    private var streamingWords: String? {
        guard let last = items.last, case let .agent(said, _) = last.kind, case let text = ZeroEnding.split(said).0, !text.isEmpty else {
            return nil
        }
        return text
    }
    /// Folded, what it has said shows (and a failure, as said), not its steps: while it works, until its answer comes;
    /// over, when it ended with no answer to stand in for them.
    private var showsNotes: Bool { live ? !answering : !answered }

    /// What it said, in order, the words still being written left out, and any failure as said.
    private var said: [(item: ConversationItem, text: String)] {
        let done = live && streamingWords != nil ? Array(items.dropLast()) : items
        return done.compactMap { item in
            switch item.kind {
            case let .agent(text, _):
                let words = ZeroEnding.split(text).0
                return words.isEmpty ? nil : (item, words)
            case .notice(_, error: true): return (item, "")
            default: return nil
            }
        }
    }

    static let spacing: CGFloat = 10
    /// The first thing under the heading, a message or a step, this far further down.
    static let first: CGFloat = 4
    static let ruleAbove: CGFloat = 3
    /// The conversation's gap (24) less the turn's own (10): an answer sits as near its turn as its steps do.
    static let headed: CGFloat = 14
    /// The answer's row under its words (copy, time): live words keep its room, so they become the answer unmoved.
    static let room: CGFloat = 42

    /// How far below what's above them its words sit beyond the stack's spacing.
    private func lead(steps: [ConversationItem]) -> CGFloat {
        if expanded { return steps.isEmpty ? Self.first : 2 }
        return showsNotes && !said.isEmpty ? 0 : Self.first
    }

    /// The line under the turn's grey lines: above the first thing it said (or its words, or its answer below), so
    /// "Working for…" and the steps before any message read as one group, apart from what it says. None while open.
    private enum Rule: Equatable { case none, above(String), words, bottom }

    private func rule() -> Rule {
        guard worked, !expanded else { return .none }
        if showsNotes, let first = said.first { return .above(first.item.id) }
        if live, streamingWords != nil { return .words }
        if !live, answered { return .bottom }
        return .none
    }

    /// Drawn in the gap above what it's on: it takes no room, so it coming or going moves nothing.
    private func line(_ above: CGFloat) -> some View {
        Rectangle().fill(.quaternary).frame(height: 1).offset(y: -above).allowsHitTesting(false)
    }

    @ViewBuilder private func words(_ item: ConversationItem, _ text: String) -> some View {
        if let readout = playback?.readout(item.id) { StreamingText(readout: readout, text: text) } else { MarkdownView(text: text) }
    }

    var body: some View {
        let steps = live && streamingWords != nil ? Array(items.dropLast()) : items
        let top = lead(steps: steps)
        let rule = rule()
        VStack(alignment: .leading, spacing: Self.spacing) {
            // Its heading holds its place from the turn's start to its end.
            // Opening and folding are instant, as everywhere in Zero.
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    if speaking {
                        Text(Took.text("Thought", start.flatMap { start in items.last?.date.map { $0.timeIntervalSince(start) } }))
                    } else if live, !worked {
                        Text("Thinking")
                    } else if live {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(start.map { "Working for " + Took.length(context.date.timeIntervalSince($0)) } ?? "Working")
                        }
                    } else {
                        Text(Took.text(worked ? "Worked" : "Thought", start.flatMap { start in end.map { $0.timeIntervalSince(start) } }))
                    }
                    if !items.isEmpty {
                        Image("chevron-down-outline").resizable().frame(width: 9, height: 9).rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                }
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty)
            // Over, its answer below: the line halfway down the gap between the heading and the answer's words (the
            // block's foot is drawn up into the heading, so the answer sits as near as its steps did).
            .overlay(alignment: .bottom) {
                if rule == .bottom { line(-(Self.spacing + Self.first) / 2) }
            }
            if expanded, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, item in
                        StepView(
                            model: model, session: session, item: item,
                            until: index + 1 < items.count ? items[index + 1].date : (live ? nil : end)
                        )
                        .id(item.id).washed(washed == item.id)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
            // Folded, what it has said, each staying where it was; of its steps only the one running now (below).
            if !expanded, showsNotes {
                ForEach(Array(said.enumerated()), id: \.element.item.id) { index, note in
                    Group {
                        if note.text.isEmpty {
                            StepView(model: model, session: session, item: note.item)
                        } else {
                            words(note.item, note.text)
                        }
                    }
                    .padding(.top, index == 0 ? Self.first : 0)
                    .overlay(alignment: .top) { if rule == .above(note.item.id) { line(Self.ruleAbove) } }
                    .id(note.item.id).washed(washed == note.item.id)
                    .transition(.opacity)
                }
            }
            if live {
                if let last = items.last, let text = streamingWords {
                    // What it's saying, read out at Zero's pace, where it'll be once it's the answer: nothing moves.
                    words(last, text)
                        .padding(.top, top)
                        .overlay(alignment: .top) { if rule == .words { line(Self.ruleAbove) } }
                        .padding(.bottom, Self.room)
                } else {
                    // Where it is: its latest step, on one line of fixed height whatever kind of step it is, the
                    // next replacing it; a message stays above it.
                    if !expanded {
                        Group {
                            if let last = items.last, !{ if case .notice(_, true) = last.kind { true } else { false } }(),
                                !{ if case .agent = last.kind { true } else { false } }()
                            {
                                StepLine(item: last)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
                        .opacity(0.7).allowsHitTesting(false)
                    }
                    // Between steps: not under a step still running, which says so itself. Its place kept.
                    if worked {
                        Text("Thinking…").font(.subheadline).foregroundStyle(.tertiary)
                            .opacity(items.last?.status == .running ? 0 : 1)
                    }
                }
            }
        }
        // Ended, its answer right under it, where its words were read out while it was live.
        .padding(.bottom, live ? 0 : lead(steps: items) - (answered ? Self.headed : 0))
        // A message after it: it folds.
        .onChange(of: followed) { _, now in
            if now, !live, expanded { expanded = false }
        }
        // Its words still the last thing a moment and a half after they started (an answer, not a message between
        // steps, which a step follows at once): its messages fold away and the answer reads on from the heading.
        .task(id: streamingWords == nil ? nil : items.last?.id) {
            guard live, streamingWords != nil else {
                if live, answering { answering = false }
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, live, streamingWords != nil, playback?.held != true else { return }
            if !answering { answering = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.unfold)) { note in
            if let item = note.object as? String, items.contains(where: { $0.id == item }) { expanded = true }
        }
    }
}

/// A step on one line, quietly: what the turn is doing now, under its messages.
struct StepLine: View {
    let item: ConversationItem

    var body: some View {
        HStack(spacing: 7) {
            StatusIcon(status: item.status)
            text.lineLimit(1).truncationMode(.tail)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var text: some View {
        switch item.kind {
        case let .command(command, _, _, _, _, description):
            if description.isEmpty { Text("$ " + CommandText.line(command)).font(.footnote.monospaced()) } else { Text(description) }
        case let .tool(name, detail): Text(ToolNames.name(name)).fontWeight(.medium) + Text(" " + ToolNames.detail(detail))
        case let .fileChange(changes): Text("Edited " + changes.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))
        case let .agent(text, _), let .reasoning(text), let .plan(text): Text(text.split(separator: "\n").first.map(String.init) ?? "")
        case let .notice(text, _): Text(String(NoticeText.attributed(text).characters))
        case let .table(title, _, rows): Text(title.isEmpty ? "A table of \(rows.count)" : title)
        case let .user(text, _): Text((ConversationItem.from(text)?.text ?? text).split(separator: "\n").first.map(String.init) ?? "")
        }
    }
}

extension EnvironmentValues {
    /// The conversation on screen as it plays (what's shown, what's being read out).
    @Entry var playback: Playback? = nil
}

/// One step: a command (its output a tap away), files changed, a tool, the agent's words between steps, a notice, a
/// table; the agent asking you through Zero, as that ask's card.
struct StepView: View {
    let model: PhoneModel
    let session: String
    let item: ConversationItem
    /// When the next step began: how long a thought took.
    var until: Date? = nil
    @State private var open = false

    var body: some View {
        if let ask = item.ask(in: model.asks, session: session) {
            if ask.state.isFinal { AskCard(model: model, ask: ask) } else { OpenAskRow(ask: ask) }
        } else {
            switch item.kind {
            case let .command(command, _, output, exitCode, _, _):
                Button {
                    open.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            StatusIcon(status: item.status)
                            Text("$ " + command).lineLimit(open ? nil : 1)
                            Spacer(minLength: 0)
                            if let exitCode, exitCode != 0 { Text("exit \(exitCode)").font(.caption2).foregroundStyle(.red) }
                        }
                        if open, !output.isEmpty {
                            ScrollView(.horizontal) { Text(output).padding(10) }
                                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            case let .fileChange(changes):
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: item.status)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(changes, id: \.path) { change in
                            Text(
                                (change.kind == "add" ? "Added " : change.kind == "delete" ? "Deleted " : "Edited ")
                                    + (change.path as NSString).lastPathComponent)
                        }
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            case let .tool(name, detail):
                // Its name as people say it, its arguments as their values, not JSON (as the Mac's).
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: item.status)
                    Text(ToolNames.name(name)).fontWeight(.medium)
                    Text(ToolNames.detail(detail)).foregroundStyle(.secondary)
                }
                .font(.footnote).lineLimit(1)
            case let .agent(text, _):
                MarkdownView(text: ZeroEnding.split(text).0).foregroundStyle(.secondary)
            case let .notice(text, error):
                // A server's sign-in link calls back to the Mac, where its CLI listens: here, the words alone.
                Text(String(NoticeText.attributed(text).characters)).font(.footnote).foregroundStyle(error ? .red : .secondary)
            case let .table(title, columns, rows):
                TableView(title: title, columns: columns, rows: rows)
            case let .reasoning(text):
                // As the Mac's: "Thought for 4s" and its first line; opened, all of it.
                Button {
                    open.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image("brain-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.secondary).frame(
                                width: 14, height: 16)
                            Text(Took.text("Thought", until.flatMap { until in item.date.map { until.timeIntervalSince($0) } })).fontWeight(
                                .medium)
                            if !open {
                                Text(text.split(separator: "\n").first.map(String.init) ?? "").foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if open {
                            Text(text).foregroundStyle(.secondary).padding(.leading, 22).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.footnote).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .user, .plan:
                EmptyView()
            }
        }
    }
}

/// Markdown as an answer uses it (ZeroCore's MarkdownBlock), its inline parts (bold, code, links) styled by SwiftUI.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// Being read out: what of it is drawn (StreamingText), from `base` characters in.
    var reveal: Reveal? = nil
    var base = 0
    init(text: String) { blocks = MarkdownCache.blocks(text) }
    init(blocks: [MarkdownBlock], reveal: Reveal? = nil, base: Int = 0) { self.blocks = blocks; self.reveal = reveal; self.base = base }

    // Spaced as ChatGPT's answers are: a little air between lines, a clear gap between paragraphs, so a long answer
    // reads as paragraphs rather than one block of text.
    var body: some View {
        let starts = reveal == nil ? [] : Self.starts(blocks, from: base)
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                // Being read out: only the blocks still fading in are drawn again on a tick; those read are plain
                // text, those not reached yet laid out but hidden.
                if let reveal, starts[index] < reveal.visible, starts[index] + Self.length(block) > reveal.fading {
                    Self.view(block, reveal: reveal, start: starts[index])
                        .overlay(alignment: .topLeading) { readingMark(reveal, start: starts[index], length: Self.length(block)) }
                } else if let reveal, starts[index] >= reveal.visible {
                    Self.view(block).hidden()
                } else {
                    Self.view(block)
                }
            }
        }
        .lineSpacing(3)
    }

    static func inline(_ text: String) -> Text {
        Text(MarkdownCache.inline(text))
    }

    @Environment(\.taskEnd) private var taskEnd

    /// Where the read-out has got to, in the block it's in (the answer's own blocks, not a list's inner ones): down
    /// the block by the share of its characters read, close enough to keep the page off the unread lines.
    @ViewBuilder private func readingMark(_ reveal: Reveal, start: Int, length: Int) -> some View {
        if base == 0, taskEnd != nil, start < reveal.visible, reveal.visible <= start + length {
            GeometryReader { geometry in
                ReadingMarker(end: taskEnd).frame(width: 1, height: 1)
                    .offset(y: max(0, geometry.size.height * CGFloat(reveal.visible - start) / CGFloat(max(length, 1)) - 1))
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .global).maxY
                    } action: { _ in
                        taskEnd?.recount()
                    }
            }
        }
    }

    /// Characters as drawn: what a reveal counts in.
    static func length(_ blocks: [MarkdownBlock]) -> Int { blocks.reduce(0) { $0 + length($1) } }

    static func length(_ block: MarkdownBlock) -> Int {
        switch block {
        case let .heading(_, text), let .paragraph(text), let .quote(text): MarkdownCache.drawn(text)
        case let .list(_, _, items): items.reduce(0) { $0 + MarkdownCache.drawn($1.text) + length($1.children) }
        case let .code(code): MarkdownCache.count(code)
        case let .table(rows): rows.joined().reduce(0) { $0 + MarkdownCache.drawn($1) }
        case .image, .rule: 1
        }
    }

    private static func starts(_ blocks: [MarkdownBlock], from base: Int) -> [Int] {
        var at = base
        return blocks.map { block in
            defer { at += length(block) }
            return at
        }
    }

    @ViewBuilder static func view(_ block: MarkdownBlock, reveal: Reveal? = nil, start: Int = 0) -> some View {
        // What isn't text (a table, an image, a rule, a bullet, a quote's bar) shows as the reading reaches it.
        let reached = reveal.map { $0.alpha(start) } ?? 1
        switch block {
        case let .heading(level, text):
            inline(text).revealed(reveal, start).font(
                level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold)
            )
            .padding(.top, 4)
        case let .paragraph(text): inline(text).revealed(reveal, start)
        case let .list(ordered, number, items):
            let starts = items.reduce(into: [start]) { $0.append($0.last! + MarkdownCache.drawn($1.text) + length($1.children)) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let at = starts[index]
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ordered ? "\(number + index)." : "•").foregroundStyle(.secondary).frame(minWidth: 12, alignment: .leading)
                            .opacity(reveal.map { $0.alpha(at) } ?? 1)
                        VStack(alignment: .leading, spacing: 8) {
                            inline(item.text).revealed(reveal, at)
                            if !item.children.isEmpty {
                                MarkdownView(blocks: item.children, reveal: reveal, base: at + MarkdownCache.drawn(item.text))
                            }
                        }
                    }
                }
            }
        case let .code(code):
            ScrollView(.horizontal) { Text(code).font(.footnote.monospaced()).revealed(reveal, start).padding(10) }
                .background(Theme.code.opacity(reached), in: RoundedRectangle(cornerRadius: 10))
        case let .quote(text):
            inline(text).revealed(reveal, start).foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3).opacity(reached) }
        case let .table(rows):
            if let head = rows.first { TableView(title: "", columns: head, rows: Array(rows.dropFirst()), reveal: reveal, start: start) }
        case let .image(path, alt):
            AnswerImage(path: path, alt: alt).opacity(reached)
        case .rule:
            Divider().opacity(reached)
        }
    }
}

extension View {
    /// Being read out: drawn as far as it's read, its newest words fading in (RevealRenderer).
    @ViewBuilder func revealed(_ reveal: Reveal?, _ start: Int) -> some View {
        if let reveal { textRenderer(RevealRenderer(start: start, reveal: reveal)) } else { self }
    }
}

/// A table, as `zero table` makes them: a cell naming a state shows as its pill, a risk column's level as a pill (its
/// gaps a tap away), the rest as Markdown. Wider than the phone: it scrolls sideways.
struct TableView: View {
    let title: String
    let columns: [String]
    let rows: [[String]]
    /// Being read out: each row shows as the reading reaches it (it was all at once), `start` characters in.
    var reveal: Reveal? = nil
    var start = 0
    /// More of it past an edge, to scroll to: that edge fades (the last column was cut mid-word, with nothing to say
    /// it scrolls).
    @State private var more = (left: false, right: false)

    /// Where each row starts in the read-out (the header first), in characters as drawn.
    private var rowStarts: [Int] {
        var at = start + columns.reduce(0) { $0 + MarkdownCache.drawn($1) }
        return rows.map { row in
            defer { at += row.reduce(0) { $0 + MarkdownCache.drawn($1) } }
            return at
        }
    }

    private func shown(_ at: Int) -> Double { reveal?.alpha(at) ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            ScrollView(.horizontal) {
                // A column with long words is a set width its cells wrap in, so each row is as tall as its words;
                // the rest are as wide as they need, on one line. (In a sideways scroll a cell is otherwise measured
                // on one line and only then narrowed, its wrapped lines spilling over the rows below.)
                let wide = columns.indices.map { column in rows.contains { column < $0.count && $0[column].count > 28 } }
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in Text(column).font(.caption.weight(.semibold)) }
                    }
                    .opacity(shown(start))
                    Divider().opacity(shown(start))
                    let starts = rowStarts
                    ForEach(Array(rows.enumerated()), id: \.offset) { number, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                                let content = Cell(text: cell, column: index < columns.count ? columns[index] : "")
                                if index < wide.count, wide[index] {
                                    content.fixedSize(horizontal: false, vertical: true).frame(width: 240, alignment: .leading)
                                } else {
                                    content.fixedSize()
                                }
                            }
                        }
                        .opacity(shown(starts[number]))
                    }
                }
                .font(.footnote)
                .padding(12)
            }
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                [geometry.contentOffset.x > 1, geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1]
            } action: { _, now in
                more = (now[0], now[1])
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(more.left ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(
                        width: 28)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(more.right ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(
                        width: 28)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    struct Cell: View {
        let text: String
        let column: String
        @State private var showing = false
        var body: some View {
            switch TableCell.of(text, column: column) {
            case let .risk(level, gaps):
                Button {
                    showing.toggle()
                } label: {
                    RiskPill(level: level)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showing) { Text(gaps).font(.footnote).padding().presentationCompactAdaptation(.popover) }
                .disabled(gaps.isEmpty)
            case let .state(state): StatePill(state: state)
            case .empty: MarkdownView.inline("–").foregroundStyle(.tertiary)
            case let .text(text): MarkdownView.inline(text)
            }
        }
    }
}

struct StatePill: View {
    let state: BoardRow.State
    var body: some View {
        let look = StateGlyph.look(state)
        HStack(spacing: 4) {
            StateGlyph(state: state).scaleEffect(0.8)
            Text(look.name).font(.caption.weight(.medium)).foregroundStyle(look.color)
        }
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 2)
        .background(look.color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

struct RiskPill: View {
    let level: String
    var body: some View {
        let color: Color = level == "low" ? .green : level == "medium" ? .orange : .red
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(level.capitalized).font(.caption.weight(.medium)).foregroundStyle(level == "low" ? Theme.done : color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

/// An ask the agent sent through Zero (run, ask, approve), answered here as in the inbox: its options as buttons, an
/// option that takes words ("Something else…") opening a field; once answered, the answer and a run's output.
struct AskCard: View {
    let model: PhoneModel
    let ask: Ask
    /// In a list's row, which is the card already: no card of its own (never a card in a card).
    var flat = false
    /// Under its task's name in the inbox (InboxAskRow): what kind it is in a word, the question in plain weight, its
    /// reasons a few lines until tapped.
    var inRow = false
    @State private var typing: Int?
    @State private var expanded = false
    @State private var words = ""
    @Environment(\.showMessage) private var showMessage

    /// A command for you to run yourself (an agent's question with `--code`: another machine's shell, sudo), laid out as
    /// steps. An approval's command is the agent's own, to allow or not, so it's never this.
    private var manual: Bool { (ask.kind == .question || ask.kind == .choice) && ask.command != nil && ask.state == .waiting }

    private var kindName: String {
        switch ask.kind {
        case .run: "Run on your Mac"
        case .approve: "Approval"
        case .permission: "Permission"
        default: manual ? "Run this yourself" : "Question"
        }
    }

    /// The question itself, as the Mac's card has it (CardView's headline): a question's words (its --title is the
    /// agent's context), an approval's request as a question, a run's where it stands.
    private var headline: String {
        switch ask.kind {
        case .run:
            switch ask.state {
            case .running: "Running command…"
            case .answered where ask.lost: "Lost track of the command"
            case .answered: (ask.exitCode ?? 0) == 0 ? "Ran command" : "Command failed (exit \(ask.exitCode ?? 0))"
            case .declined: "Command rejected"
            default: "Allow this command?"
            }
        case .approve, .permission: ask.title.hasSuffix("?") ? ask.title : ask.title + "?"
        case .question, .choice: ask.body.isEmpty ? ask.title : ask.body
        default: ask.title
        }
    }

    private var kindIcon: String {
        switch ask.kind {
        case .approve, .permission: "shield-outline"
        case .run: "terminal-outline"
        default: manual ? "terminal-outline" : "circle-question-glyph"
        }
    }

    /// Under it: a question's --body, why a run or an approval is wanted.
    private var supporting: String? {
        let text =
            switch ask.kind {
            case .question, .choice: ask.detail ?? ""
            default: ask.body
            }
        return text.isEmpty || text == headline ? nil : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !inRow {
                HStack(spacing: 5) {
                    Image(kindIcon).resizable().frame(width: 13, height: 13)
                    Text(kindName)
                    Text("·")
                    Text(ask.agent.label ?? ask.agent.name).lineLimit(1)
                }
                .font(.footnote.weight(.medium))
                // Whether the task is done: a question still, in the Done state's colour (the Mac's purple).
                .foregroundStyle(ask.doneCheck == true ? AnyShapeStyle(DoneShades.ink) : AnyShapeStyle(.secondary))
            }
            Text(headline).font(inRow ? .body : .body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            aboutLine
            if let supporting {
                MarkdownView(text: supporting).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(inRow && !expanded ? 3 : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { if inRow { expanded.toggle() } }
            }
            if let command = ask.command {
                // What runs is what's read: the command, the script it runs, and what it printed.
                let shown = [(ask.kind == .run ? "$ " : "") + command, ask.script, ask.output.isEmpty ? nil : ask.output].compactMap { $0 }
                    .joined(separator: "\n")
                ScrollView(.horizontal) { Text(shown).font(.footnote.monospaced()).textSelection(.enabled).padding(10) }
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            UIPasteboard.general.string = [command, ask.script].compactMap { $0 }.joined(separator: "\n")
                        } label: {
                            Image("copy-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.secondary).frame(
                                width: 32, height: 32)
                        }
                        .accessibilityLabel("Copy the command")
                    }
                if manual, let typed = ask.options.firstIndex(where: Ask.expectsText) {
                    // What it printed, from the clipboard into the reply, ready to send.
                    Button("Paste output") {
                        words = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; typing = typed
                    }
                    .font(.footnote.weight(.medium))
                }
            }
            if !ask.options.isEmpty {
                // One group, as iOS lists its choices, a line between each: a tap answers, and "Something else…" opens
                // into its box where it is. Each its own pill, four took most of a screen.
                VStack(spacing: 0) {
                    ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                        if index > 0 { Divider().padding(.leading, 14) }
                        if ask.state == .waiting, typing == index {
                            ReplyBox(placeholder: option, words: $words, fill: .clear) { text in
                                await model.answer(ask, option: index, text: text)
                            }
                        } else {
                            optionRow(index, option)
                        }
                    }
                }
                .background(rowFill, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if ask.state == .waiting {
                ReplyBox(placeholder: "Reply to \(ask.agent.label ?? ask.agent.name)…", words: $words, fill: rowFill) { text in
                    await model.reply(ask, text: text)
                }
            } else if let answer = ask.answer, ask.kind != .run {
                answeredRow(answer)
            }
            if ask.state == .running {
                Text("Running…").font(.footnote).foregroundStyle(.secondary)
            } else if ask.lost {
                Text("Lost: check what it did before running it again").font(.footnote).foregroundStyle(.orange)
            } else if ask.state == .expired {
                Text("Expired").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(flat ? 0 : 14)
        .padding(.vertical, flat ? 6 : 0)
        // Whether the task is done: the whole card in the done question's shades, a question still.
        .background(
            ask.doneCheck == true ? AnyShapeStyle(DoneShades.surface) : flat ? AnyShapeStyle(.clear) : AnyShapeStyle(.background.secondary),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(flat ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary)))
    }

    /// What it's about, quietly under the question, as the Mac's: "About" and the message's title in one grey, the title
    /// a link in Zero's style (medium, a dashed line under it) where there's a conversation to go to.
    @ViewBuilder private var aboutLine: some View {
        if let about = ask.about {
            HStack(spacing: 5) {
                Text("About")
                if let showMessage {
                    Button {
                        showMessage(about.item)
                    } label: {
                        Text(about.title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                            .overlay(alignment: .bottom) { DashedRule().offset(y: -1.5) }
                            .contentShape(Rectangle().inset(by: -8))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(about.title).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// An option's row, and once answered, how it stands: the one chosen in its state's colour (on its way, delivered,
    /// not delivered), the others dimmed. A typed answer shows its words where the box was.
    private func optionRow(_ index: Int, _ option: String) -> some View {
        let decided = ask.state != .waiting
        let chosen = decided && ask.choice == index
        let label = option.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        let answer = ask.answer ?? option
        let shown =
            chosen && Ask.expectsText(option) && answer.hasPrefix(label + ": ")
            ? String(answer.dropFirst(label.count + 2)) : chosen ? answer : option
        return choiceRow(shown, muted: !chosen && Ask.expectsText(option), chosen: chosen, grouped: true)
            .opacity(decided && !chosen ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if !decided {
                    if Ask.expectsText(option) { words = ""; typing = index } else { Task { await model.choose(ask, option: index) } }
                } else if chosen, ask.delivery == .failed {
                    Task { await model.deliver(ask) }
                }
            }
            .allowsHitTesting(!decided || chosen)
    }

    /// A reply to an ask without options, once sent: as a chosen option.
    private func answeredRow(_ answer: String) -> some View {
        choiceRow(answer, muted: false, chosen: true)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { if ask.delivery == .failed { Task { await model.deliver(ask) } } }
    }

    /// `grouped`: a row of the options' group, which has the fill: only a chosen one colours its own.
    /// The option's words as the agent wrote them, "(Recommended)" and all, as the Mac shows them.
    private func choiceRow(_ text: String, muted: Bool, chosen: Bool, grouped: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(
                    muted ? (ask.doneCheck == true ? AnyShapeStyle(DoneShades.muted) : AnyShapeStyle(.secondary)) : AnyShapeStyle(.primary)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            if chosen { standing }
        }
        // Room above and below: an option of two lines sat against the group's edge.
        .padding(.vertical, 11)
        .padding(.leading, 14).padding(.trailing, chosen ? 8 : 14).frame(minHeight: 44)
        .background(chosen ? chosenFill : grouped ? .clear : rowFill, in: RoundedRectangle(cornerRadius: grouped ? 0 : 10))
    }

    /// At the chosen row's end, the Mac's three: an orange spinner on its way (a moment to take it back first), a green
    /// tick delivered, a red cross not (a tap tries again, which the phone has no tooltip to say, so it's said).
    @ViewBuilder private var standing: some View {
        HStack(spacing: 8) {
            if ask.state == .pending {
                Button("Take back") { Task { await model.takeBack(ask) } }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                    .padding(.horizontal, 10).frame(height: 30).background(.background.opacity(0.6), in: Capsule())
            }
            if ask.delivery == .failed {
                Text("Try again").font(.footnote.weight(.medium)).foregroundStyle(.red)
                Image("xmark-outline").resizable().frame(width: 13, height: 13).foregroundStyle(.red)
            } else if ask.state.isFinal && ask.delivery != .sending {
                Image("check-outline").resizable().frame(width: 13, height: 13).foregroundStyle(.green)
            } else {
                Spinner(color: .orange).frame(width: 12, height: 12)
            }
        }
        .frame(height: 30)
    }

    private var rowFill: Color { ask.doneCheck == true ? DoneShades.row : Theme.choice }

    /// The Mac's chosen rows: apricot until it's landed, mint once it has, rose when it didn't.
    private var chosenFill: Color {
        if ask.delivery == .failed { return RowShades.red }
        return ask.state == .pending || ask.delivery == .sending ? RowShades.orange : RowShades.green
    }
}

/// The provider asking (Claude Code's or Codex's own question): each field's options as pills, solid once picked, or
/// words, as the Mac's question card.
struct QuestionCard: View {
    let model: PhoneModel
    let session: String
    let question: Question
    @State private var picked: [String: [String]] = [:]
    @State private var words: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                question.fields.count == 1 ? (question.fields.first?.header ?? "Question") : "Questions", image: "circle-question-glyph"
            )
            .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            ForEach(question.fields) { field in
                VStack(alignment: .leading, spacing: 8) {
                    Text(field.question).font(.body.weight(.semibold))
                    WrappingStack(spacing: 6) {
                        ForEach(field.options, id: \.label) { option in
                            let on = picked[field.id]?.contains(option.label) == true
                            Button(option.label) {
                                if field.multiple {
                                    picked[field.id, default: []].toggle(option.label)
                                } else {
                                    picked[field.id] = on ? [] : [option.label]
                                }
                            }
                            .buttonStyle(ChoiceChip(on: on))
                        }
                    }
                    // What a picked option means (the Mac's tip on it; the phone has no pointer to hover with).
                    ForEach(field.options.filter { picked[field.id]?.contains($0.label) == true && $0.description != nil }, id: \.label) {
                        Text($0.description ?? "").font(.footnote).foregroundStyle(.secondary)
                    }
                    if field.secret {
                        SecureField("Secret", text: binding(field.id)).modifier(AnswerField())
                    } else if field.other || field.options.isEmpty {
                        TextField(field.options.isEmpty ? "Your answer" : "Or say something else", text: binding(field.id), axis: .vertical)
                            .modifier(AnswerField())
                    }
                }
            }
            WideButton(title: "Answer", prominent: true) {
                Task { await model.answer(session: session, question: question.id, answers: answers) }
            }
            .disabled(question.fields.contains { (answers[$0.id] ?? []).isEmpty })
            .opacity(question.fields.contains { (answers[$0.id] ?? []).isEmpty } ? 0.4 : 1)
        }
        .padding(14)
        .zeroCard()
    }

    private var answers: [String: [String]] {
        var out = picked
        for (id, text) in words where !text.isEmpty { out[id, default: []].append(text) }
        return out
    }

    private func binding(_ id: String) -> Binding<String> { Binding(get: { words[id] ?? "" }, set: { words[id] = $0 }) }

    /// An option: a pill, solid once picked.
    private struct ChoiceChip: ButtonStyle {
        let on: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.subheadline.weight(.medium))
                .foregroundStyle(on ? AnyShapeStyle(Theme.onKnob) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(on ? AnyShapeStyle(Theme.knob) : AnyShapeStyle(.background), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary)))
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }

    /// The free answer's field: a plain field on the page's surface, a hairline round it.
    private struct AnswerField: ViewModifier {
        func body(content: Content) -> some View {
            content.textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
    }
}

/// The provider asking to run a command or change files: its choices as the ask card's options, one group with a line
/// between each.
struct ApprovalCard: View {
    let model: PhoneModel
    let session: String
    let approval: Approval
    @State private var commandOpen = false

    /// What's asked, short: the command or the changes are below it, not spelled out again in the question.
    private var question: String {
        if approval.command != nil { return "Allow this command?" }
        if !approval.changes.isEmpty { return approval.changes.count == 1 ? "Allow this change?" : "Allow these changes?" }
        return approval.title.hasSuffix("?") ? approval.title : approval.title + "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval", image: "shield-outline").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(question).font(.body.weight(.semibold))
            if let reason = approval.reason { Text(reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            if let command = approval.command {
                let lines = command.split(separator: "\n", omittingEmptySubsequences: false).count
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal) { Text(command).font(.footnote.monospaced()).lineLimit(commandOpen ? nil : 8) }
                    if lines > 8 {
                        Button(commandOpen ? "Show less" : "Show all \(lines) lines") { commandOpen.toggle() }
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                }
                .padding(10).padding(.trailing, 22).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    Button {
                        UIPasteboard.general.string = command
                    } label: {
                        Image("copy-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.secondary).frame(
                            width: 32, height: 32)
                    }
                    .accessibilityLabel("Copy the command")
                }
            }
            ForEach(approval.changes, id: \.path) { change in Text(change.path).font(.footnote.monospaced()).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(Array(approval.choices.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { Divider().padding(.leading, 14) }
                    Button {
                        Task { await model.decide(session: session, approval: approval.id, choice: choice.id) }
                    } label: {
                        Text(choice.label).font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 11).padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.choice, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .zeroCard()
    }
}

private extension Array where Element == String {
    mutating func toggle(_ value: String) { if let index = firstIndex(of: value) { remove(at: index) } else { append(value) } }
}

/// Markdown parsed once per text: a page drawn again (a new step arriving, a tick of the clock) reuses what it parsed.
@MainActor enum MarkdownCache {
    private final class Blocks { let value: [MarkdownBlock]; init(_ value: [MarkdownBlock]) { self.value = value } }
    private final class Inline { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    private static let blockCache: NSCache<NSString, Blocks> = {
        let c = NSCache<NSString, Blocks>(); c.countLimit = 500; return c
    }()
    private static let inlineCache: NSCache<NSString, Inline> = {
        let c = NSCache<NSString, Inline>(); c.countLimit = 3000; return c
    }()

    private static let drawnCounts: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>(); c.countLimit = 3000; return c
    }()
    private static let plainCounts: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>(); c.countLimit = 500; return c
    }()

    /// Characters an inline text draws (its Markdown marks left out), counted once.
    static func drawn(_ text: String) -> Int {
        if let kept = drawnCounts.object(forKey: text as NSString) { return kept.intValue }
        let count = inline(text).characters.count
        drawnCounts.setObject(NSNumber(value: count), forKey: text as NSString)
        return count
    }

    /// Characters in a text as it is (a code block's), counted once.
    static func count(_ text: String) -> Int {
        if let kept = plainCounts.object(forKey: text as NSString) { return kept.intValue }
        let count = text.count
        plainCounts.setObject(NSNumber(value: count), forKey: text as NSString)
        return count
    }

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let kept = blockCache.object(forKey: text as NSString) { return kept.value }
        let parsed = MarkdownBlock.parse(text)
        blockCache.setObject(Blocks(parsed), forKey: text as NSString)
        return parsed
    }

    static func inline(_ text: String) -> AttributedString {
        if let kept = inlineCache.object(forKey: text as NSString) { return kept.value }
        let parsed =
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        inlineCache.setObject(Inline(parsed), forKey: text as NSString)
        return parsed
    }
}

/// A step's state, as the Mac shows it: a spinner while it runs, a quiet tick done (done needs no colour, as Codex's
/// steps), a red cross failed, declined in orange; one size whatever the state, the first line's height.
struct StatusIcon: View {
    let status: ItemStatus
    var body: some View {
        Group {
            switch status {
            case .running: Spinner().frame(width: 12, height: 12)
            case .done: Image("check-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.tertiary)
            case .failed: Image("circle-xmark-glyph").resizable().frame(width: 14, height: 14).foregroundStyle(.red)
            case .declined: Image("ban-outline").resizable().frame(width: 14, height: 14).foregroundStyle(.orange)
            }
        }
        .frame(width: 14, height: 16)
    }
}

/// A message's images as tiles, from the right as the Mac lays them; each a tap from its full size.
/// Rows of views from the leading (or trailing) edge, wrapping at the width given.
struct WrappingStack: Layout {
    var spacing: CGFloat
    var trailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            let shift = trailing ? bounds.width - row.width : 0
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + shift + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, items: [(Int, CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append((items, y, x - spacing, height))
                y += height + spacing; x = 0; height = 0; items = []
            }
            items.append((index, x))
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}

struct MessageImages: View {
    /// Each tile's image, and whether it stands for a video (its first still, a play mark on it).
    let tiles: [(path: String, video: Bool)]
    @State private var shown: String?

    var body: some View {
        // In rows from the right: several (a video's, say) wrap rather than widen the page past the screen.
        WrappingStack(spacing: 6, trailing: true) {
            ForEach(tiles, id: \.path) { tile in
                ImageTile(path: tile.path, side: 88)
                    .overlay {
                        if tile.video {
                            Image("media-play-glyph").resizable().frame(width: 12, height: 12).foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(.black.opacity(0.55), in: Circle())
                        }
                    }
                    .onTapGesture { shown = tile.path }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .sheet(item: Binding(get: { shown.map(Shown.init) }, set: { shown = $0?.path })) { shown in
            ImageViewer(path: shown.path)
        }
    }

    private struct Shown: Identifiable { let path: String; var id: String { path } }
}

/// An image from the Mac, as large as asked, a placeholder of the same size until it comes: nothing moves.
struct ImageTile: View {
    let path: String
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.primary.opacity(0.08) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .task(id: path) { image = await PhoneModel.shared.image(path, side: Int(side * 3)) }
    }
}

/// An image an agent shows (a screenshot, a render), from the Mac: the answer's width, its own proportions once it
/// comes, a tap from its full size.
struct AnswerImage: View {
    let path: String
    let alt: String
    @State private var image: UIImage?
    @State private var open = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(image.size, contentMode: .fit)
            } else {
                Color.primary.opacity(0.08).aspectRatio(16 / 10, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .accessibilityLabel(alt)
        .onTapGesture { open = true }
        .sheet(isPresented: $open) { ImageViewer(path: path) }
        .task(id: path) { image = await PhoneModel.shared.image(path, side: 1600) }
    }
}

/// One image, whole, to look at.
struct ImageViewer: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { Spinner().frame(width: 22, height: 22) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { image = await PhoneModel.shared.image(path, side: 2400) }
    }
}

/// A done question's own shades, one hue (the Done state's purple) from its surface to its ink, as the Mac's: the
/// purple faded over grey went muddy.
enum DoneShades {
    private static func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> UIColor {
        let v = l + s * min(l, 1 - l)
        return UIColor(hue: h / 360, saturation: v == 0 ? 0 : 2 * (1 - l / v), brightness: v, alpha: 1)
    }
    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let surface = dynamic(dark: hsl(292, 0.45, 0.14), light: hsl(292, 1, 0.985))
    static let row = dynamic(dark: hsl(292, 0.50, 0.21), light: hsl(292, 0.85, 0.945))
    static let ink = Color.purple
    static let muted = dynamic(dark: hsl(292, 0.55, 0.75), light: hsl(292, 0.30, 0.48))
}

/// The Mac's pastel rows for a chosen option, in both appearances.
enum RowShades {
    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(
            uiColor: UIColor {
                $0.userInterfaceStyle == .dark
                    ? UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
                    : UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
            })
    }
    static let green = dynamic(dark: (0.13, 0.25, 0.16), light: (0.87, 0.96, 0.89))
    static let orange = dynamic(dark: (0.30, 0.22, 0.12), light: (0.99, 0.93, 0.85))
    static let red = dynamic(dark: (0.32, 0.14, 0.14), light: (0.99, 0.89, 0.89))
}

/// "Something else…" open where its row was: the same shape, the words wrapping as they grow, sent from the round
/// button inside it (the composer's), focused as it opens.
private struct ReplyBox: View {
    let placeholder: String
    @Binding var words: String
    let fill: Color
    let send: (String) async -> Void
    @FocusState private var focused: Bool
    private var empty: Bool { words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $words, axis: .vertical)
                .font(.subheadline.weight(.medium)).lineLimit(1...6).focused($focused)
                .padding(.vertical, 12)
            Button {
                let text = words; words = ""; focused = false; Task { await send(text) }
            } label: {
                Image("arrow-up-outline").resizable().frame(width: 14, height: 14)
                    .foregroundStyle(Theme.onKnob)
                    .frame(width: 30, height: 30).background(Theme.knob.opacity(empty ? 0.25 : 1), in: Circle())
            }
            .disabled(empty)
            .padding(.bottom, 7)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 14).padding(.trailing, 7).frame(minHeight: 44)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        // A moment after it's there: asked for in the same update, focus is dropped.
        .task {
            try? await Task.sleep(for: .milliseconds(50)); focused = true
        }
    }
}
