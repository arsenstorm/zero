import Testing
@testable import ZeroCore

/// Agents end a turn with Zero's ending ("[zero: done]", "[zero: asked 3f2a]"), which Zero's hook reads. The app shows
/// it as the answer's state instead of as words in it.
@Test func zerosEndingComesOffTheAnswerAsItsState() {
    #expect(ZeroEnding.split("PR #13336 is open.\n\n[zero: done]") == ("PR #13336 is open.", .done))
    #expect(ZeroEnding.split("Which one?\n[zero: asked 3f2a9c]  ") == ("Which one?", .asked("3f2a9c")))
    #expect(ZeroEnding.split("Can't reach staging.\n\n[zero: blocked]") == ("Can't reach staging.", .blocked))
    #expect(ZeroEnding.split("Pausing between steps.\n[zero: working]") == ("Pausing between steps.", .working))
    #expect(ZeroEnding.split("It says [zero: done] in the middle") == ("It says [zero: done] in the middle", nil), "only as the last line")
    #expect(ZeroEnding.split("[zero: done]") == ("", .done))
}
