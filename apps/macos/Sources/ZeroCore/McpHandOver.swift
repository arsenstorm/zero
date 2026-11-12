import Foundation

/// Codex's own MCP servers: those in its config.toml's `[mcp_servers]`, as `codex mcp list --json` describes them (its
/// plugins' servers aren't the user's to move, so they're left out).
public enum CodexMcpServers {
    public static func list(
        home: URL = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    ) async -> [ClaudeMcpServers.Server] {
        guard let config = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8),
            config.contains("[mcp_servers")
        else { return [] }
        let listed = await McpHandOver.output(["codex", "mcp", "list", "--json"]) ?? Data()
        return parse(listed, config: config)
    }

    /// `listed`: `codex mcp list --json`'s output; `config`: its config.toml, for which servers are the user's own.
    static func parse(_ listed: Data, config: String) -> [ClaudeMcpServers.Server] {
        // `[mcp_servers.name]`, `[mcp_servers."a name"]` and their subtables (`.env`): no TOML reader for one name.
        let header = #/^\[mcp_servers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))[.\]]/#.anchorsMatchLineEndings()
        let own = Set(config.matches(of: header).map { String($0.output.1 ?? $0.output.2 ?? "") })
        let entries = (try? JSONSerialization.jsonObject(with: listed)) as? [[String: Any]] ?? []
        return entries.compactMap { entry -> ClaudeMcpServers.Server? in
            guard let name = entry["name"] as? String, own.contains(name) else { return nil }
            let transport = entry["transport"] as? [String: Any] ?? [:]
            let command = transport["command"] as? String
            let args = transport["args"] as? [String] ?? []
            let passed = transport["env_vars"] as? [Any] ?? []
            return ClaudeMcpServers.Server(
                name: name, detail: (transport["url"] as? String) ?? ([command ?? ""] + args).joined(separator: " "), project: nil,
                needsSignIn: false, cli: .codex, command: command, args: args, env: transport["env"] as? [String: String] ?? [:],
                movable: command != nil && transport["cwd"] is NSNull && passed.isEmpty)
        }
        .sorted { $0.name < $1.name }
    }
}

/// Settings › MCP servers' "Manage in Zero": one of a CLI's own local servers moved into Zero's list, started when
/// first used, then taken out of the CLI's config by the CLI itself; and "Give back", which puts it back where it was.
/// Its values are passed to the CLI in its arguments (as `claude mcp add -e` takes them), never shown or logged.
public enum McpHandOver {
    /// Where a server Zero took over came from, kept by the app so it can be given back.
    public struct Origin: Codable, Equatable, Sendable {
        public let cli: ClaudeMcpServers.Cli
        /// The project it was in, for one of a Claude project's own.
        public let project: String?
    }

    /// Zero's server for it: same command, arguments and environment, for every workspace, started when first used.
    /// The values go in Zero's file (`inFile`) or are returned for the Keychain.
    public static func server(for cli: ClaudeMcpServers.Server, inFile: Bool) -> (server: ZerodLink.McpServer, secrets: [String: String]) {
        let env = cli.env.sorted { $0.key < $1.key }
        let values = env.map { ZerodLink.McpServer.Value(name: $0.key, value: inFile ? $0.value : nil, from: inFile ? .file : .keychain) }
        let server = ZerodLink.McpServer(name: cli.name, command: cli.command, args: cli.args, env: values, lazy: true)
        return (server, inFile ? [:] : cli.env)
    }

    /// The CLI's command taking it out of its config, and the folder to run it in (a Claude project's own: its project).
    public static func removal(_ cli: ClaudeMcpServers.Server) -> (argv: [String], cwd: String?) {
        switch cli.cli {
        case .claude: (["claude", "mcp", "remove", cli.name, "-s", cli.project == nil ? "user" : "local"], cli.project)
        case .codex: (["codex", "mcp", "remove", cli.name], nil)
        }
    }

