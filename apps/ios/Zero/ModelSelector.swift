import SwiftUI

/// The Mac's model selector for the phone, as two steps: the model, with a tick on the one in effect; then that model,
/// its logo, purpose and context, and its effort levels. Nothing changes until a level is picked (or a model without
/// levels is), so going back leaves things as they were.
struct ModelSelector: View {
    let provider: Provider
    let models: [PhoneModel.ModelChoice]
    /// The model and effort in effect: the task's, or what was picked here.
    let current: (model: String?, effort: String?)
    let pick: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(models) { model in
                Button {
                    if model.levels.isEmpty { pick(model.id, nil); dismiss() } else { path = [model.id] }
                } label: {
                    row(model.name, detail: model.context, chosen: model.id == current.model, more: !model.levels.isEmpty)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(provider.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: String.self) { id in
                if let model = models.first(where: { $0.id == id }) { levels(of: model) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The second step: what the model is, then how hard it thinks.
    private func levels(of model: PhoneModel.ModelChoice) -> some View {
        // The level in effect, if this is the model in effect; else the model's own default.
        let effort = model.id == current.model ? current.effort ?? model.defaultLevel : model.defaultLevel
        return List {
            Section {
                VStack(spacing: 0) {
                    logo(model.icon, size: 40).padding(.bottom, 10)
                    Text(model.name).font(.subheadline.weight(.semibold))
                    Text(describe(model)).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
                    if !model.context.isEmpty { Text(model.context).font(.footnote).foregroundStyle(.tertiary).padding(.top, 4) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("Effort") {
                ForEach(model.levels, id: \.id) { level in
                    Button { pick(model.id, level.id); dismiss() } label: {
                        row(level.name, detail: "", chosen: level.id == effort, more: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A choice: its name, a detail under it, and the tick at the right edge, as the workspace picker has it.
    private func row(_ name: String, detail: String, chosen: Bool, more: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(chosen ? .semibold : .regular)).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Image("circle-check-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(Color.accentColor).opacity(chosen ? 1 : 0)
            if more { Image("chevron-down-outline").resizable().frame(width: 10, height: 10).rotationEffect(.degrees(-90)).foregroundStyle(.secondary) }
        }
        .frame(minHeight: 36).contentShape(Rectangle())
    }

    @ViewBuilder private func logo(_ name: String, size: CGFloat) -> some View {
        if ["claude", "openai"].contains(name) {
            Image("provider-" + name).resizable().scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        }
    }

    /// Descriptions come with and without a full stop; here they all end in one.
    private func describe(_ row: PhoneModel.ModelChoice) -> String {
        let text = (row.detail.isEmpty ? row.provider : row.detail).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return text }
        return ".!?…".contains(last) ? text : text + "."
    }
}
