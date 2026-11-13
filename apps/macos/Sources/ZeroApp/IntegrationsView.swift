import AppKit
import SwiftUI
import ZeroCore

/// The integrations, as Settings names and draws them: connected so agents can follow pull requests, issues and
/// threads, and so issue ids and channels in messages link.
enum Integration: String, CaseIterable, Identifiable {
    case github, linear, slack
    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .linear: "Linear"
        case .slack: "Slack"
        }
    }

    @ViewBuilder func icon(size: CGFloat) -> some View {
        switch self {
        case .github: NucleoIcon("github", fill: "glyph", size: size)
        case .slack: NucleoIcon("slack", fill: "glyph", size: size)
        case .linear:
            if let mark = Self.linearMark {
                Image(nsImage: mark).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
            }
        }
    }

    /// Linear isn't in Nucleo, and the app bundles its tile (a light mark on a dark square): the mark alone, its
    /// brightness as its opacity and cropped to it, so it draws as a template like the rest.
    static let linearMark: NSImage? = {
        guard let tile = Bundle.main.image(forResource: "linear"), let source = tile.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let (width, height) = (source.width, source.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var (minX, minY, maxX, maxY) = (width, height, 0, 0)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let light = (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
                let alpha = UInt8(max(0, min(1, (light - 0.28) / 0.22)) * Double(pixels[i + 3]))
                (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (alpha, alpha, alpha, alpha)
                if alpha > 40 { (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y)) }
            }
        }
        guard maxX > minX,
            let mark = context.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        let image = NSImage(cgImage: mark, size: NSSize(width: mark.width, height: mark.height))
        image.isTemplate = true
        return image
    }()

    /// The account it's connected as: gh's login, the Linear workspace, or the Slack workspace.
    @MainActor func account(in state: IntegrationState?) -> String? {
        switch self {
        case .github: state?.github
        case .linear: state?.linear
        case .slack: state?.slack.flatMap { $0.isEmpty ? nil : $0.map(\.team.name).joined(separator: ", ") }
        }
    }

    /// What agents can follow through it (the Following section).
    var followingDetail: String {
        switch self {
        case .github:
            "Agents follow pull requests with zero follow <url>: reviews, comments, CI, pushes and merges reach them between turns."
        case .linear:
            "Agents follow issues, or one comment thread, with zero follow <url>: status changes and comments reach them between turns."
        case .slack: "Agents follow threads and channels with zero follow <url>: replies reach them between turns."
        }
    }
}

/// Settings › GitHub, Linear or Slack: its connection, how what it names in messages links, and what agents follow
/// through it.
struct IntegrationPage: View {
    let integration: Integration
    let workspace: Workspace?
    @AppStorage(GitHubLinks.key) private var github = true
    @AppStorage(LinearLinks.enabledKey) private var linear = true
    @AppStorage(LinearLinks.key) private var linearInApp = true
    @State private var connectingSlack = false

