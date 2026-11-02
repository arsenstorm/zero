---
name: merge-risk
description: Grade the risk of merging a pull request (low, medium or high) before it goes to the user to merge, with the gaps that make it riskier. Use on a finished, tested PR, in a helper or subagent so the grade isn't the author's own; its first line goes into the hand-off and into a "Merge risk" column of a zero table.
---

# Merge risk

Adapted from Warp's [merge-risk](https://github.com/warpdotdev/common-skills/blob/main/.agents/skills/merge-risk/SKILL.md). The point: the user merges a low-risk PR at a glance and reads a high-risk one closely, knowing where to look.

Read the PR (`gh pr view`, `gh pr diff`), its issue and its comments. Grade each category ✅ (1), 👀 (2) or ⚠️ (3):

- **Alignment:** the code does what the issue and the PR description say. Every ask in the issue is built, or descoped on the issue with a reason. Drive-bys and assumptions are written down.
- **Impact** (weight 2): the blast radius. Sensitive paths count extra whatever the diff's size: auth, permissions, billing, personal data, secrets, data migrations, alerts and notifications, dependency bumps, infrastructure and config. So do layout shifts, other callers of a changed API, and narrow screens.
- **Verification** (weight 2): proof beyond unit tests. A UI change has screenshots, before and after where it applies. A change that can slow a page is measured. Edge cases are tested, or named as untested.
- **Rollback cost** (weight 1.5): a two-way door reverts with the merge. A one-way door doesn't: a migration or job that changes rows, an e-mail, message or webhook sent to customers, a deleted record, a call to a third party.
- **Error detection:** if it breaks in production, error tracking or a log says so before a customer does. No rescue, catch or fallback that hides a failure.

Score = Σ(grade × weight) / Σ(weights): below 1.5 is **low**, below 2.25 **medium**, otherwise **high**. Keep the numbers to yourself.

Return one line, then only the categories that aren't ✅, each with its gap in a few words and a file link where it helps:

```
Merge risk: medium. Data backfill with no dry run; no screenshot of the new banner.
- Rollback cost ⚠️: the backfill rewrites 1,200 rows (`script/backfill.rb`)
- Verification 👀: banner not rendered at 390px
```

A gap you can close (a missing screenshot, an untested edge case) is closed before the PR goes to the user, not reported.

In a `zero table`, the cell is the line without its "Merge risk:" label: `medium. Data backfill with no dry run; no screenshot of the new banner`. Zero shows the level as a pill and the gaps when the user hovers over it.
