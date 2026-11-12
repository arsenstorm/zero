import Foundation

/// Zero's own health, checked at launch and every few minutes: zerod (who started it, its sockets, quarantine, its
/// descriptors, its build), crash and hang reports, and the app's main thread. Each check with its state and a fix the
/// user clicks; Settings › Health lists them, and only trouble shows elsewhere.

/// zerod's `selfCheck` (crates/zerod/src/self_check.rs).
public struct ZerodSelfCheck: Decodable, Equatable, Sendable {
    public struct Parent: Decodable, Equatable, Sendable {
        public let pid: Int
        public let path: String?
    }
    public struct Descriptors: Decodable, Equatable, Sendable {
        public let open: Int
        public let limit: Int
    }
    public let pid: Int
    public let parent: Parent
    public let quarantined: Bool
    public let descriptors: Descriptors
    public let exe: String?
    /// Its build on disk was replaced since it started: an install that didn't restart it.
    public let replaced: Bool
}

/// A crash or hang report macOS wrote for one of Zero's programs.
public struct CrashReport: Equatable, Sendable {
    public let url: URL
    public let date: Date
}

/// The app's main thread blocked: when, and for how long (as long as the watchdog saw it, if it never came back).
public struct AppHang: Codable, Equatable, Sendable {
    public let at: Date
    public let seconds: Double
}

public struct HealthCheck: Identifiable, Equatable, Sendable {
    public enum State: Sendable { case ok, warning, failing, unknown }
    public enum Fix: Equatable, Sendable {
        case restartZerod, startZerod, openReport(URL), dismiss
    }
    public let id: Health.Kind
    public let state: State
    public let detail: String
    public let fix: Fix?
    public var title: String { id.rawValue }
}

public enum Health {
    public enum Kind: String, CaseIterable, Sendable {
        case zerod = "zerod", cli = "The zero command", quarantine = "Quarantine", descriptors = "Open files"
        case build = "zerod's build", crashes = "Crashes", app = "Zero's window"
    }

    /// Main-thread blocks longer than this are hangs.
    public static let hangThreshold: Double = 5

    public static func judge(
        _ zerod: ZerodSelfCheck?, cliAnswers: Bool, app: String, appZerod: String, reports: [CrashReport], hang: AppHang?,
        seen: Date
    ) -> [HealthCheck] {
        func check(_ kind: Kind, _ state: HealthCheck.State, _ detail: String, _ fix: HealthCheck.Fix? = nil) -> HealthCheck {
            HealthCheck(id: kind, state: state, detail: detail, fix: fix)
        }
        var checks: [HealthCheck] = []
        if let zerod {
            let parent = zerod.parent.path.map(name) ?? "pid \(zerod.parent.pid)"
            if zerod.parent.pid == 1 || zerod.parent.path?.hasPrefix(app + "/") == true {
                checks.append(check(.zerod, .ok, "Running (pid \(zerod.pid)), started by \(zerod.parent.pid == 1 ? "macOS" : "Zero")."))
            } else if zerod.parent.path?.contains(".app/") == true {
                checks.append(
                    check(
                        .zerod, .failing,
                        "Started by \(parent), not Zero: what agents make may be quarantined, and it ends with \(parent).",
                        .restartZerod))
            } else {
                checks.append(check(.zerod, .warning, "Started by \(parent), not Zero.", .restartZerod))
            }
            checks.append(
                cliAnswers
                    ? check(.cli, .ok, "Answers on zero.sock.")
                    : check(.cli, .failing, "zero.sock doesn't answer: agents can't reach you.", .restartZerod))
            checks.append(
                zerod.quarantined
                    ? check(
                        .quarantine, .failing, "Files agents make are quarantined, so macOS blocks what they build.", .restartZerod)
                    : check(.quarantine, .ok, "Files agents make aren't quarantined."))
            let (open, limit) = (zerod.descriptors.open, zerod.descriptors.limit)
            let used = limit > 0 ? Double(open) / Double(limit) : 0
            let state: HealthCheck.State = used >= 0.95 ? .failing : used >= 0.8 ? .warning : .ok
            checks.append(check(.descriptors, state, "\(open) of \(limit) in use.", state == .ok ? nil : .restartZerod))
            if zerod.replaced {
                checks.append(check(.build, .warning, "An older build than the one installed.", .restartZerod))
            } else if let exe = zerod.exe, exe != appZerod {
                checks.append(check(.build, .warning, "Runs \(exe), not this app's.", .restartZerod))
            } else {
                checks.append(check(.build, .ok, "This app's."))
            }
        } else {
            checks.append(check(.zerod, .failing, "Not answering on zerod.sock.", .startZerod))
            for kind in [Kind.cli, .quarantine, .descriptors, .build] {
                checks.append(check(kind, .unknown, "Unknown while zerod doesn't answer."))
            }
        }
        let new = reports.filter { $0.date > seen }.sorted { $0.date < $1.date }
        if let latest = new.last {
            let count = new.count == 1 ? "A report" : "\(new.count) reports"
            checks.append(
                check(
                    .crashes, .warning, "\(count) since you last looked; latest \(latest.url.lastPathComponent).", .openReport(latest.url)))
        } else {
            checks.append(check(.crashes, .ok, "None since you last looked."))
        }
        if let hang, hang.at > seen {
            let when = hang.at.formatted(date: .abbreviated, time: .shortened)
            checks.append(check(.app, .warning, "Stopped responding for \(Int(hang.seconds)) s on \(when).", .dismiss))
        } else {
            checks.append(check(.app, .ok, "Responsive."))
        }
        return checks
    }