    /// The CLI's command putting it back as it was, with its values (by name).
    public static func giveBack(_ server: ZerodLink.McpServer, values: [String: String], to origin: Origin) -> (
        argv: [String], cwd: String?
    ) {
        switch origin.cli {
        case .claude:
            var entry: [String: Any] = ["type": "stdio", "command": server.command ?? "", "args": server.args]
            if !values.isEmpty { entry["env"] = values }
            let json =
                (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return (["claude", "mcp", "add-json", server.name, json, "-s", origin.project == nil ? "user" : "local"], origin.project)
        case .codex:
            let env = values.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            return (["codex", "mcp", "add", server.name] + env + ["--", server.command ?? ""] + server.args, nil)
        }
    }

    public static func origin(of id: String, in defaults: UserDefaults = .standard) -> Origin? {
        defaults.data(forKey: "mcpOrigin." + id).flatMap { try? JSONDecoder().decode(Origin.self, from: $0) }
    }

    static func remember(_ origin: Origin?, of id: String, in defaults: UserDefaults = .standard) {
        defaults.set(origin.flatMap { try? JSONEncoder().encode($0) }, forKey: "mcpOrigin." + id)
    }

    /// A CLI run through the user's login shell (an app started from Finder has no Homebrew PATH): nil when it
    /// worked, else the last line it said, with `hiding`'s values taken out.
    static func run(_ argv: [String], cwd: String?, hiding secrets: [String]) async -> String? {
        let (status, said) = await launch(argv, cwd: cwd, keep: false)
        guard status != 0 else { return nil }
        var line =
            String(decoding: said, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
            ?? "\(argv[0]) stopped (\(status))"
        for secret in secrets where !secret.isEmpty { line = line.replacingOccurrences(of: secret, with: "…") }
        return line
    }

    /// What a CLI wrote out, when it worked.
    static func output(_ argv: [String]) async -> Data? {
        let (status, said) = await launch(argv, cwd: nil, keep: true)
        return status == 0 ? said : nil
    }

    /// Runs it, returning its exit status and its output (`keep`) or what it said on stderr.
    private static func launch(_ argv: [String], cwd: String?, keep: Bool) async -> (Int32, Data) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "\"$@\"", "zero"] + argv
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let pipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = keep ? pipe : FileHandle.nullDevice
            process.standardError = keep ? FileHandle.nullDevice : pipe
            guard (try? process.run()) != nil else { return (-1, Data()) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }.value
    }
}

extension Workspace {
    /// One of a CLI's own servers into Zero's list, then out of the CLI's config; taken back out of Zero's list if
    /// the CLI wouldn't let it go. An error to show, or nil.
    public func manageInZero(_ cli: ClaudeMcpServers.Server, inFile: Bool) async -> String? {
        let (server, secrets) = McpHandOver.server(for: cli, inFile: inFile)
        let before = Set(mcpServers.map(\.id))
        if let error = await saveMcpServer(server, secrets: secrets) { return error }
        guard let saved = mcpServers.first(where: { !before.contains($0.id) && $0.name == server.name }) else {
            return "Zero's list didn't take it"
        }
        let (argv, cwd) = McpHandOver.removal(cli)
        if let error = await McpHandOver.run(argv, cwd: cwd, hiding: Array(cli.env.values)) {
            await deleteMcpServer(saved)
            return error
        }
        McpHandOver.remember(.init(cli: cli.cli, project: cli.project), of: saved.id)
        return nil
    }

    /// One Zero took over, back to the CLI it came from (as it is now in Zero), then out of Zero's list.
    public func giveBack(_ server: ZerodLink.McpServer) async -> String? {
        guard let origin = McpHandOver.origin(of: server.id) else { return "Zero doesn't know where it came from" }
        var values: [String: String] = [:]
        for value in server.env {
            switch value.from {
            case .file: values[value.name] = value.value
            case .keychain:
                values[value.name] = Keychain.loadString(service: ZerodLink.McpServer.keychain, account: server.id + "." + value.name)
            case .command: break
            }
        }
        let (argv, cwd) = McpHandOver.giveBack(server, values: values, to: origin)
        if let error = await McpHandOver.run(argv, cwd: cwd, hiding: Array(values.values)) { return error }
        await deleteMcpServer(server)
        McpHandOver.remember(nil, of: server.id)
        return nil
    }
}
