import Foundation
import Testing
@testable import ZeroCore

private func yours(_ id: String, _ text: String, at: Int) -> ConversationItem { ConversationItem(id: id, turn: nil, kind: .user(text: text, images: []), status: .done, at: at) }

/// A message sent while its agent starts shows at once, and gives way to the conversation's own once that's in.
@Test func aMessageSentShowsAtOnceUntilTheConversationHasIt() {
    let before = [yours("u1", "yes", at: 1_000)]
    let echo = Sending(text: "yes", images: [], at: 5_000)
    let shown = Sending.merge(before, [echo])
    #expect(shown.map(\.id) == ["u1", echo.id], "the same words as an earlier message still show: it's a new one")
    let arrived = before + [yours("u2", "yes, expanded by a loop", at: 5_200)]
    #expect(Sending.merge(arrived, [echo]).map(\.id) == ["u1", "u2"], "the agent has it: the conversation's own, once")
}
