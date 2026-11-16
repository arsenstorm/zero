import Foundation
import Testing
@testable import ZeroCore

private func yours(_ id: String, _ text: String, at: Int) -> ConversationItem {
    ConversationItem(id: id, turn: nil, kind: .user(text: text, images: []), status: .done, at: at)
}

/// A message sent while its agent starts shows at once, and gives way to the conversation's own once that's in.
@Test func aMessageSentShowsAtOnceUntilTheConversationHasIt() {
    let before = [yours("u1", "yes", at: 1_000)]
    let echo = Sending(text: "yes", images: [], at: 5_000)
    let shown = Sending.merge(before, [echo])
    #expect(shown.map(\.id) == ["u1", echo.id], "the same words as an earlier message still show: it's a new one")
    let arrived = before + [yours("u2", "yes, expanded by a loop", at: 5_200)]
    #expect(Sending.merge(arrived, [echo]).map(\.id) == ["u1", "u2"], "the agent has it: the conversation's own, once")
}

/// Steered from the strip, a queued message goes under its row's id: the strip knows it's in the conversation from
/// the click (Zero's own copy) and after (zerod's item keeps the id), so it never stays there as Next.
@Test func aSteeredRowIsCarriedFromTheClickOn() {
    let echo = Sending(id: "queuing-1", text: "why? [Image 1]", images: ["/a.png"], at: 5_000)
    #expect(Sending.merge([], [echo]).map(\.sent) == ["queuing-1"], "Zero's own copy is the message of that id")
    #expect(Sending.carried([], [echo]).contains("queuing-1"), "from the click")
    let zerods = ConversationItem(
        id: "user-3", turn: nil, kind: .user(text: "why? [Image #1]", images: ["/a.png"]), status: .done, at: 5_100, sent: "queuing-1")
    #expect(Sending.carried([zerods], []).contains("queuing-1"), "and once zerod has it")
    #expect(!Sending.carried([zerods], []).contains("queuing-2"), "another row stays")
}
