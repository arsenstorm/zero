import AppKit
import SwiftUI
import ZeroCore

struct ConversationView: View {
    let workspace: Workspace
    let inbox: InboxController
    /// Shown, as against kept behind the page shown: only the shown page answers Esc and holds the keyboard.
    var active = true
    @State private var isActive = true
    /// Your messages waiting for after the agent's turn, and whether they're held since you stopped it.
    var queued: [Queued] = []
    var held = false
    /// A change of model or permissions picked while a turn ran, applied as it ends (zerod's).
    var next: BoardRow.Next?
    /// The task's whole conversation, observed on its own: its words redraw this view, not the window.
    let live: LiveConversation
    /// Opens another task: a branch made from this one.
    var open: (String) -> Void = { _ in }
    private var conversation: Conversation { live.conversation }
    /// What's being written, in an object of its own: typing redraws the composer, not this view and its timeline,
    /// which only ever write it (a quote, a rewind, a sent message).
    @State private var box = DraftBox()
    private var draft: String {
        get { box.text }
        nonmutating set { box.text = newValue }
    }
    /// Held at the end of the conversation as it opens and while you're at its end; let go when you scroll away.
    @State private var following = true
    /// Your hand on the page (dragging, or its momentum): nothing else moves it meanwhile.
    @State private var userScrolling = false
    /// The message of yours being gone back to.
    @State private var rewinding: ConversationItem?
    /// The conversation's blocks, rows and asks, kept between redraws.
    @State private var shape = TimelineShape()
    /// What of the conversation is on screen: zerod's items played back in order, an answer read out before what follows.
    @State private var playback = Playback()
    /// Folds of quiet turns (TimelineRow) the user opened.
    @State private var openQuiet: Set<String> = []
    /// Esc twice in quick succession: pick a message to rewind to, then how (RewindCard).
    @State private var pickingRewind = false
    @State private var lastEscape: Date?
    @State private var escapeMonitor: Any?
    /// Images going with the next message.
    @State private var images: [URL] = []
    /// Where the conversation is scrolled to, and how much of it there is: for the scrollbar drawn over it.
    @State private var position = ScrollPosition(edge: .bottom)
    /// Where it's scrolled and what's on screen, read only by the scrollbar, the way down and the rail: scrolling
    /// redraws those, not the conversation.
    @State private var tracker = ScrollTracker()
    /// Your messages in the whole conversation, for the rail.
    /// The rows standing in for older items are on screen: only then is the next page fetched, and one page per
    /// approach: the next only once those rows have left the screen and come back as you scroll on.
    @State private var olderShown = false
    @State private var newerShown = false
    @State private var olderArmed = true
    /// How tall the composer is: the conversation fades out just above it.
    /// The composer's height with what sits on it (the question card, the queue), read only by the few views it sizes:
    /// held in the conversation's own state, a card coming or going redrew the whole timeline, a frame lost each time.
    @State private var foot = Foot()
    /// A question card sliding in or out, and the conversation with it.
    static let slideDuration = 0.25
    /// When the user last clicked in the app (anywhere: what's opened by a click isn't the conversation's end growing).
    @MainActor static var clicked = Date.distantPast
    @MainActor static let clickWatch: Any? = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
        MainActor.assumeIsolated { clicked = Date() }
        return event
    }
    static let slide = Animation.smooth(duration: slideDuration)
    /// The card's rise: ease-out cubic, the curve the room at the end grows on, step for step.
    static let rise = Animation.timingCurve(0.33, 1, 0.68, 1, duration: slideDuration)

    @Observable final class Foot {
        /// When this conversation was opened: a question card there already shows in place, not coming in.
        @ObservationIgnored let opened = Date()
        var height: CGFloat = 0
        /// How far the conversation is scrolled up from its end, the question card's height, and whether the pointer
        /// is on the card: read by the card and the mask alone, so a scroll redraws those, not the conversation.
        var below: CGFloat = 0
        var card: CGFloat = 0
        /// The composer's own height: the conversation shows down to it (behind the question card too), never under it.
        var composer: CGFloat = 0
        /// The pointer on the card, or on the composer: either brings the card up.
        var overCard = false
        var overComposer = false
        var overQueue = false
        /// A text box in the card focused: being typed in, it stays up whatever the pointer does.
        var typing = false
        var hovering: Bool { overCard || overComposer || overQueue || typing }
        /// How far the card has sunk behind the composer: as far as the conversation is scrolled up from its end, until
        /// only its strip shows (the surface under it gone too); none while the pointer is on it or the composer.
        var sunk: CGFloat { arriving || hovering ? 0 : min(below, deepest) }
        /// Just come: sliding up (Sinker) as the conversation slides up for it (EndRoom), neither sunk nor raised by
        /// the scroll or the pointer meanwhile.
        var arriving = false
        /// As far as it sinks: all but its strip.
        var deepest: CGFloat { max(0, card - AskDock.tuck - 24) }
    }
    private var composerHeight: CGFloat { foot.height }
    /// Queued from here, not yet in zerod's queue: shown in the strip until it is.
    @State private var queuing: [Queued] = []
    private var shownQueue: [Queued] {
        queued + queuing.filter { pending in !queued.contains { $0.text == pending.text } }
    }
    /// Just sent: the message sits at the top of the page with room under it for the answer, which fills that room
    /// without moving anything, as Codex's does. Over once you scroll.
    @State private var lifted = false
    /// The lift's scroll has put the message at the top: only then can scrolling up end the lift.
    @State private var liftPlaced = false
    /// Scrolled by you since the lift: only then does the question card sink with it. Before, the room under the
    /// message, past the page's foot as it came, read as scrolled up and sank the card, then raised it.
    @State private var liftScrolled = false
    /// The message just sent and the least height of the conversation from it down: a page's worth, so the message
    /// sits at the top with room under it that the answer fills without changing the page's size, so nothing moves.
    /// A scroll up gives the room back: from where you stop you can come down a composer's height, no further.
    @State private var liftId: String?
    @State private var liftMin: CGFloat = 0
    @State private var pageHeight: CGFloat = 0
    /// The room just gone: growth still anchors to the top until scrolling settles, so taking it away moves nothing.
    @State private var settling = false
    /// A question, ask or approval just answered: the page keeps the height it had, so the card fades out where it
    /// was and nothing above it moves; what comes next (its agent starting, its reply) fills that room. Given back
    /// when you scroll.
    @State private var room: CGFloat = 0
    /// An older page is coming in above: the page keeps its distance from the end through that, so what's read stays.
    @State private var loadingAbove = false
    /// Another provider picked for the next message; nil keeps the task's own.
    @State private var provider: Provider?
    /// A model and effort picked for the next message; nil keeps the task's own.
    @State private var model: String?
    @State private var effort: String?
    /// The blocks on screen, by the message of yours each answers to: the rail's bright ticks.

    var body: some View {
        VStack(spacing: 0) {
            if let terminal = conversation.terminal {
                // The provider's own terminal has the task, for what only it has: the same thread, typed into there.
                HostTerminal(id: terminal.id, claudeCode: conversation.provider == .claude).id(terminal.id)
            } else {
                conversationPane
            }
        }
    }

    /// The next older page, with what's read kept where it is: the offset moves by exactly what was added above once
    /// the new rows have measured (the scroll view's own anchoring isn't to be relied on through that).
    /// A page that adds nothing to see (its turns all folded into the quiet ones already there) leaves the top on
    /// screen, and no scroll can take it off: the next comes straight on, in the same go, until something shows or
    /// there's nothing older. A page that shows something is one per scroll, as ever.
    private func loadOlder() async {
        guard olderShown, olderArmed else { return }
        olderArmed = false
        loadingAbove = true
        defer { loadingAbove = false }
        while live.earlier > 0, !Task.isCancelled {
            let (before, left) = (tracker.geometry, live.earlier)
            await workspace.loadEarlier(conversation.id)
            // Nothing came (zerod didn't answer): no going round.
            guard live.earlier < left else { return }
            var grew = false
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if let before, let now = tracker.geometry, now.contentSize.height > before.contentSize.height + 1 {
                    position.scrollTo(y: before.contentOffset.y + (now.contentSize.height - before.contentSize.height))
                    grew = true
                    break
                }
            }
            if grew || !olderShown { return }
        }
    }

    /// One block as a row: compared before it's drawn (a word streamed into the last answer redraws only that one),
    /// and reporting whether it's on screen, for the rail.
    /// A card answered fades out where it was (and a new one in): its own animation, so nothing else in the
    /// conversation is animated with it.
    static let fade = AnyTransition.opacity.animation(.easeOut(duration: 0.2))

    /// A block. The asks its turn made are among its steps, folded as thinking is; the card to answer one is above
    /// the composer.
    private func row(_ block: TimelineBlock, turns: [String: String]) -> some View { blockRow(block, turns: turns) }

    private func blockRow(_ block: TimelineBlock, turns: [String: String]) -> some View {
        BlockRow(
            block: block, cwd: conversation.cwd, quote: quote, save: save, rewind: { rewinding = $0 },
            later: { [workspace, id = conversation.id] text in Task { await workspace.askToSaveForLater(id, answer: text) } }
        ).equatable()
            .id(block.id)
            .onScrollVisibilityChange(threshold: 0.05) { shown in
                guard let turn = turns[block.id] else { return }
                if shown { tracker.seen[block.id] = turn } else { tracker.seen[block.id] = nil }
            }
            .onDisappear { tracker.seen[block.id] = nil }
    }

    /// Where you are in the conversation: at its end (nothing kept), or the block at the top of the screen.
    private func rememberScroll() {
        guard let geometry = tracker.geometry else { return }
        if geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) < 60 {
            ScrollMemory.keep(nil, in: conversation.id)
            return
        }
        let order = TimelineBlock.of(conversation.items, working: false).map(\.id)
        guard let top = order.first(where: { tracker.seen[$0] != nil }), let turn = tracker.seen[top] else { return }
        ScrollMemory.keep((top, turn), in: conversation.id)
    }

    /// The message as a quote at the end of what's being written.
    private func quote(_ text: String) {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        draft = (draft.isEmpty ? "" : draft + "\n\n") + quoted + "\n\n"
    }

    /// The message kept as a scratchpad in Saved, named by its first line.
    private func save(_ text: String) {
        let first = text.split(separator: "\n").first.map { String($0.prefix(60)) } ?? "Saved"
        let title = first.replacingOccurrences(of: "/", with: "\u{2215}").trimmingCharacters(
            in: CharacterSet(charactersIn: "#> ").union(.whitespaces))
        Task { await workspace.createPad(title: title.isEmpty ? "Saved" : title, folder: "Saved", content: text) }
    }

    /// The blocks before the lifted message, and from it on (none when nothing's lifted).
    private func split(_ blocks: [TimelineBlock]) -> (head: [TimelineBlock], tail: [TimelineBlock]) {
        guard lifted, let at = blocks.firstIndex(where: { $0.id == liftId }) else { return (blocks, []) }
        return (Array(blocks[..<at]), Array(blocks[at...]))
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                scrollingTimeline
                    // Soft edges: at the top, there's more above; just above the composer, the text fades out before it,
                    // as Codex's does, with nothing behind the composer but the page.
                    // Under the composer: nothing, so the conversation doesn't show at its sides.
                    .mask { SoftFoot(foot: foot) }
                    // Scrolled up: a way back down, just above the composer (and its question card's strip), under the card.
                    .overlay(alignment: .bottom) { wayDown(proxy) }
                    // The composer lies over the conversation's foot; the conversation runs the full height under it.
                    .overlay(alignment: .bottom) { composerOverlay }
                    .overlay(alignment: .trailing) {
                        ThinScrollbar(tracker: tracker) {
                            following = false; lifted = false; position.scrollTo(y: $0)
                        }.padding(.trailing, 2)
                    }
                    .overlay(alignment: .leading) { rail(proxy) }
                    // Fetched again as your messages come and go, not with every word streamed.
                    .task(id: conversation.items.count(where: { if case .user = $0.kind { true } else { false } }) + live.earlier) {
                        await workspace.outline(conversation.id)
                    }
                    // Left, it goes back to its latest items: memory doesn't grow with every long task opened.
                    .onDisappear {
                        rememberScroll(); workspace.trim(conversation.id); lifted = false
                    }
                    // Back where you were: the block that was at the top of the screen, its older page loaded first if
                    // it isn't any more. At the end, it opens at the end, as ever.
                    .task { await restoreScroll() }
                    .onAppear { opened() }
                    .onDisappear {
                        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
                    }
                    .onChange(of: active, initial: true) { isActive = active }
                    // An answer that lands while you're here is seen once you do something in the task (click, scroll,
                    // type): just having it open isn't reading it.
                    .simultaneousGesture(TapGesture().onEnded { workspace.markSeen(conversation.id) })
                    .onChange(of: images) { Drafts.save("task:" + conversation.id, text: box.text, images: images) }
                    .overlay { rewindOverlay }
            }
        }
    }

    /// The timeline in its scroll view, with how the page is held: at the end, on what's read, or on a lifted message.
    private var scrollingTimeline: some View {
        ScrollView { timelineColumn }
            .scrollIndicators(.never)
            // Opened at the end, and held there as answers measure themselves and new ones come, while you're at
            // the end; content added above (an older page) leaves what you're reading where it is.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Only you scroll: what's read keeps its distance from the top as the agent adds words below, so
            // nothing moves under your eyes. The end is kept only while you're at it (following), and while an
            // older page comes in above.
            // Following, the end isn't held by the anchor (which moved the page the whole way in a frame) but scrolled to
            // as the page grows (scrollGeometryChanged): slid, a step at a time.
            .defaultScrollAnchor(loadingAbove && !lifted && !settling ? .bottom : .top, for: .sizeChanges)
            .onAppear { _ = Self.clickWatch }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, height in pageHeight = height }
            // The message just sent goes to the top of the page once it's in the conversation.
            .onChange(of: conversation.items.last(where: \.isYours)?.id) { _, id in placeLift(id) }
            // Where you were in it, kept when scrolling stops and when you leave.
            .onScrollPhaseChange { _, phase in scrollPhaseChanged(phase) }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { before, now in scrollGeometryChanged(from: before, to: now) }
            .background { PlaybackClock(playback: playback) }
    }

    /// Laid out in full, not lazily: a lazy stack keeps the heights it guessed for rows measured off
    /// screen, so its end could sit below its last row and the page open blank. The page loaded is a
    /// few dozen rows; older pages come in on demand above.
    private var timelineColumn: some View {
        // What's on screen is what playback has reached: opened (or shown again, or a window jumped to) it's all there.
        let items = shape.merge(conversation.items, sending: workspace.sending[conversation.id] ?? [])
        playback.update(items, conversation: conversation.id, live: active && live.later == 0, now: Date())
        shape.update(
            items: items, shown: playback.count,
            working: playback.working(conversation.status == .working || conversation.status == .waiting))
        let (blocks, turns) = (shape.blocks, shape.turns)
        let (head, tail) = split(blocks)
        return VStack(alignment: .leading, spacing: 18) {
            olderRows
            ForEach(shape.rows(head)) { line in
                switch line {
                case let .block(block): row(block, turns: turns)
                case let .quiet(id, blocks, count):
                    QuietTurns(
                        turns: count,
                        open: Binding(
                            get: { openQuiet.contains(id) }, set: { if $0 { openQuiet.insert(id) } else { openQuiet.remove(id) } })
                    ) {
                        ForEach(blocks) { block in row(block, turns: turns) }
                    }
                    .id(id)
                }
            }
            if !tail.isEmpty {
                liftedTail(tail, turns: turns)
            }
            // Its provider still getting ready (signing in, say): say so, rather than an empty page.
            // Or woken by a message just sent: its agent is starting, the message waiting for it above.
            if startingUp {
                Thinking(text: "Starting \(conversation.provider.title)…").id("starting")
            }
            if let health { healthCallout(health) }
            if let diff = conversation.diff, conversation.status == .idle, !diff.isEmpty {
                CaughtUp(playback: playback) { lastTurnDiff(diff) }
            }
            newerRows
            // Room for the composer and the fade above it: scrolled to the end, the last message sits just
            // above the composer, and the scrollbar is at the bottom. Just sent, a page of room, so the
            // message can sit at the top.
            EndRoom(foot: foot).id("end")
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { [tracker] in
            tracker.columnHeight = $0
        }
        .frame(minHeight: room, alignment: .top)
        .padding(.top, 20)
        .centredColumn(760)
        .environment(\.askInbox, inbox)
        .environment(\.playback, playback)
        .environment(\.askSession, conversation.id)
        .environment(\.replyToSelection) { quote($0) }
    }

    /// More above: rows standing in for it, the next page fetched as they come into view, the view
    /// kept on what was at its top.
    @ViewBuilder private var olderRows: some View {
        let more = live.earlier
        if more > 0 {
            // On screen, older pages come in (as many as it takes to show something); kept alive just off screen by
            // the list, it fetches nothing. Anchored at the bottom, the view stays on what's read as each page goes in
            // above. A slim row, not stand-in turns: the chat opens on itself, and says it's loading only while it is.
            LoadingEarlier(loading: loadingAbove).id("earlier")
                .onScrollVisibilityChange(threshold: 0.01) { shown in
                    olderShown = shown
                    if !shown { olderArmed = true }
                }
                .task(id: olderShown) { await loadOlder() }
        }
    }

    /// Lifted: from the message just sent down, at least a page tall, so what the agent adds
    /// under it fills room that is already there and the page's size doesn't change.
    private func liftedTail(_ tail: [TimelineBlock], turns: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(tail) { block in row(block, turns: turns) }
        }
        .frame(minHeight: liftMin, alignment: .top)
    }

    private var startingUp: Bool {
        conversation.status == .starting || (conversation.status == .offline && !(workspace.sending[conversation.id] ?? []).isEmpty)
    }

    /// Stuck or out of usage: a callout where the trouble is, at the end of the work, like a failure's.
    private func healthCallout(_ health: (label: String, text: String)) -> some View {
        CautionCallout(text: health.label + ": " + health.text, tone: .amber) {
            // Out of usage: the task carries on with another provider, the whole conversation with it.
            if conversation.attention == .limited {
                HStack(spacing: 8) {
                    ForEach(Self.takeOver.filter { $0 != conversation.provider }, id: \.self) { other in
                        Button("Continue with \(other.title)") { carryOn(with: other) }
                    }
                }
            }
        }
        .id("health")
    }

    private func lastTurnDiff(_ diff: String) -> some View {
        DisclosureGroup("Everything the last turn changed") {
            DiffText(diff: diff)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        }.padding(.top, 4)
    }

    /// Newer than the window jumped to: rows standing in for them, the next page fetched as they come
    /// into view (page after page while they stay on screen).
    @ViewBuilder private var newerRows: some View {
        if live.later > 0 {
            SkeletonTurns().id("later")
                .onScrollVisibilityChange(threshold: 0.01) { newerShown = $0 }
                .task(id: newerShown ? live.later : -1) { if newerShown { await workspace.loadNewer(conversation.id) } }
        }
    }

    /// The message just sent goes to the top of the page once it's in the conversation.
    private func placeLift(_ id: String?) {
        // Once per send: a worker's report landing right after (a message of its own) mustn't move the page again.
        guard lifted, !liftPlaced, let id else { return }
        liftId = id
        liftMin = max(0, pageHeight - 52 - composerHeight - 32)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard lifted else { return }
            position.scrollTo(id: id, anchor: UnitPoint(x: 0, y: 52 / max(pageHeight, 1)))
            liftPlaced = true
            // The room as it came out, past the page's foot: what's beyond it taken off, so the page is at its end.
            // Left, the question card read it as scrolled up and sat sunk by as much.
            try? await Task.sleep(for: .milliseconds(50))
            guard lifted, let g = tracker.geometry else { return }
            let over = Self.end(of: g) - g.contentOffset.y
            if over > 0.5 { liftMin = max(0, liftMin - over) }
        }
    }

    /// Scrolled by you: it stops following the end, until you're back at it. Scrolling while the rows
    /// for older items show asks for the next page (one page per gesture, never a chain).
    private func scrollPhaseChanged(_ phase: ScrollPhase) {
        userScrolling = phase == .interacting || phase == .decelerating
        if phase == .interacting { userScrolled() }
        if phase == .idle { scrollStopped() }
    }

    private func userScrolled() {
        workspace.markSeen(conversation.id)
        following = false
        liftScrolled = true
        if olderShown, !olderArmed { olderArmed = true; Task { await loadOlder() } }
    }

    private func scrollStopped() {
        settling = false
        giveBackLiftRoom()
        rememberScroll()
        // At the end, following: never while lifted, whose room ends exactly at the page's foot (the
        // lift's own scroll settles here too, and would read as you having scrolled to the end).
        // At the end means at it, not near it: a release of the lift leaves the end a few points off.
        guard let g = tracker.geometry, !lifted else { return }
        following = live.later == 0 && Self.end(of: g) - g.contentOffset.y < 2
    }

    /// Lifted, the room gives way behind you as you scroll up: from where you stop you can come
    /// back down a composer's height, no further. Far enough up and the room is gone, the lift
    /// with it. The page is put back where you stopped, in case the shrink moved it.
    private func giveBackLiftRoom() {
        guard lifted, liftPlaced, let g = tracker.geometry else { return }
        let offset = g.contentOffset.y
        let beyond = max(0, g.contentSize.height - g.containerSize.height - offset - composerHeight)
        guard beyond > 0 else { return }
        liftMin = max(0, liftMin - beyond)
        if liftMin == 0 { lifted = false; liftPlaced = false; liftId = nil }
        DispatchQueue.main.async { position.scrollTo(y: offset) }
    }

    private func scrollGeometryChanged(from before: ScrollGeometry, to now: ScrollGeometry) {
        tracker.geometry = now
        // Grown at its end while you were there (a card, a turn's end, words streaming, the composer taller): the page
        // slides to its new end on the card's curve, not moved there in a frame. More than a page (a task opened, a
        // window jumped to) goes at once: sliding a whole screen would only slow it.
        let grew = now.contentSize.height - before.contentSize.height
        // Just after a click, it grew because something was opened (a step, a notice): it opens down from where it is,
        // the page not following the end (which pushed all above it up, as if it shifted).
        if following, !lifted, !loadingAbove, !userScrolling, grew > 0.5, Self.end(of: before) - before.contentOffset.y < 2,
            Date().timeIntervalSince(Self.clicked) > 0.6
        {
            if grew < now.containerSize.height {
                withAnimation(Self.rise) { position.scrollTo(edge: .bottom) }
            } else {
                position.scrollTo(edge: .bottom)
            }
        }
        // How far up from the end: the question card on the composer sinks as far, behind it.
        // From where the scroll stops (the toolbar's inset at the top taken off: left in, the end read 38 pt off and the
        // card sat sunk that much at the very bottom).
        // Only your own scrolling sinks it: following the end as words stream in, the page slides to each new end, and
        // read mid-slide that distance sank the card and raised it again, many times a second.
        let below = (lifted && !liftScrolled) || (following && !userScrolling) ? 0 : max(0, Self.end(of: now) - now.contentOffset.y)
        if abs(foot.below - below) > 0.5 { foot.below = below }
        // The room an answered card left goes back as you scroll up, no faster: kept down to the window's foot, so the
        // page never moves on its own. Taken back all at once, at a scroll's start, the conversation's end jumped up to
        // the window's foot, the page thrown down by the card's height. (The column starts 20 down.)
        if room > 0, userScrolling {
            let foot = now.contentOffset.y + now.containerSize.height + now.contentInsets.top - now.contentInsets.bottom - 20
            if foot <= tracker.columnHeight { room = 0 } else if foot < room - 0.5 { room = foot }
        }
        // Lifted, and the reply has outgrown the room while you sat at its foot: the lift has done its
        // work, and the page follows the end from here, as it would have without it.
        let wasAtFoot = Self.end(of: before) - before.contentOffset.y < 2
        let outgrown = Self.end(of: now) - now.contentOffset.y > 2
        if liftHolding, wasAtFoot, outgrown {
            lifted = false; liftPlaced = false; liftId = nil; following = true
            position.scrollTo(edge: .bottom)
            return
        }
        // Following the end (as it opens, and while you're at it): rows measure themselves after the first
        // layout, and the list's height can settle far from its first guess (a long conversation came out
        // 2,000 pt shorter, leaving the view past its end, blank). It stays at the end of what's there.
        let end = Self.end(of: now)
        if following, end > 0, abs(now.contentOffset.y - end) > 2 {
            position.scrollTo(edge: .bottom)
        }
        // Past the end is never a place to be (a page left blank until scrolled): back to the end, whether
        // following it or restoring where you were.
        else if end > 0, now.contentOffset.y > end + 2 {
            position.scrollTo(edge: .bottom)
        }
        // Scrolled up past the room under a sent message (it's wholly below the page): the room goes, out
        // of sight, so scrolling back down ends at the conversation's end.
    }

    /// The lift placed and your hand off the page.
    private var liftHolding: Bool { lifted && liftPlaced && !userScrolling }

    /// The offset at the end: the content, less the page, with the insets (the title bar's 38 above)
    /// in; without them being at the end read as 38 short of it.
    private static func end(of g: ScrollGeometry) -> CGFloat {
        g.contentSize.height + g.contentInsets.bottom - g.contentInsets.top - g.containerSize.height
    }

    /// What waits for after this turn sits above the composer, part of its height for the fade above: what waits on
    /// you first (questions, approvals, the agent's asks), so answering never moves the conversation.
    private var composerOverlay: some View {
        VStack(spacing: 8) {
            let queued = shownQueue
            DockSlot(
                conversation: conversation, inbox: inbox, playback: playback, foot: foot, page: pageHeight,
                behindQueue: !queued.isEmpty || held,
                answer: { [workspace, id = conversation.id] question, answers in
                    Task { await workspace.answer(id, question: question, answers: answers) }
                },
                decide: { [workspace, id = conversation.id] approval, choice in
                    Task { await workspace.decide(id, approval: approval, choice: choice) }
                },
                // An answered card leaving: the page keeps its height (see `room`).
                left: { [tracker] in room = max(room, tracker.columnHeight) })
            if !queued.isEmpty || held {
                QueueStrip(
                    queued: queued, held: held, hover: { [foot] inside in if foot.overQueue != inside { foot.overQueue = inside } },
                    steer: { item in Task { await workspace.steer(conversation.id, item: item) } },
                    edit: { item in
                        Task {
                            if await workspace.unqueue(conversation.id, item: item.id) {
                                draft = item.text; images = (item.images ?? []).map { URL(fileURLWithPath: $0) }
                            }
                        }
                    },
                    remove: { item in Task { _ = await workspace.unqueue(conversation.id, item: item.id) } },
                    release: { Task { await workspace.release(conversation.id) } }
                )
                .frame(maxWidth: 680)
            }
            composer
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [foot] in if foot.composer != $0 { foot.composer = $0 } }
                .onHover { [foot] inside in if foot.overComposer != inside { foot.overComposer = inside } }
        }
        // Once zerod has it, the one shown at once goes: left until it went, it came back when the queue emptied.
        .onChange(of: queued) { _, now in queuing.removeAll { pending in now.contains { $0.text == pending.text } } }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [foot] height in
            guard foot.height != height else { return }
            // Lifted (just sent, the message at the top): the room under it takes the change (a step to a taller
            // card, the queue's strip), so the page's size holds and the message stays. Added at the foot instead,
            // it read as the reply outgrowing the room, and the lift was let go, the page thrown to its end.
            if lifted, liftPlaced {
                liftMin = max(0, liftMin - (height - foot.height))
                foot.height = height
                return
            }
            let grew = height > foot.height
            // Grown (a question card arriving) while at the end: the end followed, the last words above the card and
            // the card all the way up. Held where it was (just sent, the page kept for the answer), the room the card
            // added went below the page, and the card sank as far, nothing scrolled.
            let atEnd = foot.below < 2 || following
            let follow = grew && atEnd
            foot.height = height
            // Following, the page slides to its new end itself (scrollGeometryChanged); held (just sent, the page kept
            // for the answer), it's taken there, on the card's curve.
            if follow && !following { DispatchQueue.main.async { withAnimation(Self.rise) { position.scrollTo(edge: .bottom) } } }
            // Shrunk (the queue's strip gone, a step to a shorter card) while at the end: still at it. Left where it
            // was, the page sat that far short of its end, and the card, reading it as scrolled up, sank as far.
            // In the same frame: a frame later, the page showed shifted for one (68 px as a turn ended).
            if !grew, atEnd { position.scrollTo(edge: .bottom) }
        }
    }

    private func wayDown(_ proxy: ScrollViewProxy) -> some View {
        WayDown(tracker: tracker, away: live.later > 0) {
            Task {
                // Jumped back through it: the latest page again first.
                if live.later > 0 { await workspace.loadLatest(conversation.id); try? await Task.sleep(for: .milliseconds(50)) }
                following = true; lifted = false
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Just above the question card's strip, as it sits sunk (the arrow shows only scrolled up, where it is), and
        // under the card: brought up, the card covers it.
        .safeAreaInset(edge: .bottom, spacing: 0) { FootRoom(foot: foot, extra: 6, sunk: true) }
    }

    /// Every message of yours, loaded or not, from zerod's outline of the conversation.
    @ViewBuilder private func rail(_ proxy: ScrollViewProxy) -> some View {
        let marks = workspace.outlines[conversation.id] ?? []
        if marks.count > 1 {
            MessageRail(marks: marks, tracker: tracker, inset: 18) { id in
                Task { await jump(to: id, proxy) }
            }
            // Redrawn when its marks change, not with every word the conversation streams.
            .equatable()
            .padding(.vertical, 40)
        }
    }

    private func jump(to id: String, _ proxy: ScrollViewProxy) async {
        following = false
        if conversation.items.contains(where: { $0.id == id }) { withAnimation { proxy.scrollTo(id, anchor: .top) }; return }
        // Not loaded: a page from it, in place of what is (not every item from it to the end,
        // all laid out), and straight there rather than animated across it.
        await workspace.jump(conversation.id, to: id)
        try? await Task.sleep(for: .milliseconds(50))
        proxy.scrollTo(id, anchor: .top)
    }

    private func restoreScroll() async {
        guard let kept = ScrollMemory.place(in: conversation.id) else { return }
        following = false
        if !conversation.items.contains(where: { $0.id == kept.turn }) { await workspace.jump(conversation.id, to: kept.turn) }
        try? await Task.sleep(for: .milliseconds(80))
        position.scrollTo(id: kept.block, anchor: .top)
    }

    /// What you'd written and attached and not sent yet, kept as you go (a branch's message waiting first).
    private func opened() {
        if let kept = Drafts.load("task:" + conversation.id) { draft = kept.text; images = kept.images }
        // Kept as it's typed, here rather than in an onChange this view would have to read it for.
        let id = conversation.id
        let (key, imagesNow) = ("task:" + id, { images })
        // Typing in it is doing something in it: its reply is seen.
        box.saved = { [weak workspace] text in
            Drafts.save(key, text: text, images: imagesNow()); workspace?.markSeen(id)
        }
        if let waiting = workspace.pendingDrafts.removeValue(forKey: conversation.id) { draft = waiting }
        Task {
            try? await Task.sleep(for: .milliseconds(600)); workspace.markSeen(id)
        }
        watchEscape()
    }

    @ViewBuilder private var rewindOverlay: some View {
        if pickingRewind {
            RewindPicker(
                messages: conversation.items.filter { if case .user = $0.kind { true } else { false } }.reversed(),
                close: { pickingRewind = false }
            ) { item in
                pickingRewind = false; rewinding = item
            }
        } else if let item = rewinding {
            RewindCard(workspace: workspace, task: conversation.id, item: item, close: { rewinding = nil }) { rewound, conversationToo in
                // The message back in the box, to send again or change.
                if conversationToo { draft = rewound.text; images = rewound.images.map { URL(fileURLWithPath: $0) } }
            } branched: {
                open($0)
            }
        }
    }

    /// Esc, then Esc again within half a second, on the page or in its composer: the rewind picker. A single Esc goes
    /// on to whatever it was for; nothing opens over a card already open.
    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isActive, event.keyCode == 53, !pickingRewind, rewinding == nil else { return event }
            let now = Date()
            if let last = lastEscape, now.timeIntervalSince(last) < 0.5 {
                lastEscape = nil
                guard conversation.items.contains(where: { if case .user = $0.kind { true } else { false } }) else { return event }
                pickingRewind = true
                return nil
            }
            lastEscape = now
            return event
        }
    }

    private var composer: some View {
        let busy = conversation.status == .working || conversation.status == .waiting
        // Typing to a task whose agent has stopped starts it now, so the message goes the moment it's sent.
        return Composer(
            draft: Binding(
                get: { box.text },
                set: {
                    box.text = $0; if !$0.isEmpty { workspace.warm(conversation.id) }
                }), placeholder: placeholder, canSend: conversation.status != .starting, folder: conversation.cwd, workspace: workspace,
            images: $images, active: active,
            stop: busy && conversation.terminal == nil ? { Task { await workspace.interrupt(conversation.id) } } : nil,
            queue: busy && conversation.terminal == nil
                ? {
                    // Return while it works: the message waits for after this turn, in the strip above.
                    let (text, attached) = ImageToken.outgoing(draft, images: images.map(\.path))
                    draft = ""
                    images = []
                    // In the strip at once, in the same frame the composer empties: waiting for zerod's word, the
                    // composer shrank one frame and the strip came the next, the page dropping and jumping back.
                    let pending = Queued(id: "pending-" + UUID().uuidString, text: text, images: attached)
                    queuing.append(pending)
                    Task {
                        await workspace.queue(conversation.id, text: text, images: attached)
                        try? await Task.sleep(for: .seconds(5))
                        queuing.removeAll { $0.id == pending.id }
                    }
                } : nil,
            // ponytail: the first agent ask waiting, not the dock's page shown; follow the pager if several wait.
            pick: { [inbox, conversation] digit in
                guard conversation.questions.isEmpty, conversation.approvals.isEmpty,
                    let ask = inbox.store.asks.first(where: { $0.isAgents(in: conversation.id) && !$0.state.isFinal }),
                    digit <= ask.options.count
                else { return false }
                inbox.choose(digit - 1, on: ask.id)
                return true
            }
        ) {
            let (text, attached) = ImageToken.outgoing(draft, images: images.map(\.path))
            draft = ""
            images = []
            send(text, images: attached, with: provider ?? conversation.provider)
            lifted = true
            NotificationCenter.default.post(name: WorkBlock.fold, object: nil)
            liftPlaced = false
            liftScrolled = false
            following = false
        } controls: {
            // The model for the next message: one of this provider's, or another provider's, which takes the task
            // over, conversation and all.
            // Mid-turn, what's kept for the next turn shows, marked so; a pick then is kept for it too.
            let kept = busy && (next?.provider != nil || next?.model != nil || next?.effort != nil)
            let current = kept ? (next?.provider ?? conversation.provider) : provider ?? conversation.provider
            let chosen =
                kept
                ? (next?.model ?? (next?.provider == nil ? conversation.model : nil))
                : provider == nil ? (model ?? conversation.model) : model
            let level =
                kept
                ? (next?.effort ?? (next?.provider == nil && next?.model == nil ? conversation.effort : nil))
                : effort ?? (provider == nil && model == nil ? conversation.effort : nil)
            // The model is the subject, its provider the icon: "Opus 5.5 · High". No model picked, the provider's first;
            // a provider with no catalogue (OpenCode) by its name.
            let catalogue = ComposerRows.catalogue(current)
            let name = catalogue.first { $0.id == chosen }?.name ?? chosen ?? catalogue.first?.name ?? current.title
            ComposerChip(
                id: "task.\(conversation.id).agent",
                label: [name, level.map { effortLabel($0, short: true) }].compactMap { $0 }.joined(separator: " · "),
                symbol: "terminal", icon: current.mark, kind: .runtime, prominent: true, pending: kept,
                rows: {
                    ComposerRows.taskModels(conversation, chosen: (current, chosen)) { picked, choice in
                        if busy {
                            Task {
                                await workspace.switchProvider(
                                    conversation.id, to: picked, model: choice.id.isEmpty ? nil : choice.id,
                                    effort: choice.levels.contains { $0.id == level } ? level : nil)
                            }
                            return
                        }
                        provider = picked == conversation.provider ? nil : picked
                        model = choice.id.isEmpty ? nil : choice.id
                        if let effort, !choice.levels.contains(where: { $0.id == effort }) { self.effort = nil }
                    }
                }, level: { id in id == "\(current.rawValue)/\(chosen ?? "")" ? level : nil },
                setLevel: { _, picked in
                    if busy { Task { await workspace.switchProvider(conversation.id, to: current, model: chosen, effort: picked) }; return }
                    effort = picked
                }
            )
            .tip(kept ? "From the next turn" : "")
            // Mid-turn, a pick is kept for the next turn (the agent starts again with it then), marked so.
            let permissions = busy ? (next?.permissions ?? conversation.permissions) : conversation.permissions
            ComposerChip(
                id: "task.\(conversation.id).permissions", label: permissions == .auto ? "Auto" : "Unrestricted",
                symbol: permissions == .auto ? "wand-sparkle" : "bolt-lightning:glyph", tint: permissions == .auto ? nil : .orange,
                pending: busy && next?.permissions != nil
            ) {
                ComposerRows.list(
                    "Permissions",
                    [
                        (
                            "auto", "Auto", "\(conversation.provider.title) decides what's safe, and asks you the rest",
                            permissions == .auto,
                            { Task { await workspace.setPermissions(conversation.id, .auto) } }
                        ),
                        (
                            "unrestricted", "Unrestricted", "Anything, without asking", permissions == .unrestricted,
                            { Task { await workspace.setPermissions(conversation.id, .unrestricted) } }
                        ),
                    ])
            }
            .tip(
                busy && next?.permissions != nil
                    ? "From the next turn" : busy ? "Picked now, it applies from the next turn" : "What the agent may do without asking")
        }
        // A little narrower than the conversation.
        .centredColumn(680)
        .padding(.top, 4).padding(.bottom, 16)
    }

    /// The providers a task can move to: they read Zero's record natively (Claude Code resumes it, Codex imports it).
    static let takeOver: [Provider] = [.claude, .codex]

    private func send(_ text: String, images: [String] = [], with chosen: Provider) {
        Task {
            let (model, effort) = (model, effort)
            if chosen != conversation.provider {
                guard await workspace.switchProvider(conversation.id, to: chosen, model: model, effort: effort) else { return }
                provider = nil
            }
            // Sent from a window back in it: to the latest, where the message will be.
            if live.later > 0 { await workspace.loadLatest(conversation.id) }
            // Not sent (zerod refused it, or wasn't there): the words back in the box, never lost.
            guard await workspace.send(conversation.id, text: text, images: images, model: model, effort: effort) else {
                if draft.isEmpty { draft = text; self.images = images.map { URL(fileURLWithPath: $0) } }
                return
            }
            self.model = nil
            self.effort = nil
        }
    }

    private func carryOn(with other: Provider) {
        send(
            "You've taken this task over from \(conversation.provider.title), which ran out of usage. Carry on from where it stopped.",
            with: other)
    }

    /// What's wrong, and what to do about it: the session's attention beyond working or waiting.
    private var health: (label: String, text: String)? {
        switch conversation.attention {
        case .stuck: return ("Stuck", conversation.stalled ?? "It has stopped making progress.")
        case .limited:
            let reset =
                (conversation.usage?.resetsAt).map {
                    " Resets \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened))."
                } ?? ""
            return ("Usage limit", "The provider's usage limit is reached.\(reset)")
        // A failure is in the conversation itself, as a callout.
        default: return nil
        }
    }

    private var placeholder: String {
        switch conversation.status {
        case .offline: "Message to resume it"
        case .working, .waiting: conversation.provider == .opencode ? "OpenCode answers one message at a time" : "Steer it while it works"
        default: "Reply"
        }
    }
}

