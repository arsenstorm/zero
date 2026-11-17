import Foundation
import Observation

/// Linear issues ("OPS-3096", "eng-9559"), pull requests ("#12846", "app#12846") and commits ("064c6bb7b5") in
/// what agents write, as links.
public enum References {
    private static let pattern = try! NSRegularExpression(
        pattern:
            #"\b([A-Za-z]{1,5})-(\d+)\b|(?:\b([\w.-]+/[\w.-]+|[\w.-]+))?#(\d+)\b|(?<![\w-])([0-9a-f]{7,40})(?![\w-]|\.\w)|(?<![\w/&#])#([a-z][a-z0-9._-]+)\b"#
    )

    /// Each reference's range in `text` (UTF-16, as NSString counts) and where it goes. A bare "#123" or commit
    /// needs `repo` ("owner/name"); "name#123" takes `repo`'s owner. Issues are ids whose prefix is a team in
    /// `linear` (team key → workspace URL key, from the connected workspaces), so "UTF-8" stays text.
    /// `linearApp` opens them in Linear's app.
    /// `owner` stands in for `repo`'s when the folder is one of repositories, not a repository ("name#123" still
    /// links). `github` off, no pull request or commit links. `slack` are the workspaces connected: with one,
    /// "#channel" opens the channel in Slack.
    /// `pulls` are the pull requests the task follows, by number, each with the repositories it follows that number in:
    /// a bare "#123" followed in one is there, before the folder's. A commit is in the repository of the pull request
    /// beside it, in its sentence or, for a table cell, in its `row` (the row's cells); with none beside it, in the folder's;
    /// with several repositories there, or one unknown, in none.
    public static func find(
        in text: String, repo: String?, linear: [String: String], linearApp: Bool, owner: String? = nil, github: Bool = true,
        slack: [Slack.State] = [], pulls: [String: Set<String>] = [:], row: String? = nil
    ) -> [(range: NSRange, url: URL)] {
        let ns = text as NSString
        let addresses = addresses(in: text)
        let own = addresses.compactMap { range in
            ns.substring(with: range).hasPrefix("zero://") ? URL(string: ns.substring(with: range)).map { (range, $0) } : nil
        }
        // A pull request's repository: named, the task's follow of its number when that's one repo (or the folder's among
        // several), else the folder's.
        func pullRepo(_ name: String?, _ number: String) -> String? {
            switch name {
            case nil:
                let followed = pulls[number] ?? []
                if followed.count == 1 { return followed.first }
                return followed.isEmpty || followed.contains(where: { $0.caseInsensitiveCompare(repo ?? "") == .orderedSame }) ? repo : nil
            case let name? where name.contains("/"): return name
            case let name?: return (repo.map { String($0.split(separator: "/")[0]) } ?? owner).map { $0 + "/" + name }
            }
        }
        // The repository of the pull requests in `scope`: nil with none there; inside, nil when they name more than one or
        // one of unknown repository (it could be the commit's).
        func besideRepo(_ scope: String) -> String?? {
            let scopeNS = scope as NSString
            let hidden = Self.addresses(in: scope)
            let repos = pattern.matches(in: scope, range: NSRange(location: 0, length: scopeNS.length)).compactMap { match -> String?? in
                guard match.range(at: 4).location != NSNotFound,
                    !hidden.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { return nil }
                let name = match.range(at: 3).location == NSNotFound ? nil : scopeNS.substring(with: match.range(at: 3))
                return .some(pullRepo(name, scopeNS.substring(with: match.range(at: 4)))?.lowercased())
            }
            guard !repos.isEmpty else { return nil }
            let distinct = Set(repos.compactMap { $0 })
            return .some(!repos.contains(nil) && distinct.count == 1 ? distinct.first : nil)
        }
        return
            (own
            + links(in: text, addresses: addresses, linear: linear, linearApp: linearApp, github: github, slack: slack) {
                number, name in
                pullRepo(name, number)
            } commit: { range in
                besideRepo(row ?? sentence(of: range, in: text)) ?? repo
            }).sorted { $0.range.location < $1.range.location }
    }

