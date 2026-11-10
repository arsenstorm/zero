import Foundation

/// The line Zero has an agent end its turn with: done (nothing left it can do), waiting (on someone else), working, or
/// asked (with the ask's id); "completed" and "blocked", as agents said them before, are done and waiting. The app
/// shows it as the answer's state rather than as words in the answer.
public enum ZeroEnding: Equatable, Sendable {
    case done, waiting, working
    case asked(String)

    /// Compiled once: in place, it was compiled again for every message drawn.
    nonisolated(unsafe) private static let line = #/\[zero: (done|completed|waiting|blocked|working|asked ([^\]\s]+)|asked)\]/#

    /// The answer without its ending, and the ending, when its last line is one.
    public static func split(_ text: String) -> (String, ZeroEnding?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Its last line alone: a pattern run over a long answer for a line at its end cost the rail and the timeline
        // tens of milliseconds on the main thread.
        let last = trimmed[(trimmed.lastIndex(of: "\n").map(trimmed.index(after:)) ?? trimmed.startIndex)...]
        guard last.hasPrefix("[zero: "),
              let match = last.wholeMatch(of: Self.line) else { return (text, nil) }
        let answer = trimmed[..<last.startIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        // No ask's id: no ask to wait on, so no state of its own, but not words to show either.
        if match.output.1 == "asked" { return (answer, nil) }
        let ending: ZeroEnding = switch match.output.1 {
        case "done", "completed": .done
        case "waiting", "blocked": .waiting
        case "working": .working
        default: .asked(String(match.output.2 ?? ""))
        }
        return (answer, ending)
    }
}

/// How long ago something happened, as short as a list's corner: "now", "5m", "8h", "1d", "2w".
public enum Ago {
    public static func short(_ at: Int, now: Int = Int(Date().timeIntervalSince1970 * 1000)) -> String {
        let minutes = max(0, now - at) / 60_000
        switch minutes {
        case ..<1: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(60 * 24): return "\(minutes / 60)h"
        case ..<(60 * 24 * 7): return "\(minutes / (60 * 24))d"
        default: return "\(minutes / (60 * 24 * 7))w"
        }
    }
}
