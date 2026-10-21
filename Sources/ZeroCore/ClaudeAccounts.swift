import Foundation

/// Claude Code accounts Zero can switch between. Claude Code signs in through one Keychain item ("Claude Code-
/// credentials") plus `oauthAccount` in ~/.claude.json; Zero keeps a copy of each account's item under its own
/// name and swaps the chosen one in, so every Claude Code (agents and the terminal) runs as that account.
/// Agents already running keep the account they started with until they restart.
@MainActor @Observable
public final class ClaudeAccounts {
    public struct Account: Codable, Sendable, Identifiable {
        public var email: String
        public var plan: String?
        /// ~/.claude.json's `oauthAccount` for this account, as JSON.
        var oauthAccount: Data?
        /// The Keychain item's account attribute, which Claude Code looks it up by.
        var keychainAccount: String
        public var id: String { email }
    }

    /// The share of a limit used, 0–100, in the 5-hour and 7-day windows.
    public struct Usage: Sendable { public let fiveHour: Double?; public let sevenDay: Double? }

    /// Which usage limit auto-switch watches; `either` switches when one of the two reaches the threshold.
    public enum Window: String, CaseIterable, Sendable { case fiveHour, weekly, either }

    public static let shared = ClaudeAccounts()
    static let claudeService = "Claude Code-credentials"

