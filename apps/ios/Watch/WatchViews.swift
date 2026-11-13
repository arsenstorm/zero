import SwiftUI

@main struct ZeroWatchApp: App {
    init() { WatchModel.shared.start() }
    var body: some Scene { WindowGroup { Home(model: WatchModel.shared) } }
}

/// A task's state as the phone and the Mac show it: their icons and colours (Rows.swift's StateGlyph).
enum Look {
    static func of(_ state: String) -> (icon: String, color: Color, name: String) {
        switch state {
        case "needsYou": ("hand-3-glyph", .blue, "Needs you")
        case "trouble": ("triangle-warning-glyph", .orange, "In trouble")
        case "blocked": ("circle-minus-glyph", .red, "Blocked")
        case "working": ("arrow-rotate-clockwise-glyph", .blue, "Working")
        case "handed": ("hand-holding-box-glyph", .teal, "Over to you")
        case "waiting": ("hourglass-glyph", .secondary, "Waiting")
        case "answered": ("message-check-glyph", .indigo, "Replied")
        case "read": ("message-check-glyph", .secondary, "Replied")
        case "done": ("badge-check-glyph", .purple, "Done")
        case "paused": ("circle-pause-glyph", .secondary, "Paused")
        case "inTerminal": ("terminal-outline", .blue, "In Terminal")
        case "offline": ("power-off-glyph", .secondary, "Offline")
        default: ("moon-glyph", .secondary, "Idle")
        }
    }
}

struct Glyph: View {
    let name: String
    var size: CGFloat = 16
    var body: some View { Image(name).resizable().renderingMode(.template).frame(width: size, height: size) }
}

/// The asks waiting on you, then the tasks, as the phone's Inbox and Tasks; New task at the top.
struct Home: View {
    let model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                if let trouble = model.trouble {
                    Text(trouble).font(.footnote).foregroundStyle(.orange)
                }
                if model.state.asks.isEmpty {
                    Label {
                        Text("Nothing needs you")
                    } icon: {
                        Glyph(name: "inbox-glyph")
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(model.state.asks) { ask in
                    NavigationLink {
                        AskPage(model: model, ask: ask)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(ask.from).lineLimit(1)
                            } icon: {
                                Glyph(name: "hand-3-glyph", size: 14)
                            }
                            .font(.footnote).foregroundStyle(.blue)
                            Text(ask.title).lineLimit(3)
                        }
                    }
                }
                Section("Tasks") {
                    ForEach(model.state.tasks) { task in
                        NavigationLink {
                            TaskPage(model: model, task: task)
                        } label: {
                            TaskRow(task: task)
                        }
                    }
                }
            }
            .navigationTitle("Zero")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        NewTaskPage(model: model)
                    } label: {
                        Glyph(name: "plus-outline")
                    }
                    .accessibilityLabel("New task")
                }
            }
        }
        .task { await model.refresh() }
    }
}

struct TaskRow: View {
    let task: WatchState.Task
    var body: some View {
        let look = Look.of(task.state)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Glyph(name: look.icon, size: 14).foregroundStyle(look.color)
                Text(task.name).lineLimit(1)
            }
            if let line = task.line, !line.isEmpty {
                Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// An ask, answered here: its options as buttons, one ending "…" (or an ask with none) dictated or scribbled.
struct AskPage: View {
    let model: WatchModel
    let ask: WatchState.Ask
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(ask.from).font(.footnote).foregroundStyle(.secondary)
                Text(ask.title).font(.headline)
                if let detail = ask.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                if ask.options.isEmpty {
                    TextFieldLink(prompt: Text("Your answer")) {
                        Label {
                            Text("Reply")
                        } icon: {
                            Glyph(name: "microphone-outline")
                        }.frame(maxWidth: .infinity)
                    } onSubmit: { text in
                        send(["op": "reply", "ask": ask.id, "text": text])
                    }
                }
                ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                    if option.hasSuffix("…") || option.hasSuffix("...") {
                        TextFieldLink(prompt: Text(option)) {
                            Text(option).frame(maxWidth: .infinity)
                        } onSubmit: { text in
                            send(["op": "answer", "ask": ask.id, "option": index, "text": text])
                        }
                    } else {
                        Button {
                            send(["op": "choose", "ask": ask.id, "option": index])
                        } label: {
                            Text(option).frame(maxWidth: .infinity)
                        }
                        .tint(option.hasPrefix("Deny") || option == "No" || option.hasPrefix("Reject") ? .red : nil)
                    }
                }
            }
            .disabled(sending)
        }
        .navigationTitle("Ask")
    }

    private func send(_ message: [String: Any]) {
        if (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return }
        sending = true
        nonisolated(unsafe) let message = message
        Task {
            if await model.ask(message) != nil { dismiss() }
            sending = false
        }
    }
}

