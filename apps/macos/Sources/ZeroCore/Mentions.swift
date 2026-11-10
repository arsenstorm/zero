import Foundation

/// What "/" and "@" offer in a composer: Claude Code's commands and skills, and the project's files.
public struct Mention: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case command, file, loop }
    public let kind: Kind
    /// The text that goes into the message ("/commit", "@Sources/Zero/main.swift").
    public let insert: String
    public let detail: String?
    public var id: String { insert }
    public init(kind: Kind, insert: String, detail: String?) { self.kind = kind; self.insert = insert; self.detail = detail }
}

public enum ClaudeCommands {
    /// Claude Code's own slash commands. Sending one opens the agent's screen in Zero, since what they show (a
    /// picker, a report) lives in its terminal; skills and custom commands are prompts, answered like any message.
    public static let builtIns: [String: String] = [
        "add-dir": "Add a working directory", "agents": "Manage subagents", "clear": "Clear the conversation",
        "compact": "Summarise the conversation to free context", "config": "Open settings", "context": "Show context use",
        "cost": "Show usage and cost", "doctor": "Check the installation", "effort": "Set reasoning effort",
        "export": "Export the conversation", "help": "List commands", "hooks": "Manage hooks", "init": "Write a CLAUDE.md",
        "login": "Sign in", "logout": "Sign out", "mcp": "Manage MCP servers", "memory": "Edit memory files",
        "model": "Switch model", "permissions": "Manage permissions", "plugin": "Manage plugins",
        "resume": "Resume an earlier session", "review": "Review a pull request", "rewind": "Rewind the conversation",
        "status": "Show status",
    ]

    public static func isBuiltIn(_ message: String) -> Bool {
        guard message.hasPrefix("/") else { return false }
        let word = message.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return builtIns[word] != nil
    }

    nonisolated(unsafe) private static var cache: [String: (at: Date, items: [Mention])] = [:]
    private static let lock = NSLock()

    /// Built-ins, then skills and custom commands: the user's, the project's, and installed plugins' (as
    /// "plugin:name"). Read from disk at most once a minute per project.
    public static func all(projectPath: String?) -> [Mention] {
        let key = projectPath ?? ""
        if let hit = lock.withLock({ cache[key] }), Date().timeIntervalSince(hit.at) < 60 { return hit.items }
        var items = builtIns.sorted { $0.key < $1.key }.map { Mention(kind: .command, insert: "/" + $0.key, detail: $0.value) }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        var roots = [home]
        if let projectPath { roots.append(URL(fileURLWithPath: projectPath).appendingPathComponent(".claude")) }
        for root in roots {
            items += skills(in: root.appendingPathComponent("skills"), prefix: "")
            items += commands(in: root.appendingPathComponent("commands"), prefix: "")
        }
        items += pluginItems(home: home)
        var seen = Set<String>()
        items = items.filter { seen.insert($0.insert).inserted }
        lock.withLock { cache[key] = (Date(), items) }
        return items
    }

    private static func skills(in dir: URL, prefix: String) -> [Mention] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().compactMap { name in
            let file = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let meta = frontmatter(text)
            return Mention(kind: .command, insert: "/" + prefix + (meta["name"] ?? name), detail: meta["description"].map(firstSentence))
        }
    }

    private static func commands(in dir: URL, prefix: String) -> [Mention] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.sorted().map { name in
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return Mention(
                kind: .command, insert: "/" + prefix + String(name.dropLast(3)), detail: frontmatter(text)["description"].map(firstSentence)
            )
        }
    }

    private static func pluginItems(home: URL) -> [Mention] {
        let manifest = home.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: manifest),
            let plugins = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["plugins"] as? [String: [[String: Any]]]
        else { return [] }
        return plugins.sorted { $0.key < $1.key }.flatMap { key, installs -> [Mention] in
            guard let path = installs.first?["installPath"] as? String else { return [] }
            let plugin = String(key.split(separator: "@").first ?? Substring(key))
            let root = URL(fileURLWithPath: path)
            return skills(in: root.appendingPathComponent("skills"), prefix: plugin + ":")
                + commands(in: root.appendingPathComponent("commands"), prefix: plugin + ":")
        }
    }

    static func frontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        var result: [String: String] = [:]
        var folding: String? // a key whose value is a YAML block (">-", "|") on the indented lines below
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            if let key = folding, line.first == " " || line.first == "\t" {
                let part = line.trimmingCharacters(in: .whitespaces)
                result[key] = (result[key].map { $0.isEmpty ? "" : $0 + " " } ?? "") + part
                continue
            }
            folding = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", ">-", "|", "|-"].contains(value) { folding = key; result[key] = ""; continue }
            if value.count >= 2, value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }

    private static func firstSentence(_ text: String) -> String {
        let cut = text.range(of: ". ").map { String(text[..<$0.lowerBound]) } ?? text
        return cut.count > 90 ? String(cut.prefix(89)) + "…" : cut
    }
}

public enum ProjectFiles {
    nonisolated(unsafe) private static var cache: [String: (at: Date, files: [String])] = [:]
    private static let lock = NSLock()

    /// The project's files relative to its root: git's view when it is a repository (tracked plus untracked,
    /// ignored ones left out), else a walk that skips hidden and build folders. 20,000 at most; cached 30 s.
    public static func list(_ root: String) async -> [String] {
        if let hit = lock.withLock({ cache[root] }), Date().timeIntervalSince(hit.at) < 30 { return hit.files }
        let files = await Task.detached { git(root) ?? walk(root) }.value
        lock.withLock { cache[root] = (Date(), files) }
        return files
    }

    private static func git(_ root: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Array(String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(20_000).map(String.init))
    }

    private static func walk(_ root: String) -> [String] {
        let skip: Set<String> = ["node_modules", ".build", "build", "dist", "DerivedData", "Pods", "vendor"]
        guard
            let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var files: [String] = []
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(String(url.path.dropFirst(prefix.count)))
            if files.count >= 20_000 { break }
        }
        return files
    }

    /// Best matches for a typed fragment: file name starting with it, then file name containing it, then path
    /// containing it, then its letters in order; shorter paths first within a rank.
    public static func match(_ query: String, in files: [String], limit: Int = 8) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(files.sorted { $0.count < $1.count }.prefix(limit)) }
        var ranked: [(Int, String)] = []
        for file in files {
            let path = file.lowercased()
            let name = (path as NSString).lastPathComponent
            let rank: Int
            if name.hasPrefix(q) {
                rank = 0
            } else if name.contains(q) {
                rank = 1
            } else if path.contains(q) {
                rank = 2
            } else if isSubsequence(q, of: path) {
                rank = 3
            } else {
                continue
            }
            ranked.append((rank, file))
        }
        return ranked.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.count < $1.1.count }.prefix(limit).map(\.1)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = Substring(haystack)
        for c in needle { guard let i = rest.firstIndex(of: c) else { return false }; rest = rest[rest.index(after: i)...] }
        return true
    }
}
