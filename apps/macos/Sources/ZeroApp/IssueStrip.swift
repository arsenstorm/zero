import AppKit
import SwiftUI
import ZeroCore

/// A lead's issues (`zero issue`) as one live board at the top of its conversation, so its messages carry only what
/// changed and what it decided. Closed, a 36 pt strip: how many, a pill per state, and the first that's on the user.
/// Opened, the board drops over the page (never pushing it): a row per issue, as tall as its words, with its PR,
/// what it needs from the user and the lead's own columns (`zero issue --pr --needs --field`), in zerod's order as it
/// opens and kept so while open (a changed row stays put, its cell lit a moment); a row opened shows a worker's ask,
/// answerable there, and the states it went through. One issue, and the strip is its row.
struct IssueStrip: View {
    let workspace: Workspace
    let inbox: InboxController
    let navigation: Navigation
    /// The lead's conversation, its issues with their steps.
    let conversation: Conversation
    /// Its board row: its workers, for each issue's ask and links.
    let row: BoardRow?
    let open: (String) -> Void

    /// The strip's height and the room above and below it: the conversation starts under it.
    static let height: CGFloat = 36
    static let room: CGFloat = height + 16
    /// Told by the details pane's Issues line: open this session's board.
    static let show = Notification.Name("IssueStrip.show")

    @State private var opened = false
    @State private var order: [String] = []
    @State private var expanded: String?
    @State private var hovered: String?
    @State private var lit: [String: Set<IssueBoard.Cell>] = [:]
    @FocusState private var focus: String?
    /// The board's own height, so it's as tall as its rows up to its most, and scrolls past that.
    @State private var boardHeight: CGFloat = 0

    private var issues: [BoardRow.Issue] { conversation.issues ?? [] }

