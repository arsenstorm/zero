import CryptoKit
import Foundation
import Network

/// Linear workspaces connected through OAuth (authorization code with PKCE: a client id and no secret). Zero
/// reads each workspace's URL key and team keys, so issue ids in agents' messages link to the right workspace.
@MainActor @Observable
public final class Linear {
    public struct Workspace: Codable, Sendable, Identifiable {
        public var urlKey: String
        public var name: String
        public var teams: [String]
        /// The workspace's logo, as Linear serves it; nil when it has none.
        public var logo: URL?
        var access: String
        var refresh: String?
        var expires: Date
        public var id: String { urlKey }
    }

    public static let clientID = "6a5057347cad54818f0b528ee7763622"
    nonisolated static let port: UInt16 = 47615
    static let redirect = "http://localhost:47615/oauth/linear"

    public static let shared = Linear()
    public private(set) var workspaces: [Workspace] = []
    /// Moves when a logo lands on disk, so views showing one read it again.
    public private(set) var logos = 0

    init() { workspaces = Keychain.load() }

    /// Team key → workspace URL key; the workspace connected first wins a key two of them share.
    public var teams: [String: String] {
        var map: [String: String] = [:]
        for workspace in workspaces { for team in workspace.teams where map[team] == nil { map[team] = workspace.urlKey } }
        return map
    }

    /// Opens Linear's consent page in the browser and waits for it to come back. Returns an error to show, or nil.
    public func connect(open: @escaping (URL) -> Void) async -> String? {
        let verifier = Self.random()
        let state = Self.random()
        var authorize = URLComponents(string: "https://linear.app/oauth/authorize")!
        authorize.queryItems = [
            .init(name: "client_id", value: Self.clientID), .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "read"),
            .init(name: "state", value: state), .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        do {
            let callback = try await Callback.wait { open(authorize.url!) }
            guard callback["state"] == state, let code = callback["code"] else {
                return callback["error_description"] ?? callback["error"] ?? "Linear didn't connect."
            }
            var workspace = try await Self.describe(Self.token([
                "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                "client_id": Self.clientID, "code_verifier": verifier,
            ]))
            workspace.name = workspace.name.isEmpty ? workspace.urlKey : workspace.name
            workspaces.removeAll { $0.urlKey == workspace.urlKey }
            workspaces.append(workspace)
            Keychain.save(workspaces)
            await cacheLogo(workspace)
            return nil
        } catch {
            return "Couldn't connect Linear: \(error.localizedDescription)"
        }
    }

    public func remove(_ urlKey: String) {
        workspaces.removeAll { $0.urlKey == urlKey }
        Keychain.save(workspaces)
        try? FileManager.default.removeItem(at: Self.logoFile(urlKey))
    }

    /// Each workspace's logo, kept on disk so the connections sheet shows it straight away.
    public nonisolated static func logoFile(_ urlKey: String) -> URL {
        Paths.dir.appendingPathComponent("linear").appendingPathComponent("\(urlKey).logo")
    }

    private func cacheLogo(_ workspace: Workspace) async {
        guard let url = workspace.logo, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let file = Self.logoFile(workspace.urlKey)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
        logos += 1
    }

    /// New teams since the last look, refreshing tokens on the way. A workspace that refuses stays as it was.
    public func refresh() async {
        for (index, workspace) in workspaces.enumerated() {
            guard let fresh = try? await Self.updated(workspace) else { continue }
            workspaces[index] = fresh
            await cacheLogo(fresh)
        }
        Keychain.save(workspaces)
    }

    private static func updated(_ workspace: Workspace) async throws -> Workspace {
        var tokens = workspace
        if workspace.expires < Date().addingTimeInterval(60), let refresh = workspace.refresh {
            tokens = try await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        }
        return try await describe(tokens)
    }

