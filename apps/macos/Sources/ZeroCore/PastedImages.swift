import Foundation

/// Images pasted into a plain reply box (an ask's "Something else…"): their paths go after the words, so the answer
/// the agent reads names them, and the box shows the words with the images as tiles. `folder` is where Zero keeps
/// them (~/.zero/attachments): only its paths are images.
public enum PastedImages {
    /// The words as typed, and the images' paths in their order.
    public static func split(_ text: String, folder: String) -> (words: String, images: [String]) {
        let pattern = "(?:^|[ \\n])(" + NSRegularExpression.escapedPattern(for: folder + "/") + "\\S+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let whole = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: whole.length))
        guard !matches.isEmpty else { return (text, []) }
        let words = NSMutableString(string: text)
        for match in matches.reversed() { words.deleteCharacters(in: match.range) }
        return (words as String, matches.map { whole.substring(with: $0.range(at: 1)) })
    }

    /// The text kept and sent: the words, then each image's path. `split` gives the words back exactly as typed.
    public static func join(_ words: String, _ images: [String]) -> String {
        images.reduce(words) { $0.isEmpty ? $1 : $0 + " " + $1 }
    }
}