    public private(set) var accounts: [Account] = []
    public private(set) var active: String?
    /// Accounts with a long-lived token of their own, so a single agent can run as them.
    public private(set) var perAgent: Set<String> = []
    public private(set) var usage: [String: Usage] = [:]
    public var autoSwitch: Bool {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "claudeAutoSwitch") }
    }
    /// The share of a limit, in percent, at which auto-switch moves on.
    public var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "claudeAutoSwitchThreshold") }
    }
    public var window: Window {
        didSet { UserDefaults.standard.set(window.rawValue, forKey: "claudeAutoSwitchWindow") }
    }
    /// Called after the active account changes, so models can be fetched for it.
    public var onSwitch: (() -> Void)?

    private static let file = Paths.dir.appendingPathComponent("claude-accounts.json")
    private static let claudeJSON = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    private var timer: Timer?

    init() {
        autoSwitch = UserDefaults.standard.object(forKey: "claudeAutoSwitch") as? Bool ?? true
        threshold = UserDefaults.standard.object(forKey: "claudeAutoSwitchThreshold") as? Double ?? 98
        window = UserDefaults.standard.string(forKey: "claudeAutoSwitchWindow").flatMap(Window.init(rawValue:)) ?? .either
        accounts = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        if accounts.isEmpty { importSwitcher() }
        active = Self.activeEmail()
        if let active, !accounts.contains(where: { $0.email == active }) { captureActive() }
        perAgent = Set(accounts.map(\.email).filter { AgentLaunch.token($0) != nil })
    }

    /// Mints a year-long token for `email` with `claude setup-token` (Arsen signs in as that account in the
    /// browser) and keeps it in the Keychain. Returns an error to show, or nil.
    public func setUpPerAgent(_ email: String) async -> String? {
        let output = await Self.setupToken()
        // The token can wrap across lines in the terminal UI; it has no spaces of its own.
        let joined = output.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let range = joined.range(of: #"sk-ant-oat01-[A-Za-z0-9_-]{20,}"#, options: .regularExpression) else {
            return "Claude Code didn't give a token. Try again and finish signing in."
        }
        guard AgentLaunch.save(String(joined[range]), for: email) else { return "Couldn't keep the token in the Keychain." }
        perAgent.insert(email)
        return nil
    }

    public func removePerAgent(_ email: String) {
        AgentLaunch.delete(email)
        perAgent.remove(email)
    }

    /// Checks usage now and every five minutes after.
    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    /// Makes `email` the account Claude Code signs in as. Returns an error to show, or nil.
    @discardableResult
    public func switchTo(_ email: String) -> String? {
        guard email != active else { return nil }
        guard let target = accounts.first(where: { $0.email == email }), let credentials = Self.read(Self.slot(email)) else {
            return "Zero has no sign-in saved for \(email). Remove it and add it again."
        }
        saveActive()
        guard Self.write(Self.claudeService, account: target.keychainAccount, secret: credentials) else {
            return "Couldn't switch to \(email)."
        }
        if let oauth = target.oauthAccount { Self.setOAuthAccount(oauth) }
        active = email
        onSwitch?()
        Task { await check(switching: false) }
        return nil
    }

    /// Signs in to another account with `claude auth login` (it opens the browser) and keeps it active.
    public func add() async -> String? {
        saveActive()
        let previous = active
        _ = await Self.claude("auth logout")
        while Self.delete(Self.claudeService) {}
        let output = await Self.claude("auth login")
        guard Self.read(Self.claudeService) != nil, let email = Self.activeEmail() else {
            if let previous { switchBack(previous) }
            return output.isEmpty ? "Claude Code didn't sign in." : output
        }
        active = email
        captureActive()
        onSwitch?()
        Task { await check(switching: false) }
        return nil
    }

    public func remove(_ email: String) {
        guard email != active else { return }
        removePerAgent(email)
        accounts.removeAll { $0.email == email }
        usage[email] = nil
        _ = Self.delete(Self.slot(email))
        persist()
    }

    private func switchBack(_ email: String) {
        guard let account = accounts.first(where: { $0.email == email }), let credentials = Self.read(Self.slot(email)) else { return }
        _ = Self.write(Self.claudeService, account: account.keychainAccount, secret: credentials)
        if let oauth = account.oauthAccount { Self.setOAuthAccount(oauth) }
        active = email
    }

    /// Fetches each account's usage; at the threshold, moves to the account with the most room.
    func check(switching: Bool = true) async {
        active = Self.activeEmail()
        // Signed in from the terminal to an account Zero hadn't seen: keep it too.
        if let active, !accounts.contains(where: { $0.email == active }) { captureActive() }
        saveActive()
        for account in accounts {
            guard let token = Self.read(Self.slot(account.email)).flatMap(Self.accessToken) else { continue }
            usage[account.email] = await Self.fetchUsage(token)
        }
        guard switching, autoSwitch, let active, let current = usage[active], exhausted(current) else { return }
        let others = accounts.filter { $0.email != active }
        let target = others.first { usage[$0.email].map { !exhausted($0) } ?? false } ?? others.first { usage[$0.email] == nil }
        if let target { switchTo(target.email) }
    }

    func exhausted(_ usage: Usage) -> Bool { Self.exhausted(usage, at: threshold, watching: window) }

    static func exhausted(_ usage: Usage, at threshold: Double, watching window: Window) -> Bool {
        let used = switch window {
        case .fiveHour: usage.fiveHour ?? 0
        case .weekly: usage.sevenDay ?? 0
        case .either: max(usage.fiveHour ?? 0, usage.sevenDay ?? 0)
        }
        return used >= threshold
    }

    /// Copies Claude Code's current sign-in into the active account's slot: Claude Code rotates its tokens, and
    /// the slot must hold the latest ones before Zero swaps another account in.
    private func saveActive() {
        guard let active, let index = accounts.firstIndex(where: { $0.email == active }),
              let credentials = Self.read(Self.claudeService) else { return }
        _ = Self.write(Self.slot(active), account: accounts[index].keychainAccount, secret: credentials)
        if let oauth = Self.oauthAccount() { accounts[index].oauthAccount = oauth }
        persist()
    }

    /// Adds the account Claude Code is signed in as now.
    private func captureActive() {
        guard let email = Self.activeEmail(), let credentials = Self.read(Self.claudeService) else { return }
        let keychainAccount = Self.keychainAccount(Self.claudeService) ?? NSUserName()
        _ = Self.write(Self.slot(email), account: keychainAccount, secret: credentials)
        accounts.removeAll { $0.email == email }
        accounts.append(Account(email: email, plan: Self.plan(credentials), oauthAccount: Self.oauthAccount(), keychainAccount: keychainAccount))
        persist()
    }

    /// Claude Switcher's saved accounts, the first time Zero runs without any of its own.
    private func importSwitcher() {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-switcher/accounts.json")
        guard let data = try? Data(contentsOf: config), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = json["accounts"] as? [[String: Any]] else { return }
        for entry in saved where (entry["provider"] as? String ?? "claude") == "claude" {
            guard let email = entry["email"] as? String, let credentials = Self.read("claude-switcher:\(email)") else { continue }
            let keychainAccount = entry["keychain_account"] as? String ?? NSUserName()
            guard Self.write(Self.slot(email), account: keychainAccount, secret: credentials) else { continue }
            let oauth = (entry["oauth_account"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            accounts.append(Account(email: email, plan: entry["subscription_type"] as? String ?? Self.plan(credentials),
                                    oauthAccount: oauth, keychainAccount: keychainAccount))
        }
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(accounts).write(to: Self.file, options: .atomic)
    }

    // MARK: Claude Code's files

    static func slot(_ email: String) -> String { "Zero Claude: \(email)" }

    private static func claudeConfig() -> [String: Any]? {
        (try? Data(contentsOf: claudeJSON)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func activeEmail() -> String? {
        (claudeConfig()?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    private static func oauthAccount() -> Data? {
        (claudeConfig()?["oauthAccount"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    /// Replaces `oauthAccount` in ~/.claude.json and leaves the rest of it as it is.
    private static func setOAuthAccount(_ oauth: Data) {
        guard var config = claudeConfig(), let account = try? JSONSerialization.jsonObject(with: oauth) else { return }
        config["oauthAccount"] = account
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) {
            try? data.write(to: claudeJSON, options: .atomic)
        }
    }

    private static func plan(_ credentials: String) -> String? {
        oauth(credentials)?["subscriptionType"] as? String
    }

    static func accessToken(_ credentials: String) -> String? {
        oauth(credentials)?["accessToken"] as? String
    }

    private static func oauth(_ credentials: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(credentials.utf8)) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
    }

    private static func fetchUsage(_ token: String) async -> Usage? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> Double? { ((json[key] as? [String: Any])?["utilization"] as? NSNumber)?.doubleValue }
        return Usage(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
    }

    // MARK: Keychain, through macOS's `security` tool (no prompt; see Linear's Keychain)

    private static func read(_ service: String) -> String? {
        security(["find-generic-password", "-s", service, "-w"])
    }

    private static func keychainAccount(_ service: String) -> String? {
        guard let attributes = security(["find-generic-password", "-s", service]),
              let line = attributes.split(separator: "\n").first(where: { $0.contains("\"acct\"") }),
              let value = line.split(separator: "=", maxSplits: 1).last else { return nil }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private static func write(_ service: String, account: String, secret: String) -> Bool {
        while delete(service) {}
        return security(["add-generic-password", "-s", service, "-a", account, "-w", secret]) != nil
    }

    private static func delete(_ service: String) -> Bool {
        security(["delete-generic-password", "-s", service]) != nil
    }

    private static func security(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `claude setup-token` under a pseudo-terminal (it is an interactive screen), its whole output.
    private static func setupToken() async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/zsh", "-lc", "claude setup-token"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// `claude` from a login shell, so it is the one on Arsen's PATH.
    private static func claude(_ arguments: String) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "claude \(arguments) 2>&1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? "" : String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

/// Starting one agent as a particular account. Claude Code takes `CLAUDE_CODE_OAUTH_TOKEN` from its settings
/// once, at start, so the token goes into a settings file only Arsen can read, the agent starts with
/// `--settings <file>`, and once it is up the file is rewritten without the token. Solo keeps the launch
/// arguments, so they name the file and never hold the token itself. The tokens live in the Keychain.
public enum AgentLaunch {
    static let folder = Paths.dir.appendingPathComponent("claude/launch")
    static func service(_ email: String) -> String { "Zero Claude token: \(email)" }

    /// A new launch file for `email`, holding its token. nil when the account has no token.
    public static func arm(_ email: String) -> String? {
        arm(email, at: folder.appendingPathComponent("\(UUID().uuidString).json").path)
    }

    /// Puts `email`'s token back into an existing launch file, before the agent is started again.
    @discardableResult
    public static func arm(_ email: String, at path: String) -> String? {
        guard let token = token(email) else { return nil }
        return write(["ZERO_MANAGED": "1", "CLAUDE_CODE_OAUTH_TOKEN": token], to: path) ? path : nil
    }

    /// The agent is up: the file keeps only what any later start of it needs.
    public static func scrub(_ path: String) { _ = write(["ZERO_MANAGED": "1"], to: path) }

    /// The launch file named in an agent's arguments, if it has one.
    public static func file(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--settings"), arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        return path.hasPrefix(folder.path) ? path : nil
    }

    private static func write(_ env: [String: String], to path: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: ["env": env]) else { return false }
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }

    static func token(_ email: String) -> String? { security(["find-generic-password", "-s", service(email), "-w"]) }

    static func save(_ token: String, for email: String) -> Bool {
        security(["add-generic-password", "-U", "-s", service(email), "-a", email, "-w", token]) != nil
    }

    static func delete(_ email: String) { _ = security(["delete-generic-password", "-s", service(email)]) }

    private static func security(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
