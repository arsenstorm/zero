import SwiftUI
import ZeroCore

/// Every setting search finds, and the one place its name and line are written: its row takes them from here
/// (SettingRow(.launchAtLogin)), so the search can't say something the page doesn't. A row's line that changes with
/// its state (Show log's path) keeps the line here as what the setting is. Lists (accounts, phones, sites) are found
/// by their section. A new setting is a case here, which the switch below won't build without.
enum Setting: String, CaseIterable {
    case launchAtLogin, inboxHotkey, notifyNeedsYou, notifyTrouble, notifyFinished, updates, zerodAtLogin, icons, health, showLog
    case showWelcome
    case undoAnswer, askExpiry
    case showBar, barInbox, barAgents, barAgentsFrom, barSettingsButton, followScreen, barInWindow, barAgentList
    case relay, phones
    case plugin, archiveDone, terminalApp, suggestFiles, pausedSend, plainAnswers, stuckCommands, stuckThresholds
    case subagents, compactWindow, buildCache, placesCommand
    case activity, claudeAccounts, codexAccounts, opencodeAccounts
    case commitAsAgent, signingKey, coauthor, coauthorName, gitFolders
    case openLinksIn, panelHosts, chrome, firefox, safari, pageDialogs, blockedSites
    case accessibility, screenRecording
    case mcpServers
    case workspaces, projects
    case githubConnection, githubLinks, githubToken, githubPush
    case linearConnection, linearLinks, linearApp, linearWrites
    case slackConnection, slackPosts

    typealias Page = SettingsView.Page