/// The conversation's blocks, the message each answers and the folded rows, worked out again only
/// when what they're made of changes: the column is asked for on every frame of a scroll, and working them out reads
/// every item. Arrays left as they were compare at once (they share their storage).
final class TimelineShape {
    private var merged: (items: [ConversationItem], sending: [Sending], all: [ConversationItem])?
    private var made: (items: [ConversationItem], shown: Int, working: Bool)?
    private(set) var blocks: [TimelineBlock] = []
    private(set) var turns: [String: String] = [:]
    private var folded: (head: [TimelineBlock], rows: [TimelineRow])?

    /// The conversation's items and what's just been sent, which shows at once, before its agent has it (Sending).
    func merge(_ items: [ConversationItem], sending: [Sending]) -> [ConversationItem] {
        if let merged, merged.items == items, merged.sending == sending { return merged.all }
        let all = Sending.merge(items, sending)
        merged = (items, sending, all)
        return all
    }

    /// The blocks of the first `shown` items: those playback has reached.
    func update(items: [ConversationItem], shown: Int, working: Bool) {
        if let made, made.working == working, made.shown == shown, made.items == items { return }
        made = (items, shown, working)
        blocks = TimelineBlock.of(shown >= items.count ? items : Array(items.prefix(shown)), working: working)
        turns = TimelineBlock.turns(blocks)
    }

