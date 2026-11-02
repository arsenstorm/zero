import SwiftUI

/// Later, as on the Mac: what's saved to come back to, open first; each its note in plain words and everything
/// behind it in full.
struct LaterView: View {
    let model: PhoneModel

    var body: some View {
        List {
            Section("Later") {
                if model.later.isEmpty {
                    Text("Nothing saved for later. In a task, choose Save for later from its menu, and its agent writes down what's left.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(model.later) { item in
                    NavigationLink { LaterDetail(model: model, id: item.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.note).lineLimit(2).strikethrough(item.done, color: .secondary)
                            Text([item.task, item.createdAt.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .opacity(item.done ? 0.55 : 1)
                    }
                    .swipeActions {
                        Button(item.done ? "Not done" : "Done") { Task { await model.editLater(item.id, ["done": !item.done]) } }.tint(.green)
                    }
                }
            }
        }
        .refreshable { await model.loadLater() }
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
                        Menu {
                            ForEach(model.tasks) { row in
                                Button(row.task) {
                                    Task {
                                        try? await model.send(LaterAsk.pickUp(item), images: [], to: row.session)
                                        model.tab = .tasks
                                        model.path = [row.session]
                                    }
                                }
                            }
                        } label: { Text("Send to a task") }
                            .buttonStyle(.glassProminent)
                        Button(item.done ? "Not done" : "Done") {
                            Task { await model.editLater(item.id, ["done": !item.done]); self.item = await model.laterItem(id) }
                        }
                        .buttonStyle(.glass)
                        Button("Copy") { UIPasteboard.general.string = item.note + (item.artifact.map { "\n\n" + $0 } ?? "") }
                            .buttonStyle(.glass)
                    }
                    ForEach(item.links, id: \.self) { link in
                        if let url = URL(string: link) { Link(link, destination: url).font(.footnote).lineLimit(1) }
                    }
                    Divider()
                    if let artifact = item.artifact, !artifact.isEmpty { MarkdownView(text: artifact) }
                    else { Text("No artifact: the note is all there is.").foregroundStyle(.tertiary) }
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