    private var parts: (page: Page, section: String, title: String, detail: String, keywords: [String]) {
        switch self {
        case .launchAtLogin:
            (.general, "Zero", "Launch Zero at login", "So agents can always reach you.", ["startup", "login item", "open"])
        case .inboxHotkey: (.general, "Zero", "Inbox hotkey", "Opens the inbox from any app.", ["shortcut", "keyboard", "global", "key"])
        case .notifyNeedsYou:
            (
                .general, "Notifications", "Needs you", "A task asks you something or has a step for you, or one of its workers asks.",
                ["notification", "sound", "alert"]
            )
        case .notifyTrouble:
            (
                .general, "Notifications", "In trouble", "A task fails, gets stuck, runs out of usage, or is blocked.",
                ["notification", "sound", "alert", "error"]
            )
        case .notifyFinished:
            (
                .general, "Notifications", "Finished", "A task is done, replied, or waiting on someone else.",
                ["notification", "sound", "alert", "done"]
            )
        case .updates:
            (.general, "About", "Updates", "Zero's version, and an update when there is one.", ["version", "upgrade", "release"])
        case .zerodAtLogin:
            (
                .general, "About", "Start Zero's daemon at login", "It runs your agents from login, with or without the app open.",
                ["zerod", "login items", "background"]
            )
        case .icons: (.general, "About", "Icons", "Which icons this build draws.", ["nucleo", "lucide"])
        case .health:
            (.general, "Health", "Health", "Zero's own checks, and what to do when one fails.", ["diagnostics", "status", "problem"])
        case .showLog: (.general, "Help", "Show log", "What Zero did and when.", ["logs", "debug", "diagnostics"])
        case .showWelcome:
            (.general, "Help", "Show welcome again", "The welcome screens, as at first launch.", ["onboarding", "intro", "tour"])
        case .undoAnswer: (.inbox, "Answers", "Undo an answer", "Esc takes it back within this time.", ["take back", "escape"])
        case .askExpiry:
            (.inbox, "Answers", "Unanswered asks expire after", "When the agent didn't set its own expiry.", ["timeout", "ttl"])
        case .showBar:
            (
                .bar, "Control bar", "Show the control bar", "Off, asks reach you in Zero's window, notifications and the Dock.",
                ["pill", "hide"]
            )
        case .barInbox: (.bar, "In the bar", "Inbox", "Open asks, blue while one waits.", ["count"])
        case .barAgents: (.bar, "In the bar", "Agents", "A dot for each task, as the sidebar lists them.", ["dots", "tasks", "pinned"])
        case .barAgentsFrom:
            (
                .bar, "In the bar", "Show agents from", "Other workspaces' agents under their mark, folded while nothing there needs you.",
                []
            )
        case .barSettingsButton: (.bar, "In the bar", "Settings button", "Under the bar, out when the pointer is on it.", ["gear"])
        case .followScreen: (.bar, "Placement", "Follow the active screen", "The bar moves to the screen you use.", ["display", "monitor"])
        case .barInWindow:
            (.bar, "Placement", "Show the bar in Zero's window", "Rather than at the screen's edge.", ["dock", "docked", "full screen"])
        case .barAgentList:
            (.bar, "Agents in the bar", "Agents in the bar", "Rename them, remove them, and drag them into order.", ["rename", "reorder"])
        case .relay:
            (
                .devices, "Relay", "Relay server", "Passes your phone's messages to this Mac, end-to-end encrypted.",
                ["iphone", "mobile", "tunnel"]
            )
        case .phones: (.devices, "Phones", "Phones", "Pair a phone, or remove one.", ["iphone", "mobile", "pair", "qr", "device"])
        case .plugin:
            (
                .agents, "Setup", "Zero plugin", "Lets your agents reach your inbox and use your scratchpads.",
                ["install", "claude code", "codex", "mcp"]
            )
        case .archiveDone:
            (
                .agents, "Tasks", "Archive done tasks",
                "Done means finished end to end. Put away then; back when something they follow changes.", ["put away"]
            )
        case .terminalApp:
            (
                .agents, "Tasks", "Terminal app", "Where Open in Terminal takes a task, and a running command's output.",
                ["iterm", "ghostty", "warp"]
            )
        case .suggestFiles:
            (.agents, "Tasks", "Suggest files after @", "Files from the task's project as you type.", ["mention", "autocomplete"])
        case .pausedSend:
            (.agents, "Tasks", "Sending to a paused task", "Ask each time, resume it, or queue the message for Resume.", ["queue"])
        case .plainAnswers:
            (
                .agents, "Tasks", "Plain answers",
                "Short sentences, simple words, steps as lists. A workspace can turn it off. From each task's next start.",
                ["simplified english", "ste", "writing"]
            )
        case .stuckCommands:
            (
                .agents, "Stuck commands", "When a command looks stuck",
                "Stuck: well past its usual time, with no output and no CPU, or waiting for input no one will type. Stopped, its agent is told why and carries on.",
                ["hung", "hang", "timeout", "kill"]
            )
        case .stuckThresholds:
            (
                .agents, "Stuck commands", "Thresholds", "When a command counts as stuck, and the commands Zero never stops.",
                ["hung", "minutes"]
            )
        case .subagents:
            (
                .agents, "Advanced", "Let agents use their own subagents",
                "Off: they hand work to Zero workers, which you can see and stop. From each task's next start.", ["workers"]
            )
        case .compactWindow:
            (
                .agents, "Advanced", "Summarise conversations at",
                "Smaller turns, less usage. Claude Code and Codex, from each task's next start.",
                ["compact", "context", "tokens", "summarize"]
            )
        case .buildCache:
            (
                .agents, "Advanced", "Shared build cache", "Agents' copies of a project reuse each other's compiled dependencies.",
                ["sccache", "compile"]
            )
        case .placesCommand:
            (
                .agents, "Advanced", "Task places command", "A command that tells Zero which folder each ticket's task runs in.",
                ["worktree", "folder"]
            )
        case .activity: (.signins, "Activity", "Activity", "Every account's turns by day.", ["usage", "graph"])
        case .claudeAccounts: (.signins, "Claude Code", "Claude Code", "Its accounts and models.", Self.accountWords + ["anthropic"])
        case .codexAccounts: (.signins, "Codex", "Codex", "Its accounts and models.", Self.accountWords + ["chatgpt", "openai"])
        case .opencodeAccounts: (.signins, "OpenCode", "OpenCode", "Its accounts and models.", Self.accountWords)
        case .commitAsAgent:
            (
                .git, "Agents' commits", "Agents commit as their own account",
                "Their commits are signed and verified; your terminal keeps your key.", ["github account", "verified"]
            )
        case .signingKey:
            (.git, "Agents' commits", "Signing key", "The key agents sign their commits with.", ["ssh", "verified", "private key"])
        case .coauthor:
            (
                .git, "Agents' commits", "Credit you as co-author",
                "Agents become the author and add you as Co-authored-by. Off: you stay the author.", []
            )
        case .coauthorName: (.git, "Agents' commits", "Your name and email", "Whom the co-author line names.", ["email"])
        case .gitFolders:
            (.git, "Only in these folders", "Only in these folders", "Where agents commit this way: every folder, or those you add.", [])
        case .openLinksIn:
            (
                .chrome, "Side panel", "Open links in",
                "Where links you click in Zero open. Option-click opens one in the other place.",
                ["localhost", "development", "default browser", "github", "option"]
            )
        case .panelHosts:
            (
                .chrome, "Side panel", "Also open in the side panel",
                "Besides this Mac's and the local network's addresses: hosts like a staging site, with their subdomains.",
                ["staging", "domain", "host"]
            )
        case .chrome:
            (
                .chrome, "Chrome", "Zero for Chrome", "Lets agents use Chrome, each task in tabs of its own",
                ["extension", "browser", "tabs"]
            )
        case .firefox:
            (
                .chrome, "Firefox", "Firefox Developer Edition", "Opened by Zero under remote control when an agent asks for it",
                ["browser"]
            )
        case .safari:
            (.chrome, "Safari", "Let agents use Safari", "For comparing pages: a signed-out Safari window with real clicks", ["browser"])
        case .pageDialogs:
            (
                .chrome, "Dialogs", "Replace pages' dialogs in agents' tabs (experimental)",
                "A page's alert, confirm or prompt answers at once and is told to the agent, so its window never comes forward",
                ["popup"]
            )
        case .accessibility:
            (
                .desktop, "Permissions", "Accessibility", "Lets agents read apps' windows and act in them, each app as you allow it.",
                ["desktop", "apps", "click", "computer use"]
            )
        case .screenRecording:
            (
                .desktop, "Permissions", "Screen Recording", "Lets agents take pictures and videos of apps' windows you allow.",
                ["desktop", "screenshot", "video", "capture"]
            )
        case .blockedSites: (.chrome, "Blocked sites", "Blocked sites", "Sites no task may open.", ["block", "deny", "domains"])
        case .mcpServers: (.mcp, "Servers", "Servers", "The MCP servers your agents use, and the workspaces they're in.", ["tools", "add"])
        case .workspaces: (.workspaces, "Workspaces", "Workspaces", "Each with its own tasks, folders and settings.", ["add"])
        case .projects: (.workspaces, "Projects", "Projects", "The folders tasks start in.", ["folders", "repositories", "repos"])
        case .githubConnection: (.github, "Connection", "Connection", "Through the GitHub CLI, signed in as it already is.", ["gh"])
        case .githubLinks:
            (
                .github, "Links", "Link pull requests and commits", "repo#123, #123 and commit hashes in messages open on GitHub.",
                ["pr"]
            )
        case .githubToken:
            (
                .github, "Agents' access", "Give agents their own GitHub token",
                "Limits what their gh commands and pushes can reach. Only in the folders Settings › Git keeps it to.",
                ["pat", "permissions"]
            )
        case .githubPush:
            (.github, "Agents' access", "Push with the GitHub CLI's sign-in", "Rather than SSH, which may wait on your own key.", ["https"])
        case .linearConnection: (.linear, "Connection", "Connection", "Linear, connected and kept on this Mac.", [])
        case .linearLinks: (.linear, "Links", "Link issues", "ABC-123 in messages opens the issue.", ["tickets"])
        case .linearApp: (.linear, "Links", "Open issues in the Linear app", "Rather than the browser.", [])
        case .linearWrites:
            (
                .linear, "Agents", "Let agents make changes",
                "Agents read Linear through Zero. On, they can change it too, each change approved by you. Zero asks Linear for write access only while this is on: after changing it, disconnect and connect Linear again.",
                ["write"]
            )
        case .slackConnection: (.slack, "Connection", "Connection", "Slack workspaces, their #channels and message links.", [])
        case .slackPosts:
            (
                .slack, "Agents", "Let agents post",
                "Agents read Slack through Zero. On, they can post too, each post approved by you. Zero's Slack app has chat:write only while this is on: after changing it, add or remove chat:write in the app's User Token Scopes in Slack, reinstall it, and connect Slack again with the new token.",
                ["write", "message"]
            )
        }
    }

