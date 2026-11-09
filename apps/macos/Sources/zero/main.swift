import Foundation
import ZeroCore

func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
func fail(_ message: String, _ code: Int32 = 1) -> Never { stderr(message); exit(code) }
func usage(help: Bool = false) -> Never {
    let text = """
    usage:
      zero ask     "short question?" [--option A --option B ...] [--body "details"] [--title T] [--code 'command or snippet'] [--block]
                   the question is one line (about 12 words); the details the user may need go in --body
                   --block: you can't go on without the answer; Zero holds your other events until it's answered
                   an option ending with "…" asks the user for text; the answer is then "label: text"
      zero approve "what you want to do" [--body "details"] [--code 'command or snippet']   (Yes / No / Suggest something else…)
      zero run     'command' --why "what you need the output for" [--cwd DIR] [--title T]
                   runs on the user's Mac after they press Run; a script file's contents are shown to them
      zero note    "where you are now" [--waiting] [--needs "what the user should do, when they can"]
                   (no answer; sets your agent's dot and its row on Zero's board: working, or waiting on something
                   other than the user. Done is zero done's)
      zero done    "what's done" [--confirm TOKEN | --ask]
                   marks the task done, in two steps: alone, it's refused with what done means and a token; if it
                   is so (the user said it's done, or it's finished end to end: merged, deployed and checked), run it
                   again with --confirm TOKEN within 5 minutes. Unsure: --ask asks the user (end [zero: asked <id>])
      zero withdraw <id> [--reason "why"]   (take back an open ask that no longer needs the user)
      zero wait    <id>
      zero status  <id>
      zero list
      zero attach  [agent]   (shows one of Zero's own agents' terminal here to watch or type in; ⌃] lets go. No agent: lists them)
      zero say     <agent> "text"   (sends the user's words to the agent through Zero, as the inbox's message box does)
    sessions Zero runs (from inside one, the session you are in is the lead):
      zero spawn   "task" [--brief FILE] [--loop NAME] [--provider codex|claude|opencode] [--model M] [--effort E] [--cwd DIR]
                   [--label NAME] [--ticket REF] [--permissions auto|unrestricted] [--workspace ID]
                   starts a worker of this session (its folder and permissions unless given others) and prints its id;
                   when it finishes, fails or gets stuck, this session is told. Outside a session: a new session here.
                   --workspace puts it in another workspace (zero workspaces lists them); otherwise it is in yours.
      zero workspaces   (the user's workspaces: id and name)
      zero send    <session or name> "text"   (a message to a session, resumed first if it is offline; from inside a task, marked
                   as that task's and given between the other's turns, as a worker's report is)
      zero wait    <session>... [--any] [--timeout MINUTES]   (until they stop working: finished, failed, stuck, or waiting on the user)
      zero workers   (the sessions this one started, or adopted)
      zero adopt   <task | Claude Code session id>   (makes it a worker of this session, taken into Zero first if it isn't
                   there: you're told when it finishes, and zero send, wait and result reach it)
      zero detach  <task | session id>   (a worker let go of its lead: a task of its own; its lead hears no more of it)
      zero migrate <session id> [--label L] [--workspace ID]   (a Claude Code, Codex or OpenCode session from outside Zero
                   becomes a task where it ran, with its history; not opened: a message resumes it on its own thread)
      zero tasks   (every task Zero has: id, state, lead, ticket, Claude Code session, name and folder)
      zero board   [--watch]   (the board as JSON: each task's row, its state, name, issue rows, open asks and workers, as the
                   sidebar shows them; --watch prints it again, a line of JSON, each time it changes)
      zero result  <session>   (its last answer)
      zero loops   (the loops Zero keeps: named instructions, used as @name in a message or a brief, or with spawn --loop)
      zero loop    <name>   (a loop's words; an @name inside it is a child loop: start workers on it with spawn --loop)
      zero later   save "note" [--asked] [--file artifact.md | --file -] [--link URL]... [--attach FILE]...
                   (saves work the user will come back to, in Zero's Later: the note is a headline under 100 characters
                   in plain words; the artifact is everything you worked out behind it, in full. --asked only when the
                   user asked you to save it; otherwise it's a suggestion, at most 3 open per task, gone in a week
                   unless the user keeps it. Not for ticket ideas, reminders to yourself, or what needs the user: ask)
      zero later   list [words] | view <id> [--version N] | edit <id> [--note "…"] [--file …] [--link …] [--attach …]
                   | done <id> | open <id> | delete <id>   (an item's link is zero://later/<id>; view prints it all)
      zero pause   [session...]   (puts tasks on hold with their workers, every task when none is named: each working one
                   is asked to wrap up and end its turn, given five minutes, then stopped; words for them wait)
      zero unpause [session...]   (takes them off hold: those with words waiting resume for them)
      zero close   <session>...   (a worker you've read: it leaves the board; its record is kept in zerod's archive)
      zero table   "Title" --column NAME... --row "cell | cell | …"...   [--session ID]
                   (a table for the user, drawn by Zero in your conversation: a cell that is a state (working, waiting,
                   done) shows as its pill, and in a column named for a risk, a cell opening with low, medium
                   or high shows that as a pill, the rest on hover; tickets and PRs as links; or JSON on stdin: {"title","columns","rows"})
      zero issue   TICKET you|working|waiting|parked|done ["text"] [--session ID]   (a row for one of the issues you lead,
                   which the user reads coming back: you, with what you need from them; waiting, on whom; parked, why.
                   Set it whenever the issue's state changes)
      zero attr    NAME [VALUE] [--session ID]   (something about this task for the user to see on it, such as
                   zero attr PR https://github.com/org/repo/pull/12; a link opens. No value takes it back)
      zero label   "name" [--ticket REF] [--where PLACE] [--session ID]   (names this session, or another; --where says where it runs,
                   a bench or a machine, for the board's Where; --where "" goes back to its folder)
      zero follow  <url | topic>... [--mine] [--about "word,other words"] [--session ID]
                   (hear of changes between your turns, however long you've been idle: a pull request (its reviews,
                   comments, CI, pushes, merge), a Linear issue or one comment thread in it, a Slack thread or channel.
                   Topics: github/<owner>/<repo>/<pr>, linear/<ISSUE>[/<thread>], slack/<channel>[/<thread-ts>]; a URL does.
                   A busy channel: --mine hears only messages naming the pull requests you follow; --about, these words)
      zero unfollow <topic>... | --all [--session ID]
      zero following [--session ID]   (what you follow, and how reading it goes)
      zero browser <tool> ['{"json": "input"}'] [--session ID]   (Chrome, through Zero for Chrome: the browser_ tools of
                   Zero's MCP server, for agents without it: zero browser tabs '{"createIfEmpty": true}', zero browser
                   navigate '{"url": "example.com"}'. Screenshots are saved to a file and its path printed)
      zero notify  <session> "text"   (words for a session, given between its turns: for event sources and scripts)
      zero watch   [--session ID] -- command...   (runs it in the background; this session is told how it ended, so end
                   your turn instead of polling: zero watch -- gh pr checks 42 --watch)
      zero watch   --file PATH [--alert TEXT]... [--until TEXT] [--quiet MINUTES]   (watches a log as it grows, from now
                   on: a line with an --alert text is told with the lines before it, at most once a minute; --until ends
                   the watch when a line with it is printed; --quiet says when the file stops growing. Each is text, or a pattern
                   between slashes; pick what only trouble has: a compiler's errors are "/:\\d+:\\d+: (fatal )?error: /"
                   (plain ": error: " also matches source quoting one). zero watch list | zero watch stop ID)
      zero schedule "what for" --at TIME | --in DURATION   (wakes this task then: it hears "Scheduled: what for" as
                   Zero's word, woken if it's parked. Kept across Zero's restarts. TIME is 05:12 (your clock, the next
                   one), 05:12Z or 05:12 UTC, or 2026-11-05T05:12Z; DURATION is 90m, 2h, 1d or 1h30m. For reminders
                   to yourself: a check due later, a deploy to look at. zero schedule list | zero schedule cancel ID)
      zero remind  <minutes> "text" [--session ID]   (the same, in minutes)
      zero usage   (each provider's limits as its CLI last reported them)
      zero mcp     (Zero's MCP server on stdio, giving an agent the user's scratchpads: add it as an MCP server's command)
    common: --async (print the id and return) --agent NAME ($ZERO_AGENT) --ticket ID (the ticket the ask is about,
            shown as its context) --ttl MINUTES (default from Zero's settings) --help
    exit: 0 answered (answer on stdout; for run, the command's output and exit code), 2 declined, 3 expired
    """
    if help { print(text); exit(0) }
    fail(text)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
// The MCP server is zerod's own, beside this in Zero.app; it speaks on stdio, so this program becomes it.
if command == "mcp" {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let zerod = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("zerod").path
        ?? here.appendingPathComponent("zerod").path
    let argv = [zerod, "mcp"] + args.dropFirst()
    var cArgs = argv.map { strdup($0) } + [nil]
    execv(zerod, &cArgs)
    fail("zero: no zerod at \(zerod)")
}
args.removeFirst()
if ["help", "--help", "-h"].contains(command) || args.contains("--help") || args.contains("-h") { usage(help: true) }

var flags: [String: [String]] = [:]
var positional: [String] = []
var i = 0
while i < args.count {
    let arg = args[i]
    // After "--" everything is the command (zero watch -- gh pr checks 42 --watch).
    if arg == "--" { positional.append(contentsOf: args[(i + 1)...]); break }
    if arg.hasPrefix("--") {
        let key = String(arg.dropFirst(2))
        if ["async", "blocked", "done", "merged", "completed", "waiting", "any", "mine", "all", "asked", "watch", "block", "ask"].contains(key) {
            flags[key, default: []].append("1")
        } else {
            i += 1
            guard i < args.count else { fail("zero: missing value for --\(key)") }
            flags[key, default: []].append(args[i])
        }
    } else {
        positional.append(arg)
    }
    i += 1
}
func flag(_ key: String) -> String? { flags[key]?.last }
let async = flag("async") != nil
let ttl = (flag("ttl").flatMap(Double.init) ?? 0) * 60 // 0: let the app apply its default expiry

func connect() -> UnixSocket {
    do { return try UnixSocket.connect(path: Paths.socket) } catch { fail("zero: Zero.app is not running (\(error))") }
}

/// A session of zerod's: its ids are 16 hex digits, where an ask's are 6 letters and digits.
func isSession(_ id: String) -> Bool { id.count == 16 && id.allSatisfy(\.isHexDigit) }

/// One request to zerod, failing the command with zerod's own words.
func zerod<T>(_ body: (ZerodLink) async throws -> T) async -> T {
    guard let link = try? ZerodLink() else { fail("zero: Zero's daemon isn't running (open Zero)") }
    defer { link.close() }
    do { return try await body(link) } catch { fail("zero: \(error.localizedDescription)") }
}

/// The session a command is about: --session, else the one this runs in.
func targetSession() -> String? { flag("session") ?? ProcessInfo.processInfo.environment["ZERO_SESSION"] }

switch command {
case "ask": askCommand()
case "approve": approveCommand()
case "permission": permissionCommand()
case "question": questionCommand()
case "withdraw": withdrawCommand()
case "prompt": promptCommand()
case "run": runCommand()
case "note": noteCommand()
case "done": doneCommand()
case "wait" where positional.first.map(isSession) == true: await waitSessionsCommand()
case "wait": waitCommand()
case "status": statusCommand()
case "say": sayCommand()
case "spawn": await spawnCommand()
case "send": await sendCommand()
case "close": await closeCommand()
case "workers": await workersCommand()
case "adopt": await adoptCommand()
case "detach": await detachCommand()
case "migrate": await migrateCommand()
case "tasks": await tasksCommand()
case "board": await boardCommand()
case "workspaces": await workspacesCommand()
case "loops": await loopsCommand()
case "loop": await loopCommand()
case "result": await resultCommand()
case "label": await labelCommand()
case "table": await tableCommand()
case "issue": await issueCommand()
case "attr": await attrCommand()
case "follow": await followCommand()
case "unfollow": await unfollowCommand()
case "later": await laterCommand()
case "pause", "unpause": await pauseCommand(command)
case "following": await followingCommand()
case "browser": await browserCommand()
case "notify": await notifyCommand()
case "watch" where positional.first == "list": await watchListCommand()
case "watch" where positional.first == "stop": await watchStopCommand()
case "watch" where flag("file") != nil: await watchFileCommand()
case "watch" where targetSession() != nil: await watchCommand()
case "schedule": await scheduleCommand()
case "remind": await remindCommand()
case "usage": await usageCommand()
case "attach": attach(positional.first)
case "list": listCommand()
default: usage()
}
