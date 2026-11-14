import AppKit
import SwiftUI
import ZeroCore

// Settings › Accounts: the accounts and keys each CLI runs as (zerod's signins.rs). Zero keeps them and gives each
// task's CLI one as it starts (the one with the least of its week left, so one is used up before the next); the CLIs
// still make every call to their providers. Added in place, in the card, rather than in a sheet.

struct SignInsPage: View {
    let workspace: Workspace?
    /// The account being added (or switched to a token), in its dialog.
    @State private var adding: Adding?
    /// The CLI a model is being added for, in its dialog.
    @State private var addingModel: Provider?
    /// Every account's turns by day, once read.
    @State private var activity = AccountActivity()

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let workspace {
                // Every account's turns together, kept by zerod whatever becomes of the accounts: replacing a sign-in
                // doesn't lose its days.
                SettingsSection(title: "Activity") {
                    ActivityGraph(activity: activity).padding(18).bleedingCard()
                }
                ForEach([Provider.claude, .codex, .opencode], id: \.self) { cli in
                    SettingsSection(
                        title: cli.title,
                        icon: cli.mark.map {
                            AnyView(
                                $0.resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16).clipShape(
                                    RoundedRectangle(cornerRadius: 4)))
                        },
                        accessory: AnyView(
                            HStack(spacing: 4) {
                                GhostButton(title: "Add model", icon: "plus", open: addingModel == cli) {
                                    addingModel = addingModel == cli ? nil : cli
                                }
                                AddAccountButton(cli: cli) { way in adding = Adding(cli: cli, way: way) }
                            })
                    ) {
                        section(cli, in: workspace)
                    }
                }
                .zeroDialog(item: $adding) { adding in
                    AddAccount(cli: adding.cli, way: adding.way, replacing: adding.replacing, workspace: workspace)
                }
                .zeroDialog(item: $addingModel) { cli in AddModel(cli: cli) }

            }
        }
        .task { await CustomModels.shared.load() }
        // Opened, the page has zerod read each account's usage now, not only when it's next due (zerod reads them itself).
        .task {
            guard let workspace else { return }
            await workspace.loadSignIns()
            activity = await workspace.accountActivity()
            await workspace.readUsage()
        }
    }

    private func section(_ cli: Provider, in workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            accounts(cli, in: workspace)
            AddedModels(cli: cli, workspace: workspace)
        }
    }

    private func accounts(_ cli: Provider, in workspace: Workspace) -> some View {
        let mine = workspace.signins.filter { $0.cli == cli }
        return VStack(spacing: 0) {
            // A line between them, edge to edge as each row's hover fill is, square (the card's corners round the
            // first and last).
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, signin in
                if index > 0 { Hairline() }
                SignInRow(signin: signin, workspace: workspace) {
                    // A token signs in again in a folder of its own; a folder's account, as a token.
                    adding = Adding(cli: cli, way: signin.kind == .token ? .signIn : .token, replacing: signin)
                }
            }
            if mine.isEmpty {
                Text("None yet").font(.system(size: 13)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 44)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .bleedingCard()
    }
}

/// An account being added, in its dialog: for which CLI, how, and the account it signs in again, if any.
private struct Adding: Identifiable {
    let cli: Provider
    let way: AddWay
    var replacing: ZerodLink.SignIn? = nil
    var id: String { "\(cli.rawValue)-\(way)-\(replacing?.id ?? "")" }
}

/// How an account is added: its CLI's own sign-in in the browser, a Claude Code token, or a key (OpenCode's: for
/// which provider).
private enum AddWay: Equatable, CustomStringConvertible {
    case signIn, token, key(AddAccount.OpenCodeProvider?)
    var description: String {
        switch self {
        case .signIn: "signIn";
        case .token: "token";
        case .key(let provider): "key-\(provider?.rawValue ?? "")"
        }
    }
}

/// The heading's ghost button: Zero's menu of the ways to add one of this CLI's accounts.
private struct AddAccountButton: View {
    let cli: Provider
    let pick: (AddWay) -> Void
    @State private var anchor = CGRect.zero

    private var id: String { "add-\(cli.rawValue)" }

    var body: some View {
        GhostButton(title: "Add account", icon: "plus", open: WorkspaceSelector.shared.open == id) {
            WorkspaceSelector.shared.toggle(id, kind: .menu, anchor: anchor, rows: { rows })
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            anchor = $0
        }
    }

