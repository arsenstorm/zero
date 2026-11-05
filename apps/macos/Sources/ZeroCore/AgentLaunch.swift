import Foundation

/// Starting one agent as a particular account. Claude Code takes `CLAUDE_CODE_OAUTH_TOKEN` from its settings
/// once, at start, so the token goes into a settings file only the user can read, the agent starts with
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

/// `claude setup-token` under a pseudo-terminal (it is an interactive screen), with its input kept open so the
/// code from the browser can be typed into it, and its output collected to read the token from.
public final class TokenSetup: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var text = ""

    public init() {}

    func start() -> Bool {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // Wide enough that the token, about 110 characters, prints on one line instead of wrapping.
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-lc", "stty cols 400 rows 50; claude setup-token"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            self?.lock.withLock { self?.text += chunk }
        }
        return (try? process.run()) != nil
    }

    var running: Bool { process.isRunning }

    func send(_ code: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data((code + "\r").utf8))
    }

    /// The token once Claude Code has printed it, on one line of its (wide) screen. Control sequences (colours,
    /// cursor moves, links) are taken out first, so none can cut it short.
    func token() -> String? {
        let screen = lock.withLock { text }
        let plain = screen
            .replacingOccurrences(of: #"\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?<>=]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}[()][A-Za-z0-9]"#, with: "", options: .regularExpression)
        return plain.range(of: #"sk-ant-oat01-[A-Za-z0-9_-]{40,}"#, options: .regularExpression).map { String(plain[$0]) }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
