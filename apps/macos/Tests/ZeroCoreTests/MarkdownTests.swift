import Testing
@testable import ZeroCore

/// Agents answer in Markdown: its blocks (headings, lists inside lists, quotes, tables, code) are read here so the app
/// can lay each out as such; what's inside a line stays Markdown for the text to style.
@Test func anAnswersBlocksAreReadAsWhatTheyAre() {
    let text = """
    Yes, staging works for this. Here's the plan:

    **What's already in place**
    - **A test integration exists:** at `web-test`.
    - **The bench can't do it.**

    ## The test
    1. **Matched account.** Expected:
       - you land on the sign-in page
       - no integration exists yet

       Then sign in.
    2. **Signed in.** Install again.

    > Careful with prod.

    | Step | Result |
    |---|---|
    | 1 | ok |

    ```ruby
    puts 1
    ```
    ---
    """
    let blocks = MarkdownBlock.parse(text)
    #expect(blocks == [
        .paragraph("Yes, staging works for this. Here's the plan:"),
        .paragraph("**What's already in place**"),
        .list(ordered: false, start: 1, items: [
            .init(text: "**A test integration exists:** at `web-test`."),
            .init(text: "**The bench can't do it.**"),
        ]),
        .heading(level: 2, text: "The test"),
        .list(ordered: true, start: 1, items: [
            .init(text: "**Matched account.** Expected:", children: [
                .list(ordered: false, start: 1, items: [.init(text: "you land on the sign-in page"), .init(text: "no integration exists yet")]),
                .paragraph("Then sign in."),
            ]),
            .init(text: "**Signed in.** Install again."),
        ]),
        .quote("Careful with prod."),
        .table([["Step", "Result"], ["1", "ok"]]),
        .code("puts 1"),
        .rule,
    ])
}

@Test func aListStartsWhereItsNumberSays() {
    #expect(MarkdownBlock.parse("3. three\n4. four") == [.list(ordered: true, start: 3, items: [.init(text: "three"), .init(text: "four")])])
}
