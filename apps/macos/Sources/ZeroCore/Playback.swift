import Foundation
import Observation

/// A conversation as the Mac plays it: what zerod reports, in its order, at a pace someone can follow. An answer is
/// read out word by word, and what came after it (the next turn's message, its steps, an ask answered, an event)
/// waits until it's read, then steps out a beat at a time. The more is waiting, the faster it goes, so the screen keeps
/// a couple of seconds behind at most; far behind, it shows the rest at once. Your own message never waits: it shows
/// at once, and whatever is before it with it. Opened, it shows what's there as it is; no history is replayed.
@MainActor @Observable public final class Playback {
    /// Characters a second an answer is read at with nothing waiting (Codex's, measured from a recording).
    public static let pace: Double = 240
    /// Between one step (or ask, notice, event) and the next, with nothing else waiting.
    public static let beat: Double = 0.1
    /// The lag the pace aims for: with more than this much waiting (at the steady pace), it speeds up in proportion,
    /// so a steady flow faster than the pace is followed this far behind, and a burst drains smoothly.
    public static let lag: Double = 2
    /// The fastest it reads, as a multiple of the steady pace: more than this behind, and the limit below comes into play.
    public static let fastest: Double = 8
    /// Further behind than this (since the oldest thing waiting came), or this many items waiting: the rest at once.
    public static let limit: Double = 10
    public static let crowd = 30
    /// How long a run of words takes to fade in.
    public static let fade: Double = 0.7

    /// This one's cap on speeding up, and how far behind it shows the rest at once: the statics, unless set (the
    /// phone reads more calmly, a word at a time).
    @ObservationIgnored public var fastest = Playback.fastest
    @ObservationIgnored public var limit = Playback.limit

    /// How many of the items given are on screen: always the first ones.
    public private(set) var count = 0
    /// Something to show, read out or fade in: the clock runs only then.
    public private(set) var playing = false
    /// Everything given is on screen and read out.
    public private(set) var caughtUp = true
    /// When the oldest thing not yet on screen came (the next words to read, or the next item): nil when nothing waits.
    public private(set) var waitingSince: Date?
    /// What's worked with: the observed values above are written from these, never read back (see `settle`).
    @ObservationIgnored private var shownCount = 0 { didSet { if shownCount != oldValue { count = shownCount } } }
    @ObservationIgnored private var published = (playing: false, caughtUp: true)
    @ObservationIgnored private var publishedWaiting: Date?
    @ObservationIgnored private var cards: [String: Date] = [:]
    /// Zero's own copies of messages just sent (Sending) that have shown: zerod's copy of one (the item that keeps its
    /// id, `sent`), in its place, shows at once too.
    @ObservationIgnored private var sent: Set<String> = []

    @ObservationIgnored private var items: [ConversationItem] = []
    @ObservationIgnored private var conversation: String?
    /// The last item shown: where the conversation's items are, however many come in above.
    @ObservationIgnored private var through: String?
    /// When each item first came.
    @ObservationIgnored private var came: [String: Date] = [:]
    @ObservationIgnored private var readouts: [String: Readout] = [:]
    /// Those still reading or fading, ticked by the clock.
    @ObservationIgnored private var active: [Readout] = []
    /// The answer being read out, or the last one shown, which may yet grow.
    @ObservationIgnored private var reading: Readout?
    /// Seconds of the steady pace earned and not yet spent.
    @ObservationIgnored private var credit: Double = beat
    @ObservationIgnored private var last: Date?
    @ObservationIgnored private var lengths: [String: (raw: Int, count: Int)] = [:]

    public init() {}

    /// What's there to read out of an item: an answer's words (without Zero's ending), none yet as it starts; nil for
    /// anything else.
    public static func words(_ item: ConversationItem) -> String? {
        guard case let .agent(said, _) = item.kind else { return nil }
        return ZeroEnding.split(said).0
    }

    /// What's being read out of this answer, or has been: nil for one shown whole.
    public func readout(_ id: String) -> Readout? { readouts[id] }

    /// Items given that aren't on screen yet.
    public var held: Bool { shownCount < items.count }

    /// The turn on screen still going: zerod's word once everything is shown; until then, unless the next to show is a
    /// message, starting a turn of its own.
    public func working(_ zerod: Bool) -> Bool {
        guard shownCount < items.count else { return zerod }
        if case .user = items[shownCount].kind { return false }
        return true
    }