    /// A program's name from its path: the app it's in (Google Chrome), else its file.
    static func name(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let bundle = parts.first(where: { $0.hasSuffix(".app") }) { return String(bundle.dropLast(4)) }
        return parts.last.map(String.init) ?? path
    }

    public static let reportsFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")

    /// Zero's programs' crash and hang reports in `dir`: `Zero-2026-11-11-142542.ips`, `Zero_2026-11-11-142542.hang`.
    public static func reports(in dir: URL = reportsFolder) -> [CrashReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url in
            let name = url.lastPathComponent
            guard ["ips", "hang", "spin"].contains(url.pathExtension), name.wholeMatch(of: #/(Zero|zerod|zero-host)[-_]\d.*/#) != nil
            else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return CrashReport(url: url, date: date)
        }
    }
}

/// Runs the checks at launch and every five minutes, and the fixes the user clicks.
@MainActor @Observable public final class HealthMonitor {
    public static let shared = HealthMonitor()
    public private(set) var checks: [HealthCheck] = []
    public var trouble: Bool { checks.contains { $0.state == .failing || $0.state == .warning } }
    /// Reports and hangs before this were looked at.
    private var seen: Date {
        get { UserDefaults.standard.object(forKey: "healthSeen") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "healthSeen") }
    }
    nonisolated static let hangFile = Paths.dir.appendingPathComponent("app-hang.json")
    private var started = false

    public func start() {
        guard !started else { return }
        started = true
        // The first launch looks only at what happens from now on, not at every report from before Zero checked.
        if UserDefaults.standard.object(forKey: "healthSeen") == nil { seen = Date() }
        Watchdog.start(file: Self.hangFile)
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    public func check() async {
        let zerod = await Self.selfCheck()
        let (cli, reports, hang) = await Task.detached {
            (
                (try? UnixSocket.connect(path: Paths.socket)).map {
                    $0.close(); return true
                } ?? false, Health.reports(),
                (try? Data(contentsOf: HealthMonitor.hangFile)).flatMap { try? JSONDecoder().decode(AppHang.self, from: $0) }
            )
        }.value
        checks = Health.judge(
            zerod, cliAnswers: cli, app: Bundle.main.bundlePath, appZerod: ZerodLink.executable, reports: reports, hang: hang, seen: seen)
    }

    /// Reports and hangs so far looked at: no longer trouble.
    public func markSeen() async {
        seen = Date()
        await check()
    }

    /// zerod out and a new one started by the app (or whoever starts it), turns paused and carried on as for an update.
    public func restartZerod() async {
        guard let old = await Self.selfCheck()?.pid, let link = try? ZerodLink() else { return await startZerod() }
        _ = try? await link.call("restart", ["args": ["fresh": true]])
        link.close()
        // Turns pause first (a running command is let finish): looked at again until another zerod answers.
        for _ in 0..<36 {
            try? await Task.sleep(for: .seconds(5))
            if let pid = await Self.selfCheck()?.pid, pid != old { break }
        }
        await check()
    }

    public func startZerod() async {
        _ = await ZerodLink.ensureRunning()
        await check()
    }

    /// zerod's own report, or none when it doesn't answer within five seconds.
    private static func selfCheck() async -> ZerodSelfCheck? {
        guard let link = try? ZerodLink() else { return nil }
        // Closing it fails the call waiting: a zerod that accepts but never answers doesn't hold the check up.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5)); link.close()
        }
        defer { timeout.cancel(); link.close() }
        guard let result = try? await link.call("selfCheck"), let data = try? JSONSerialization.data(withJSONObject: result) else {
            return nil
        }
        return try? JSONDecoder().decode(ZerodSelfCheck.self, from: data)
    }
}

/// A thread of its own posting to the main thread every second: a post not run within Health.hangThreshold is a hang,
/// written to `file` (and its length kept up to date) so it's said even if Zero has to be force quit.
enum Watchdog {
    static func start(file: URL) {
        Thread.detachNewThread {
            let pending = NSLock()
            nonisolated(unsafe) var posted: Date?
            var hang: AppHang?
            while true {
                Thread.sleep(forTimeInterval: 1)
                let waiting = pending.withLock { posted }
                if let waiting {
                    let seconds = Date().timeIntervalSince(waiting)
                    guard seconds > Health.hangThreshold else { continue }
                    hang = AppHang(at: hang?.at ?? waiting, seconds: seconds)
                    try? JSONEncoder().encode(hang).write(to: file, options: .atomic)
                    continue
                }
                hang = nil
                pending.withLock { posted = Date() }
                DispatchQueue.main.async { pending.withLock { posted = nil } }
            }
        }
    }
}
