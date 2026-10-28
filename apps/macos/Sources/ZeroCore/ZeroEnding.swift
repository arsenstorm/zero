import Foundation

/// The line Zero's hook has an agent end its turn with: done, asked (with the ask's id), blocked, or working. The app
/// shows it as the answer's state rather than as words in the answer.
public enum ZeroEnding: Equatable, Sendable {
    case done, blocked, working
    case asked(String)

    /// The answer without its ending, and the ending, when its last line is one.
    public static func split(_ text: String) -> (String, ZeroEnding?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: #/(?:^|\n)\[zero: (done|blocked|working|asked ([^\]\s]+))\]$/#) else { return (text, nil) }
        let ending: ZeroEnding = switch match.output.1 {
        case "done": .done
        case "blocked": .blocked
        case "working": .working
        default: .asked(String(match.output.2 ?? ""))
        }
        let answer = trimmed[..<match.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer, ending)
    }
}
