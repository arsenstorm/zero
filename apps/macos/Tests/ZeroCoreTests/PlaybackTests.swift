import Foundation
import Testing
@testable import ZeroCore

private func item(_ id: String, _ kind: ConversationItem.Kind) -> ConversationItem {
    ConversationItem(id: id, turn: nil, kind: kind, status: .done, at: 0)
}
/// Yours, all with the same words: what tells them apart is what they are, never what they say.
private func yours(_ id: String, sent: String? = nil) -> ConversationItem {
    ConversationItem(id: id, turn: nil, kind: .user(text: "do it", images: []), status: .done, at: 0, sent: sent)
}
private func zero(_ id: String) -> ConversationItem { item(id, .user(text: "<!-- from: zero -->\nThe user answered your ask", images: [])) }
private func words(_ id: String, _ count: Int, final: Bool = true) -> ConversationItem {
    item(id, .agent(text: String(repeating: "word ", count: count / 5), finalAnswer: final))
}
private func step(_ id: String) -> ConversationItem { item(id, .tool(name: "Read", detail: "a file")) }

/// A conversation playing on a clock of its own: `t` seconds after it was opened.
@MainActor private final class Player {
    let playback = Playback()
    let start = Date(timeIntervalSince1970: 1_000_000)
    var t: Double = 0
    var items: [ConversationItem] = []
    init(_ items: [ConversationItem] = []) { self.items = items; give() }
    func give(_ more: [ConversationItem] = []) {
        items += more
        playback.update(items, conversation: "c", live: true, now: start.addingTimeInterval(t))
    }
    /// Ticks at 30 a second for `seconds`.
    func play(_ seconds: Double) {
        for _ in 0..<Int((seconds * 30).rounded()) {
            t += 1 / 30
            playback.advance(to: start.addingTimeInterval(t))
        }
    }
    var shown: [String] { items.prefix(playback.count).map(\.id) }
    func read(_ id: String) -> Int { playback.readout(id)?.shown ?? 0 }
}

@MainActor @Test func openingShowsEverythingAtOnce() {
    let player = Player([yours("u1"), step("s1"), words("a1", 2000)])
    #expect(player.shown == ["u1", "s1", "a1"])
    #expect(!player.playback.playing, "nothing to replay: no clock")
    #expect(player.playback.caughtUp)
}

@MainActor @Test func whatComesDuringAReadOutWaitsForIt() {
    let player = Player([yours("u1")])
    player.give([words("a1", 1000, final: false)])
    player.play(0.5)
    #expect(player.shown == ["u1", "a1"])
    #expect(player.read("a1") > 0 && player.read("a1") < 1000)
    // Turn 1 ends, a Zero message starts turn 2, which gets to work: all of it waits for the answer.
    player.give([zero("z2"), step("s2")])
    player.play(0.5)
    #expect(player.shown == ["u1", "a1"], "nothing after the answer while it's read out")
    #expect(!player.playback.working(false), "turn 1 is over on screen")
    #expect(!player.playback.working(true), "turn 2 working isn't shown under turn 1's answer")
    player.play(6)
    #expect(player.read("a1") == 1000)
    #expect(player.shown == ["u1", "a1", "z2", "s2"], "then what followed, in order")
    #expect(player.playback.working(true))
}

@MainActor @Test func nothingWaitingReadsAtTheSteadyPace() {
    let player = Player([yours("u1")])
    player.give([words("a1", 400)])
    player.play(1)
    // 240 a second, give or take the word the clock is in and the first beat it starts with.
    #expect((240...275).contains(player.read("a1")))
}

@MainActor @Test func stepsStepOutInOrderQuicklyNotAllAtOnce() {
    let player = Player([yours("u1")])
    player.give([step("s1"), step("s2"), step("s3"), step("s4")])
    player.play(1 / 30)
    #expect(player.shown.count < 5, "not all in one frame")
    #expect(player.shown.first == "u1")
    player.play(0.5)
    #expect(player.shown == ["u1", "s1", "s2", "s3", "s4"], "and not slowly")
}