    /// An address written out is one thing: nothing in it is a commit, issue or channel of its own ("01a1e4b4537c" in
    /// zero://task/01a1e4b4537c009e). Zero's own open in Zero; others are left to whatever links them.
    private static func addresses(in text: String) -> [NSRange] {
        address.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// The sentence `range` is in: from the end of the last one (".", "!" or "?" then a space, or a line break) to the next.
    private static func sentence(of range: NSRange, in text: String) -> String {
        let ns = text as NSString
        let ends = sentenceEnd.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let start = ends.last { $0.location + $0.length <= range.location }.map { $0.location + $0.length } ?? 0
        let end = ends.first { $0.location >= range.location + range.length }?.location ?? ns.length
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+|\n"#)

    private static func links(
        in text: String, addresses: [NSRange], linear: [String: String], linearApp: Bool, github: Bool, slack: [Slack.State],
        pull: (_ number: String, _ name: String?) -> String?, commit: (NSRange) -> String?
    ) -> [(range: NSRange, url: URL)] {
        let ns = text as NSString
        func group(_ match: NSTextCheckingResult, _ i: Int) -> String? {
            match.range(at: i).location == NSNotFound ? nil : ns.substring(with: match.range(at: i))
        }
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            match in
            guard !addresses.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            let link: String?
            if let team = group(match, 1)?.uppercased(), let number = group(match, 2) {
                guard let workspace = linear[team] else { return nil }
                let path = "\(workspace)/issue/\(team)-\(number)"
                link = linearApp ? "linear://\(path)" : "https://linear.app/\(path)"
            } else if let number = group(match, 4) {
                guard github else { return nil }
                link = pull(number, group(match, 3)).map { "https://github.com/\($0)/pull/\(number)" }
            } else if let sha = group(match, 5) {
                guard github else { return nil }
                // A hash has letters and digits; "1234567" and "deadbeef" are something else.
                guard sha.contains(where: \.isNumber), sha.contains(where: \.isLetter) else { return nil }
                link = commit(match.range).map { "https://github.com/\($0)/commit/\(sha)" }
            } else if let channel = group(match, 6) {
                link = SlackLinks.channel(channel, in: slack)
            } else {
                link = nil
            }
            return link.flatMap(URL.init(string:)).map { (match.range, $0) }
        }
    }

    /// Each task's followed pull requests: number → the repositories ("owner/name") it follows that number in. A
    /// worker's count for its lead too (`leads`: worker → lead), as the lead writes about its workers' pull requests.
    public static func pulls(_ followed: [ZerodLink.Followed], leads: [String: String]) -> [String: [String: Set<String>]] {
        var out: [String: [String: Set<String>]] = [:]
        for follow in followed {
            // "github/owner/name/123", or with "pull" before the number.
            let parts = follow.topic.split(separator: "/").filter { $0 != "pull" }.map(String.init)
            guard parts.count == 4, parts[0] == "github", parts[1] != "*", parts[3].allSatisfy(\.isNumber) else { continue }
            for task in [follow.session] + (leads[follow.session].map { [$0] } ?? []) {
                out[task, default: [:]][parts[3], default: []].insert("\(parts[1])/\(parts[2])".lowercased())
            }
        }
        return out
    }
    private static let address = try! NSRegularExpression(pattern: #"\b[a-z][a-z0-9+.-]*://[^\s<>()\[\]"'`]+"#)

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
        #if os(macOS)
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
        #else
            // No git on the phone: its links come from what the Mac sends.
            return nil
        #endif
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

/// Linear's team keys to the connected workspace's URL key ("ENG" → "acme"), from zerod's connection: which "ENG-123"
/// in messages are issues, and where they open.
public enum LinearTeams {
    @MainActor public static var known: [String: String] {
        get { LinkInputs.shared.teams }
        set { LinkInputs.shared.teams = newValue }
    }
}

/// What makes words in messages links beyond their own folder (Linear's teams, Slack's workspaces, loops, pads, the
/// links' settings), as a number bumped when one of them changes. It's in rendered messages' cache keys and read by
/// their views: a message rendered before its issue's team was known links it once it is.
@MainActor @Observable public final class LinkInputs {
    public static let shared = LinkInputs()
    public private(set) var version = 0
    var teams: [String: String] = [:] {
        didSet { if teams != oldValue { changed() } }
    }
    /// Each task's followed pull requests (`References.pulls`): which repository a bare "#123" of its is in.
    public var pulls: [String: [String: Set<String>]] = [:] {
        didSet { if pulls != oldValue { changed() } }
    }

    public func changed() { version += 1 }
}

/// Whether GitHub's references in messages are links (Settings › GitHub).
public enum GitHubLinks {
    public static let key = "githubLinks"
    /// Pull requests (repo#123) and commits in messages as links; on unless turned off.
    public static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
