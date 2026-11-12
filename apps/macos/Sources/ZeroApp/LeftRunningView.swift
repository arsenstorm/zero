import SwiftUI
import ZeroCore

/// What tasks left running (zerod's left.rs): dev servers and other processes their commands started that outlived
/// them, simulators they booted, containers they brought up. Shown, never stopped unasked: Stop is the user's.
enum LeftRunningLook {
    static func icon(_ kind: LeftRunning.Thing.Kind) -> String {
        switch kind {
        case .process: "terminal"
        case .simulator: "mobile"
        case .container: "layers"
        }
    }

    /// How long it has run, short: "40 min", "3 h", "2 d".
    static func age(_ since: Int64, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince1970) - Int(since / 1000)) / 60
        if minutes < 60 { return "\(max(1, minutes)) min" }
        if minutes < 48 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / (24 * 60)) d"
    }

    /// "3 left running · 2.1 GB".
    static func summary(_ tasks: [LeftRunning]) -> String {
        let count = tasks.reduce(0) { $0 + $1.things.count }
        return "\(count) left running · \(TaskDetails.bytes(tasks.reduce(0) { $0 + $1.memory }))"
    }
}

/// A task's things left running, a row each: what it is, for how long, what it holds, and Stop.
struct LeftRunningRows: View {
    let workspace: Workspace
    let session: String
    let things: [LeftRunning.Thing]

    var body: some View {
        TimelineView(.everyMinute) { now in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(things) { thing in row(thing, now: now.date) }
            }
        }
    }

    private func row(_ thing: LeftRunning.Thing, now: Date) -> some View {
        HStack(alignment: .top, spacing: 7) {
            NucleoIcon(LeftRunningLook.icon(thing.kind), size: 13).foregroundStyle(.secondary).frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(thing.name).lineLimit(1).truncationMode(.middle).tip(thing.name)
                Text("\(LeftRunningLook.age(thing.since, now: now)) · \(thing.memory > 0 ? TaskDetails.bytes(thing.memory) : "–")")
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Stop") { Task { await workspace.stopLeft(session, things: [thing.id]) } }
                .buttonStyle(.plain).foregroundStyle(.secondary).tip(stopTip(thing.kind))
        }
    }

    private func stopTip(_ kind: LeftRunning.Thing.Kind) -> String {
        switch kind {
        case .process: "Stop it and what it started"
        case .simulator: "Shut the simulator down"
        case .container: "Stop it (nothing is removed)"
        }
    }
}

/// From the sidebar's Tasks card: what settled tasks (done, archived, quiet half an hour) left running, by task, with
/// Stop for each and for all of a task's.
struct LeftRunningDialog: View {
    let workspace: Workspace
    @Environment(\.closeDialog) private var close

    var body: some View {
        let tasks = workspace.left.filter(\.value.settled).sorted { $0.value.memory > $1.value.memory }
        VStack(alignment: .leading, spacing: 12) {
            DialogTitle(text: tasks.isEmpty ? "Nothing left running" : LeftRunningLook.summary(tasks.map(\.value)))
            Text("Started by tasks that are done, archived or quiet. Some may be meant to stay, such as a dev server you're using.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(tasks, id: \.key) { id, left in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(left.task).fontWeight(.medium).lineLimit(1)
                                if left.archived { Text("Archived").foregroundStyle(.secondary) }
                                Spacer()
                                Button("Stop all") { Task { await workspace.stopLeft(id) } }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            LeftRunningRows(workspace: workspace, session: id, things: left.things)
                        }
                    }
                }
                .font(.system(size: 12.5))
            }
            .thinScrollbar()
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                DialogButton(title: "Done", kind: .primary) { close() }
            }
        }
        .frame(width: 420, alignment: .leading)
    }
}