    var body: some View {
        Sections {
            if let workspace { connection(workspace) }
            switch integration {
            case .github:
                SettingsSection(title: "Links") {
                    Rows {
                        SettingRow(
                            title: "Link pull requests and commits", detail: "repo#123, #123 and commit hashes in messages open on GitHub."
                        ) { Switch(isOn: $github) }
                    }
                }
                AgentsGitHubAccess()
            case .linear:
                SettingsSection(title: "Links") {
                    Rows {
                        SettingRow(title: "Link issues", detail: "ABC-123 in messages opens the issue.") { Switch(isOn: $linear) }
                        SettingRow(title: "Open issues in the Linear app", detail: "Rather than the browser.") {
                            Switch(isOn: Binding(get: { linear && LinearLinks.installed && linearInApp }, set: { linearInApp = $0 }))
                                .disabled(!linear || !LinearLinks.installed)
                                .tip(!LinearLinks.installed ? "Linear's app isn't installed" : linear ? "" : "Issue links are off")
                        }
                    }
                }
                AgentWrites(
                    title: "Let agents make changes", key: "linearChanges",
                    detail:
                        "Agents read Linear through Zero. On, they can change it too, each change approved by you. Zero asks Linear for write access only while this is on: after changing it, disconnect and connect Linear again."
                )
            case .slack:
                AgentWrites(
                    title: "Let agents post", key: "slackPosts",
                    detail:
                        "Agents read Slack through Zero. On, they can post too, each post approved by you. Zero's Slack app has chat:write only while this is on: after changing it, add or remove chat:write in the app's User Token Scopes in Slack, reinstall it, and connect Slack again with the new token."
                )
            }
            if let workspace, integration.account(in: workspace.integrations) != nil {
                SettingsSection(title: "Following") {
                    Text(integration.followingDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FollowRows(workspace: workspace, source: integration)
                }
            }
        }
        .task { await workspace?.loadIntegrations() }
        .zeroDialog(isPresented: $connectingSlack) { if let workspace { SlackConnect(workspace: workspace) } }
    }

    @ViewBuilder private func connection(_ workspace: Workspace) -> some View {
        if let account = integration.account(in: workspace.integrations) {
            switch integration {
            case .slack:
                SettingsSection(
                    title: "Workspaces", accessory: AnyView(GhostButton(title: "Connect Slack", icon: "plus") { connectingSlack = true })
                ) {
                    Rows {
                        ForEach(workspace.integrations?.slack ?? [], id: \.team.id) { connected in
                            SettingRow(
                                title: connected.team.name,
                                detail: "\(connected.team.domain).slack.com: its #channels and message links open in Slack."
                            ) {
                                RowButton(title: "Disconnect") { Task { await workspace.disconnectSlack(team: connected.team.id) } }
                            }
                        }
                    }
                }
            case .github, .linear:
                SettingsSection(title: "Connection") {
                    Rows {
                        SettingRow(
                            title: integration == .github ? "Connected as \(account)" : "Connected to \(account)",
                            detail: integration == .github
                                ? "Through the GitHub CLI, signed in as it already is." : "Kept on this Mac."
                        ) {
                            if integration == .linear { RowButton(title: "Disconnect") { Task { await workspace.disconnectLinear() } } }
                        }
                    }
                }
            }
        } else {
            SettingsSection(title: "Connection") {
                ConnectCard(integration: integration, workspace: workspace) { connectingSlack = true }.bleedingCard()
            }
        }
    }
}

/// Whether agents may write through a connection (`zero slack`, `zero linear`): zerod's setting, off unless turned on,
/// and every write still the user's to approve.
private struct AgentWrites: View {
    let title: String
    let key: String
    let detail: String
    @State private var on = false
    @State private var link = try? ZerodLink()

    var body: some View {
        SettingsSection(title: "Agents") {
            Rows {
                SettingRow(title: title, detail: detail) {
                    Switch(
                        isOn: Binding(
                            get: { on },
                            set: { chosen in
                                on = chosen
                                Task { _ = try? await link?.call("configure", [key: chosen]) }
                            }))
                }
            }
        }
        .task { if let settings = try? await link?.call("settings") as? [String: Any] { on = settings[key] as? Bool ?? false } }
    }
}

/// Lays its children out in rows, starting a new row when the next doesn't fit; `trailing` ends each row at the right.
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

/// Not connected yet: the integration's mark, what it gives you, and the one step to connect it (Linear signs in in the
/// browser; GitHub goes through the GitHub CLI, signed in in a terminal; Slack takes a token, in `connectSlack`'s dialog).
struct ConnectCard: View {
    let integration: Integration
    let workspace: Workspace
    let connectSlack: () -> Void
    @State private var waiting = false

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16).fill(Theme.composer).frame(width: 64, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke))
                .overlay(integration.icon(size: 30).foregroundStyle(.primary))
                .padding(.bottom, 18)
            PageTitle(text: "Connect \(integration.title)").padding(.bottom, 6)
            BalancedText(pitch, font: .systemFont(ofSize: 13), maxWidth: 380)
                .foregroundStyle(.secondary).padding(.bottom, 20)
            switch integration {
            case .linear:
                SolidButton(title: waiting ? "Waiting for Linear…" : "Connect Linear", enabled: !waiting) { connectLinear() }
            case .slack:
                SolidButton(title: "Connect Slack…", action: connectSlack)
            case .github:
                HStack(spacing: 8) {
                    Text("gh auth login").font(.system(size: 12.5).monospaced())
                    CopyButton(text: "gh auth login", size: 24)
                }
                .padding(.leading, 12).padding(.trailing, 4).frame(height: 34)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
                .padding(.bottom, 14)
                SolidButton(title: waiting ? "Checking…" : "Check again", enabled: !waiting) { check() }
                Text("Run it in a terminal to sign the GitHub CLI in. No GitHub CLI? brew install gh.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 12)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var pitch: String {
        switch integration {
        case .linear: "Issue ids in messages open in Linear, and agents can follow an issue or one of its threads to hear its changes."
        case .github: "Agents follow pull requests through the GitHub CLI: reviews, comments, CI and merges reach them between turns."
        case .slack:
            "Channels and threads named in messages open in Slack itself, and agents can follow a thread or a channel to hear its replies. Zero reads channels, messages and names, and posts only if you let agents."
        }
    }

    private func connectLinear() {
        waiting = true
        Task {
            if let url = await workspace.connectLinear() { NSWorkspace.shared.open(url) }
            // It finishes in the browser: look again until it has.
            for _ in 0..<150 where workspace.integrations?.linear == nil {
                try? await Task.sleep(for: .seconds(2))
                await workspace.loadIntegrations()
            }
            waiting = false
        }
    }

    private func check() {
        waiting = true
        Task {
            await workspace.loadIntegrations(); waiting = false
        }
    }

}

