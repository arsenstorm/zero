import AppKit
import Observation
import SwiftUI
import ZeroCore

struct CardView: View {
    let ask: Ask
    @Bindable var controller: InboxController
    var focus: FocusState<String?>.Binding

    /// Flat: no card of its own (the inbox page, a task's status). It's the one thing being looked at, so it shows in
    /// full: its words and command unfolded, never dimmed.
    var flat = false
    /// Who asked, under the question: left out where that's already plain (a task's own status).
    var showsByline = true

    init(ask: Ask, controller: InboxController, focus: FocusState<String?>.Binding, flat: Bool = false, showsByline: Bool = true) {
        self.ask = ask
        self.controller = controller
        self.focus = focus
        self.flat = flat
        self.showsByline = showsByline
        // A card already seen is shown as it is from its first frame, even in a view built afresh.
        _entered = State(initialValue: controller.seen.contains(ask.id))
    }

    private var selected: Bool { controller.selected == ask.id }
    /// A command it can't run here, for you to run yourself and say how it went: a two-step card.
    /// A command for you to run yourself (an agent's question with `--code`: another machine's shell, sudo), laid out as
    /// steps. An approval's command is the agent's own, to allow or not, so it's never this.
    private var manual: Bool { (ask.kind == .question || ask.kind == .choice) && ask.command != nil && ask.state == .waiting }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                .background(Theme.keycap, in: Circle())
            Text(title).font(.system(size: 12.5, weight: .semibold))
        }
    }
    private var dictating: Bool { controller.dictatingFor == ask.id }
    /// With several questions open, the waiting ones your keys won't answer step back; finished cards never dim.
    /// Flat (on the inbox page, in a task's status), it's the one being looked at: never dimmed.
    private var dimmed: Bool { !flat && ask.state == .waiting && !selected && controller.cards.filter { $0.state == .waiting }.count > 1 }

    @State private var commandExpanded = false
    @State private var scriptExpanded = false
    @State private var detailExpanded = false
    /// A running run's own terminal shown in place of its output (its Terminal button).
    @State private var watching = false
    /// False until the entrance has played; cards already seen start true.
    @State private var entered = false
    /// Heights of the command box and the options while waiting; the terminal takes exactly their space.
    private var commandHeight: CGFloat { controller.measured[ask.id]?.command ?? 36 }
    private var optionsHeight: CGFloat { controller.measured[ask.id]?.options ?? 126 }
    private static let collapsedLines = 8

    /// The header carries who and why: agent, the agent's own title as context, and the live state.
    private var context: String? {
        switch ask.kind {
        case .note, .message: return nil
        case .run: return ask.title == "Run a command" ? nil : ask.title
        // An approval's title is the request itself, the headline; its body is the detail beneath.
        case .permission, .approve: return nil
        default: return ask.body.isEmpty ? nil : ask.title
        }
    }

    /// Where the command runs, when that isn't simply the agent's own folder.
    private var folder: String? { ask.cwd == ask.agent.cwd ? nil : ask.cwd }

    /// The text under the question: why a run or permission is wanted, an approval's detail, a question's --body.
    private var supporting: String? {
        switch ask.kind {
        case .run, .permission, .approve: ask.body
        case .question, .choice: ask.detail
        default: nil
        }
    }

    /// Under the question: the agent's name when cards from several agents share the inbox, and the context.
    private var byline: String? {
        let who = controller.agentFilter == nil ? controller.store.displayName(of: ask.agent.name) : nil
        // Other agents asking for this same run wait on this card.
        let twins = controller.store.asks.filter { $0.sameAs == ask.id && !$0.state.isFinal }.count
        let also = twins > 0 ? "and \(twins) other agent\(twins == 1 ? "" : "s")" : nil
        let parts = [[who, also].compactMap { $0 }.joined(separator: " "), context].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The headline is the question itself; for a run ask it is always the same question.
    private var headline: String {
        switch ask.kind {
        case .run:
            switch ask.state {
            case .running: return "Running command…"
            case .answered where ask.lost: return "Lost track of the command"
            case .answered: return (ask.exitCode ?? 0) == 0 ? "Ran command" : "Command failed (exit \(ask.exitCode ?? 0))"
            case .declined: return "Command rejected"
            default: return "Allow this command?"
            }
        case .permission: return ask.title.hasSuffix("?") ? ask.title : ask.title + "?"
        case .approve: return ask.title.hasSuffix("?") ? ask.title : ask.title + "?"
        case .note, .message: return ask.body
        default: return ask.body.isEmpty ? ask.title : ask.body
        }
    }

    private var commandIsLong: Bool {
        guard let command = ask.command else { return false }
        return command.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines || command.count > 400
    }

    var body: some View {
        if ask.kind == .message { messageBubble } else { card }
    }

    /// The user's message to the agent: a bubble on the right with a small time beside it, no header and no
    /// dismiss; delivery trouble shows underneath.
    private var messageBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Yours are solid: black in light mode, white in dark, the text in the opposite.
            HuggingWidth(max: 260) {
                Text(ask.body).font(.system(size: 13)).foregroundStyle(Theme.onKnob).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(Theme.knob)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            if ask.status == "starting" {
                Text("Starting…").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var card: some View {
        Group {
            if flat { cardContent.clipped() } else { cardContent.card() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { if $0, ask.state == .waiting { controller.select(ask.id) } }
        .onTapGesture { controller.select(ask.id) }
        // First showing: it joins at the bottom of the stack, so it rises 8 pt with a fade, 200 ms on the
        // (0.32, 0.72, 0, 1) ease-out, the same curve the stack grows with. Seen cards appear as they are.
        .offset(y: entered ? 0 : 8)
        .opacity(entered ? 1 : 0)
        .onAppear {
            if controller.seen.contains(ask.id) || reduceMotion {
                entered = true
            } else {
                controller.seen.insert(ask.id)
                withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.2)) { entered = true }
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: docked ? 10 : 12) {
            if ask.kind == .note { noteText } else { header }
            // Why the agent wants it, or what it found, in its own words: six lines, the rest a click away.
            if let supporting, !supporting.isEmpty { supportingText(supporting) }
            if showsTerminal {
                terminal
            } else if let command = ask.command {
                commandBlock(command)
            }
            if showsOptions { options }
            footer
        }
        // A reply hugs its text like a chat bubble, up to about 65% of the column, and sits left.
        .modifier(BubbleWidth(hug: ask.kind == .note, max: 220))
        .opacity(dimmed ? 0.55 : 1) // 0.45 left light-mode text with too small an L gap to read
        .padding(.horizontal, flat ? 16 : 14).padding(.vertical, ask.kind == .note ? 12 : 14)
    }

    /// A run that has started (or finished) shows its terminal in place of the command and the options.
    private var showsTerminal: Bool { ask.kind == .run && (ask.state == .running || ask.state == .answered) }

    /// Options carry the state: the chosen row goes orange with a spinner while it can still be taken back,
    /// then green with a tick once delivered. The rest dim. A typed answer shows as a row of its own.
    /// Not for a reply: an empty options stack still cost the column's 12 pt below the text.
    private var showsOptions: Bool { ask.kind != .note && ask.state != .expired && !showsTerminal }

    private var decided: Bool { ask.state != .waiting }

    /// The question leads; beneath it, who (in the inbox, where cards from
    /// several agents sit together) and the agent's own title for it.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.system(size: 15, weight: .semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if showsByline, let byline {
                    Text(byline).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // No time and no dismiss: a finished card folds into Earlier, or leaves the inbox when it next opens.
            if ask.state == .running {
                // Its own terminal: watched in place of the output, or typed into if it asks something.
                if ask.runTerminal != nil {
                    Button(watching ? "Output" : "Terminal") { watching.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Button("Stop") { controller.store.cancelRun(ask.id) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
            }
        }
    }

    /// An agent's words and nothing else; the time is in Earlier once the card folds away.
    @ViewBuilder private var noteText: some View {
        MarkdownText(ask.body, cwd: ask.agent.cwd ?? ask.cwd)
        if ask.status == "blocked" { Text("Blocked").font(.system(size: 11, weight: .medium)).foregroundStyle(.red) }
    }

    /// Three lines; a longer one fades out on its last line instead of being cut mid-word, and a
    /// click on the text opens it in place. No button and no extra row.
    private func supportingText(_ supporting: String) -> some View {
        let long = supporting.count > 180 && !flat
        let folded = long && !detailExpanded
        return Group {
            // Folded, a click opens it; selecting text would take that click. Open, it is selectable.
            if folded {
                Text(supporting).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
            } else {
                Text(supporting).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, folded ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard long else { return }
                controller.holdTop = true
                withAnimation(.easeOut(duration: 0.2)) { detailExpanded.toggle() }
            }
            .pointerStyle(long ? .link : nil)
            .tip(long ? (detailExpanded ? "Click to fold" : "Click to read it all") : "")
    }

    @ViewBuilder private func commandBlock(_ command: String) -> some View {
        // A command for you to run yourself (it can't be run from here: another machine's shell, sudo): a step.
        if manual { step(1, "Run this") }
        commandBox(command)
        if manual { tellStep }
    }

    private func commandBox(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .lineLimit(commandIsLong && !commandExpanded && !flat ? Self.collapsedLines : nil)
                .fixedSize(horizontal: false, vertical: true)
            // The script the command runs, so what the user approves is what they can read.
            if let script = ask.script { scriptText(script) }
            if folder != nil || commandIsLong { commandFooter }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
        // Copied in one click, the script with it: what you run is what you read.
        .overlay(alignment: .topTrailing) { CopyCommand(text: [command, ask.script].compactMap { $0 }.joined(separator: "\n")).padding(6) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.measured[ask.id] = ($0, optionsHeight) }
    }

    @ViewBuilder private func scriptText(_ script: String) -> some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
        Text(script.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary).textSelection(.enabled)
            .lineLimit(scriptExpanded ? nil : 12).fixedSize(horizontal: false, vertical: true)
        if script.split(separator: "\n").count > 12 {
            foldButton(scriptExpanded ? "Show less" : "Show the whole script", $scriptExpanded)
        }
    }

    private var commandFooter: some View {
        HStack {
            if let folder {
                Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if commandIsLong && !flat {
                foldButton(commandExpanded ? "Show less" : "Show all", $commandExpanded)
            }
        }
    }

    private func foldButton(_ title: String, _ expanded: Binding<Bool>) -> some View {
        Button(title) { controller.holdTop = true; expanded.wrappedValue.toggle() }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    private var tellStep: some View {
        HStack {
            step(2, "Then tell \(controller.store.displayName(of: ask.agent.name))")
            Spacer()
            // What it printed, from the clipboard into the reply, ready to send.
            if let typed = ask.options.firstIndex(where: Ask.expectsText) { pasteOutputButton(typed) }
        }
    }

    private func pasteOutputButton(_ typed: Int) -> some View {
        Button {
            controller.drafts[ask.id] = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            controller.choose(typed, on: ask.id)
        } label: {
            NucleoLabel("Paste output", icon: "copy", size: 12).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(Hovering(radius: 6)).tip("Put what you copied into the reply, to send")
    }

    private var options: some View {
        VStack(spacing: docked ? 6 : 12) {
            ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                if !decided, controller.textOption[ask.id] == index {
                    replyBox(placeholder: option)
                } else {
                    optionButton(index, option)
                }
            }
            if decided, ask.options.isEmpty, let answer = ask.answer, ask.kind != .run {
                Button { controller.store.deliverAnswer(ask.id) } label: { optionRow(answer, key: nil, chosen: true, decided: true) }
                    .buttonStyle(.plain).allowsHitTesting(ask.delivery == .failed)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { controller.measured[ask.id] = (commandHeight, $0) } }
    }

    private func optionButton(_ index: Int, _ option: String) -> some View {
        // Not `.disabled`: that greys the whole label, chosen row included. Decided rows just ignore clicks.
        // A decided row takes a click only to retry an answer that didn't reach the agent.
        let retry = decided && ask.choice == index && ask.delivery == .failed
        return Button { if retry { controller.store.deliverAnswer(ask.id) } else if !decided { controller.choose(index, on: ask.id) } } label: {
            optionRow(decided && ask.choice == index ? (ask.answer ?? option) : option,
                      key: "\(index + 1)", chosen: decided && ask.choice == index, decided: decided)
        }.buttonStyle(.plain).allowsHitTesting(!decided || retry)
    }

    private func replyBox(placeholder: String) -> some View {
        ReplyBox(placeholder: placeholder,
                 text: Binding(get: { controller.drafts[ask.id, default: ""] }, set: { controller.drafts[ask.id] = $0 }),
                 key: ask.id, focus: focus, dictating: dictating,
                 onMic: { controller.select(ask.id); controller.toggleDictation() }, onSend: { controller.send(ask.id) })
            .background(Theme.choice).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Same language as the pill: orange needs you, red blocked, green done, blue working.
    private var stateColor: Color {
        if ask.kind == .message { return (ask.status ?? "").hasPrefix("failed") ? .red : .gray }
        if ask.kind == .note { return AgentStatus.of([ask]).color }
        switch ask.state {
        case .waiting, .pending: return .orange
        case .declined: return .gray
        default: return .blue
        }
    }

    @ViewBuilder private var footer: some View {
        switch ask.state {
        case .waiting:
            // Only a free-text question has its own reply box; option cards answer through their options.
            if ask.options.isEmpty { replyBox(placeholder: "Reply to \(controller.store.displayName(of: ask.agent.name))…") }
        case .pending:
            EmptyView()
        case .answered where ask.lost:
            statusRow("Lost: check what it did before running it again", color: .orange)
        case .running, .answered:
            EmptyView()
        case .declined:
            EmptyView() // the chosen row already shows the rejection, and any text that came with it
        case .expired:
            statusRow("Expired", color: .secondary)
        }
    }

    /// Once a run starts, the command box takes exactly the space it and the options had, fixed, like a small
    /// terminal: the command on the first line, the output scrolling beneath it and following the newest line.
    @ViewBuilder private var terminal: some View {
        if watching, let id = ask.runTerminal {
            HostTerminal(id: id).id(id)
                .frame(maxWidth: .infinity)
                .frame(height: commandHeight + 12 + optionsHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            output
        }
    }

    private var output: some View {
        TerminalView(command: ask.command ?? "", output: ask.output)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: commandHeight + 12 + optionsHeight)
            .background(Theme.code).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func optionRow(_ text: String, key: String?, chosen: Bool, decided: Bool) -> some View {
        // An answer Zero types into an agent that isn't waiting stays orange until it lands, and goes red if it can't.
        let failed = ask.delivery == .failed
        let settled = ask.state.isFinal && ask.delivery != .sending && !failed
        let surface: Color = chosen ? (failed ? Theme.redRow : settled ? Theme.greenRow : Theme.orangeRow) : Theme.choice
        let cap: Color = chosen ? (failed ? Theme.redCap : settled ? Theme.greenCap : Theme.orangeCap) : Theme.choiceCap
        return HStack(spacing: 10) {
            if let key {
                Text(key).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                    .foregroundStyle(chosen ? .white : .primary)
                    .background(cap).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            // A text option reads like a placeholder: pick it and the input appears with the same wording.
            Text(text).font(.system(size: 13))
                .foregroundStyle(!chosen && Ask.expectsText(text) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer()
            if chosen {
                ZStack {
                    if failed {
                        NucleoIcon("xmark", size: 13).foregroundStyle(.red)
                            .transition(.opacity)
                    } else if settled {
                        NucleoIcon("check", size: 13).foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        Spinner(color: .orange).frame(width: 12, height: 12).transition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .tip(chosen && failed ? "Couldn't reach the agent. Click to try again." : "")
        .opacity(decided && !chosen ? 0.4 : 1)
        // Colour only: surface, key cap and icon ease between states; the row itself never moves.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.state)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.choice)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ask.delivery)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.askDocked) private var docked

    /// Same height as the reply box, so the footer swaps text without moving anything.
    private func statusRow(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .padding(.horizontal, 10)
    }

}
