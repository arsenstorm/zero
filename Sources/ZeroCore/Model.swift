import Foundation

/// `note` needs no answer: it is an agent saying where it is. `message` goes the other way: Arsen to the agent.
/// `permission` is Claude Code asking to use a tool in a session nobody watches: the plugin's hook brings it here.
public enum AskKind: String, Codable, Sendable { case question, choice, approve, run, note, message, permission }

public enum AskState: String, Codable, Sendable {
    case waiting, pending, running, answered, declined, expired
    public var isFinal: Bool { self == .answered || self == .declined || self == .expired }
}

public struct AgentIdentity: Codable, Hashable, Sendable {
    public var name: String
    public var host: String
    public var cwd: String?
    public var soloProcessID: Int?
    /// Solo scopes its calls to a project; every call about the process carries this one.
    public var soloProjectID: Int?
    public var ticket: String?
    /// What to show for the agent (Claude's own title for the session once it has one); `name` stays the stable key.
    public var label: String?
    /// The runtime's session id (a Claude Code session), so the conversation can be resumed and titled.
    public var session: String?
    /// The Claude account the agent runs as, when it was started as one other than Claude Code's active account.
    public var account: String?

    public init(name: String, host: String, cwd: String? = nil, soloProcessID: Int? = nil, soloProjectID: Int? = nil, ticket: String? = nil, label: String? = nil, session: String? = nil) {
        self.name = name; self.host = host; self.cwd = cwd; self.soloProcessID = soloProcessID; self.soloProjectID = soloProjectID; self.ticket = ticket; self.label = label; self.session = session
    }
}

public struct Ask: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: AskKind
    public var title: String
    public var body: String
    public var options: [String]
    public var command: String?
    public var cwd: String?
    public var agent: AgentIdentity
    public var createdAt: Date
    public var expiresAt: Date
    public var state: AskState
    public var answer: String?
    public var output: String
    public var exitCode: Int32?
    public var answeredAt: Date?
    /// For notes: "blocked" or "done"; nil means working.
    public var status: String?
    /// Index of the option Arsen picked, when he picked one.
    public var choice: Int?
    /// False when the agent asked with --async and ended its turn: nothing waits for the answer, so Zero types
    /// it into the agent's session instead.
    public var waits: Bool?
    /// How that typed answer is getting on; nil when the agent reads the answer itself.
    public var delivery: Delivery?

    public enum Delivery: String, Codable, Sendable { case sending, delivered, failed }
    /// For a question: what Arsen may want to know to answer it, shown in smaller text under the question.
    public var detail: String?
    /// For a run of a script file (`sh path`, or the path itself): the script, so Arsen can read what will run.
    public var script: String?
    /// A run asking for exactly the command another agent's open run already asks for: it shares that run's
    /// card and outcome instead of showing a second one.
    public var sameAs: String?

    /// An option ending with "…" asks for text: picking it opens an input, and the answer is "label: text".
    public static func expectsText(_ option: String) -> Bool { option.hasSuffix("…") || option.hasSuffix("...") }

    public init(kind: AskKind, title: String, body: String = "", options: [String] = [],
                command: String? = nil, cwd: String? = nil, agent: AgentIdentity, ttl: TimeInterval = 3600) {
        id = Ask.newID()
        self.kind = kind; self.title = title; self.body = body; self.options = options
        self.command = command; self.cwd = cwd; self.agent = agent
        createdAt = Date(); expiresAt = createdAt.addingTimeInterval(ttl)
        state = .waiting; output = ""
    }

    /// A permission ask from Claude Code's PermissionRequest hook input: what the tool will do as the headline
    /// (Bash's own description of the command, else the tool and its target), the command or target in the code
    /// block, and why, in the agent's own latest words from its transcript.
    public static func permission(hook: Data, agent: AgentIdentity, ttl: TimeInterval) -> Ask? {
        guard let json = try? JSONSerialization.jsonObject(with: hook) as? [String: Any], let tool = json["tool_name"] as? String else { return nil }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let (what, code): (String, String) = switch tool {
        case "Bash": ((input["description"] as? String).map { $0.hasSuffix("?") ? String($0.dropLast()) : $0 } ?? "Run a command", input["command"] as? String ?? "")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": ("\(tool == "Write" ? "Write" : "Edit") a file", input["file_path"] as? String ?? input["notebook_path"] as? String ?? "")
        case "WebFetch": ("Fetch a page", input["url"] as? String ?? "")
        default: ("Use \(tool)", (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        let why = (json["transcript_path"] as? String).flatMap(lastWords) ?? ""
        // "Always allow" applies the rule Claude Code itself suggests for this request, so offered only with one.
        let suggested = !((json["permission_suggestions"] as? [Any]) ?? []).isEmpty
        let options = suggested ? ["Allow", "Always allow", "Deny", "Deny, and say why…"] : ["Allow", "Deny", "Deny, and say why…"]
        return Ask(kind: .permission, title: what, body: why, options: options,
                   command: String(code.prefix(2000)), cwd: json["cwd"] as? String, agent: agent, ttl: ttl)
    }

    /// The agent's last words before the tool call: the latest assistant text in its transcript, trimmed.
    static func lastWords(_ transcript: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], entry["type"] as? String == "assistant",
                  let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            if let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
            }
        }
        return nil
    }

    /// The script a run command executes, when it is a readable file: `sh|bash|zsh <file> …` or `<file> …`.
    public static func script(of command: String, cwd: String?) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let path = ["sh", "bash", "zsh"].contains(first) ? (words.count > 1 ? words[1] : "") : first
        guard !path.isEmpty, !path.hasPrefix("-") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : ((cwd ?? FileManager.default.currentDirectoryPath) as NSString).appendingPathComponent(expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
        // A compiled program isn't something to read; a script is, at least its first screens of it.
        return text.count > 6000 ? String(text.prefix(6000)) + "\n…" : text
    }

    public static func newID() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

/// One JSON object per line over the socket. `op`: create | wait | status | list.
public struct Request: Codable, Sendable {
    public var op: String
    public var ask: Ask?
    public var id: String?
    public var wait: Bool?
    /// For `message`: the agent's name and what to send it.
    public var agent: String?
    public var text: String?
    public init(op: String, ask: Ask? = nil, id: String? = nil, wait: Bool? = nil, agent: String? = nil, text: String? = nil) {
        self.op = op; self.ask = ask; self.id = id; self.wait = wait; self.agent = agent; self.text = text
    }
}

/// `op`: created | ask | asks | output | done | error.
public struct Response: Codable, Sendable {
    public var op: String
    public var id: String?
    public var ask: Ask?
    public var asks: [Ask]?
    public var chunk: String?
    public var message: String?
    public init(op: String, id: String? = nil, ask: Ask? = nil, asks: [Ask]? = nil, chunk: String? = nil, message: String? = nil) {
        self.op = op; self.id = id; self.ask = ask; self.asks = asks; self.chunk = chunk; self.message = message
    }
}

public enum Paths {
    public static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zero")
    public static let socket = dir.appendingPathComponent("zero.sock").path
    public static let log = dir.appendingPathComponent("asks.jsonl")
}

public let jsonEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
public let jsonDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
