import Foundation
import Observation

/// Signing a Claude account in as a year-long token (`claude setup-token`: Claude's page in the browser, then a code
/// to paste back if it asks), kept in the Keychain as one of Zero's sign-ins. A task runs as it with the token alone
/// and the user's own Claude Code folder for everything else, so MCP sign-ins, plugins and settings are every
/// account's. Claude Code does the signing in; Zero reads the token it prints, and asks Claude Code whose it is.
@MainActor @Observable public final class ClaudeSignIn {
    public enum Status: Equatable, Sendable { case signingIn, checking, done, failed(String) }
    public private(set) var status: Status?
    @ObservationIgnored private var setup: TokenSetup?

    public init() {}

    /// A new sign-in named `label` (Claude Code doesn't say whose a token is), or `replacing` one (an account with a folder of its own), keeping its id so tasks set to it
    /// carry on as it.
    public func start(replacing: ZerodLink.SignIn? = nil, label: String = "", in workspace: Workspace) {
        cancel()
        let setup = TokenSetup()
        guard setup.start() else { status = .failed("Couldn't start Claude Code's sign-in."); return }
        self.setup = setup
        status = .signingIn
        // Some sign-ins finish without a code: watched for the token for ten minutes either way.
        Task {
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(1))
                guard self.setup === setup else { return }
                // Claude Code exits as soon as it has printed the token: what it printed is read once more after.
                let ended = !setup.running
                if ended { try? await Task.sleep(for: .milliseconds(500)) }
                if let token = setup.token() {
                    status = .checking
                    setup.stop()
                    self.setup = nil
                    let whose = await Self.account(of: token)
                    var signin = ZerodLink.SignIn(
                        cli: .claude, kind: .token, label: whose.email ?? replacing?.label ?? (label.isEmpty ? "Claude account" : label))
                    if let replacing { signin.id = replacing.id }
                    signin.plan = whose.plan ?? replacing?.plan
                    let error = await workspace.addSignIn(signin, secret: token)
                    status = error.map(Status.failed) ?? .done
                    return
                }
                if ended { break }
            }
            guard self.setup === setup else { return }
            setup.stop()
            self.setup = nil
            status = .failed("Claude Code's sign-in ended without a token. Try again.")
        }
    }

    /// The code Claude's page shows, handed to Claude Code; the watch above picks up the token it prints.
    public func submit(code: String) {
        status = .checking
        setup?.send(code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func cancel() {
        setup?.stop()
        setup = nil
        status = nil
    }

    /// Whose a token is, as Claude Code says (`claude auth status`), run with the token in an empty folder of its
    /// own: in the user's own, Claude Code would answer for the account signed in there. The token goes in the
    /// process's environment, never its arguments.
    nonisolated static func account(of token: String) async -> (email: String?, plan: String?) {
        await Task.detached {
            let empty = FileManager.default.temporaryDirectory.appendingPathComponent("zero-claude-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "claude auth status --json"]
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            env["CLAUDE_CONFIG_DIR"] = empty.path
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (nil, nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let said = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (said?["email"] as? String, said?["subscriptionType"] as? String)
        }.value
    }
}