    /// zerod's items now. Another conversation, or one not on screen (`live` false), is shown whole.
    public func update(_ items: [ConversationItem], conversation: String, live: Bool, now: Date) {
        if conversation == self.conversation, live, items == self.items { return }
        let opening = conversation != self.conversation
        if opening { reset(conversation) }
        self.items = items
        if let through, let at = items.lastIndex(where: { $0.id == through }) {
            shownCount = at + 1
        } else {
            // What was shown went (rewound, a page replaced): what's known stays shown, what's new plays.
            shownCount = items.prefix { came[$0.id] != nil }.count
        }
        for item in items where came[item.id] == nil { came[item.id] = now }
        if let reading, let item = items.last(where: { $0.id == reading.id }) {
            let total = length(item)
            if total > reading.total { reading.arrived.append((total, now)) }
            reading.total = total
        }
        if opening || !live {
            show(through: items.count - 1, now: now, fading: false)
        } else if let yours = items.lastIndex(where: justSent), yours >= shownCount {
            // Yours just sent shows at once, and whatever is before it with it, fading in. One queued while it worked
            // (sent on by zerod as the turn ended) waits its turn, as anything else does.
            show(through: yours, now: now, fading: true)
        } else if items.count - shownCount > Self.crowd {
            show(through: items.count - 1, now: now, fading: true)
        }
        settle(now)
    }

    /// Whether something that came at `seen` (a question card) may show: everything that came before it is on screen,
    /// the step that asked and the words leading to it. What came after it doesn't hold it back.
    public func admits(_ seen: Date) -> Bool { waitingSince.map { seen < $0 } ?? true }

    /// When a card was first seen in this conversation (`now` the first time it's asked about).
    public func cardSeen(_ id: String, now: Date) -> Date {
        if let at = cards[id] { return at }
        cards[id] = now
        return now
    }

    /// The clock's tick (at most 30 a second, while `playing`).
    public func advance(to now: Date) {
        let step = min(max(0, now.timeIntervalSince(last ?? now)), 0.1)
        last = now
        if let behind = oldestWaiting, now.timeIntervalSince(behind) > limit {
            show(through: items.count - 1, now: now, fading: true)
        }
        credit += step * min(fastest, max(1, waiting / Self.lag))
        while credit > 0 {
            if let reading, reading.read < reading.total {
                guard read(reading, now: now) else { break }
                continue
            }
            guard shownCount < items.count, !fadingBefore(items[shownCount], now: now) else { credit = min(credit, Self.beat); break }
            let item = items[shownCount]
            if Self.words(item) != nil {
                reveal(item, now: now, whole: false)
                continue
            }
            guard credit >= Self.beat else { break }
            credit -= Self.beat
            reveal(item, now: now, whole: false)
        }
        for readout in active {
            readout.runs.removeAll { now.timeIntervalSince($0.since) >= Self.fade }
            readout.now = now
        }
        settle(now)
    }

    /// A message (the next turn's) waits for the last words before it to finish fading in, not just to be read.
    private func fadingBefore(_ item: ConversationItem, now: Date) -> Bool {
        guard case .user = item.kind, let reading else { return false }
        return reading.runs.contains { now.timeIntervalSince($0.since) < Self.fade }
    }

    /// Reads on as far as the credit goes, to the end of a word; false when it goes nowhere.
    private func read(_ readout: Readout, now: Date) -> Bool {
        let chars = Int(credit * Self.pace)
        guard chars >= 1, let item = items.last(where: { $0.id == readout.id }) else { return false }
        if readout.letters.count != readout.total { readout.letters = Array(Self.words(item) ?? "") }
        let end = min(readout.letters.count, readout.total)
        var next = min(end, readout.read + chars)
        // Whole words: each fades in as one, never one cut off with half of it there.
        while next < end, !readout.letters[next].isWhitespace { next += 1 }
        credit -= Double(next - readout.read) / Self.pace
        readout.runs.append((readout.read, now))
        readout.read = next
        return next >= readout.total
    }

    /// Shows everything up to and including `index` now: an answer being read out finished, every answer whole.
    private func show(through index: Int, now: Date, fading: Bool) {
        if let reading, reading.read < reading.total { finish(reading, now: now, fading: fading) }
        while shownCount <= index { reveal(items[shownCount], now: now, whole: true, fading: fading) }
        credit = Self.beat
    }

    /// Yours just sent from the composer: Zero's own copy (Sending), or zerod's in its place once it has it, known by
    /// the copy's id it keeps. Never by its words: one queued with the same words waits its turn.
    private func justSent(_ item: ConversationItem) -> Bool {
        guard item.isYours else { return false }
        return item.id.hasPrefix("sending-") || item.sent.map(sent.contains) == true
    }

    private func reveal(_ item: ConversationItem, now: Date, whole: Bool, fading: Bool = true) {
        shownCount += 1
        through = item.id
        if item.id.hasPrefix("sending-") { sent.insert(item.id) }
        // Opened, only the last answer can still grow, and be read out.
        guard Self.words(item) != nil, !whole || fading || item.id == items.last?.id else { reading = nil; return }
        let readout = readouts[item.id] ?? Readout(id: item.id, now: now)
        readouts[item.id] = readout
        readout.total = length(item)
        readout.arrived = [(readout.total, came[item.id] ?? now)]
        reading = readout
        if whole { finish(readout, now: now, fading: fading) } else { track(readout) }
    }