/// Centred text wrapped into lines of even length (CSS's text-wrap: balance): as narrow as still takes the same number
/// of lines it needs at `maxWidth`, so no line is left with a word or two.
struct BalancedText: View {
    let text: String
    let font: NSFont
    let maxWidth: CGFloat

    init(_ text: String, font: NSFont, maxWidth: CGFloat) { self.text = text; self.font = font; self.maxWidth = maxWidth }

    var body: some View {
        Text(text).font(Font(font)).multilineTextAlignment(.center).frame(width: width).fixedSize(horizontal: false, vertical: true)
    }

    /// Narrows from `maxWidth` while the text still fits in as many lines.
    private var width: CGFloat {
        let lines = { (width: CGFloat) -> Int in
            let height = (text as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                attributes: [.font: font]
            ).height
            return Int((height / (font.ascender - font.descender + font.leading)).rounded())
        }
        let target = lines(maxWidth)
        var (low, high) = (CGFloat(40), maxWidth)
        while high - low > 2 {
            let middle = (low + high) / 2
            if lines(middle) > target { low = middle } else { high = middle }
        }
        return ceil(high) + 1
    }
}

/// Linear links open in Linear's app when it's installed, unless you'd rather the browser.
enum LinearLinks {
    static let key = "linearOpensInApp"
    /// Issues (ABC-123) in messages as links; on unless turned off. Opening them in the app needs this on.
    static let enabledKey = "linearLinks"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static let installed = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "linear://")!) != nil
    static var inApp: Bool { enabled && installed && UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// The link to open: Linear's web link as the app's (linear://acme/issue/ENG-1), when the app opens it.
    static func url(_ link: String) -> URL? {
        let web = "https://linear.app/"
        return URL(string: inApp && link.hasPrefix(web) ? "linear://" + link.dropFirst(web.count) : link)
    }

    /// Opens a link the way the user set: every link a user clicks in Zero goes through here, so a Linear issue
    /// written as a full web link (an agent's Markdown link, a follow, a Later item) opens in the app too.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(Self.url(url.absoluteString) ?? url)
    }
}

/// Connecting a Slack workspace: Zero's Slack app made in it from the manifest, then the user token Slack shows.
struct SlackConnect: View {
    let workspace: Workspace
    @Environment(\.closeDialog) private var dismiss
    @State private var token = ""
    /// Whether agents may post: the app is made with chat:write only then.
    @State private var posts = false
    @State private var link = try? ZerodLink()
    @State private var waiting = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogTitle(
                text: "Connect Slack",
                detail:
                    "Zero reads channels, messages and names, and posts only if you let agents. Each workspace gets Zero's own Slack app. Connected before? Give your app the scopes in the manifest (chat:write only if agents may post), reinstall it, and paste the new token."
            )
            DialogPart(title: "1. Make Zero's app in the workspace") {
                HStack {
                    Text("Slack opens with it filled in: Create, then Install to Workspace.").font(.system(size: 12.5)).fixedSize(
                        horizontal: false, vertical: true)
                    Spacer()
                    DialogButton(title: "Open Slack") { NSWorkspace.shared.open(Slack.createAppURL(posts: posts)) }
                }
            }
            DialogPart(title: "2. Paste its User OAuth Token") {
                SecureField("", text: $token, prompt: Text("xoxp-…")).textFieldStyle(.dialog).onSubmit(connect).firstField()
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                DialogButton(title: "Cancel") { dismiss() }
                DialogButton(
                    title: waiting ? "Connecting…" : "Connect", kind: .primary,
                    enabled: !waiting && !token.trimmingCharacters(in: .whitespaces).isEmpty, action: connect)
            }
        }
        .frame(width: 440)
        .task {
            if let settings = try? await link?.call("settings") as? [String: Any] { posts = settings["slackPosts"] as? Bool ?? false }
        }
    }

    private func connect() {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        waiting = true
        problem = nil
        Task {
            problem = await workspace.connectSlack(token: token)
            waiting = false
            if problem == nil { dismiss() }
        }
    }
}