    private static let accountWords = ["sign in", "login", "account", "api key", "model", "subscription"]

    var page: Page { parts.page }
    var section: String { parts.section }
    var title: String { parts.title }
    var detail: String { parts.detail }
    var entry: SettingsEntry {
        SettingsEntry(id: rawValue, page: page.rawValue, section: section, title: title, detail: detail, keywords: parts.keywords)
    }
    /// A section found as a whole (a list, a card of its own): it lands at the section, not on a row.
    var isSection: Bool { title == section }
    static func anchor(section: String) -> String { "section:" + section }
    /// The folded part it's in, unfolded as it's opened: the key its page keeps the fold in.
    var unfolds: String? { section == "Advanced" ? AgentsAdvanced.key : nil }

    static let index = allCases.map(\.entry)
}

/// Whether Settings › Agents shows its Advanced rows.
enum AgentsAdvanced { static let key = "settingsAgentsAdvanced" }

extension EnvironmentValues {
    /// The setting a search result just opened: its row lit, the light fading.
    @Entry var settingLit: Setting? = nil
    /// Where a row sits in its card (Rows), so a fill on it takes the card's corners there.
    @Entry var rowEnds: (first: Bool, last: Bool) = (false, false)
}

/// Settings' search, at the top of its sidebar: ⌘F says itself while it's empty, × in its place once something is
/// typed. ↑↓ move through the results, ↩ opens one, Esc clears.
struct SettingsSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let move: (Int) -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            NucleoIcon("magnifier", size: 13).foregroundStyle(.secondary)
            TextField("Search settings", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                .focused(focused)
                .onSubmit(open)
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            Group {
                if query.isEmpty {
                    Text("⌘F").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                } else {
                    Button {
                        query = ""
                    } label: {
                        NucleoIcon("xmark", size: 11).foregroundStyle(.secondary).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).tip("Clear")
                }
            }
            .frame(width: 20)
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 30)
        .searchField()
        // The whole field takes the click, its padding too.
        .contentShape(Rectangle()).onTapGesture { focused.wrappedValue = true }
        .padding(.bottom, 6)
        // ⌘F from anywhere in Settings.
        .background { Button("") { focused.wrappedValue = true }.keyboardShortcut("f", modifiers: .command).hidden() }
    }
}

