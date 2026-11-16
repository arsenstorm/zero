import Foundation

/// One setting as Settings' search finds it: its page and section, its name and line as its row shows them, and other
/// words people use for it ("compact" for Summarise conversations at).
public struct SettingsEntry: Hashable, Sendable, Identifiable {
    public let id: String
    public let page: String
    public let section: String
    public let title: String
    public let detail: String
    public let keywords: [String]

    public init(id: String, page: String, section: String, title: String, detail: String, keywords: [String] = []) {
        self.id = id; self.page = page; self.section = section; self.title = title; self.detail = detail; self.keywords = keywords
    }

    /// How well `query` finds it, best first: each word typed starts a word of its title (0); of its title, section,
    /// page or keywords (1); or of those or its line (2). Nil when it doesn't.
    public func rank(_ query: String) -> Int? {
        let typed = Self.words(query)
        guard !typed.isEmpty else { return nil }
        let named = [title, section, page] + keywords
        return [[title], named, named + [detail]].firstIndex { fields in
            let words = Self.words(fields.joined(separator: " "))
            return typed.allSatisfy { word in words.contains { $0.hasPrefix(word) } }
        }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

public enum SettingsSearch {
    /// The entries `query` finds, by page: the page of the best match first, and in a page the best first; equal
    /// matches in the index's order.
    public static func results(_ entries: [SettingsEntry], for query: String) -> [(page: String, entries: [SettingsEntry])] {
        let ranked = entries.enumerated().compactMap { index, entry in entry.rank(query).map { (entry, $0, index) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
        var pages: [String] = []
        for entry in ranked where !pages.contains(entry.page) { pages.append(entry.page) }
        return pages.map { page in (page, ranked.filter { $0.page == page }) }
    }
}
