import Testing
@testable import ZeroCore

private let pad = """
# Working with worktrees

This is the ledger. Edit only your own row.
It has two lines.

The CLI lives in the workbench repo:

| Folder | Bench | Status |
|---|:-:|---|
| `copper/gray-wolf` | gray-wolf | held |
| a \\| b | c | |

- [ ] Ship it
- [x] Test it

  indented under the list
- one more

```swift
let a = 1

let b = 2
```
> A quote
---
![shot](/tmp/shot.png)
"""

@Test func blocksJoinedAreThePadExactly() {
    for text in [pad, pad + "\n", "\n\n" + pad + "\n\n\n", "", "\n", "one line", "```\nunclosed\n\nstill code"] {
        #expect(PadBlocks.join(PadBlocks.split(text)) == text, "\(text.debugDescription)")
    }
}

@Test func eachBlockIsOneThingThePageShows() {
    let blocks = PadBlocks.split(pad)
    #expect(blocks.map(\.kind) == [.heading(1), .paragraph, .paragraph, .table, .list, .code, .quote, .rule, .image(path: "/tmp/shot.png")])
    #expect(blocks[1].body == "This is the ledger. Edit only your own row.\nIt has two lines.")
    #expect(blocks[4].body.hasSuffix("- one more"), "a list runs on past a blank line to what's indented under it")
    #expect(blocks[5].body.contains("let a = 1\n\nlet b = 2"), "a blank line inside code stays in the code")
    // An unclosed fence is code to the end, as Markdown has it: one block to fix, not a broken page.
    #expect(PadBlocks.split("Intro\n\n```\nnot closed\n\n## Ledger").map(\.kind) == [.paragraph, .code])
}

@Test func aTableIsEditedAsCellsAndWrittenBack() {
    let table = PadBlocks.split(pad)[3].body
    let rows = PadBlocks.cells(table)
    #expect(rows == [["Folder", "Bench", "Status"], ["`copper/gray-wolf`", "gray-wolf", "held"], ["a | b", "c", ""]])
    let divider = PadBlocks.divider(of: table)
    #expect(divider == "|---|:-:|---|")
    #expect(PadBlocks.table(rows, divider: divider) == "| Folder | Bench | Status |\n|---|:-:|---|\n| `copper/gray-wolf` | gray-wolf | held |\n| a \\| b | c |  |")
    // A column added: the old divider no longer fits, so a plain one.
    #expect(PadBlocks.table([["A", "B"], ["1"]], divider: "|---|") == "| A | B |\n|---|---|\n| 1 |  |")
}