    /// Fills in the workspace's URL key, name and team keys for these tokens.
    private static func describe(_ tokens: Workspace) async throws -> Workspace {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": "{ organization { urlKey name logoUrl } teams(first: 250) { nodes { key } } }"])
        struct Reply: Decodable {
            struct Data: Decodable {
                struct Organization: Decodable { let urlKey: String; let name: String; let logoUrl: String? }
                struct Teams: Decodable { struct Team: Decodable { let key: String }; let nodes: [Team] }
                let organization: Organization
                let teams: Teams
            }
            let data: Data
        }
        let reply = try JSONDecoder().decode(Reply.self, from: try await send(request))
        var workspace = tokens
        workspace.urlKey = reply.data.organization.urlKey
        workspace.name = reply.data.organization.name
        workspace.logo = reply.data.organization.logoUrl.flatMap(URL.init(string:))
        workspace.teams = reply.data.teams.nodes.map { $0.key.uppercased() }
        return workspace
    }

    private static func token(_ form: [String: String]) async throws -> Workspace {
        var request = URLRequest(url: URL(string: "https://api.linear.app/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        struct Reply: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double? }
        let reply = try JSONDecoder().decode(Reply.self, from: try await send(request))
        return Workspace(urlKey: "", name: "", teams: [], access: reply.access_token, refresh: reply.refresh_token,
                         expires: Date().addingTimeInterval(reply.expires_in ?? 86_400))
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Linear", code: 0, userInfo: [NSLocalizedDescriptionKey: "Linear answered \((response as? HTTPURLResponse)?.statusCode ?? 0)."])
        }
        return data
    }

    private static func random() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The browser's one trip back: a listener on the redirect port for the single request Linear sends it.
private enum Callback {
    static func wait(then start: @escaping () -> Void) async throws -> [String: String] {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Linear.port)!)
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<[String: String], Error>) {
                guard !finished else { return }
                finished = true
                listener.cancel()
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: start()
                case .failed(let error): finish(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let line = data.map { String(decoding: $0, as: UTF8.self) }?.components(separatedBy: "\r\n").first ?? ""
                    let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    guard path.hasPrefix("/oauth/linear") else { connection.cancel(); return }
                    let page = "<!doctype html><meta charset=utf-8><title>Zero</title><body style=\"font:15px -apple-system;margin:4em;text-align:center\">Linear is connected. You can close this tab."
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    let items = URLComponents(string: "http://localhost\(path)")?.queryItems ?? []
                    finish(.success(Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })))
                }
            }
            listener.start(queue: .main)
            // Abandoned in the browser: give the port back after five minutes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(.success(["error": "Linear didn't answer in time."])) }
        }
    }
}

/// The workspaces and their tokens, as one item in the login Keychain. Read and written through macOS's
/// `security` tool, as Claude Code does: the item then trusts that tool rather than this build of Zero, so a
/// rebuilt or updated Zero reads it without asking for the Keychain password.
enum Keychain {
    static func loadString(service: String, account: String) -> String? {
        security(["find-generic-password", "-s", service, "-a", account, "-w"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveString(_ value: String?, service: String, account: String) {
        if let value { _ = security(["add-generic-password", "-U", "-s", service, "-a", account, "-w", value]) }
        else { _ = security(["delete-generic-password", "-s", service, "-a", account]) }
    }

    static func load() -> [Linear.Workspace] {
        guard let encoded = security(["find-generic-password", "-s", "Zero Linear", "-a", "workspaces", "-w"]),
              let data = Data(base64Encoded: encoded) else { return [] }
        return (try? JSONDecoder().decode([Linear.Workspace].self, from: data)) ?? []
    }

    static func save(_ workspaces: [Linear.Workspace]) {
        guard !workspaces.isEmpty, let data = try? JSONEncoder().encode(workspaces) else {
            _ = security(["delete-generic-password", "-s", "Zero Linear", "-a", "workspaces"])
            return
        }
        _ = security(["add-generic-password", "-U", "-s", "Zero Linear", "-a", "workspaces", "-w", data.base64EncodedString()])
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
}
