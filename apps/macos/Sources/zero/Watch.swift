import Foundation
import ZeroCore

@MainActor func watchListCommand() async {
    let session = targetSession()
    let watches = await zerod { try await $0.watches(session: session) }
    if watches.isEmpty { print("zero: nothing watched") }
    for watch in watches {
        let alerts = (watch["alerts"] as? [String] ?? []).map { "alert \"\($0)\"" }
        let rest = [(watch["done"] as? String).map { "until \"\($0)\"" }, (watch["quiet"] as? Int).map { "quiet \($0)m" }].compactMap { $0 }
        print("\(watch["id"] as? String ?? "")  \(watch["file"] as? String ?? "")  \((alerts + rest).joined(separator: ", "))")
    }
}

@MainActor func watchStopCommand() async {
    guard positional.count == 2 else { usage() }
    await zerod { try await $0.unwatch(positional[1]) }
    print("zero: stopped watching")
}

@MainActor func watchFileCommand() async {
    guard let session = targetSession(), let file = flag("file") else { usage() }
    let path = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL.path
    let id = await zerod { try await $0.watchFile(session: session, file: path, alerts: flags["alert"] ?? [], done: flag("until"), quiet: flag("quiet").flatMap(Int.init)) }
    print("zero: watching \(path) (\(id)); this session will be told when it prints what you're watching for")
}

@MainActor func watchCommand() async {
    guard !positional.isEmpty, let session = targetSession() else { usage() }
    await zerod { try await $0.watch(session: session, command: positional.joined(separator: " ")) }
    print("zero: watching; this session will be told how it ends")
}

@MainActor func scheduleCommand() async {
    let session = targetSession()
    switch positional.first {
    case "list":
        let list = await zerod { try await $0.schedules(session: session) }
        if list.isEmpty { print("zero: nothing scheduled") }
        for item in list { print("\(item["id"] as? String ?? "?")  \(when(item["at"]))  \(item["text"] as? String ?? "")") }
    case "cancel":
        guard positional.count == 2 else { usage() }
        await zerod { try await $0.unschedule(positional[1]) }
        print("zero: \(positional[1]) won't wake it")
    default:
        guard let session, !positional.isEmpty else { usage() }
        guard let at = flag("at").map(Schedule.at) ?? flag("in").map(Schedule.in) else {
            fail("zero: when? --at 05:12, 05:12Z or 2026-11-05T05:12Z, or --in 90m")
        }
        guard let date = at else { fail("zero: can't read that time: --at 05:12, 05:12Z or 2026-11-05T05:12Z, or --in 90m, 2h, 1d") }
        guard date > Date() else { fail("zero: that time has passed") }
        let saved = await zerod { try await $0.schedule(session: session, at: date, text: positional.joined(separator: " ")) }
        print("zero: scheduled as \(saved["id"] as? String ?? "?") for \(when(saved["at"]))")
    }
}

private func when(_ at: Any?) -> String {
    guard let at = at as? Int else { return "?" }
    let date = Date(timeIntervalSince1970: TimeInterval(at))
    return date.formatted(date: .abbreviated, time: .shortened) + " (" + date.formatted(.relative(presentation: .named)) + ")"
}

@MainActor func remindCommand() async {
    guard positional.count >= 2, let minutes = Int(positional[0]), let session = targetSession() else { usage() }
    await zerod { try await $0.remind(session: session, minutes: minutes, text: positional[1...].joined(separator: " ")) }
}

/// When `zero schedule` is for: a clock time (your clock's, or UTC with Z), a date and time, or a while from now.
enum Schedule {
    static func at(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let utc = text.hasSuffix("Z") || text.uppercased().hasSuffix(" UTC")
        let clock = text.replacingOccurrences(of: " UTC", with: "", options: .caseInsensitive).replacingOccurrences(of: "Z", with: "")
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if utc { calendar.timeZone = TimeZone(identifier: "UTC")! }
        // The next time the clock says it: today, or tomorrow if that's gone.
        return calendar.nextDate(after: Date(), matching: DateComponents(hour: parts[0], minute: parts[1]), matchingPolicy: .nextTime)
    }

    static func `in`(_ text: String) -> Date? {
        var seconds = 0, number = ""
        for character in text.lowercased() where character != " " {
            if character.isNumber { number.append(character); continue }
            guard let n = Int(number), let unit = ["s": 1, "m": 60, "h": 3600, "d": 86400][String(character)] else { return nil }
            seconds += n * unit
            number = ""
        }
        guard number.isEmpty, seconds > 0 else { return nil }
        return Date().addingTimeInterval(TimeInterval(seconds))
    }
}