    func rows(_ head: [TimelineBlock]) -> [TimelineRow] {
        if let folded, folded.head == head { return folded.rows }
        let rows = TimelineRow.of(head)
        folded = (head, rows)
        return rows
    }
}

/// Playback's clock: ticks at most 30 times a second while something is shown, read out or fading, and not at all
/// otherwise. Its own view, so a tick redraws nothing else: what changed (an item shown, words read) redraws what
/// reads it.
private struct PlaybackClock: View {
    let playback: Playback
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playback.playing)) { context in
            Color.clear.onChange(of: context.date) { _, now in playback.advance(to: now) }
        }
    }
}

/// Shown once playback has caught up with zerod: what comes with a turn's end comes after its last words.
private struct CaughtUp<Content: View>: View {
    let playback: Playback
    @ViewBuilder let content: () -> Content
    var body: some View { if playback.caughtUp { content() } }
}

/// The room at the timeline's foot for the composer and the fade above it: its own view, so the composer's height
/// changing sizes this alone, not the conversation.
private struct EndRoom: View {
    let foot: ConversationView.Foot
    var body: some View { Color.clear.frame(height: foot.height + 32) }
}

/// The conversation's soft edges as a mask, the foot's under the composer: a view of its own, so the composer's height
/// changing redraws the mask, not the conversation (a modifier reading it counted as the conversation reading it).
private struct SoftFoot: View {
    let foot: ConversationView.Foot
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 32)
            // Under the composer only: the conversation runs on behind the question card, which a ring of its own sets
            // apart (Sinker).
            Color.clear.frame(height: foot.composer)
        }
    }
}