@MainActor @Test func catchUpKeepsTheLagBoundedAndSpeedsUpSmoothly() {
    let player = Player([yours("u1")])
    player.give([words("a1", 0, final: false)])
    // The agent writes 600 characters a second, two and a half times the steady pace, for ten seconds.
    var text = ""
    var paces: [Int] = []
    for second in 0..<10 {
        for _ in 0..<30 {
            text += "word word word word "
            player.items[1] = item("a1", .agent(text: text, finalAnswer: false))
            player.give()
            let before = player.read("a1")
            player.play(1 / 30)
            paces.append((player.read("a1") - before) * 30)
        }
        if second >= 3 {
            let behind = Double(text.count - player.read("a1")) / 600
            #expect(behind < 3, "never more than about 2 s behind what's come (\(behind) s at \(second) s)")
        }
    }
    // Smooth: the pace never leaps from one frame to the next by more than a few words' worth.
    let average = zip(paces, paces.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / paces.count
    #expect(average < 300, "the pace changes gradually (\(average) chars/s a frame on average)")
}

@MainActor @Test func aLongAnswerComingWholeIsReadOutFasterButStillReadOut() {
    let player = Player([yours("u1")])
    player.give([words("a1", 2000)])
    player.play(1)
    #expect(player.read("a1") > 400, "faster than 240 a second with so much to read")
    #expect(player.read("a1") < 2000, "but read out, not shown at once")
    player.play(5)
    #expect(player.read("a1") == 2000, "done in about five seconds, not eight")
}

@MainActor @Test func farBehindItShowsTheRestAtOnce() {
    let player = Player([yours("u1")])
    // More than anyone reads in ten seconds even sped up.
    player.give([words("a1", 40000), step("s1")])
    player.play(10.5)
    #expect(player.read("a1") == 40000)
    #expect(player.shown == ["u1", "a1", "s1"])
}

@MainActor @Test func aCrowdOfItemsWaitingShowsAtOnce() {
    let player = Player([yours("u1")])
    player.give([words("a1", 2000)])
    player.play(0.2)
    player.give((0..<40).map { step("s\($0)") })
    #expect(player.playback.count == player.items.count, "too many waiting: shown")
}

@MainActor @Test func yourMessageShowsAtOnceAndWhatsBeforeItCatchesUp() {
    let player = Player([yours("u1")])
    player.give([words("a1", 2000), step("s1")])
    player.play(0.3)
    #expect(player.read("a1") < 2000)
    // Just sent from the composer (Zero's own copy until zerod has it): at once, with all before it.
    player.give([yours("sending-1")])
    #expect(player.shown == ["u1", "a1", "s1", "sending-1"], "yours at once, and all before it")
    #expect(player.read("a1") == 2000, "the answer above it finished")
    player.play(0.8)
    #expect(player.playback.caughtUp && !player.playback.playing, "its last words faded in within the fade")
    // zerod's copy in its place (it keeps the copy's id): shown as it was, not played again.
    player.items.removeLast()
    player.give([yours("u2", sent: "sending-1")])
    #expect(player.shown == ["u1", "a1", "s1", "u2"])
}

@MainActor @Test func aQueuedMessageWaitsForTheAnswerBeforeIt() {
    // Queued while it worked (in the strip, not just sent): when the turn ends and zerod sends it on, it comes after
    // the answer is read out, not cutting it short.
    let player = Player([yours("u1")])
    player.give([words("a1", 2000)])
    player.play(0.3)
    player.give([yours("u2"), step("s2")])
    #expect(player.shown == ["u1", "a1"], "the answer still reading: the message waits")
    #expect(player.read("a1") < 2000)
    player.play(10)
    #expect(player.shown == ["u1", "a1", "u2", "s2"], "then in its turn")
}

@MainActor @Test func zerosMessagesWaitTheirTurn() {
    let player = Player([yours("u1")])
    player.give([words("a1", 1000), zero("z2")])
    player.play(0.2)
    #expect(player.shown == ["u1", "a1"], "not yours: in order, after the answer")
}

@MainActor @Test func offScreenItDoesNotPlay() {
    let player = Player([yours("u1")])
    player.items += [words("a1", 2000), step("s1")]
    player.playback.update(player.items, conversation: "c", live: false, now: player.start)
    #expect(player.playback.count == 3)
    #expect(!player.playback.playing)
}

@MainActor @Test func anotherConversationOpensWhole() {
    let player = Player([yours("u1")])
    player.give([words("a1", 2000)])
    player.playback.update([yours("v1"), words("b1", 3000)], conversation: "d", live: true, now: player.start)
    #expect(player.playback.count == 2)
    #expect(!player.playback.playing)
}

@MainActor @Test func olderItemsComingInAboveShowAsTheyCome() {
    let player = Player([yours("u3"), words("a3", 100)])
    player.items = [yours("u1"), words("a1", 100), yours("u2"), words("a2", 100)] + player.items
    player.give()
    #expect(player.playback.count == 6)
}

@MainActor @Test func wordsStillComingAfterItOpenedAreReadOut() {
    let player = Player([yours("u1"), words("a1", 100, final: false)])
    player.items[1] = words("a1", 600, final: false)
    player.give()
    player.play(0.5)
    #expect((200...600).contains(player.read("a1")), "what's new read out from where it was")
}

@MainActor @Test func aCardComesOnceWhatCameBeforeItIsShown() {
    // An ask comes as the agent is still being read out: it waits for the words and step before it, not for the words
    // that came after it.
    let player = Player([yours("u1")])
    player.give([words("a1", 1000, final: false)])
    player.play(0.2)
    player.t += 0.01
    player.give([step("s1")])
    let seen = player.start.addingTimeInterval(player.t + 0.01)
    #expect(!player.playback.admits(seen), "the words and step before it are still to show")
    player.t += 0.02
    player.give([words("a2", 2000)])
    player.play(4.2)
    #expect(player.shown.contains("s1") && player.read("a2") < 2000, "its step shown, the words after it still reading")
    #expect(player.playback.admits(seen), "everything before it shown: up it comes, whatever came after")
    // Opened with it already there: at once.
    let opened = Player([yours("u1"), step("s1")])
    #expect(opened.playback.admits(opened.start))
}

@MainActor @Test func aQueuedMessageWithTheWordsOfOneJustSentStillWaits() {
    // Sent from the composer, then the same words queued while it answers: zerod's copy of the first shows at once, the
    // queued one waits for the answer like any other.
    let player = Player([yours("u0")])
    player.give([yours("sending-1")])
    player.items.removeLast()
    player.give([yours("u1", sent: "sending-1")])
    #expect(player.shown == ["u0", "u1"])
    player.give([words("a1", 2000)])
    player.play(0.3)
    player.give([yours("u2", sent: "queue-1"), step("s2")])
    #expect(player.shown == ["u0", "u1", "a1"], "the same words, but not the message just sent: it waits")
    #expect(player.read("a1") < 2000, "and the answer reads on, not finished at once")
    player.play(10)
    #expect(player.shown == ["u0", "u1", "a1", "u2", "s2"])
}

@MainActor @Test func aMessageFromElsewhereWithTheSameWordsWaitsToo() {
    // Your words from another device (or zerod's copy of something not sent here) aren't the one just sent here.
    let player = Player([yours("u0")])
    player.give([yours("sending-1")])
    player.give([words("a1", 2000)])
    player.play(0.3)
    player.give([yours("u2")])
    #expect(!player.shown.contains("u2"))
}

@MainActor @Test func aQueuedMessageComesOnceTheLastWordsHaveFadedIn() {
    let player = Player([yours("u1")])
    player.give([words("a1", 100), yours("u2", sent: "queue-1")])
    player.play(0.6)
    #expect(player.read("a1") == 100, "read out")
    #expect(player.shown == ["u1", "a1"], "its last words still fading in: the message waits")
    player.play(0.8)
    #expect(player.shown == ["u1", "a1", "u2"])
}
