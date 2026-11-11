import Foundation

/// Linear issues ("OPS-3096", "eng-9559"), pull requests ("#12846", "app#12846") and commits ("064c6bb7b5") in
/// what agents write, as links.
public enum References {
    private static let pattern = try! NSRegularExpression(
        pattern:
            #"\b([A-Za-z]{1,5})-(\d+)\b|(?:\b([\w.-]+/[\w.-]+|[\w.-]+))?#(\d+)\b|\b([0-9a-f]{7,40})\b|(?<![\w/&#])#([a-z][a-z0-9._-]+)\b"#)

    /// Each reference's range in `text` (UTF-16, as NSString counts) and where it goes. A bare "#123" or commit
    /// needs `repo` ("owner/name"); "name#123" takes `repo`'s owner. Issues are ids whose prefix is a team in
    /// `linear` (team key → workspace URL key, from the connected workspaces), so "UTF-8" stays text.
    /// `linearApp` opens them in Linear's app.
    /// `owner` stands in for `repo`'s when the folder is one of repositories, not a repository ("name#123" still
    /// links). `github` off, no pull request or commit links. `slack` are the workspaces connected: with one,
    /// "#channel" opens the channel in Slack.
    public static func find(
        in text: String, repo: String?, linear: [String: String], linearApp: Bool, owner: String? = nil, github: Bool = true,
        slack: [Slack.State] = []
    ) -> [(range: NSRange, url: URL)] {
        let ns = text as NSString
        func group(_ match: NSTextCheckingResult, _ i: Int) -> String? {
            match.range(at: i).location == NSNotFound ? nil : ns.substring(with: match.range(at: i))
        }
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let link: String?
            if let team = group(match, 1)?.uppercased(), let number = group(match, 2) {
                guard let workspace = linear[team] else { return nil }
                let path = "\(workspace)/issue/\(team)-\(number)"
                link = linearApp ? "linear://\(path)" : "https://linear.app/\(path)"
            } else if let number = group(match, 4) {
                guard github else { return nil }
                let target: String? =
                    switch group(match, 3) {
                    case nil: repo
                    case let name? where name.contains("/"): name
                    case let name?: (repo.map { String($0.split(separator: "/")[0]) } ?? owner).map { $0 + "/" + name }
                    }
                link = target.map { "https://github.com/\($0)/pull/\(number)" }
            } else if let sha = group(match, 5) {
                guard github else { return nil }
                // A hash has letters and digits; "1234567" and "deadbeef" are something else.
                guard sha.contains(where: \.isNumber), sha.contains(where: \.isLetter) else { return nil }
                link = repo.map { "https://github.com/\($0)/commit/\(sha)" }
            } else if let channel = group(match, 6) {
                link = SlackLinks.channel(channel, in: slack)
            } else {
                link = nil
            }
            return link.flatMap(URL.init(string:)).map { (match.range, $0) }
        }
    }

    /// "owner/name" of the GitHub repository holding `cwd`, from its origin remote. Cached; nil when there is none.
    public static func repo(of cwd: String) -> String? {
        if let hit = lock.withLock({ repos[cwd] }) { return hit }
        let found = origin(cwd).flatMap(parse)
        lock.withLock { repos[cwd] = .some(found) }
        return found
    }

    /// The owner of the repositories in `cwd`: its own, or (a folder of checkouts and worktrees) that of the first
    /// repository one or two levels down. Cached like `repo(of:)`.
    public static func owner(of cwd: String) -> String? {
        if let own = repo(of: cwd) { return String(own.split(separator: "/")[0]) }
        if let hit = lock.withLock({ owners[cwd] }) { return hit }
        let found = children(of: cwd, depth: 2).lazy.compactMap { origin($0).flatMap(parse) }.first.map {
            String($0.split(separator: "/")[0])
        }
        lock.withLock { owners[cwd] = .some(found) }
        return found
    }

    private static func children(of folder: String, depth: Int) -> [String] {
        guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let folders = names.filter { !$0.hasPrefix(".") }.map { folder + "/" + $0 }.sorted()
            .filter { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeDirectory }
        return folders + folders.flatMap { children(of: $0, depth: depth - 1) }
    }

    static func parse(_ remote: String) -> String? {
        guard let range = remote.range(of: "github.com") else { return nil }
        var path = remote[range.upperBound...].drop { $0 == ":" || $0 == "/" }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        return path.split(separator: "/").count == 2 ? String(path) : nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var repos: [String: String?] = [:]
    nonisolated(unsafe) private static var owners: [String: String?] = [:]

    private static func origin(_ cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "remote", "get-url", "origin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Not waitUntilExit: it runs the run loop, and this is called while SwiftUI lays a message out; whatever
        // ran in it changed the view graph mid-update and SwiftUI aborted (crash 2026-11-11 17:46). Its output read
        // to the end, git is exiting: a plain wait.
        while process.isRunning { usleep(500) }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Slack's links as the app's: a message or channel link (https://acme.slack.com/archives/C123/p1700000000123456)
/// opens in Slack itself once the workspace is connected (Slack.swift), which gives its team id and channel ids.
public enum SlackLinks {
    @MainActor public static var teams: [Slack.State] { Slack.shared.teams }

    /// Where "#name" goes, in the workspace that has a channel of that name (else the first): straight into Slack when
    /// its id is known, else Slack's own redirect by name, which goes through the browser. None with none connected.
    public static func channel(_ name: String, in teams: [Slack.State]) -> String? {
        guard let workspace = teams.first(where: { $0.channels[name] != nil }) ?? teams.first else { return nil }
        let team = workspace.team.id
        return workspace.channels[name].map { "slack://channel?team=\(team)&id=\($0)" }
            ?? "https://slack.com/app_redirect?team=\(team)&channel=\(name)"
    }

    /// A Slack link as the app's, in the workspace its domain names.
    public static func url(_ link: URL, in teams: [Slack.State]) -> URL? {
        guard let host = link.host, let team = teams.first(where: { host == "\($0.team.domain).slack.com" })?.team.id else { return nil }
        let parts = link.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "archives" else { return nil }
        var query = "team=\(team)&id=\(parts[1])"
        if parts.count >= 3, parts[2].hasPrefix("p"), parts[2].dropFirst().allSatisfy(\.isNumber) {
            let digits = parts[2].dropFirst()
            query += "&message=\(digits.dropLast(6)).\(digits.suffix(6))"
        }
        if let thread = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "thread_ts" })?
            .value
        {
            query += "&thread_ts=\(thread)"
        }
        return URL(string: "slack://channel?" + query)
    }
}

/// Whether GitHub's references in messages are links (Settings › Links).
public enum GitHubLinks {
    public static let key = "githubLinks"
    /// Pull requests (repo#123) and commits in messages as links; on unless turned off.
    public static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