/// A task: its state, its last answer in a few lines, and a message dictated to it, a pause or a stop.
struct TaskPage: View {
    let model: WatchModel
    let task: WatchState.Task
    @State private var last: String?
    @State private var done: String?

    var body: some View {
        let look = Look.of(model.state.tasks.first { $0.id == task.id }?.state ?? task.state)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Glyph(name: look.icon, size: 14)
                    Text(look.name)
                }
                .font(.footnote).foregroundStyle(look.color)
                Text(task.name).font(.headline)
                if let line = task.line, !line.isEmpty {
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
                // Its space kept while it loads: nothing jumps.
                Text(last ?? " ").font(.footnote).lineLimit(10)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                    .redacted(reason: last == nil ? .placeholder : [])
                if let done { Text(done).font(.footnote).foregroundStyle(.secondary) }
                TextFieldLink(prompt: Text("Message")) {
                    Label {
                        Text("Message")
                    } icon: {
                        Glyph(name: "microphone-outline")
                    }.frame(maxWidth: .infinity)
                } onSubmit: { text in
                    act(["op": "send", "session": task.id, "text": text], said: "Sent")
                }
                if look.name == "Paused" {
                    Button {
                        act(["op": "resume", "session": task.id], said: "Resumed")
                    } label: {
                        Label {
                            Text("Resume")
                        } icon: {
                            Glyph(name: "media-play-glyph")
                        }.frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        act(["op": "pause", "session": task.id], said: "Pausing after this step")
                    } label: {
                        Label {
                            Text("Pause")
                        } icon: {
                            Glyph(name: "circle-pause-glyph")
                        }.frame(maxWidth: .infinity)
                    }
                }
                if look.name == "Working" {
                    Button(role: .destructive) {
                        act(["op": "stop", "session": task.id], said: "Stopped")
                    } label: {
                        Label {
                            Text("Stop")
                        } icon: {
                            Glyph(name: "media-stop-glyph")
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Task")
        .task {
            let reply = await model.ask(["op": "last", "session": task.id])
            last = (reply?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No answer yet"
        }
    }

    private func act(_ message: [String: Any], said: String) {
        if (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return }
        nonisolated(unsafe) let message = message
        Task { if await model.ask(message) != nil { done = said } }
    }
}

/// A task started by voice: a project folder picked, then what it's to do, dictated.
struct NewTaskPage: View {
    let model: WatchModel
    @State private var folders: [String]?
    @State private var started: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let started {
                Text(started).foregroundStyle(.secondary)
            } else if let folders {
                ForEach(folders, id: \.self) { folder in
                    TextFieldLink(prompt: Text("What should it do?")) {
                        Label {
                            Text((folder as NSString).lastPathComponent).lineLimit(1)
                        } icon: {
                            Glyph(name: "folder-glyph")
                        }
                    } onSubmit: { text in
                        start(text, in: folder)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("New task")
        .task {
            folders = (await model.ask(["op": "projects"]))?["projects"] as? [String] ?? []
        }
    }

    private func start(_ text: String, in folder: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await model.ask(["op": "start", "text": text, "folder": folder]) != nil {
                started = "Started in \((folder as NSString).lastPathComponent)"
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            }
        }
    }
}