/// Room as tall as the composer (and `extra`), for what sits just above it.
private struct FootRoom: View {
    let foot: ConversationView.Foot
    var extra: CGFloat = 0
    /// Short by what the question card sinks.
    var sunk = false
    var body: some View { Color.clear.frame(height: max(0, foot.height - (sunk ? foot.deepest : 0)) + extra).allowsHitTesting(false) }
}

/// What waits on you, on the composer: the agent's asks read here, so one coming or going redraws this, not the
/// conversation. A tab behind what's in front of it, its foot under it (drawn later, over it): the composer, at the
/// queue's inset; or the queue's tab, one inset further back.
private struct DockSlot: View {
    let conversation: Conversation
    let inbox: InboxController
    let playback: Playback
    let foot: ConversationView.Foot
    let page: CGFloat
    let behindQueue: Bool
    let answer: (String, [String: [String]]) -> Void
    let decide: (String, String) -> Void
    let left: () -> Void
    /// Cards that have shown: they stay while playback falls behind again, never going and coming back.
    @State private var shown: Set<String> = []

    var body: some View {
        // A card comes once playback has shown what came before it (the step that asked, the words leading to it), not
        // what came after it, which plays on above it.
        let now = Date()
        let admit = { (id: String) in shown.contains(id) || playback.admits(playback.cardSeen(id, now: now)) }
        let asks = inbox.store.asks.filter { $0.isAgents(in: conversation.id) && !$0.state.isFinal && admit($0.id) }
        let questions = conversation.questions.filter { admit($0.id) }
        let approvals = conversation.approvals.filter { admit($0.id) }
        let ids = questions.map(\.id) + asks.map(\.id) + approvals.map(\.id)
        AskDock(
            session: conversation.id, cwd: conversation.cwd, questions: questions, approvals: approvals,
            asks: asks, inbox: inbox, page: page, foot: foot, answer: answer, decide: decide
        )
        .equatable()
        .padding(.horizontal, behindQueue ? 26 : 13)
        .frame(maxWidth: 680)
        .padding(.bottom, ids.isEmpty ? 0 : -(AskDock.tuck + 8))
        .onChange(of: ids, initial: true) { old, new in
            shown.formUnion(new)
            if !Set(old).subtracting(new).isEmpty { left() }
        }
    }
}

