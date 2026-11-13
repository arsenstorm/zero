import SwiftUI

/// Later, after Linear's My issues: Open and Done as pills at the top; what agents saved on their own in a card of
/// its own, as Linear's Delegated; then one line a note, newest first: the state of the task it came from, the note,
/// how long ago. (Two-line rows of a bold note and its task read heavy, and grouped under tasks it was mostly headings.)
struct LaterView: View {
    let model: PhoneModel
    @State private var showing = Shown.open

    enum Shown: String, CaseIterable { case open = "Open", done = "Done" }
    /// The page's column, the title's: where the pills' words, "Suggested" and every row start (and the times end).
    static let column: CGFloat = 20
    /// The pills' words to their fill's edge.
    static let pillPadding: CGFloat = 10

    var body: some View {
        let newest = model.later.sorted { $0.created > $1.created }
        let open = newest.filter { !$0.done }, done = newest.filter(\.done)
        let suggested = open.filter { $0.suggested == true }, kept = open.filter { $0.suggested != true }
        List {
            HStack(spacing: 4) {
                ForEach(Shown.allCases, id: \.self) { shown in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showing = shown }
                    } label: {
                        HStack(spacing: 6) {
                            Text(shown.rawValue)
                            Text("\((shown == .open ? open : done).count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(showing == shown ? .primary : .secondary)
                        .padding(.horizontal, LaterView.pillPadding).frame(height: 36)
                        .background { if showing == shown { Capsule().fill(Color(.secondarySystemFill)) } }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            // The pills' words on the title's column, as "Suggested" and the rows are; the selected one's fill reaches past.
            .listRowInsets(EdgeInsets(top: 4, leading: LaterView.column - LaterView.pillPadding, bottom: 10, trailing: 20))
            .listRowSeparator(.hidden)
            if showing == .open {
                if !suggested.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                        ForEach(suggested) { item in LaterLine(model: model, item: item) }
                    }
                    // Its heading and rows on the title's column, 12 pt inside it; the card reaching past it either side.
                    .padding(.horizontal, 12).padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 0, leading: LaterView.column - 12, bottom: 12, trailing: LaterView.column - 12))
                    .listRowSeparator(.hidden)
                }
                ForEach(kept) { item in LaterLine(model: model, item: item).modifier(LaterRowInsets()) }
            } else {
                ForEach(done) { item in LaterLine(model: model, item: item).modifier(LaterRowInsets()) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if (showing == .open ? open : done).isEmpty {
                ContentUnavailableView {
                    Text(showing == .open ? "Nothing for later" : "Nothing done yet")
                } description: {
                    Text(
                        showing == .open
                            ? "In a task, choose Save for later from its menu: it waits here, paused, until you resume it."
                            : "Notes you mark done show here.")
                }
                .allowsHitTesting(false)
            }
        }
        .refreshable { await model.loadLater() }
    }
}

/// A line in Later's list: on the icons' column, as the card's lines are, either side.
private struct LaterRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowInsets(EdgeInsets(top: 0, leading: LaterView.column, bottom: 0, trailing: LaterView.column)).listRowSeparator(
            .hidden)
    }
}

/// A note saved for later, on one line as Linear's issues are: the state of the task it came from (still waiting on
/// you, done, gone), the note, how long ago. Opens the note in full; swiped, done or not.
struct LaterLine: View {
    let model: PhoneModel
    let item: ZerodLink.LaterItem

    var body: some View {
        ZStack {
            // The way in, under the row: a link's own chevron isn't drawn.
            NavigationLink {
                LaterDetail(model: model, id: item.id)
            } label: {
                EmptyView()
            }.opacity(0)
            HStack(spacing: 12) {
                if item.done {
                    Image("circle-check-glyph").resizable().frame(width: 20, height: 20).foregroundStyle(.green)
                } else if let from = item.from, let row = model.row(from) {
                    StateGlyph(state: row.ownState, size: 20)
                } else {
                    // Its task gone (archived): nothing to say of it but that the note is kept.
                    Image("bookmark-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(.tertiary).frame(width: 20, height: 20)
                }
                FadingLine(text: item.note, font: .body).foregroundStyle(item.done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimeBeside(at: item.created * 1000)
            }
            .frame(minHeight: 44)
        }
        .swipeActions {
            Button(item.done ? "Not done" : "Done") { Task { await model.editLater(item.id, ["done": !item.done]) } }.tint(.green)
        }
    }
}

struct LaterDetail: View {
    let model: PhoneModel
    let id: String
    @State private var item: ZerodLink.LaterItem?

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.note).font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let task = item.task { Text(task).fontWeight(.medium); Text("·") }
                        Text(item.createdAt.formatted(.relative(presentation: .named)))
                        if item.done { Text("Done").foregroundStyle(.green) }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let resume = item.resume, !item.done {
                            // A whole task saved for later: back among the tasks, off hold.
                            Button("Resume") {
                                Task {
                                    let session = await model.resumeLater(item.id) ?? resume
                                    model.tab = .tasks
                                    model.path = [session]
                                }
                            }
                            .buttonStyle(.glassProminent)
                        } else {
                            Menu {
                                ForEach(model.tasks) { row in
                                    Button(row.task) {
                                        Task {
                                            try? await model.send(laterPickUp(item), images: [], to: row.session)
                                            model.tab = .tasks
                                            model.path = [row.session]
                                        }
                                    }
                                }
                            } label: {
                                Text("Send to a task")
                            }
                            .buttonStyle(.glassProminent)
                        }
                        Button(item.done ? "Not done" : "Done") {
                            Task {
                                await model.editLater(item.id, ["done": !item.done]); self.item = await model.laterItem(id)
                            }
                        }
                        .buttonStyle(.glass)
                        Button("Copy") { UIPasteboard.general.string = item.note + (item.artifact.map { "\n\n" + $0 } ?? "") }
                            .buttonStyle(.glass)
                    }
                    ForEach(item.links, id: \.self) { link in
                        if let url = URL(string: link) { Link(link, destination: url).font(.footnote).lineLimit(1) }
                    }
                    Divider()
                    if let artifact = item.artifact, !artifact.isEmpty {
                        MarkdownView(text: artifact)
                    } else {
                        Text("No artifact: the note is all there is.").foregroundStyle(.tertiary)
                    }
                }
                .padding()
            } else {
                Spinner().frame(width: 22, height: 22).frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { item = await model.laterItem(id) }
    }
}