    private var rows: [SelectorSection] {
        if cli == .opencode {
            return ComposerRows.menu([
                AddAccount.OpenCodeProvider.allCases.map { option in
                    (option.rawValue, "\(option.rawValue) key", "key", false, { pick(.key(option)) })
                }
            ])
        }
        if cli == .claude {
            return ComposerRows.menu([
                [
                    ("signIn", "Sign in with Claude", "circle-user", false, { pick(.signIn) }),
                    ("token", "Use a token", "key", false, { pick(.token) }),
                    ("key", "Anthropic API key", "key", false, { pick(.key(nil)) }),
                ]
            ])
        }
        return ComposerRows.menu([
            [
                ("signIn", "Sign in with ChatGPT", "circle-user", false, { pick(.signIn) }),
                ("key", "OpenAI API key", "key", false, { pick(.key(nil)) }),
            ]
        ])
    }
}

extension Provider: @retroactive Identifiable { public var id: String { rawValue } }

private struct SignInRow: View {
    let signin: ZerodLink.SignIn
    let workspace: Workspace
    /// Opened (a click): its usage under it, in the card.
    @State private var open = false
    /// A Claude account switched to the other way of signing in: a token to its own folder, a folder to a token.
    let switchSignIn: () -> Void
    @State private var menuFrame = CGRect.zero
    @State private var hovered = false
    /// Its name being asked for, in Zero's dialog.
    @State private var naming = false
    /// Remove picked: confirmed in the row, where its usage was.
    @State private var removing = false

    private var detail: String {
        switch signin.kind {
        case .token: signin.plan.map { "\($0.capitalized) plan" } ?? "Subscription"
        case .apiKey: signin.variable.map { "API key · \($0)" } ?? "API key"
        case .codexHome: signin.plan.map { "ChatGPT \($0.capitalized)" } ?? "ChatGPT"
        case .claudeHome: signin.plan.map { "\($0.capitalized) plan" } ?? "Subscription"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(signin.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if signin.pending == true {
                        HStack(spacing: 6) {
                            Spinner().frame(width: 10, height: 10); Text("Signing in… finish in your browser")
                        }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if removing {
                    Button("Cancel") { removing = false }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(
                        .secondary)
                    Button("Remove") { Task { await workspace.removeSignIn(signin) } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
                        .tip("Its tasks can't restart as it, and it has to be signed in again to come back")
                } else if let usage = workspace.signinUsage[signin.id], UsageShown.limited(usage, now: Int(Date().timeIntervalSince1970)) {
                    Text("At its limit").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.red)
                }
                if !removing && signin.pending != true {
                    NucleoIcon("chevron-down", size: 10).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
                    menuButton
                }
            }
            .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 12)
            .background(hovered && !open && !removing ? Theme.row : .clear, in: Rectangle())
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            // A click opens it in place, taller: its usage and when it resets. Its ⋯ has rename, switch and remove.
            .onTapGesture {
                if !removing && signin.pending != true { open.toggle() }
            }
            if open {
                AccountDetails(signin: signin, workspace: workspace)
                    .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .zeroDialog(isPresented: $naming) {
            let unnamed = signin.label == ClaudeSignIn.unnamed
            NameSheet(
                title: unnamed ? "Whose account is this?" : "Rename", name: unnamed ? "" : signin.label, action: unnamed ? "Save" : "Rename"
            ) {
                name in Task { await workspace.renameSignIn(signin, to: name) }
            }
        }
    }

    private var menuButton: some View {
        Button {
            let width = SelectorView.width(.menu)
            WorkspaceSelector.shared.toggle(
                "signin-\(signin.id)", kind: .menu,
                anchor: CGRect(x: menuFrame.maxX - width, y: menuFrame.minY, width: width, height: menuFrame.height)
            ) {
                var rows: [(id: String, title: String, glyph: String, selected: Bool, pick: () -> Void)] = [
                    (
                        "rename", "Rename…", "pen", false, { naming = true }
                    )
                ]
                switch signin.kind {
                case .claudeHome: rows.append(("token", "Switch to a token", "key", false, switchSignIn))
                case .token: rows.append(("browser", "Switch to a browser sign-in", "circle-user", false, switchSignIn))
                default: break
                }
                return ComposerRows.menu([rows, [("remove", "Remove…", "trash", false, { removing = true })]])
            }
        } label: {
            NucleoIcon("dots", size: 14).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(Hovering(radius: 6)).tip("More")
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            menuFrame = $0
        }
    }
}

/// How much of each of an account's windows its CLI last said was used: a column each, the 5-hour then the week, at
/// fixed widths so every row lines up (a window it gave no figure for keeps its place), and under each, when it resets.
/// A window that has reset since is unused.
struct UsageColumns: View {
    let usage: Usage
    static let slots = [("5 hours", "5h"), ("7 days", "Week")]

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = Int(context.date.timeIntervalSince1970)
            HStack(spacing: 18) {
                ForEach(Self.slots, id: \.0) { name, short in
                    if let window = usage.windows.first(where: { $0.name == name }) {
                        let live = (window.resetsAt ?? Int.max) > now
                        column(
                            short, used: live ? min(1, window.used) : 0,
                            resets: live ? window.resetsAt.map { UsageMeter.resets($0, now: now) } : nil)
                    } else {
                        Color.clear.frame(width: Self.width, height: 1)
                    }
                }
            }
        }
    }

