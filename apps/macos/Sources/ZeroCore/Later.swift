import Foundation

/// The words that ask a task's agent to save something for later: Zero writes nothing itself, the agent does.
public enum LaterAsk {
    public static func text(answer: String? = nil) -> String {
        let what =
            answer.map {
                "what this answer of yours says:\n\n> "
                    + $0.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n> ") + "\n\n"
            }
            ?? "what you have so far: where the work stands and what's left. "
        return """
            The user wants to save \(what)for later. Save it with `zero later save "note" --asked --file -` and the artifact on stdin \
            (add --link for related threads or pages, --attach for screenshots or files):
            - The note: a headline under 100 characters in plain words, saying what needs doing later. No ids, paths or lists.
            - The artifact: everything you've worked out behind it, in full, in Markdown. Findings, causes with file:line, \
            the plan, commands, links. Nothing summed up or left out: someone starting from it later has only this.
            Then tell the user its link, and carry on with anything you were doing.
            """
    }

    /// The words a new task starts from to pick an item up.
    public static func pickUp(_ item: ZerodLink.LaterItem) -> String {
        "Pick up \(item.link): \(item.note)\n\nRead it in full first with `zero later view \(item.id)`, and mark it done with `zero later done \(item.id)` once it is."
    }
}