    var body: some View {
        GeometryReader { page in
            VStack(spacing: 0) {
                if issues.count == 1, let only = issues.first {
                    row(only, now: Date(), headed: false)
                } else {
                    strip
                    if opened {
                        Hairline()
                        board(most: page.size.height * 0.6 - Self.height)
                    }
                }
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .compositingGroup().shadow(color: .black.opacity(opened || expanded != nil ? 0.12 : 0), radius: 12, y: 4)
            .frame(maxWidth: 760 + 36)
            .padding(.horizontal, 22).padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: issues, initial: true) { before, after in light(before == after ? [] : before, after) }
        .onReceive(NotificationCenter.default.publisher(for: Self.show)) { note in
            if note.object as? String == conversation.id, !opened { toggle() }
        }
    }

    private func toggle() {
        if !opened { order = IssueBoard.sorted(issues).map(\.ticket) }
        withAnimation(Motion.animation(.easeOut(duration: 0.18))) { opened.toggle() }
        if !opened { expanded = nil }
    }

    /// The cells a change touched, lit, and the wash fading out after a moment.
    private func light(_ before: [BoardRow.Issue], _ after: [BoardRow.Issue]) {
        let changed = IssueBoard.changed(from: before, to: after)
        guard !changed.isEmpty else { return }
        lit.merge(changed) { $0.union($1) }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.6)) { for ticket in changed.keys { lit[ticket] = nil } }
        }
    }

    // MARK: Strip

    private var strip: some View {
        // What's on the user: one with an ask to answer first.
        let theirs = IssueBoard.sorted(issues).filter { ["you", "over"].contains($0.state) }
        let first = theirs.first { ask($0) != nil } ?? theirs.first
        return HStack(spacing: 10) {
            Text("Issues").font(.system(size: 12.5, weight: .medium))
            Text("\(issues.count)").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                ForEach(IssueBoard.counts(issues), id: \.state) { state, count in Count(state: state, count: count) }
            }
            Spacer(minLength: 8)
            if let first {
                HStack(spacing: 5) {
                    if first.state == "you" { PixelIcon("px-circle-question", height: 12).foregroundStyle(.blue) }
                    Text(first.ticket).foregroundStyle(.secondary)
                    Text(needs(first) ?? first.text).fontWeight(.medium).foregroundStyle(.primary)
                }
                .font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            }
            NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(opened ? 180 : 0))
        }
        .padding(.horizontal, 14).frame(height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    // MARK: Board

    private func board(most: CGFloat) -> some View {
        ScrollView {
            TimelineView(.everyMinute) { now in
                VStack(spacing: 0) {
                    head
                    ForEach(Array(IssueBoard.kept(issues, order: order).enumerated()), id: \.element.ticket) { _, issue in
                        Hairline()
                        row(issue, now: now.date, headed: true)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { boardHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .thinScrollbar()
        .frame(height: min(boardHeight, max(most, 120)))
    }

    /// The lead's own columns (`--field`), in the order any row first gave them.
    private var fieldNames: [String] {
        var names: [String] = []
        for field in issues.flatMap({ $0.fields ?? [] }) where !names.contains(field.name) { names.append(field.name) }
        return names
    }

    private var head: some View {
        HStack(spacing: Column.gap) {
            Text("State").frame(width: Column.state, alignment: .leading)
            Text("Issue").frame(width: Column.issue, alignment: .leading)
            Text("PR").frame(width: Column.pr, alignment: .leading)
            Text("Where it stands").frame(maxWidth: .infinity, alignment: .leading)
            Text("Needs you").frame(width: Column.needs, alignment: .leading)
            ForEach(fieldNames, id: \.self) { Text($0).lineLimit(1).frame(width: Column.field, alignment: .leading) }
            Color.clear.frame(width: Column.age, height: 1)
        }
        .font(.system(size: 12, weight: .medium)).tracking(-0.2)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.tint)
    }

    private enum Column {
        static let gap: CGFloat = 12
        static let state: CGFloat = 96, issue: CGFloat = 70, pr: CGFloat = 126, needs: CGFloat = 140, field: CGFloat = 80
        static let age: CGFloat = 28
    }

    /// One issue: its line, as tall as its words (up to three lines each) and never under 40 pt; opened, its worker's
    /// ask and its steps. `headed`: under the board's headings; alone (one issue), the strip itself.
    private func row(_ issue: BoardRow.Issue, now: Date, headed: Bool) -> some View {
        let open = expanded == issue.ticket
        let cells = lit[issue.ticket] ?? []
        // Alone, the strip is its row: one line, in the strip's room.
        let lines = headed ? 3 : 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Column.gap) {
                StateLabel(state: issue.boardState)
                    .background(Wash(on: cells.contains(.state)))
                    .frame(width: Column.state, alignment: .leading)
                ticket(issue.ticket).frame(width: Column.issue, alignment: .leading)
                prCell(issue).frame(width: Column.pr, alignment: .leading)
                words(issue.text, lit: cells.contains(.text), lines: lines).frame(maxWidth: .infinity, alignment: .leading)
                needsCell(issue, lines: lines).frame(width: Column.needs, alignment: .leading)
                ForEach(fieldNames, id: \.self) { name in
                    fieldCell(issue.fields?.first { $0.name == name }?.value, lines: lines).frame(width: Column.field, alignment: .leading)
                }
                Text(IssueBoard.age(since: issue.since, now: now)).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: Column.age, alignment: .trailing)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, headed ? 11 : 0)
            .frame(minHeight: headed ? 40 : Self.height)
            .opacity(["done", "parked"].contains(issue.state) && !open ? 0.6 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.animation(.easeOut(duration: 0.18))) { expanded = open ? nil : issue.ticket }
            }
            if open { details(issue) }
        }
        // Square: the card's clip rounds it where it meets the corners.
        .background(hovered == issue.ticket ? Theme.hover : Color.clear)
        .onHover { inside in
            if inside { hovered = issue.ticket } else if hovered == issue.ticket { hovered = nil }
        }
    }

    /// Words that wrap, up to `lines`.
    private func words(_ text: String, lit: Bool = false, lines: Int) -> some View {
        Text(text.isEmpty ? "–" : text).lineLimit(lines).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary.opacity(0.85)))
            .background(Wash(on: lit))
    }

    // MARK: Cells

    /// What the issue waits on the user for: the lead's words (`--needs`), else the open ask about it.
    private func needs(_ issue: BoardRow.Issue) -> String? {
        if let needs = issue.needs, !needs.isEmpty { return needs }
        if let ask = ask(issue) { return Self.firstLine(ask.body.isEmpty ? ask.title : ask.body) }
        return nil
    }

    @ViewBuilder private func needsCell(_ issue: BoardRow.Issue, lines: Int) -> some View {
        if let words = needs(issue) {
            Text(words).fontWeight(.medium).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }

    /// Its pull request as repo#number, a link.
    @ViewBuilder private func prCell(_ issue: BoardRow.Issue) -> some View {
        if let pr = pullRequest(issue) {
            Button {
                open(pr)
            } label: {
                TaskDetails.linked(TaskDetails.shown(pr))
            }
            .buttonStyle(.plain).tip(pr)
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }

    /// A column of the lead's: Low, Medium or High as the risk pill, anything else as words.
    @ViewBuilder private func fieldCell(_ value: String?, lines: Int) -> some View {
        if let value, ["low", "medium", "high"].contains(value.lowercased()) {
            RiskLabel(level: value.lowercased())
        } else if let value, !value.isEmpty {
            words(value, lines: lines)
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func ticket(_ ticket: String) -> some View {
        if let url = TaskDetails.ticketURL(ticket) {
            Button {
                open(url.absoluteString)
            } label: {
                TaskDetails.linked(ticket)
            }.buttonStyle(.plain).tip(url.absoluteString)
        } else {
            Text(ticket).fontWeight(.medium).lineLimit(1)
        }
    }

    // MARK: Opened

    /// A worker's ask, answerable here (the lead's own is docked above the composer), then its steps.
    private func details(_ issue: BoardRow.Issue) -> some View {
        let steps = IssueBoard.steps(issue)
        return VStack(alignment: .leading, spacing: 0) {
            if let ask = ask(issue), ask.session != conversation.id {
                CardView(ask: ask, controller: inbox, focus: $focus, flat: true, showsByline: false)
                    .padding(.leading, Column.state + 12 - 16).padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.when(step.at)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
                        TaskStateIcon(state: IssueBoard.state(step.state))
                            .scaleEffect(0.86).frame(width: 14, height: 14)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                        Text(step.text.isEmpty ? "–" : step.text).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .font(.system(size: 12.5))
            .padding(.leading, 16 + Column.state + 12).padding(.trailing, 16).padding(.bottom, 14)
            if let worker = worker(issue) {
                Button("Open its worker") { navigation.worker = worker }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .padding(.leading, 16 + Column.state + 12).padding(.bottom, 14)
            }
        }
    }

    // MARK: What Zero knows of each issue

    /// The worker on it: the lead's worker started for its ticket.
    private func worker(_ issue: BoardRow.Issue) -> String? {
        (row?.team ?? []).first { member in workspace.conversation(member.session)?.ticket == issue.ticket }?.session
    }

    /// The open ask about it: its worker's, or one asked about its ticket (`zero ask --ticket`).
    private func ask(_ issue: BoardRow.Issue) -> Ask? {
        let worker = worker(issue)
        return inbox.store.asks.first { ask in
            !ask.state.isFinal && ![.note, .message].contains(ask.kind)
                && (ask.agent.ticket == issue.ticket || (worker != nil && ask.session == worker))
        }
    }

    /// Its pull request: the lead's (`--pr`), else its worker's (`zero attr PR`), as the details pane finds a task's.
    private func pullRequest(_ issue: BoardRow.Issue) -> String? {
        if let pr = issue.pr, !pr.isEmpty { return pr }
        guard let worker = worker(issue), let conversation = workspace.conversation(worker) else { return nil }
        return TaskLinksList.of(conversation, row: row?.member(worker), in: workspace).first { $0.url.contains("/pull/") }?.url
    }

    private static func firstLine(_ text: String) -> String {
        // Plain: its inline code's marks left out.
        String(text.split(whereSeparator: \.isNewline).first ?? "").replacingOccurrences(of: "`", with: "")
    }

    /// A step's time: today's as a time, an earlier day's with its date.
    private static func when(_ ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A state's pill with how many are in it, for the strip; its name on hover.
private struct Count: View {
    let state: BoardRow.State
    let count: Int
    var body: some View {
        let look = TaskStateIcon.look(state)
        let grey = look.color == .secondary
        HStack(spacing: 4) {
            NucleoIcon(look.symbol, fill: "glyph", size: 12).foregroundStyle(look.color)
            Text("\(count)").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(grey ? AnyShapeStyle(.secondary) : AnyShapeStyle(look.color))
        }
        .padding(.leading, 6).padding(.trailing, 7).padding(.vertical, 3)
        .background((grey ? Color.secondary : look.color).opacity(0.12), in: Capsule())
        .tip(look.name)
    }
}

/// A cell just changed: a grey wash behind it (Zero's own, as a passage gone to is lit), taking no room.
private struct Wash: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(Theme.choice).padding(.horizontal, -5).padding(.vertical, -3)
            .opacity(on ? 1 : 0).allowsHitTesting(false)
    }
}

extension EnvironmentValues {
    /// Room the issue strip takes at the top of the page: the conversation starts under it.
    @Entry var boardRoom: CGFloat = 0
}