    private func finish(_ readout: Readout, now: Date, fading: Bool) {
        if fading, readout.read < readout.total {
            readout.runs.append((readout.read, now))
            readout.now = now
            track(readout)
        }
        readout.read = readout.total
        // Shown whole, with nothing fading: done now (settle only finishes what it tracks, and this it never tracked).
        if !fading || readout.runs.isEmpty { readout.finished = true }
    }

    private func track(_ readout: Readout) {
        if !active.contains(where: { $0 === readout }) { active.append(readout) }
    }

    /// What there is still to show, in seconds at the steady pace.
    private var waiting: Double {
        var seconds = reading.map { Double(max(0, $0.total - $0.read)) / Self.pace } ?? 0
        for item in items[shownCount...] {
            seconds += Self.words(item) == nil ? Self.beat : Double(length(item)) / Self.pace
        }
        return seconds
    }

    /// When the oldest thing still to show came: the next words of the answer being read, or the next item.
    private var oldestWaiting: Date? {
        if let reading, reading.read < reading.total {
            return reading.arrived.first { $0.count > reading.read }?.at
        }
        return shownCount < items.count ? came[items[shownCount].id] : nil
    }

    private func settle(_ now: Date) {
        let unread = reading.map { $0.read < $0.total } ?? false
        if let reading, unread || !reading.runs.isEmpty { track(reading) }
        active.removeAll { readout in
            let done = readout.read >= readout.total && readout.runs.isEmpty
            readout.finished = done
            return done
        }
        let caughtUp = shownCount >= items.count && !unread
        // Written only when changed, and never read here: this runs in the conversation's body, which would otherwise
        // be redrawn by what it read.
        if caughtUp != published.caughtUp { self.caughtUp = caughtUp }
        let waiting = caughtUp ? nil : oldestWaiting
        if waiting != publishedWaiting { waitingSince = waiting; publishedWaiting = waiting }
        let playing = !caughtUp || !active.isEmpty
        if playing, !published.playing { last = now }
        if playing != published.playing { self.playing = playing }
        published = (playing, caughtUp)
    }

    private func reset(_ conversation: String) {
        self.conversation = conversation
        items = []; through = nil; came = [:]; readouts = [:]; active = []; reading = nil; shownCount = 0
        credit = Self.beat; last = nil; publishedWaiting = nil; waitingSince = nil; cards = [:]; sent = []
    }

    /// An answer's length in characters, counted again only when its text changed.
    private func length(_ item: ConversationItem) -> Int {
        guard case let .agent(said, _) = item.kind else { return 0 }
        let raw = said.utf8.count
        if let known = lengths[item.id], known.raw == raw { return known.count }
        let count = Self.words(item)?.count ?? 0
        lengths[item.id] = (raw, count)
        return count
    }
}

/// How much of one answer is on screen, and what of it is still fading in: read by the answer's view alone, so the
/// clock redraws that view and nothing else.
@MainActor @Observable public final class Readout {
    public let id: String
    /// Characters shown, from the start.
    public private(set) var shown = 0
    /// The clock's time, for the fade: moves while this is reading or fading.
    public internal(set) var now: Date
    /// Read out and faded in: plain text from here.
    public private(set) var done = false
    /// What Playback works with, written through to the two above (never read back by it, so reading this in the
    /// conversation's body doesn't have the clock redraw it).
    @ObservationIgnored var read = 0 { didSet { if read != oldValue { shown = read } } }
    @ObservationIgnored var finished = false { didSet { if finished != oldValue { done = finished } } }
    /// Where each run the clock passed starts, and when.
    @ObservationIgnored var runs: [(at: Int, since: Date)] = []
    @ObservationIgnored var total = 0
    /// How long the answer was at each time it grew: when the words after `read` came.
    @ObservationIgnored var arrived: [(count: Int, at: Date)] = []
    @ObservationIgnored var letters: [Character] = []

    init(id: String, now: Date) { self.id = id; self.now = now }

    /// Characters read, as `shown`, but read without a view taking it as something it draws from: for a view made
    /// in SwiftUI's update (RevealText), which would otherwise be updated on every tick.
    public var readSoFar: Int { read }

    /// The runs still fading in (where each starts, in characters, and when it began), read as `readSoFar` is: for a
    /// view made mid-read-out, which carries their fades on rather than showing them at once.
    public var fadingSoFar: [(at: Int, since: Date)] { runs }

    /// How far character `i` has faded in.
    public func alpha(_ i: Int) -> Double {
        guard let run = runs.last(where: { $0.at <= i }) else { return 1 }
        return min(1, max(0, now.timeIntervalSince(run.since) / Playback.fade))
    }
}