extension View {
    /// A sidebar's search field (Settings, Scratchpads): the field's own white or dark fill and a hairline edge, which
    /// reads on the sidebar's grey in both appearances.
    func searchField() -> some View {
        background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldEdge))
    }
}

/// What the search found, in the page's place: a card for each page, a row for each setting with its section; the
/// one ↑↓ is on lit, the pointer moving it as a menu's does. Nothing found is one line where the first heading would
/// be, so nothing jumps.
struct SettingsResults: View {
    let query: String
    let results: [(page: String, entries: [SettingsEntry])]
    @Binding var selected: Int
    let open: (SettingsEntry) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitle(text: "Search").padding(.bottom, 24)
                    if results.isEmpty {
                        Text("No settings match “\(query.trimmingCharacters(in: .whitespaces))”.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).frame(height: 26)
                    } else {
                        Sections {
                            ForEach(Array(results.enumerated()), id: \.element.page) { index, found in
                                let page = SettingsView.Page(rawValue: found.page) ?? .general
                                let start = results[..<index].map(\.entries.count).reduce(0, +)
                                SettingsSection(title: page.rawValue, icon: AnyView(Self.mark(page))) {
                                    card(found.entries, from: start)
                                }
                            }
                        }
                    }
                }
                .centredColumn(680).padding(.vertical, 28)
            }
            .thinScrollbar()
            .onChange(of: selected) { _, index in
                let all = results.flatMap(\.entries)
                if all.indices.contains(index) { proxy.scrollTo(all[index].id) }
            }
        }
    }

    static func mark(_ page: SettingsView.Page) -> some View {
        Group {
            if let integration = page.integration {
                integration.icon(size: 14)
            } else {
                NucleoIcon(page.icon, size: 14).foregroundStyle(.secondary)
            }
        }
    }

    private func card(_ entries: [SettingsEntry], from start: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                if offset > 0 { Hairline().padding(.horizontal, 18) }
                let index = start + offset
                // Square, but for the card's own corners at its ends.
                let top: CGFloat = offset == 0 ? 14 : 0, bottom: CGFloat = offset == entries.count - 1 ? 14 : 0
                Button {
                    open(entry)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.system(size: 13, weight: .medium))
                            Text(entry.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        if entry.section != entry.title {
                            Text(entry.section).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        index == selected ? Theme.chip : .clear,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { selected = index } }
                .id(entry.id)
            }
        }
        .bleedingCard()
    }
}