    private static let width: CGFloat = 104

    private func column(_ name: String, used: Double, resets: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                UsageMeter(used: used, width: 56)
                Text(UsageMeter.percent(used)).font(.system(size: 11.5, weight: .medium)).monospacedDigit().fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(resets ?? " ").font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(width: Self.width)
    }
}

/// A window's use as a thin bar: grey, orange from 90%, red once full.
struct UsageMeter: View {
    let used: Double
    var width: CGFloat = 46

    var body: some View {
        Capsule().fill(Theme.row).frame(width: width, height: 4)
            .overlay(alignment: .leading) { Capsule().fill(Self.color(used)).frame(width: width * used, height: 4) }
    }

    static func color(_ used: Double) -> Color { used >= 1 ? .red : used >= 0.9 ? .orange : Color.primary.opacity(0.5) }
    static func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }

    /// When a window resets, as it's read at a glance: how long until, within a day ("in 4h 44m"); its day and time
    /// past that ("Mon 21:00").
    static func resets(_ at: Int, now: Int = Int(Date().timeIntervalSince1970)) -> String {
        let minutes = max(0, at - now) / 60
        if minutes < 60 { return "Resets in \(max(1, minutes))m" }
        if minutes < 24 * 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets " + Date(timeIntervalSince1970: TimeInterval(at)).formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The rail's Tasks card: what every running task's processes use together (zerod's uses.rs: its CLI, MCP servers and
/// commands) and the heaviest few, what tasks left running, and while memory is short, that first.
struct TasksUseCard: View {
    let workspace: Workspace
    /// Opens a task by its session (MemoryNotice's links).
    var open: (String) -> Void = { _ in }
    /// Everything tasks left running (LeftRunningDialog), opened by the rail's mark, which stays while the card goes.
    let openLeft: () -> Void

    var body: some View {
        let uses = workspace.uses
        let memory = uses.values.reduce(0) { $0 + $1.memory }
        let cpu = uses.values.reduce(0) { $0 + $1.cpu }
        let heaviest = uses.sorted { $0.value.memory > $1.value.memory }.prefix(3).map { id, use in
            (id, workspace.conversation(id).map(Workspace.label(of:)) ?? id, TaskDetails.bytes(use.memory))
        }
        VStack(alignment: .leading, spacing: 8) {
            // While memory is short, in this card rather than one of its own: one card for what tasks use.
            if let shortage = MemoryWatch.shared.shortage {
                MemoryNotice(shortage: shortage, workspace: workspace, open: open, openLeft: openLeft)
                Hairline()
            }
            HStack(spacing: 6) {
                NucleoIcon("server", size: 12).frame(width: 12, height: 12)
                Text("Tasks").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(uses.isEmpty ? "None running" : "\(TaskDetails.bytes(memory)) · \(Int(cpu.rounded()))% CPU")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
            }
            ForEach(heaviest, id: \.0) { id, name, memory in
                Button {
                    open(id)
                } label: {
                    HStack(spacing: 6) {
                        Text(name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(memory).monospacedDigit().fixedSize()
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // What tasks that are done, archived or quiet left running (zerod's left.rs): a quiet line that opens it.
            let settled = workspace.left.values.filter(\.settled)
            if !settled.isEmpty {
                Button(action: openLeft) {
                    HStack(spacing: 6) {
                        NucleoIcon("power-off", size: 12).frame(width: 12, height: 12)
                        Text(LeftRunningLook.summary(Array(settled))).font(.system(size: 11)).monospacedDigit().lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain).tip("Left running by tasks that are done, archived or quiet")
            }
        }
    }
}

/// One account's usage on the rail's card, on one line: its rings with its CLI's mark inside (as the rail draws them),
/// then its name; on hover, each window's share and reset ("5 h · 28% · resets 19:40").
struct UsageAccount: View {
    let signin: ZerodLink.SignIn
    let usage: Usage
    let now: Int

    var body: some View {
        HStack(spacing: 8) {
            UsageRing(cli: signin.cli, usage: usage, now: now).frame(width: 32, height: 32)
            Text(signin.label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .tip(details)
    }

    private var details: String {
        if usage.noLimits == true { return "No plan limits" }
        let limit =
            UsageShown.limited(usage, now: now)
            ? ["At its limit" + (usage.resetsAt.map { " until " + Self.clock($0, now: now) } ?? "")] : []
        let windows = ["5 hours", "7 days"].compactMap { name in
            usage.windows.first { $0.name == name }.map { window in
                let used = UsageShown.used(window, now: now)
                let parts = [name == "7 days" ? "Week" : "5 h", "\(UsageMeter.percent(used)) used"]
                let live = window.resetsAt.flatMap { $0 > now ? $0 : nil }
                return (parts + (live.map { ["resets " + Self.clock($0, now: now)] } ?? [])).joined(separator: " · ")
            }
        }
        return (limit + windows + [UsageShown.stale(usage, now: now)].compactMap { $0 }).joined(separator: "\n")
    }

    /// A reset as a time: today's alone ("19:40"), later ones with their day ("Mon 10:00").
    static func clock(_ at: Int, now: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        let today = Calendar.current.isDate(date, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(now)))
        return today
            ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// An account's use as rings, each coloured by its own use (green, yellow, orange, red) on a track of the same colour,
/// faint, so an unused window reads as available rather than empty: the inner its week, the outer its 5 hours (drawn
/// only on a plan that has them), the inner the same size either way; its CLI's mark inside.
struct UsageRing: View {
    let cli: Provider
    let usage: Usage
    let now: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let window = { (name: String) in usage.windows.first { $0.name == name }.map { UsageShown.used($0, now: now) } }
        // At its limit with no window full (its CLI said so without figures): the week's ring spent until it resets.
        let stopped = UsageShown.limited(usage, now: now) && !usage.windows.contains { UsageShown.used($0, now: now) >= 1 }
        ZStack {
            if let five = window("5 hours") { ring(five, diameter: 28) }
            ring(stopped ? 1 : window("7 days") ?? 0, diameter: 20)
            ProviderGlyph(cli: cli)
        }
        .frame(width: 32, height: 32)
    }

    private func ring(_ used: Double, diameter: CGFloat) -> some View {
        let color = Self.color(used)
        return ZStack {
            // Fainter tints wash out on white: the light track is stronger.
            Circle().stroke(color.opacity(scheme == .dark ? 0.25 : 0.4), lineWidth: 2.25)
            // Unused: no arc (a round cap on an empty one would still draw a dot).
            if used > 0 {
                Circle().trim(from: 0, to: used)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// A ring's colour by its use: green, yellow from 40%, orange from 70%, red from 90%. The system's tones, the
    /// yellow a readable amber on light.
    static let levels: [(from: Double, color: Color)] = [
        (0.9, .red), (0.7, .orange),
        (0.4, Color(nsColor: Theme.dynamicColor(dark: .systemYellow, light: NSColor(red: 0.82, green: 0.55, blue: 0, alpha: 1)))),
        (0, .green),
    ]
    static func color(_ used: Double) -> Color { levels.first { used >= $0.from }?.color ?? .green }
}

/// A CLI's mark alone, sized to fill a circle as the others do (Provider.glyph).
struct ProviderGlyph: View {
    let cli: Provider
    var body: some View {
        if let glyph = cli.glyph {
            glyph.resizable().scaledToFit().foregroundStyle(.primary).frame(width: cli.glyphSize.width, height: cli.glyphSize.height)
        } else {
            NucleoIcon("terminal", size: 11)
        }
    }
}

/// In the outer rail, above Settings: the account a turn last ended on, unless it's at its limit (UsageShown), as its
/// ring (UsageRing). Its card: every account's windows and their resets, grouped by CLI. Its figures read from zerod every minute (zerod reads each CLI itself).
struct RailUsage: View {
    let workspace: Workspace
    /// Settings › Accounts and models, on a click.
    let openAccounts: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = Int(context.date.timeIntervalSince1970)
            let shown = workspace.usageShown(now: context.date)
            if let (signin, usage) = shown.first {
                RailPeek(action: openAccounts) {
                    UsageRing(cli: signin.cli, usage: usage, now: now)
                } card: {
                    // By CLI, each under its name: the group with the most recently used account first.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(UsageShown.byCLI(shown), id: \.[0].0.cli) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group[0].0.cli.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                ForEach(group, id: \.0.id) { signin, usage in UsageAccount(signin: signin, usage: usage, now: now) }
                            }
                        }
                    }
                }
            }
        }
        // Its place kept while nothing's known yet (a first run), so nothing below it moves when it comes.
        .frame(width: 32, height: 32)
        .task {
            while !Task.isCancelled {
                // zerod not connected yet (at launch): again in a second, not a minute.
                let read = await workspace.loadSignIns()
                try? await Task.sleep(for: .seconds(read ? 60 : 1))
            }
        }
    }
}

/// In the outer rail, above the usage rings: the Mac's health at a glance, as tasks use it: a server mark, orange while
/// memory is short. Its card: what tasks use, the heaviest, what they left running.
struct RailTasks: View {
    let workspace: Workspace
    /// Opens a task by its session.
    let open: (String) -> Void
    @State private var showingLeft = false

    var body: some View {
        let short = MemoryWatch.shared.shortage != nil
        RailPeek {
            NucleoIcon("server", size: 17).foregroundStyle(short ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        } card: {
            TasksUseCard(workspace: workspace, open: open) { showingLeft = true }
        }
        // Here rather than in the card, which goes as the pointer moves to the dialog.
        .zeroDialog(isPresented: $showingLeft) { LeftRunningDialog(workspace: workspace) }
    }
}

/// A rail mark whose card shows while the pointer is on it or on the card: across the sidebar's width, 8 pt in from each
/// of its edges, its bottom on the mark's, growing upward, so the pointer goes straight across onto it (a clear strip
/// spans the gap, so it doesn't close on the way). A click on the mark does `action`, if any, and puts the card away. Zero's own card, drawn in
/// place, no motion.
struct RailPeek<Mark: View, Card: View>: View {
    var action: (() -> Void)? = nil
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let card: () -> Card
    @State private var overMark = false
    @State private var overCard = false
    /// Across the sidebar's space, in from both its edges by the same 8.
    @AppStorage(SidebarWidth.key) private var sidebarWidth = SidebarWidth.standard

    /// From the mark's right edge (the rail is 48 wide, the mark 32 in its middle) to the card: past the rail's edge, 8.
    private static var gap: CGFloat { 8 + 8 }

    var body: some View {
        let open = overMark || overCard
        mark()
            .frame(width: 32, height: 32)
            .background(open ? Theme.railHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { overMark = $0 }
            .onTapGesture {
                guard let action else { return }
                overMark = false; overCard = false
                action()
            }
            .overlay(alignment: .bottomLeading) {
                if open {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: Self.gap)
                        card()
                            .padding(12)
                            .frame(width: sidebarWidth - 16, alignment: .leading)
                            .modifier(MenuCard(radius: 12, linear: true))
                    }
                    .contentShape(Rectangle())
                    .fixedSize()
                    .onHover { overCard = $0 }
                    .offset(x: 32)
                }
            }
            // Away with the page it was over (a task opened from it, say), until the pointer comes onto the mark again.
            .closesWithFloating {
                overMark = false; overCard = false
            }
    }
}

/// Adding one, in a dialog: its CLI's own sign-in in the browser (under way as it opens), or a key. Closes itself once
/// the account is added (or its sign-in is under way in the browser).
private struct AddAccount: View {
    let cli: Provider
    let way: AddWay
    /// Signing this one in again (a token in a folder of its own, or a folder's account as a token), its id kept.
    var replacing: ZerodLink.SignIn? = nil
    let workspace: Workspace
    @Environment(\.closeDialog) private var dismiss
    @State private var label = ""
    @State private var key = ""
    @State private var provider = OpenCodeProvider.go
    @State private var problem: String?
    @State private var working = false
    @State private var claude = ClaudeSignIn()
    @State private var code = ""
    /// Claude's page, in case the browser didn't open it.
    @State private var page: URL?
    /// A token's switch to a folder under way, in the browser.
    @State private var switching = false

    /// OpenCode's providers that take a key, and the variable OpenCode reads each from.
    enum OpenCodeProvider: String, CaseIterable, Identifiable {
        case go = "OpenCode Go", anthropic = "Anthropic", openai = "OpenAI", openrouter = "OpenRouter"
        var id: String { rawValue }
        var variable: String {
            switch self {
            case .go: "OPENCODE_API_KEY"
            case .anthropic: "ANTHROPIC_API_KEY"
            case .openai: "OPENAI_API_KEY"
            case .openrouter: "OPENROUTER_API_KEY"
            }
        }
    }

    private var keyed: Bool { if case .key = way { true } else { false } }

    private var title: String {
        if let replacing {
            return way == .token ? "Sign \(replacing.label) in again as a token" : "Switch \(replacing.label) to a browser sign-in"
        }
        if way == .token { return "Use a Claude Code token" }
        if case .key(let option) = way {
            return option.map { "\($0.rawValue) key" } ?? (cli == .claude ? "Anthropic API key" : "OpenAI API key")
        }
        return cli == .claude ? "Sign in with Claude" : "Sign in with ChatGPT"
    }

    private var explanation: String {
        if replacing != nil && way == .signIn {
            return
                "Sign in on Claude's page in your browser, as this account. It keeps its tasks and activity, and its token goes once you're in."
        }
        if way == .token { return "Claude's sign-in page opens in your browser. Its tasks get a year-long token, kept in your Keychain." }
        return switch (cli, keyed) {
        case (.claude, false): "Claude's sign-in page opens in your browser; the account shows here once you're in."
        case (.codex, false): "ChatGPT's sign-in page opens in your browser; the account shows here once you're in."
        case (.claude, true): "Billed per use, and kept in your Keychain."
        case (.codex, true): "Billed per use. Codex keeps it, in a home of this account's own."
        case (.opencode, _): "Given to OpenCode as \(provider.variable), and kept in your Keychain."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(
                text: title,
                detail: explanation
            )
            if keyed { keyForm } else if way == .token { claudeSteps } else { browserStep }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                DialogButton(title: "Cancel", action: cancel)
                if keyed {
                    DialogButton(title: "Save", kind: .primary, enabled: !key.trimmed.isEmpty && !working, action: save)
                } else if case .failed = claude.status {
                    DialogButton(title: "Try again", kind: .primary) { claude.start(replacing: replacing, in: workspace) }
                } else if way == .signIn && problem != nil {
                    DialogButton(title: "Try again", kind: .primary) {
                        problem = nil; Task { await browser() }
                    }
                }
            }
        }
        .frame(width: 440)
        // Opened from the menu: the sign-in starts at once.
        .onAppear {
            if case .key(let option?) = way { provider = option }
            if way == .token { claude.start(replacing: replacing, in: workspace) }
            if way == .signIn { Task { await browser() } }
        }
        // A token switching: done once zerod has it signed in in its folder.
        .onChange(of: workspace.signins.first { $0.id == replacing?.id }?.kind) { _, kind in
            if way == .signIn && kind == .claudeHome { done() }
        }
        // Closed mid-way: Claude Code's sign-in stops with it.
        .onDisappear { claude.cancel() }
    }

    private func cancel() { claude.cancel(); dismiss() }
    private func name(_ signin: ZerodLink.SignIn) {
        guard !label.trimmed.isEmpty else { return }
        Task {
            await workspace.renameSignIn(signin, to: label.trimmed); done()
        }
    }
    private func done() { dismiss() }

    private func field(_ prompt: String, text: Binding<String>, secret: Bool = false) -> some View {
        Group {
            if secret { SecureField("", text: text, prompt: Text(prompt)) } else { TextField("", text: text, prompt: Text(prompt)) }
        }
        .textFieldStyle(.dialog)
    }

    @ViewBuilder private var claudeSteps: some View {
        switch claude.status {
        case .signingIn, .checking:
            HStack(spacing: 8) {
                Spinner().frame(width: 12, height: 12)
                Text("Finish signing in on Claude's page in your browser.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                field("Its code, if Claude shows one", text: $code).onSubmit { claude.submit(code: code) }
                RowButton(title: "Send", enabled: !code.trimmed.isEmpty && claude.status != .checking) { claude.submit(code: code) }
            }
        case .done:
            // Claude didn't say whose the token is: its name is asked here, as part of signing in.
            if let saved = claude.saved, saved.label == ClaudeSignIn.unnamed {
                HStack(spacing: 8) {
                    field("Whose account is this? (its email, or a name)", text: $label).firstField().onSubmit { name(saved) }
                    RowButton(title: "Save", enabled: !label.trimmed.isEmpty) { name(saved) }
                }
            } else {
                Color.clear.frame(height: 0).onAppear(perform: done)
            }
        case .failed(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var browserStep: some View {
        if problem == nil {
            HStack(spacing: 8) {
                Spinner().frame(width: 12, height: 12)
                Text(
                    switching
                        ? "Finish signing in on Claude's page in your browser."
                        : cli == .claude ? "Opening Claude's sign-in page…" : "Opening ChatGPT's sign-in page…"
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                if let page {
                    Button {
                        NSWorkspace.shared.open(page)
                    } label: {
                        TaskDetails.linked("Open it again")
                    }
                    .buttonStyle(.plain).font(.system(size: 12))
                }
            }
        }
    }

    /// Its CLI's own sign-in in the browser. A new account closes the dialog once it's under way (its row says it's
    /// signing in); a token switching waits here until it's done. Claude Code opens its page itself; Codex's is opened
    /// here.
    private func browser() async {
        if cli == .codex { return await codex(apiKey: nil) }
        let (opened, error) = await workspace.signInClaude(replacing: replacing)
        if let error { problem = error; return }
        page = opened
        if replacing == nil { done() } else { switching = true }
    }

    private var keyForm: some View {
        VStack(spacing: 8) {
            field(cli == .opencode ? "A name for it (\(provider.rawValue))" : "A name for it", text: $label).firstField()
            field("Its API key", text: $key, secret: true).onSubmit(save)
        }
    }

    private func save() {
        guard !key.trimmed.isEmpty else { return }
        working = true
        Task {
            switch cli {
            case .codex: await codex(apiKey: key.trimmed)
            case .claude: await keep(.init(cli: .claude, kind: .apiKey, label: label.trimmed.isEmpty ? "Anthropic API key" : label.trimmed))
            case .opencode:
                await keep(
                    .init(
                        cli: .opencode, kind: .apiKey, label: label.trimmed.isEmpty ? provider.rawValue : label.trimmed,
                        variable: provider.variable))
            }
            working = false
        }
    }

    private func keep(_ signin: ZerodLink.SignIn) async {
        if let error = await workspace.addSignIn(signin, secret: key.trimmed) { problem = error } else { done() }
    }

    private func codex(apiKey: String?) async {
        let (page, error) = await workspace.signInCodex(
            label: apiKey == nil ? nil : (label.trimmed.isEmpty ? "OpenAI API key" : label.trimmed), apiKey: apiKey)
        if let error { problem = error; return }
        if let page { NSWorkspace.shared.open(page) }
        done()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The models added to Zero for a CLI, under its accounts (added from the heading's Add model): one its own list
/// doesn't have yet (a new release), by the id the CLI is started with and a name for the picker. Zero-wide: every
/// account of this CLI offers it, but those its provider refused it.
private struct AddedModels: View {
    let cli: Provider
    let workspace: Workspace

    private var mine: [CustomModels.Model] { CustomModels.shared.models.filter { $0.cli == cli } }

    var body: some View {
        if !mine.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(mine.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Hairline().padding(.horizontal, 18) }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).font(.system(size: 13, weight: .medium))
                            Text(model.id).font(.system(size: 11.5).monospaced()).foregroundStyle(.secondary)
                            if let note = availability(model) { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        RowButton(title: "Remove") { Task { await CustomModels.shared.remove(model) } }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .bleedingCard()
        }
    }

    /// Which of this CLI's accounts can't use it, as their provider said when a task tried: tasks on it go to the others.
    private func availability(_ model: CustomModels.Model) -> String? {
        let accounts = workspace.signins.filter { $0.cli == cli }
        let refused = accounts.filter { workspace.signinRefused[$0.id]?.contains(model.id) == true }
        guard !refused.isEmpty else { return nil }
        if refused.count == accounts.count { return "None of your accounts can use it" }
        return "Not on " + refused.map(\.label).joined(separator: ", ") + ": tasks on it run as your other accounts"
    }
}

/// An account opened, under its row: how much of each of its plan's windows it has used and when each resets.
private struct AccountDetails: View {
    let signin: ZerodLink.SignIn
    let workspace: Workspace

    var body: some View {
        let usage = workspace.signinUsage[signin.id]
        let now = Int(Date().timeIntervalSince1970)
        let windows = UsageColumns.slots.compactMap { name, _ in usage?.windows.first { $0.name == name } }
        VStack(alignment: .leading, spacing: 18) {
            // Each window its plan has, a tile apiece side by side: what's used, large, its bar, when it resets.
            if windows.isEmpty {
                Text(
                    usage?.noLimits == true
                        ? "No plan limits: its plan has no windows to use up."
                        : usage.map { UsageShown.limited($0, now: now) } == true
                            ? "At its limit. Its CLI hasn't said how much of each window it has used."
                            : "No usage figures yet. A Claude Code token's usage comes from its tasks as they run, so it shows once one has."
                )
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) {
                    ForEach(windows, id: \.name) { window in tile(window, now: now) }
                }
            }
        }
    }

    private func tile(_ window: UsageWindow, now: Int) -> some View {
        let live = (window.resetsAt ?? Int.max) > now
        let used = live ? min(1, window.used) : 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(window.name == "7 days" ? "This week" : "Last 5 hours").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(UsageMeter.percent(used)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                .foregroundStyle(used >= 1 ? .red : .primary)
            Capsule().fill(Theme.row).frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { space in Capsule().fill(UsageMeter.color(used)).frame(width: space.size.width * used) }
                }
            Text(live ? window.resetsAt.map { UsageMeter.resets($0, now: now) } ?? " " : "Reset since it was read")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.row.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .tip(UsageShown.stale(read: window.readAt, now: now) ?? "")
    }
}

/// The last year a square a day, a column a week (Sunday at the top), as GitHub's contribution graph: empty grey, then
/// four greens by how many turns that day had against the busiest day (Zero counts them from when it started to). A
/// day's count on hover, and each account's.
struct ActivityGraph: View {
    let activity: AccountActivity
    static let gap: CGFloat = 3, cell: CGFloat = 12, labels: CGFloat = 26
    /// As many weeks as the width holds at full size, up to a year: squares that fill the card rather than a year's
    /// worth of specks.
    @State private var weeks = 26

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        // The first column's Sunday: the grid ends on today's column, today in its weekday's row.
        let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today) ?? today
        let days = activity.totals
        let busiest = max(1, days.values.max() ?? 1)
        let total = days.filter { $0.key >= start }.values.reduce(0, +)
        let columns = (0..<weeks).map { calendar.date(byAdding: .day, value: $0 * 7, to: start) ?? start }
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                // A month's name over the week it starts in, the current month's too (into the card's padding at the
                // right edge); the first column's only if the next doesn't start one, so two never overlap.
                HStack(spacing: Self.gap) {
                    Color.clear.frame(width: Self.labels - Self.gap, height: 1)
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, sunday in
                        let month = { (i: Int) in calendar.component(.month, from: columns[i]) }
                        let starts = index == 0 ? columns.count < 2 || month(0) == month(1) : month(index) != month(index - 1)
                        Text(starts ? sunday.formatted(.dateTime.month(.abbreviated)) : "")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            .frame(width: Self.cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    // Monday, Wednesday and Friday, as GitHub labels its rows.
                    VStack(alignment: .leading, spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            Text([1, 3, 5].contains(row) ? calendar.shortWeekdaySymbols[row] : "").font(.system(size: 9.5)).foregroundStyle(
                                .secondary
                            )
                            .frame(width: Self.labels - Self.gap, height: Self.cell, alignment: .leading)
                        }
                    }
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, sunday in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { row in
                                let day = calendar.date(byAdding: .day, value: row, to: sunday) ?? sunday
                                if day > today {
                                    Color.clear.frame(width: Self.cell, height: Self.cell)
                                } else {
                                    let count = days[day] ?? 0
                                    RoundedRectangle(cornerRadius: 3).fill(Self.shade(count, busiest: busiest))
                                        .overlay {
                                            if day == today {
                                                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                                            }
                                        }
                                        .frame(width: Self.cell, height: Self.cell)
                                        .tip(tip(day, count: count))
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text(total == 0 ? "Counted from today" : "\(total) turn\(total == 1 ? "" : "s") in \(weeks) weeks").monospacedDigit()
                Spacer()
                Text("Less")
                ForEach([0, 1, 2, 3, 4], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(Self.level(level)).frame(width: 10, height: 10)
                }
                Text("More")
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            weeks = max(8, min(53, Int((width - Self.labels + Self.gap) / (Self.cell + Self.gap))))
        }
    }

    /// The day's turns, then each account's, the most first.
    private func tip(_ day: Date, count: Int) -> String {
        let accounts = (activity.days[day] ?? [:]).sorted { $0.value > $1.value }
            .map { "\(activity.names[$0.key] ?? $0.key): \($0.value)" }
        return
            ([
                "\(count == 0 ? "No" : "\(count)") turn\(count == 1 ? "" : "s") · "
                    + day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            ]
            + accounts).joined(separator: "\n")
    }

    private static func shade(_ count: Int, busiest: Int) -> Color {
        guard count > 0 else { return level(0) }
        return level(min(4, 1 + Int(Double(count) / Double(busiest) * 3.999)))
    }

    static func level(_ level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.07)
        case 1: Color.green.opacity(0.35)
        case 2: Color.green.opacity(0.55)
        case 3: Color.green.opacity(0.78)
        default: Color.green
        }
    }
}

/// A model added to Zero for a CLI, in a dialog as an account is: its id as the CLI takes it, and its name.
private struct AddModel: View {
    let cli: Provider
    @Environment(\.closeDialog) private var dismiss
    @State private var id = ""
    @State private var name = ""

    private var example: String {
        switch cli {
        case .claude: "claude-mythos-5-2";
        case .codex: "gpt-5.5-codex";
        case .opencode: "provider/model"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(
                text: "Add a \(cli.title) model",
                detail:
                    "For a model \(cli.title) doesn't list yet. It's offered on every \(cli.title) account; an account that turns out not to have it is left out."
            )
            VStack(spacing: 8) {
                TextField("", text: $id, prompt: Text("Its id, as \(cli.title) takes it (\(example))")).textFieldStyle(.dialog).firstField()
                    .onSubmit(
                        save)
                TextField("", text: $name, prompt: Text("Its name in the picker (Mythos 5.2)")).textFieldStyle(.dialog).onSubmit(save)
            }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(title: "Add", kind: .primary, enabled: !id.trimmed.isEmpty, action: save)
            }
        }
        // The dialog's own width, as Add account's: unset, it took the window's.
        .frame(width: 440)
    }

    private func save() {
        let id = id.trimmed, name = name.trimmed
        guard !id.isEmpty else { return }
        Task { await CustomModels.shared.add(CustomModels.Model(cli: cli, id: id, name: name.isEmpty ? id : name)) }
        dismiss()
    }
}