/// Drawn again only when what it's given changes: the task page redraws with the board and the inbox (a question
/// arriving), and handed the same conversation, its `open` a new closure, it redrew every message. Its own state and
/// what it observes still redraw it.
extension ConversationView: Equatable {
    static func == (a: ConversationView, b: ConversationView) -> Bool {
        a.live === b.live && a.workspace === b.workspace && a.inbox === b.inbox && a.active == b.active
            && a.queued == b.queued && a.held == b.held && a.next == b.next
    }
}

/// The question card sinking behind the composer as the conversation is scrolled up from its end, one point for one,
/// until only its strip shows; back up while the pointer is on it. Moved, not faded, and its place kept, so nothing
/// else moves. Its own view reads the scroll (`Sinker`), so a scroll redraws the card's position alone.
struct Sinking: ViewModifier {
    let foot: ConversationView.Foot
    func body(content: Content) -> some View { Sinker(foot: foot, content: content) }
}

private struct Sinker<Card: View>: View {
    let foot: ConversationView.Foot
    let content: Card
    /// Come up from behind the composer: its whole height down at first (clipped at its foot, out of sight), sliding
    /// up on the curve the conversation slides up on as the room at its end grows for the card (EndRoom), the two
    /// starting together.
    @State private var risen = false

    var body: some View {
        content
            .environment(\.dockFocus) { [foot] on in if foot.typing != on { foot.typing = on } }
            // Over the conversation, which runs on behind it: a ring of blur and fade at its edges sets it apart.
            .background { Ring() }
            .onHover { inside in if foot.overCard != inside { foot.overCard = inside } }
            .offset(y: foot.sunk)
            .visualEffect { [risen] card, proxy in card.offset(y: risen ? 0 : proxy.size.height) }
            .animation(.smooth(duration: 0.25), value: foot.hovering)
            // What has sunk is gone below its place (behind the composer), not shown under it; the ring above and at
            // its sides kept.
            .mask { Rectangle().padding(.horizontal, -Ring.width).padding(.top, -Ring.width) }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [foot] in if foot.card != $0 { foot.card = $0 } }
            .onDisappear { [foot] in
                foot.card = 0; foot.overCard = false; foot.typing = false
            }
            .onAppear {
                // There as the conversation opened (waiting already): in place at once. Only one that comes while
                // it's open comes in.
                if Date().timeIntervalSince(foot.opened) < 0.5 { risen = true; return }
                foot.arriving = true
                DispatchQueue.main.async { withAnimation(ConversationView.rise) { risen = true } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [foot] in foot.arriving = false }
            }
    }
}

/// The question card's edge over the conversation behind it: what's just around it blurred and faded, out to a
/// soft edge.
private struct Ring: View {
    static let width: CGFloat = 22
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 18 + Self.width, topTrailingRadius: 18 + Self.width, style: .continuous)
    }
    var body: some View {
        shape.fill(.thinMaterial)
            .overlay(shape.fill(Theme.card.opacity(0.45)))
            .padding(.horizontal, -Self.width).padding(.top, -Self.width)
            .mask { shape.padding(.horizontal, -Self.width / 3).padding(.top, -Self.width / 3).blur(radius: Self.width / 2.5) }
            .allowsHitTesting(false)
    }
}
