import AppKit
import Observation
import SwiftUI
import ZeroCore

/// Markdown the way agents write it: paragraphs with inline emphasis and `code`, and fenced blocks set in
/// monospace on their own surface. ponytail: fences and inline syntax only; headings and lists read as text.
struct MarkdownText: View {
    let text: String
    /// Where "#123" points: the GitHub repository of the agent's folder.
    var repo: String?
    /// Whose "name#123" is, when the folder holds repositories rather than being one.
    var owner: String?
    /// The body text's size; headings, code and markers scale with it. The inbox's cards are smaller than a task's page.
    var size: CGFloat
    /// Quieter, for a preview: headings at the text's size, code without pills, tighter spacing.
    var compact: Bool
    /// As wide as its text, not the width it's given: a message of yours, in a bubble that hugs it.
    var hugs: Bool
    /// A message of yours: "/skill" and "@loop" in it are the tokens the composer showed, drawn as the same pills.
    var yours: Bool
    /// A click not on a link (RichText's).
    var onClick: (() -> Void)?
    /// Still being revealed (StreamingText): each frame's text is styled without being kept, as it's gone by the next.
    var streaming = false
    /// While streaming: how far each character of the text (by its place in it) has faded in, and how long the text is.
    var fade: ((Int) -> Double)?
    var fadeLength = 0

    init(
        _ text: String, cwd: String? = nil, size: CGFloat = 13, compact: Bool = false, hugs: Bool = false, yours: Bool = false,
        onClick: (() -> Void)? = nil
    ) {
        self.text = text
        repo = cwd.flatMap(References.repo(of:))
        owner = cwd.flatMap(References.owner(of:))
        self.size = size
        self.compact = compact
        self.hugs = hugs
        self.yours = yours
        self.onClick = onClick
    }

    /// Set once a long text has been rendered off the main thread, so the view picks it up.
    @State private var rendered = false
    /// Texts this long render off the main thread, their plain text shown meanwhile.
    private static let long = 4000

    var body: some View {
        let _ = rendered
        if let rich = styled {
            RichText(text: rich, hugs: hugs, onClick: onClick).onChange(of: text, initial: true) { styleLong() }
        } else {
            // Its words while it's styled: a long answer never holds up the page.
            Text(ZeroEnding.split(text).0).font(.system(size: size)).lineSpacing(round(size * 0.42)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: text, initial: true) { styleLong() }
        }
    }

    /// The text styled: kept from before, styled now when short, or, for a long one still arriving, the part styled
    /// so far, which stays while the rest is styled rather than falling back to plain words with each new piece.
    private var styled: NSAttributedString? {
        if streaming {
            let made = Self.renderGrowing(text, size: size, links: links)
            guard let fade else { return made }
            return Self.faded(made, sourceLength: fadeLength, alpha: fade)
        }
        if let kept = RichMarkdown.kept(text, size: size, compact: compact, repo: repo, yours: yours) { return kept }
        if text.count < Self.long { return Self.render(text, size: size, compact: compact, links: links) }
        if let last, text.hasPrefix(last.text) { return last.rich }
        return nil
    }

    func streaming(_ on: Bool) -> MarkdownText { var copy = self; copy.streaming = on; return copy }
    func fading(shown: Int, alpha: @escaping (Int) -> Double) -> MarkdownText {
        var copy = self; copy.fade = alpha; copy.fadeLength = shown; return copy
    }

    /// The rendered text with its newest characters faded: matched to the source from the end (the Markdown's marks
    /// are few there), each run of one opacity (in 24 steps) set once.
    /// How far from the end a fade can recolour: 700 ms at Playback's fastest pace.
    nonisolated static let fadeReach = 1400

