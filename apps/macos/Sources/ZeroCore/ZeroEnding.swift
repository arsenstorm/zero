import Foundation

/// The line Zero has an agent end its turn with: done (nothing left it can do), waiting (on someone else), working, or
/// asked (with the ask's id); "completed" and "blocked", as agents said them before, are done and waiting. The app
/// shows it as the answer's state rather than as words in the answer.
public enum ZeroEnding: Equatable, Sendable {
    case done, waiting, working
    case asked(String)

    /// The answer without its ending, and the ending, when its last line is one.
    public static func split(_ text: String) -> (String, ZeroEnding?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: #/(?:^|\n)\[zero: (done|completed|waiting|blocked|working|asked ([^\]\s]+))\]$/#) else { return (text, nil) }
        let ending: ZeroEnding = switch match.output.1 {
        case "done", "completed": .done
        case "waiting", "blocked": .waiting
        case "working": .working
        default: .asked(String(match.output.2 ?? ""))
        }
        let answer = trimmed[..<match.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer, ending)
    }
}
