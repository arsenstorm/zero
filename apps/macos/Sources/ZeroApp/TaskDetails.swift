import AppKit
import SwiftUI
import ZeroCore

/// The side panel's first tab, the task's details: what needs you first (its status in words, its workers' asks
/// answerable here; its own ask docks in the conversation beside it), then its issues and workers, what it points at,
/// what it left running, the agent on it, and where it works. Nothing hides behind a hover.
struct TaskDetails: View {
    let workspace: Workspace
    /// For answering its workers' asks.
    let inbox: InboxController
    let navigation: Navigation
    let row: BoardRow?
    let conversation: Conversation
    /// Opens a link: in its app when Zero opens it in one, else in a tab of the panel (SidePanel.open).
    let open: (String) -> Void
    /// Every worker listed, not only the ones that need attention.
    @State private var allWorkers = false
    @FocusState private var focus: String?

    /// Folded parts opened: an issue's closed pull requests (by its ticket), and everything done or closed ("more").
    @State private var unfolded: Set<String> = []
    /// As wide as a browser page made the panel: the links get a column of their own, their names whole.
    @State private var wide = false

    var body: some View {
        ScrollView {
            Group {
                if wide && !followed.isEmpty {
                    HStack(alignment: .top, spacing: 40) {
                        column {
                            status; issues; workers; leftRunning; agent; folder
                        }.frame(maxWidth: 460)
                        // Its heading level with the status pill at the top of the other column.
                        column { links }.frame(maxWidth: 600).padding(.top, row == nil ? 0 : -20)
                    }
                } else {
                    // The pane's whole width: link names get the room; only long lines keep a measure (Self.measure).
                    column {
                        status; issues; workers; links; leftRunning; agent; folder
                    }
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .thinScrollbar()
        .onGeometryChange(for: Bool.self) {
            $0.size.width >= 900
        } action: {
            wide = $0
        }
        .task(id: workspace.followingVersion) { await workspace.loadFollowing() }
    }

    /// The most a paragraph runs across (its status in words, a worker's report) before it's hard to read.
    private static let measure: CGFloat = 640

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Status

    /// The pill, the words of its status, when it wakes, a change waiting for its next turn, and its workers' asks.
    @ViewBuilder private var status: some View {
        if let row {
            let asks = row.asks.compactMap { waiting in inbox.store.asks.first { $0.id == waiting.id && $0.session != conversation.id } }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StateLabel(state: row.ownState)
                    if let wakes = row.wakes {
                        Text("Wakes at \(Date(timeIntervalSince1970: TimeInterval(wakes)).formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                if let words = row.trouble ?? row.needs ?? row.now, !words.isEmpty {
                    Text(Self.inline(words)).foregroundStyle(.secondary).tint(Theme.link).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Self.measure, alignment: .leading)
                }
                if let next = nextTurn(row.next) { Text(next).foregroundStyle(.tertiary) }
                ForEach(asks) { ask in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            PixelIcon("px-circle-question", height: 12).foregroundStyle(.secondary)
                            Text(ask.session.flatMap { workspace.names[$0] } ?? "A worker").fontWeight(.medium).lineLimit(1)
                            Text("asks").foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                        // The inbox's card without its frame (a card in a card), lined up with the tab's text.
                        CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false).padding(.horizontal, -16)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// A change picked during a turn, applied as it ends.
    private func nextTurn(_ next: BoardRow.Next?) -> String? {
        guard let next else { return nil }
        let parts = [
            next.model.map { model in
                ComposerRows.catalogue(next.provider ?? conversation.provider).first { $0.id == model }?.name ?? ModelNames.readable(model)
            },
            next.effort.map { effortLabel($0, short: true) },
            next.permissions.map { $0 == .unrestricted ? "unrestricted" : "auto" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : "Next turn: " + parts.joined(separator: " · ")
    }

    // MARK: Issues and workers

    /// Its issues are the board at the top of its conversation (IssueStrip): here, a pill per state, and a way to it.
    @ViewBuilder private var issues: some View {
        let issues = row?.issues ?? []
        if !issues.isEmpty {
            section("Issues") {
                HStack(spacing: 6) {
                    ForEach(IssueBoard.counts(issues), id: \.state) { state, count in Count(state: state, count: count) }
                    Spacer(minLength: 8)
                    Button {
                        NotificationCenter.default.post(name: IssueStrip.show, object: conversation.id)
                    } label: {
                        Self.linked("Open the board")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The few that matter (needing you, in trouble, at work) first, the rest behind their count; a click shows one.
    /// Each line is its worker's (an agent's): the pixel family, by its state, and its latest words.
    @ViewBuilder private var workers: some View {
        let members = (row?.team ?? []).filter { $0.session != conversation.id }.sorted { $0.state.urgency < $1.state.urgency }
        if !members.isEmpty {
            let urgent = members.filter { $0.state.urgency <= 2 }
            let shown = allWorkers ? members : Array((urgent.isEmpty ? members : urgent).prefix(8))
            section("Workers", trailing: members.count > shown.count || allWorkers ? (allWorkers ? "Fewer" : "All \(members.count)") : nil)
            {
                allWorkers.toggle()
            } content: {
                ForEach(shown, id: \.session) { member in
                    Button {
                        navigation.worker = member.session
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Group {
                                if member.state == .working {
                                    TaskStateIcon(state: member.state)
                                } else {
                                    PixelIcon(Self.workerIcon(member.state), height: 12).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 14, height: 16).tip(TaskStateIcon.look(member.state).name)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(workspace.conversation(member.session).map(Workspace.label(of:)) ?? member.place).fontWeight(.medium)
                                    .lineLimit(1)
                                if let now = member.needs ?? member.now, !now.isEmpty {
                                    Text(Self.inline(now)).foregroundStyle(.secondary).tint(.secondary).lineLimit(2)
                                        .frame(maxWidth: Self.measure, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity([.done, .idle, .offline].contains(member.state) ? 0.6 : 1)
                }
            }
        }
    }

    /// A worker's state as AgentIcons words its reports.
    private static func workerIcon(_ state: BoardRow.State) -> String {
        switch state {
        case .needsYou: "px-circle-question"
        case .trouble: "px-robot-angry"
        case .blocked: "px-robot-ban"
        case .done, .handed: "px-robot-heart"
        case .waiting: "px-robot-sleeping"
        default: "px-robot"
        }
    }

    // MARK: Links

    private var followed: [ZerodLink.Followed] { workspace.followed.filter { $0.session == conversation.id } }

    /// The issues its links go under: its board's, done or not, and its own ticket.
    private var linkTickets: [(ticket: String, done: Bool?)] {
        let board: [(ticket: String, done: Bool?)] = IssueBoard.sorted(conversation.issues ?? row?.issues ?? []).map {
            ($0.ticket, $0.state == "done")
        }
        guard let ticket = conversation.ticket, !board.contains(where: { $0.ticket == ticket }) else { return board }
        return board + [(ticket, nil)]
    }

    /// What it follows by issue (LinkGroups): each issue still open with its open pull requests, its closed ones behind
    /// their count; then what's about no issue and its channels; everything done or closed behind one count at the end.
    /// Its own links that it doesn't follow (attributes, its ticket) first.
    @ViewBuilder private var links: some View {
        let own = TaskLinksList.of(conversation, row: row, in: workspace).filter { $0.followed == nil }
        let groups = LinkGroups.of(followed, issues: linkTickets)
        let live = groups.issues.filter { !$0.folded }
        let folded = groups.issues.filter(\.folded)
        let other = groups.other.filter { !($0.closed ?? false) }
        let closed = groups.other.filter { $0.closed ?? false }
        let hidden = folded.reduce(0) { $0 + ($1.issue == nil ? 0 : 1) + $1.changes.reduce(0) { $0 + $1.follows.count } } + closed.count
        if !own.isEmpty || !followed.isEmpty {
            section("Links") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(own) { link in
                        LinkRow(icon: link.icon) { linkWords(link.title, link.url) }
                    }
                    ForEach(live) { issueLinks($0) }
                    if !other.isEmpty || !groups.channels.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(other) { followLine($0) }
                            if !groups.channels.isEmpty { channels(groups.channels) }
                        }
                    }
                    if hidden > 0 {
                        fold("more", "\(hidden) more, done or closed")
                        if unfolded.contains("more") {
                            ForEach(folded) { issueLinks($0) }
                            if !closed.isEmpty { VStack(alignment: .leading, spacing: 4) { ForEach(closed) { followLine($0) } } }
                        }
                    }
                }
            }
        }
    }

    /// An issue: its ticket, its name and status, then its open pull requests, the closed ones behind their count.
    private func issueLinks(_ group: LinkGroups.Issue) -> some View {
        let live = group.changes.filter { !$0.closed }
        let closed = group.changes.filter(\.closed)
        let count = closed.reduce(0) { $0 + $1.follows.count }
        return VStack(alignment: .leading, spacing: 4) {
            LinkRow(icon: "ticket", pill: group.issue?.state.map { ($0, .secondary) }, unfollow: group.issue.map(unfollowing)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    let url = group.issue?.url ?? Self.ticketURL(group.ticket)
                    if let url {
                        Button {
                            open(url.absoluteString)
                        } label: {
                            Self.linked(group.ticket)
                        }.buttonStyle(.plain).fixedSize().tip(url.absoluteString)
                    } else {
                        Text(group.ticket).fontWeight(.medium).fixedSize()
                    }
                    if let issue = group.issue { name(issue.name ?? issue.title, error: issue) }
                }
            }
            ForEach(live) { change($0) }
            if !closed.isEmpty {
                if unfolded.contains(group.ticket) {
                    ForEach(closed) { change($0) }
                } else {
                    fold(group.ticket, "\(count) \(closed.allSatisfy { $0.state == "merged" } ? "merged" : "closed")")
                }
            }
        }
    }

    /// A pull request, or the same change in several repositories: each one's repo#number, its name, its state.
    private func change(_ change: LinkGroups.Change) -> some View {
        LinkRow(icon: "github:glyph", pill: change.state.map(Self.pill)) {
            Task { for follow in change.follows { await workspace.unfollow(session: follow.session, topic: follow.topic) } }
        } words: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(change.follows) { follow in
                        Button {
                            open(follow.url?.absoluteString ?? "")
                        } label: {
                            Self.linked(Self.shown(follow.url?.absoluteString ?? follow.topic))
                        }
                        .buttonStyle(.plain).fixedSize().tip(follow.url?.absoluteString ?? "")
                    }
                }
                name(change.name, error: change.follows.first { $0.error != nil })
            }
        }
    }

    /// A followed thing about no issue: a pull request or issue by its number and name, a thread by its line.
    private func followLine(_ follow: ZerodLink.Followed) -> some View {
        let icon = ["github": "github:glyph", "linear": "ticket", "slack": "slack:glyph"][follow.source] ?? "link"
        let url = follow.url?.absoluteString ?? ""
        return LinkRow(icon: icon, pill: follow.state.map(Self.pill), unfollow: unfollowing(follow)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let thing = follow.name {
                    let ref = follow.source == "github" ? Self.shown(url) : String(follow.topic.split(separator: "/").last ?? "")
                    Button {
                        open(url)
                    } label: {
                        Self.linked(ref)
                    }.buttonStyle(.plain).fixedSize().tip(url)
                    name(thing, error: follow)
                } else {
                    Button {
                        open(url)
                    } label: {
                        Self.linked(follow.title).lineLimit(1).truncationMode(.tail)
                    }.buttonStyle(.plain).tip(url)
                }
            }
        }
    }

    /// Its channels in a line, each its own link (an × to unfollow under the pointer).
    private func channels(_ follows: [ZerodLink.Followed]) -> some View {
        LinkRow(icon: "slack:glyph") {
            WrappingStack(spacing: 8) {
                ForEach(follows) { follow in
                    ChannelChip(name: follow.title, url: follow.url?.absoluteString ?? "", open: open, unfollow: unfollowing(follow))
                }
            }
        }
    }

    /// A thing's name: whole when the links have a column of their own, else cut at its end; that polling
    /// it fails, while it does.
    @ViewBuilder private func name(_ text: String, error follow: ZerodLink.Followed?) -> some View {
        if let follow, let error = follow.error {
            Text("Can't reach \(Self.service(follow.source)) · retrying").foregroundStyle(.tertiary).lineLimit(1).tip(error)
        } else {
            Text(text).foregroundStyle(.secondary).lineLimit(wide ? nil : 1).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: wide)
        }
    }

    /// A folded part's count: a click shows what's behind it.
    private func fold(_ key: String, _ words: String) -> some View {
        Button {
            if unfolded.contains(key) { unfolded.remove(key) } else { unfolded.insert(key) }
        } label: {
            HStack(spacing: 8) {
                NucleoIcon("chevron-right", size: 10).foregroundStyle(.tertiary).rotationEffect(.degrees(unfolded.contains(key) ? 90 : 0))
                    .frame(width: 14)
                Text(words).foregroundStyle(.secondary)
            }
            .frame(minHeight: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unfollowing(_ follow: ZerodLink.Followed) -> () -> Void {
        { Task { await workspace.unfollow(session: follow.session, topic: follow.topic) } }
    }

    /// A pull request's state as GitHub colours it; an issue's status grey, as each team names its own.
    private static func pill(_ state: String) -> (String, Color) {
        let color: Color = ["merged": .purple, "open": .green, "closed": .red][state] ?? .secondary
        return (state.prefix(1).uppercased() + state.dropFirst(), color)
    }

    static func service(_ source: String) -> String {
        ["github": "GitHub", "linear": "Linear", "slack": "Slack"][source] ?? source
    }

    /// One of its own links it doesn't follow (an attribute, its ticket): a link, or words.
    @ViewBuilder private func linkWords(_ title: String, _ url: String) -> some View {
        if url.isEmpty {
            Text(title).lineLimit(1).truncationMode(.middle)
        } else {
            Button {
                open(url)
            } label: {
                Self.linked(title).truncationMode(.middle)
            }.buttonStyle(.plain).tip(url)
        }
    }

    @ViewBuilder private var leftRunning: some View {
        if let left = workspace.left[conversation.id] {
            section("Left running", trailing: left.things.count > 1 ? "Stop all" : nil) {
                Task { await workspace.stopLeft(conversation.id) }
            } content: {
                LeftRunningRows(workspace: workspace, session: conversation.id, things: left.things)
            }
        }
    }

    // MARK: Agent and folder

    private var agent: some View {
        section("Agent") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                property("Model") {
                    HStack(spacing: 5) {
                        if let mark = conversation.provider.mark {
                            mark.resizable().aspectRatio(contentMode: .fit).frame(width: 13, height: 13).clipShape(
                                RoundedRectangle(cornerRadius: 3))
                        }
                        Text(
                            ModelNames.agent(
                                modelName ?? conversation.provider.title, effort: conversation.effort.map { effortLabel($0, short: true) },
                                advisor: advisor)
                        )
                        .lineLimit(1).tip([conversation.provider.title, conversation.model].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                property("Acts") {
                    if conversation.permissions == .unrestricted {
                        HStack(spacing: 5) {
                            NucleoIcon("bolt-lightning", fill: "glyph", size: 12).foregroundStyle(.orange)
                            Text("Without asking")
                        }
                    } else {
                        Text("Asks before what isn't safe")
                    }
                }
                if let signin = workspace.signins.first(where: { $0.id == conversation.signin }) {
                    property("Account") { account(signin) }
                }
                property("Uses") { uses }
            }
        }
    }

    /// The sign-in it runs as, and how much of its five hours is used.
    private func account(_ signin: ZerodLink.SignIn) -> some View {
        HStack(spacing: 6) {
            Text([signin.label, signin.plan].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
            if let usage = workspace.signinUsage[signin.id], let window = usage.windows.first(where: { $0.name != "7 days" }) {
                let used = UsageShown.used(window, now: Int(Date().timeIntervalSince1970))
                Capsule().fill(Theme.chip).frame(width: 44, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.secondary).frame(width: 44 * min(1, used)) }
                Text("\(Int((used * 100).rounded()))% of 5 hours").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
        }
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

    private var folder: some View {
        section("Folder") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                property("Where") {
                    // The place's own folder when the places command says (a bench's), else the task's: a project by its
                    // name, any other folder (a new one of its own in ~/Zero) by its path.
                    let folder = row?.path ?? conversation.cwd
                    let shown =
                        row?.place
                        ?? (Projects.folders.contains(conversation.cwd)
                            ? Projects.name(of: conversation.cwd) : (conversation.cwd as NSString).abbreviatingWithTildeInPath)
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                    } label: {
                        Self.linked(shown).truncationMode(.middle)
                    }
                    .buttonStyle(.plain).tip("Show \((folder as NSString).abbreviatingWithTildeInPath) in Finder")
                }
                if let branch = conversation.branch {
                    property("Branch") { Text(branch).lineLimit(1).truncationMode(.middle).tip(branch) }
                }
                // Finder, an editor, the terminal app in its folder: the last one used, or the list.
                property("Open in") { OpenInButton(workspace: workspace, conversation: conversation) }
                // The task in the user's own terminal app, on its CLI's own resume; back once that CLI exits.
                property("Continue") {
                    let open = conversation.terminal != nil
                    Button {
                        Task { open ? await workspace.closeTerminal(conversation.id) : await workspace.openTerminal(conversation.id) }
                    } label: {
                        Self.linked(open ? "Back to Zero" : "In \(TerminalApp.shared.name)")
                    }
                    .buttonStyle(.plain).disabled(!open && conversation.thread == nil)
                    .tip(!open && conversation.thread == nil ? "Its CLI hasn't started a session to resume yet" : "")
                }
            }
        }
    }

    // MARK: Parts

    /// A section: its heading (and an action at its right, as All 3 or Stop all), then its rows.
    private func section(
        _ title: String, trailing: String? = nil, action: @escaping () -> Void = {}, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Button(trailing, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.top, 20)
            content()
        }
    }

    private func property(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The ticket's page: Linear's link for its team's workspace.
    static func ticketURL(_ ticket: String) -> URL? {
        guard let team = ticket.split(separator: "-").first, let space = LinearTeams.known[String(team)] else { return nil }
        // The web link: the panel's opener turns it into the app's when the user has Linear links open there.
        return URL(string: "https://linear.app/\(space)/issue/\(ticket)")
    }

    /// Its value as a link (opened in the panel) when it is one, plain words otherwise.
    @ViewBuilder private func link(_ text: String, to url: URL?) -> some View {
        if let url {
            Button {
                open(url.absoluteString)
            } label: {
                Self.linked(text)
            }
            .buttonStyle(.plain).tip(url.absoluteString)
        } else {
            Text(text).lineLimit(2)
        }
    }

    private var advisor: String? {
        guard conversation.provider == .claude, let advisor = conversation.advisor else { return nil }
        return ClaudeModels.advisors(for: conversation.model ?? "").contains { $0.id == advisor } ? advisor : nil
    }

    private var modelName: String? {
        guard let model = conversation.model else { return nil }
        return ComposerRows.catalogue(conversation.provider).first { $0.id == model }?.name ?? ModelNames.readable(model)
    }

    // MARK: Shared with other views

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }

    /// Something that opens: a little heavier, on a dashed underline; no icon, no blue.
    static func linked(_ text: String) -> some View {
        Text(text).fontWeight(.medium).lineLimit(1)
            // Drawn, not the system's underline, which sits too far below the words: just under the baseline.
            .overlay(alignment: .bottom) {
                Rule().stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 1).offset(y: -1.5)
            }
            .pointerStyle(.link)
    }

    /// A line across, for the dashed underline.
    private struct Rule: Shape {
        func path(in rect: CGRect) -> Path {
            Path {
                $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
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
}

/// Everything a task points at, once each: its pull request (set with `zero attr`, else the latest its words
/// mention), its ticket, its other attributes, and what it follows. A followed one carries its latest line, or that
/// polling it fails.
struct TaskLinksList: Identifiable, Equatable {
    var id: String { url.isEmpty ? title : url }
    var icon: String
    var title: String
    var url: String
    /// Its latest line from following it ("Retry failed payments · open"), or nil.
    var detail: String?
    var followed: ZerodLink.Followed?

    @MainActor static func of(_ conversation: Conversation, row: BoardRow?, in workspace: Workspace) -> [TaskLinksList] {
        let follows = workspace.followed.filter { $0.session == conversation.id }
        var links: [TaskLinksList] = []
        var attributes = (conversation.attributes ?? [:]).sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
        if !attributes.contains(where: { $0.name.uppercased() == "PR" }), let found = mentionedPR(conversation, row: row, in: workspace) {
            attributes.insert((name: "PR", value: found), at: 0)
        }
        for (name, value) in attributes {
            let follow = follows.first { $0.url?.absoluteString == value }
            let icon = value.contains("github.com") ? "github:glyph" : TaskDetails.url(value) == nil ? "text" : "link"
            let title = TaskDetails.url(value) == nil ? "\(name): \(value)" : TaskDetails.shown(value)
            links.append(
                TaskLinksList(
                    icon: icon, title: title, url: TaskDetails.url(value) == nil ? "" : value, detail: follow?.title, followed: follow))
        }
        if let ticket = conversation.ticket {
            let team = String(ticket.split(separator: "-").first ?? "")
            let url = LinearTeams.known[team].map { "https://linear.app/\($0)/issue/\(ticket)" } ?? ""
            let follow = follows.first { $0.topic.hasSuffix(ticket) }
            links.append(TaskLinksList(icon: "ticket", title: ticket, url: url, detail: follow?.title, followed: follow))
        }
        for follow in follows where !links.contains(where: { $0.followed == follow }) {
            let icon = ["github": "github:glyph", "linear": "ticket", "slack": "slack:glyph"][follow.source] ?? "link"
            links.append(TaskLinksList(icon: icon, title: follow.title, url: follow.url?.absoluteString ?? "", followed: follow))
        }
        return links
    }

    /// The latest pull request the task's words mention, as a GitHub link.
    @MainActor private static func mentionedPR(_ conversation: Conversation, row: BoardRow?, in workspace: Workspace) -> String? {
        let texts =
            [row?.asks.first?.title, row?.needs, row?.now].compactMap { $0 }
            + (workspace.live(conversation.id)?.conversation.items ?? []).reversed().compactMap { item -> String? in
                switch item.kind {
                case let .agent(text, _), let .user(text, _): text
                default: nil
                }
            }
        return texts.lazy.compactMap { $0.firstMatch(of: #/https://github\.com/[\w.-]+/[\w.-]+/pull/\d+/#).map { String($0.0) } }.first
    }
}

/// A line of the task's links: its kind's icon, its words, its state as a pill, and an × to unfollow under the pointer.
private struct LinkRow<Words: View>: View {
    let icon: String
    var pill: (String, Color)?
    var unfollow: (() -> Void)?
    @ViewBuilder let words: Words
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            NucleoIcon(icon, size: 12).foregroundStyle(.tertiary).frame(width: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            // 2.5 above and below: a line's 20 pt, and a wrapped one keeps the same gap to the next row.
            words.padding(.vertical, 2.5).frame(maxWidth: .infinity, alignment: .leading)
            // The × takes the pill's place under the pointer, so the pills end at the column's edge and nothing moves.
            if let pill {
                StatePill(text: pill.0, color: pill.1).fixedSize().opacity(hovered && unfollow != nil ? 0 : 1)
                    .overlay(alignment: .trailing) { if hovered { cross } }
            } else if unfollow != nil {
                cross.opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .contentShape(Rectangle()).onHover { hovered = $0 }
    }

    @ViewBuilder private var cross: some View {
        if let unfollow {
            Button(action: unfollow) {
                NucleoIcon("xmark", size: 11).foregroundStyle(.secondary).frame(width: 18, height: 18)
            }
            .buttonStyle(Hovering(radius: 5)).tip("Unfollow")
        }
    }
}

/// A followed channel among others in a line: its name, and an × to unfollow it under the pointer, its place kept.
private struct ChannelChip: View {
    let name: String
    let url: String
    let open: (String) -> Void
    let unfollow: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                open(url)
            } label: {
                TaskDetails.linked(name)
            }.buttonStyle(.plain).fixedSize().tip(url)
            Button(action: unfollow) { NucleoIcon("xmark", size: 9).foregroundStyle(.secondary).frame(width: 12, height: 12) }
                .buttonStyle(.plain).tip("Unfollow").opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
        }
        .onHover { hovered = $0 }
    }
}