    nonisolated static func faded(_ made: NSAttributedString, sourceLength: Int, alpha: (Int) -> Double) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: made)
        let length = out.length
        // Only the last 700 ms' worth can be fading.
        let reach = min(length, fadeReach)
        var i = length - reach
        while i < length {
            let source = sourceLength - (length - i)
            let step = (alpha(source) * 24).rounded() / 24
            var end = i + 1
            while end < length, (alpha(sourceLength - (length - end)) * 24).rounded() / 24 == step { end += 1 }
            if step < 1 {
                let range = NSRange(location: i, length: end - i)
                out.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                    let color = (value as? NSColor) ?? .labelColor
                    out.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * step), range: run)
                }
                // An image among them fades as they do: a copy of its cell at their alpha (the styled text is shared).
                out.enumerateAttribute(.attachment, in: range) { value, run, _ in
                    guard let picture = (value as? NSTextAttachment)?.attachmentCell as? PictureCell, let image = picture.image else {
                        return
                    }
                    let cell = PictureCell(imageCell: image)
                    cell.alpha = step
                    let faded = NSTextAttachment()
                    faded.attachmentCell = cell
                    out.addAttribute(.attachment, value: faded, range: run)
                }
            }
            i = end
        }
        return out
    }

    /// The last long text styled here.
    @State private var last: (text: String, rich: NSAttributedString)?
    @State private var styler = Styler()

    /// One styling at a time for a long text: as it streams in, each pass styles the latest text, and passes again if
    /// more came meanwhile, rather than starting one per piece (each the whole answer) and dropping each unfinished.
    final class Styler { var latest = ""; var busy = false }

    private func styleLong() {
        styler.latest = text
        guard !streaming, text.count >= Self.long, !styler.busy else { return }
        if let kept = RichMarkdown.kept(text, size: size, compact: compact, repo: repo, yours: yours) { last = (text, kept); return }
        styler.busy = true
        let (size, compact, links, styler) = (size, compact, links, styler)
        Task { @MainActor in
            while true {
                let target = styler.latest
                let made = await Task.detached(priority: .userInitiated) {
                    Rendered(Self.render(target, size: size, compact: compact, links: links))
                }.value
                last = (target, made.text)
                rendered.toggle()
                if styler.latest == target { break }
            }
            styler.busy = false
        }
    }

    /// What finding links needs, read on the main thread so rendering can happen anywhere.
    private var links: Links { Self.links(repo: repo, owner: owner, yours: yours) }

    static func links(repo: String?, owner: String?, yours: Bool) -> Links {
        Links(
            repo: repo, owner: owner, github: GitHubLinks.enabled, slack: SlackLinks.teams,
            teams: LinearLinks.enabled ? Linear.shared.teams : [:],
            app: LinearLinks.inApp, loops: LoopNames.known, skills: yours, pads: PadNames.known)
    }

    /// Styles a conversation's messages ahead of their first drawing (the window opening on it), off the main thread,
    /// so the page paints at once instead of parsing as it scrolls into view.
    static func warm(_ conversation: Conversation) async {
        let repo = References.repo(of: conversation.cwd)
        let owner = References.owner(of: conversation.cwd)
        let (theirs, yours) = (links(repo: repo, owner: owner, yours: false), links(repo: repo, owner: owner, yours: true))
        let texts: [(String, Bool)] = conversation.items.compactMap { item in
            switch item.kind {
            case let .agent(text, _): (text, false)
            case let .user(text, images): (ImageToken.linked(text, images: images), true)
            default: nil
            }
        }
        await Task.detached(priority: .userInitiated) {
            for (text, mine) in texts { _ = render(text, size: 14.5, compact: false, links: mine ? yours : theirs) }
        }.value
    }

    struct Links: Sendable {
        let repo: String?
        let owner: String?
        /// Pull requests and commits as links.
        var github = true
        /// The Slack workspaces connected: "#channel" and Slack's own links open in Slack.
        var slack: [Slack.State] = []
        let teams: [String: String]
        let app: Bool
        /// The loops' names: "@name" in a message is one of them, drawn as a pill that opens it.
        var loops: [String] = []
        /// Words of yours: "/name" is a skill or command, a pill as the composer drew it (an agent's "/path" is a path).
        var skills = false
        /// The pads' titles by id: a bare zero://pad/<id> link reads as its pad's title (and section), not its address.
        var pads: [String: String] = [:]
    }

    private struct Rendered: @unchecked Sendable { let text: NSAttributedString; init(_ text: NSAttributedString) { self.text = text } }

    /// A text still arriving, styled but not kept: its finished blocks come from the block cache, its last styled anew.
    nonisolated static func renderGrowing(_ text: String, size: CGFloat, links: Links) -> NSAttributedString {
        let source = ZeroEnding.split(text).0
        let key = "\(links.repo ?? "")|\(links.owner ?? "")|\(links.skills)|false"
        let render = { (part: String, growing: Bool, trimmed: Bool) in
            RichMarkdown.render(
                MarkdownBlock.parse(part), size: size, inline: { inline($0, links: links) }, key: key, growing: growing, trimmed: trimmed)
        }
        // What's settled (MarkdownBlock.settled) is rendered once and kept; each frame parses and styles only what
        // follows it. Parsed whole, each frame's work grew with the answer.
        guard let cut = MarkdownBlock.settled(source) else { return render(source, true, true) }
        let head = String(source[..<cut])
        let kept = Settled.lock.withLock { Settled.last.first { $0.key == key && $0.size == size && $0.head == head }?.text }
        let settled = kept ?? render(head, false, false)
        if kept == nil { Settled.lock.withLock { Settled.last = [(key, size, head, settled)] + Settled.last.prefix(1) } }
        let out = NSMutableAttributedString(attributedString: settled)
        out.append(render(String(source[cut...]), true, true))
        return out
    }

    /// The settled start of the answer being read out, as last rendered: two, so two answers styled by turns (a
    /// reveal's restyle and another view's) don't style each other's settled start again each time.
    private enum Settled {
        static let lock = NSLock()
        nonisolated(unsafe) static var last: [(key: String, size: CGFloat, head: String, text: NSAttributedString)] = []
    }

    /// Parsed, styled and kept. Zero's own ending ("[zero: done]") is for its hook, not for reading.
    nonisolated static func render(_ text: String, size: CGFloat, compact: Bool, links: Links) -> NSAttributedString {
        RichMarkdown.cached(text, size: size, compact: compact, repo: links.repo, yours: links.skills) {
            let made = RichMarkdown.render(
                MarkdownBlock.parse(ZeroEnding.split(text).0), size: size, inline: { inline($0, links: links) },
                key: "\(links.repo ?? "")|\(links.owner ?? "")|\(links.skills)|\(compact)")
            // Yours, in a bubble: its code without a panel of its own (never a card in a card).
            let flat = links.skills ? RichMarkdown.flat(made) : made
            return compact ? RichMarkdown.compact(flat, size: size) : flat
        }
    }

    /// Linear issues and pull requests become links, except inside `code` and links the agent already wrote.
    nonisolated static func inline(_ prose: String, links: Links) -> AttributedString {
        var result =
            (try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(prose)
        for run in result.runs where run.link != nil {
            if let link = run.link, let app = SlackLinks.url(link, in: links.slack) { result[run.range].link = app }
        }
        for (range, url) in References.find(
            in: String(result.characters), repo: links.repo, linear: links.teams, linearApp: links.app, owner: links.owner,
            github: links.github, slack: links.slack)
        {
            guard let span = Range(range, in: result) else { continue }
            let plain = result[span].runs.allSatisfy { $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false) }
            if plain { result[span].link = url }
        }
        if !links.loops.isEmpty, let regex = try? NSRegularExpression(pattern: "(?<![\\w@])@([a-z0-9-]+)(?![\\w-])") {
            let string = String(result.characters)
            for match in regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
                let name = (string as NSString).substring(with: match.range(at: 1))
                guard links.loops.contains(name), let range = Range(match.range, in: string), let span = Range(range, in: result),
                    result[span].runs.allSatisfy({ $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false) }),
                    let url = URL(string: "zero://loop/" + name)
                else { continue }
                result[span].link = url
            }
        }
        // A pad's address written out (zero://pad/<id>, a #section after it): its title in its place, the address its
        // link, so it reads as what it is and opens it. Last to first, as each title changes the text's length.
        if let regex = try? NSRegularExpression(pattern: "zero://pad/([A-Za-z0-9]+)(?:#([A-Za-z0-9_-]+))?") {
            let string = String(result.characters)
            for match in regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)).reversed() {
                let id = (string as NSString).substring(with: match.range(at: 1))
                guard let range = Range(match.range, in: string), let span = Range(range, in: result),
                    result[span].runs.allSatisfy({ !($0.inlinePresentationIntent?.contains(.code) ?? false) }),
                    let url = URL(string: (string as NSString).substring(with: match.range))
                else { continue }
                let section =
                    match.range(at: 2).location == NSNotFound
                    ? nil : (string as NSString).substring(with: match.range(at: 2)).replacingOccurrences(of: "-", with: " ")
                let title = links.pads[id].map { $0.isEmpty ? "Untitled pad" : $0 } ?? "Scratchpad"
                var named = AttributedString(section.map { "\(title) › \($0.prefix(1).uppercased() + $0.dropFirst())" } ?? title)
                if let first = result[span].runs.first { named.mergeAttributes(first.attributes) }
                named.link = url
                result.replaceSubrange(span, with: named)
            }
        }
        if links.skills, let regex = try? NSRegularExpression(pattern: "(?<![^\\s])/[^\\s]+") {
            let string = String(result.characters)
            for match in regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
                guard let range = Range(match.range, in: string), let span = Range(range, in: result),
                    result[span].runs.allSatisfy({ $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false) }),
                    let url = URL(
                        string: "zero://skill/" + (string as NSString).substring(with: match.range).dropFirst().addingPercentEncoding(
                            withAllowedCharacters: .urlPathAllowed)!)
                else { continue }
                result[span].link = url
            }
        }
        return result
    }
}
