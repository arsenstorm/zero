import AppKit
import SwiftUI
import ZeroCore

/// The pane on a task's right: where it stands, what it needs from you, the agent on it, where it works, its workers.
struct TaskDetails: View {
    let workspace: Workspace
    /// For answering what it's blocked on, from its status.
    let inbox: InboxController
    let navigation: Navigation
    let row: BoardRow?
    let conversation: Conversation
    /// Beside a terminal: a full-height column on the sidebar's grey rather than a floating card.
    var docked = false
    /// How far in from the panel's edges it floats, and its corners: together the panel's radius (12).
    static let inset: CGFloat = 6
    static let radius: CGFloat = 12 - inset
    /// The status card, beside the pane level with the Status row: open while the pointer is on the pill or the card,
    /// held once clicked into (an answer being typed) until a click outside it or Esc.
    @State private var peek = false
    @State private var peekY: CGFloat = 0
    @State private var overPill = false
    @State private var overCard = false
    @State private var held = false
    @State private var cardFrame = CGRect.zero
    @State private var monitor: Any?
    /// Every worker listed, not only the ones that need attention.
    @State private var allWorkers = false

    var body: some View {
        // Its properties, then its issues and its workers.
        VStack(alignment: .leading, spacing: 0) {
            properties; issues; workers; leftRunning; follows
        }.padding(16)
            .frame(width: 280, alignment: .leading)
            .frame(maxHeight: docked ? .infinity : nil, alignment: .top)
            // Concentric with the panel's corner it sits in: its radius and its inset add up to the panel's (6 + 6 = 12).
            .background(docked ? Theme.composer : Theme.card, in: RoundedRectangle(cornerRadius: docked ? 0 : Self.radius))
            .overlay { if !docked { RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Theme.stroke) } }
            .compositingGroup()
            .shadow(color: .black.opacity(docked ? 0 : 0.04), radius: 10, y: 2)
            .coordinateSpace(name: "details")
            .overlay(alignment: .topLeading) {
                if peek, let row {
                    StatusCard(row: row, inbox: inbox)
                        .onHover { inside in
                            overCard = inside; if !inside { closeSoon() }
                        }
                        .simultaneousGesture(TapGesture().onEnded { hold() })
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: {
                            cardFrame = $0
                        }
                        .offset(x: -(StatusCard.width + 8), y: max(0, peekY - 14))
                }
            }
            .onDisappear(perform: release)
    }

    /// A moment to cross from the pill to the card; held, it stays.
    private func closeSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if !overPill && !overCard && !held { peek = false }
        }
    }

    /// Clicked into: it stays until a click outside it, or Esc.
    private func hold() {
        guard !held else { return }
        held = true
        let (frame, close) = ({ cardFrame }, { release() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                close()
                return nil
            }
            guard let content = event.window?.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !frame().contains(point) { close() }
            return event
        }
    }

    private func release() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = false
        peek = false
    }

    /// The agent on it, where it works, its status (its detail, and what it's blocked on, on hover), then what its agent
    /// says about it: its branch, ticket, and whatever it set with `zero attr` (a PR, say); a link opens.
    private var properties: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            property("Agent") {
                // What it runs on, to read: the provider's mark and the model by its name ("Opus 5.5"). It's changed
                // in the composer, not here.
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        if let mark = conversation.provider.mark {
                            mark.resizable().aspectRatio(contentMode: .fit).frame(width: 13, height: 13).clipShape(
                                RoundedRectangle(cornerRadius: 3))
                        }
                        Text(
                            [modelName ?? conversation.provider.title, conversation.effort.map { effortLabel($0, short: true) }].compactMap
                            { $0 }.joined(separator: " · ")
                        )
                        .lineLimit(1).truncationMode(.tail).tip(
                            [conversation.provider.title, conversation.model].compactMap { $0 }.joined(separator: " · "))
                    }
                    // Unrestricted: a bolt beside the agent, as the composer's permissions chip shows it.
                    if conversation.permissions == .unrestricted {
                        // A square to hover, so the tip shows: a bare icon gives macOS nothing to track.
                        NucleoIcon("bolt-lightning", fill: "glyph", size: 13).foregroundStyle(.orange)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                            .tip("Unrestricted: it acts without asking")
                    }
                }
            }
            property("Where") {
                // The place's own folder when the places command says (a bench's), else the task's.
                let folder = row?.path ?? conversation.cwd
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                } label: {
                    Self.linked(row?.place ?? Projects.name(of: conversation.cwd)).truncationMode(.middle)
                }
                .buttonStyle(.plain).tip("Show \((folder as NSString).abbreviatingWithTildeInPath) in Finder")
            }
            if let row {
                property("Status") {
                    StateLabel(state: row.ownState)
                        .onHover { inside in
                            overPill = inside
                            if inside { peek = true } else { closeSoon() }
                        }
                        .onGeometryChange(for: CGFloat.self) {
                            $0.frame(in: .named("details")).minY
                        } action: {
                            peekY = $0
                        }
                }
            }
            // Finder, an editor, the terminal app in its folder: the last one used, or the list.
            property("Open in") { OpenInButton(workspace: workspace, conversation: conversation) }
            // The task in the user's own terminal app, on its CLI's own resume; back once that CLI exits.
            property("Terminal") {
                let open = conversation.terminal != nil
                Button {
                    Task { open ? await workspace.closeTerminal(conversation.id) : await workspace.openTerminal(conversation.id) }
                } label: {
                    Self.linked(open ? "Back to Zero" : "Continue in \(TerminalApp.shared.name)")
                }
                .buttonStyle(.plain).disabled(!open && conversation.thread == nil)
            }
            property("Uses") { uses }
            if let branch = conversation.branch {
                property("Branch") { Text(branch).lineLimit(1).truncationMode(.middle).tip(branch) }
            }
            if let ticket = conversation.ticket {
                property("Ticket") { link(ticket, to: ticketURL(ticket)) }
            }
            ForEach(attributes, id: \.name) { attribute in
                property(attribute.name) { link(Self.shown(attribute.value), to: Self.url(attribute.value)) }
            }
        }
        .font(.system(size: 12.5))
    }

    /// What its processes use now, the split on hover; a dash while nothing runs (parked), keeping the row's place.
    @ViewBuilder private var uses: some View {
        if let uses = workspace.uses[conversation.id] {
            let parts = [
                (conversation.provider.title, uses.cli), ("MCP servers", uses.mcp), ("commands", uses.commands),
            ].filter { $0.1.memory > 0 }.map { "\($0.0) \(Self.bytes($0.1.memory))" }
            Text("\(Self.bytes(uses.memory)) · \(Int(uses.cpu.rounded()))% CPU").monospacedDigit().lineLimit(1)
                .tip(parts.joined(separator: " · "))
        } else {
            Text("–").foregroundStyle(.secondary).tip("Nothing running: its agent is parked until there's work")
        }
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }

    /// The issues a lead keeps a row for (`zero issue`): each one's state, ticket and where it stands. One with a
    /// worker of its own opens it; the ticket opens its page.
    @ViewBuilder private var issues: some View {
        let issues = (row?.issues ?? []).sorted { $0.boardState.urgency < $1.boardState.urgency }
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Issues").foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 2)
                TimelineView(.everyMinute) { now in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(issues) { issue in issueRow(issue, now: now.date) }
                    }
                }
            }
            .font(.system(size: 12.5))
        }
    }

    private func issueRow(_ issue: BoardRow.Issue, now: Date) -> some View {
        let own = (row?.team ?? []).first { member in workspace.conversations.first { $0.id == member.session }?.ticket == issue.ticket }
        return HStack(alignment: .top, spacing: 7) {
            TaskStateIcon(state: issue.boardState).frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    link(issue.ticket, to: ticketURL(issue.ticket))
                    if let waiting = issue.waiting(at: now) { Text(waiting).monospacedDigit().foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let own { Button("Open") { navigation.worker = own.session }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                if !issue.text.isEmpty { Text(issue.text).foregroundStyle(.secondary).lineLimit(3) }
            }
        }
        .opacity(["done", "parked"].contains(issue.state) ? 0.6 : 1)
    }

    /// Its workers, what each is on and where it stands, most urgent first; a click shows that worker.
    @ViewBuilder private var workers: some View {
        let members = (row?.team ?? []).filter { $0.session != conversation.id }.sorted { $0.state.urgency < $1.state.urgency }
        if !members.isEmpty {
            // The few that matter (needing you, in trouble, at work), the rest behind their count; opened, the whole
            // list scrolls inside the pane rather than running off the window.
            let urgent = members.filter { $0.state.urgency <= 2 }
            let shown = allWorkers ? members : Array((urgent.isEmpty ? members : urgent).prefix(8))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Workers").foregroundStyle(.secondary)
                    Spacer()
                    if members.count > shown.count || allWorkers {
                        Button(allWorkers ? "Fewer" : "All \(members.count)") { allWorkers.toggle() }.buttonStyle(.plain).foregroundStyle(
                            .secondary)
                    }
                }
                .padding(.top, 14).padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { workerRows(shown) }
                }
                .thinScrollbar()
                .frame(maxHeight: allWorkers ? 360 : .infinity)
                .fixedSize(horizontal: false, vertical: !allWorkers)
            }
            .font(.system(size: 12.5))
        }
    }

    /// What its commands left running (zerod's left.rs): a dev server, a simulator, containers; each with Stop.
    @ViewBuilder private var leftRunning: some View {
        if let left = workspace.left[conversation.id] {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Left running").foregroundStyle(.secondary)
                    Spacer()
                    if left.things.count > 1 {
                        Button("Stop all") { Task { await workspace.stopLeft(conversation.id) } }.buttonStyle(.plain).foregroundStyle(
                            .secondary)
                    }
                }
                .padding(.top, 14).padding(.bottom, 2)
                LeftRunningRows(workspace: workspace, session: conversation.id, things: left.things)
            }
            .font(.system(size: 12.5))
        }
    }

    /// What it follows (zero follow): each thing opens on a click, and its × unfollows it.
    @ViewBuilder private var follows: some View {
        let follows = workspace.followed.filter { $0.session == conversation.id }
        VStack(alignment: .leading, spacing: 6) {
            if !follows.isEmpty {
                Text("Follows").foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 2)
                ForEach(follows) { follow in
                    FollowLine(follow: follow) { Task { await workspace.unfollow(session: follow.session, topic: follow.topic) } }
                }
            }
        }
        .font(.system(size: 12.5))
        .task(id: workspace.followingVersion) { await workspace.loadFollowing() }
    }

    @ViewBuilder private func workerRows(_ members: [BoardRow.Member]) -> some View {
        ForEach(members, id: \.session) { member in
            Button {
                navigation.worker = member.session
            } label: {
                HStack(alignment: .top, spacing: 7) {
                    TaskStateIcon(state: member.state).frame(width: 14, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(of: member)).fontWeight(.medium).lineLimit(1)
                        if let now = member.needs ?? member.now, !now.isEmpty {
                            Text(now).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity([.done, .idle, .offline].contains(member.state) ? 0.6 : 1)
        }
    }

    private func title(of member: BoardRow.Member) -> String {
        workspace.conversations.first { $0.id == member.session }.map(Workspace.label(of:)) ?? member.place
    }

    /// A row of the pane's properties: its name in a narrow column, its value beside it.
    private func property(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.leading).frame(width: 52, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The ticket's page: Linear's link for its team's workspace.
    private func ticketURL(_ ticket: String) -> URL? {
        guard let team = ticket.split(separator: "-").first, let space = LinearTeams.known[String(team)] else { return nil }
        return LinearLinks.url("https://linear.app/\(space)/issue/\(ticket)")
    }

    /// Something that opens, as the pane shows it: a little heavier, on a dashed underline; no icon, no blue.
    static func linked(_ text: String) -> some View {
        Text(text).fontWeight(.medium).lineLimit(1)
            // Drawn, not the system's underline, which sits too far below the words: just under the baseline.
            .overlay(alignment: .bottom) {
                Rule().stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 1).offset(y: -1.5)
            }
    }

    /// A followed thing: its title, opened on a click; unfollowed from the × on hover.
    private struct FollowLine: View {
        let follow: ZerodLink.Followed
        let unfollow: () -> Void
        @State private var hovered = false
        var body: some View {
            HStack(spacing: 6) {
                Button {
                    if let url = follow.url { NSWorkspace.shared.open(url) }
                } label: {
                    TaskDetails.linked(follow.title).truncationMode(.middle)
                }
                .buttonStyle(.plain).tip(follow.error.map { "Can't read it: \($0)" } ?? follow.topic)
                Spacer(minLength: 0)
                Button(action: unfollow) { NucleoIcon("xmark", size: 11).foregroundStyle(.secondary).frame(width: 18, height: 18) }
                    .buttonStyle(Hovering(radius: 5)).tip("Unfollow").opacity(hovered ? 1 : 0)
            }
            .contentShape(Rectangle()).onHover { hovered = $0 }
        }
    }

    /// A line across, for the dashed underline.
    private struct Rule: Shape {
        func path(in rect: CGRect) -> Path {
            Path {
                $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }

    /// Its value as a link when it is one, plain words otherwise.
    @ViewBuilder private func link(_ text: String, to url: URL?) -> some View {
        if let url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Self.linked(text)
            }
            .buttonStyle(.plain).tip("Open " + url.absoluteString)
        } else {
            Text(text).lineLimit(2)
        }
    }

    /// What its agent set (`zero attr`), by name; a pull request the conversation mentions, until one's set.
    private var attributes: [(name: String, value: String)] {
        var all = (conversation.attributes ?? [:]).sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
        if !all.contains(where: { $0.name.uppercased() == "PR" }), let found = mentionedPR { all.insert((name: "PR", value: found), at: 0) }
        return all
    }

    /// The latest pull request the task's words mention, as a GitHub link.
    private var mentionedPR: String? {
        let texts =
            [row?.asks.first?.title, row?.needs, row?.now].compactMap { $0 }
            + (workspace.live(conversation.id)?.conversation.items ?? []).reversed().compactMap { item -> String? in
                switch item.kind {
                case let .agent(text, _), let .user(text, _): text;
                default: nil
                }
            }
        return texts.lazy.compactMap { $0.firstMatch(of: #/https://github\.com/[\w.-]+/[\w.-]+/pull/\d+/#).map { String($0.0) } }.first
    }

    /// A GitHub pull request as "repo#123"; any other link without its scheme; words as they are.
    static func shown(_ value: String) -> String {
        if let pr = value.firstMatch(of: #/github\.com/[\w.-]+/([\w.-]+)/pull/(\d+)/#) { return "\(pr.1)#\(pr.2)" }
        if value.hasPrefix("https://") || value.hasPrefix("http://") {
            return String(value.split(separator: "/", maxSplits: 1).last ?? Substring(value)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
        }
        return value
    }

    static func url(_ value: String) -> URL? {
        guard value.hasPrefix("https://") || value.hasPrefix("http://") else { return nil }
        return URL(string: value)
    }

    /// The model as its provider's catalogue names it; nil leaves the provider's name (its default model).
    private var modelName: String? {
        guard let model = conversation.model else { return nil }
        return ComposerRows.catalogue(conversation.provider).first { $0.id == model }?.name ?? ModelNames.readable(model)
    }
}
