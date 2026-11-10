import SwiftUI
import ZeroCore

// Following: what agents hear of between their turns (zerod's following.rs). Settings › Events lists every follow;
// each integration's page lists the follows read through it. Both are FollowRows.

struct EventsPage: View {
    let workspace: Workspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let workspace {
                let sources = Integration.allCases.filter { source in workspace.followed.contains { $0.source == source.rawValue } }
                if sources.isEmpty {
                    SettingsSection(title: "Followed") { FollowRows(workspace: workspace, source: nil) }
                } else {
                    ForEach(sources) { source in
                        SettingsSection(title: source.title, icon: AnyView(source.icon(size: 14).foregroundStyle(.secondary))) {
                            FollowRows(workspace: workspace, source: source)
                        }
                    }
                }
            }
        }
    }
}

/// The follows read through one integration (or every follow), one row each: the thing, who follows it, how reading it
/// goes; unfollow on hover.
struct FollowRows: View {
    let workspace: Workspace
    let source: Integration?

    private var rows: [ZerodLink.Followed] {
        workspace.followed.filter { source == nil || $0.source == source?.rawValue }.sorted {
            ($0.summary.isEmpty ? $0.topic : $0.summary, $0.session) < ($1.summary.isEmpty ? $1.topic : $1.summary, $1.session)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text(source == nil ? "No agent follows anything yet." : "No agent follows anything through \(source!.title) yet.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(
                        .horizontal, 18
                    ).frame(height: 44)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 18) }
                FollowRow(row: row, task: workspace.roster[row.session].map(Workspace.label(of:)) ?? "a task that is gone") {
                    Task { await workspace.unfollow(session: row.session, topic: row.topic) }
                }
            }
        }
        .bleedingCard()
        .task(id: workspace.followingVersion) { await workspace.loadFollowing() }
    }
}

private struct FollowRow: View {
    let row: ZerodLink.Followed
    let task: String
    let unfollow: () -> Void
    @State private var hovered = false

    /// The thing's description without its URL (the row opens it), or the topic when nothing was read yet.
    private var title: String {
        let words = row.summary.split(separator: " ").filter { !$0.hasPrefix("http") }.joined(separator: " ")
        return words.isEmpty ? row.topic : words
    }
    private var url: URL? { row.summary.split(separator: " ").last { $0.hasPrefix("http") }.flatMap { URL(string: String($0)) } }
    private var filter: String {
        ((row.mine ? ["only your pull requests"] : []) + (row.about.isEmpty ? [] : ["about " + row.about.joined(separator: ", ")])).joined(
            separator: ", ")
    }
    private var detail: String {
        var parts = [row.topic]
        if !filter.isEmpty { parts.append(filter) }
        if row.lastPoll > 0 {
            parts.append(
                "read "
                    + RelativeDateTimeFormatter().localizedString(
                        for: Date(timeIntervalSince1970: TimeInterval(row.lastPoll)), relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let error = row.error { Text("Can't read it: \(error)").font(.system(size: 12)).foregroundStyle(.red).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.open(URL(string: "zero://task/\(row.session)")!)
            } label: {
                Text(task).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: 24).background(Theme.chip, in: Capsule())
            }
            .buttonStyle(.plain).tip("Open the task that follows it")
            Button(action: unfollow) { NucleoIcon("xmark", size: 13).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                .buttonStyle(Hovering(radius: 7)).tip("Unfollow").opacity(hovered ? 1 : 0)
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .zeroContextMenu("follow-\(row.session)-\(row.topic)") {
            [
                (url.map { url in [MenuItem("Open", "arrow-up-right") { NSWorkspace.shared.open(url) }] } ?? [])
                    + [
                        MenuItem("Copy topic", "copy") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.topic, forType: .string)
                        }
                    ],
                [MenuItem("Unfollow", "xmark", action: unfollow)],
            ]
        }
    }
}
