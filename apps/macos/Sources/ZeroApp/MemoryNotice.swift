import SwiftUI
import ZeroCore

/// Atop the sidebar's Tasks card while memory is short (MemoryWatch): what holds it, by app, each with its total;
/// under Zero's tasks, the heaviest of them, each opening the task (its details show what it uses and left running),
/// then what all tasks left running, opening that to stop. Zero stops nothing itself. Gone once memory is fine.
struct MemoryNotice: View {
    let shortage: MemoryShortage
    let workspace: Workspace
    let open: (String) -> Void
    /// Everything tasks left running, archived ones' too (LeftRunningDialog).
    let openLeft: () -> Void

    private static let row: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                NucleoIcon("triangle-warning", fill: "glyph", size: 12).frame(width: 12, height: 12)
                    .foregroundStyle(shortage.critical ? .red : .orange)
                Text("Memory is short").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
            }
            .frame(height: Self.row)
            .tip(numbers)
            ForEach(groups) { group in
                line(group.name, group.memory, tip: group.processes == 1 ? "1 process" : "\(group.processes) processes")
                if group.tasks {
                    ForEach(heaviestTasks, id: \.id) { task in
                        line(task.name, task.memory, indent: 12, link: true, tip: "Open it: what it uses and left running")
                            .contentShape(Rectangle())
                            .onTapGesture { open(task.id) }
                            .pointerStyle(.link)
                    }
                    let left = workspace.left.values.filter(\.settled).reduce(0) { $0 + $1.memory }
                    if left > 0 {
                        line("Left running", left, indent: 12, link: true, tip: "What tasks left running, to stop")
                            .contentShape(Rectangle())
                            .onTapGesture(perform: openLeft)
                            .pointerStyle(.link)
                    }
                }
            }
        }
    }

    /// The four heaviest, and Zero's tasks among them even when lighter: what the user can stop from here.
    private var groups: [MemoryGroup] {
        let top = Array(shortage.groups.prefix(4))
        guard !top.contains(where: \.tasks), let tasks = shortage.groups.first(where: \.tasks) else { return top }
        return top + [tasks]
    }

    private var heaviestTasks: [(id: String, name: String, memory: UInt64)] {
        workspace.uses.sorted { $0.value.memory > $1.value.memory }.prefix(3).map { id, use in
            (id, workspace.conversation(id).map(Workspace.label(of:)) ?? id, use.memory)
        }
    }

    private var numbers: String {
        let swap =
            shortage.swapTotal > 0
            ? " · swap \(TaskDetails.bytes(shortage.swapUsed)) of \(TaskDetails.bytes(shortage.swapTotal))" : ""
        return "\(TaskDetails.bytes(shortage.compressed)) compressed\(swap)"
    }

    private func line(_ name: String, _ memory: UInt64, indent: CGFloat = 0, link: Bool = false, tip: String) -> some View {
        HStack(spacing: 6) {
            Group { if link { TaskDetails.linked(name) } else { Text(name).lineLimit(1) } }
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(TaskDetails.bytes(memory)).monospacedDigit().fixedSize()
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.leading, 18 + indent)
        .frame(height: Self.row)
        .tip(tip)
    }
}
