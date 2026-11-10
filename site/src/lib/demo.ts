/** The ask the hero shows: the window's open task waiting on you, the same ask docked in its conversation. */
export const heroAsk = {
  kind: "approve" as const,
  headline: "Open a pull request with the fix?",
  byline: "Fix the flaky login test",
  supporting:
    "With the cookie write before the redirect, the test passes 50 runs out of 50.",
  options: ["Yes", "No", "Suggest something else…"],
};

/** The inbox section's asks: two from each agent, each its own (nothing else on the page shows them). */
export const inboxAsks = [
  {
    agent: "Claude Code",
    task: "Add rate limits to the API",
    headline: "Limit each account, not each key?",
    supporting:
      "One account can hold many keys, so a limit per key lets it go past the limit.",
    options: ["Yes", "No", "Suggest something else…"],
  },
  {
    agent: "Codex",
    task: "Move the date pickers to version 9",
    headline: "Update the date picker now?",
    command: "pnpm up react-day-picker@9",
    options: ["Update", "Not now", "Suggest something else…"],
  },
  {
    agent: "OpenCode",
    task: "Write the 2.4 changelog",
    headline: "Mention the removed export flag?",
    supporting: "Nobody used it in the last 90 days.",
    options: ["Yes", "No", "Suggest something else…"],
  },
  {
    agent: "Claude Code",
    task: "Split the settings screen",
    headline: "Keep the old screen behind a flag?",
    supporting: "Then you can switch back if people miss it.",
    options: ["Yes", "No", "Suggest something else…"],
  },
  {
    agent: "Codex",
    task: "Clean up the test fixtures",
    headline: "Delete the 14 unused fixtures?",
    options: ["Delete", "Keep", "Suggest something else…"],
  },
  {
    agent: "OpenCode",
    task: "Speed up the search index",
    headline: "Rebuild the index tonight?",
    supporting:
      "It takes about 20 minutes, and search is slower while it runs.",
    options: ["Yes", "No", "Suggest something else…"],
  },
];
