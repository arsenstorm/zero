import SwiftUI

/// The Mac's model selector for the phone, as two steps: the model, under its agent (Claude Code, Codex, OpenCode),
/// with a tick on the one in effect; then that model, its logo, purpose and context, and its effort levels. Nothing
/// changes until a level is picked (or a model without levels is), so going back leaves things as they were. A task's
/// composer gives its own agent alone; New task, every agent, so the agent and its model are one choice.
struct ModelSelector: View {
    struct Agent { let provider: Provider; let models: [PhoneModel.ModelChoice] }
    let agents: [Agent]
    /// The agent, model and effort in effect: the task's, or what was picked here.
    let current: (provider: Provider?, model: String?, effort: String?)
    /// The agent, its model (none: an agent without a list, as OpenCode, on its own default) and effort.
    let pick: (Provider, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            // The app's own page (PageParts), not the system's inset-grouped list.
            PageScroll {
                ForEach(agents, id: \.provider) { agent in
                    PageGroup(title: agents.count > 1 ? agent.provider.title : nil) {
                        if agent.models.isEmpty {
                            Button {
                                pick(agent.provider, nil, nil); dismiss()
                            } label: {
                                row(
                                    agent.provider.title, detail: "Its own default", chosen: current.provider == agent.provider, more: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(agent.models) { model in
                            Button {
                                if model.levels.isEmpty {
                                    pick(agent.provider, model.id, nil); dismiss()
                                } else {
                                    path = [Self.key(agent.provider, model.id)]
                                }
                            } label: {
                                row(
                                    model.name, detail: model.context,
                                    chosen: current.provider == agent.provider && model.id == current.model, more: !model.levels.isEmpty)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(agents.count == 1 ? agents[0].provider.title : "Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: String.self) { key in
                if let agent = agents.first(where: { key.hasPrefix($0.provider.rawValue + "/") }),
                    let model = agent.models.first(where: { Self.key(agent.provider, $0.id) == key })
                {
                    levels(of: model, agent: agent.provider)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The second step: what the model is, then how hard it thinks.
    private static func key(_ provider: Provider, _ model: String) -> String { provider.rawValue + "/" + model }

    private func levels(of model: PhoneModel.ModelChoice, agent: Provider) -> some View {
        // The level in effect, if this is the model in effect; else the model's own default.
        let effort = model.id == current.model ? current.effort ?? model.defaultLevel : model.defaultLevel
        return PageScroll {
            PageGroup {
                VStack(spacing: 0) {
                    logo(model.icon, size: 40).padding(.bottom, 10)
                    Text(model.name).font(.subheadline.weight(.semibold))
                    Text(describe(model)).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
                    if !model.context.isEmpty { Text(model.context).font(.footnote).foregroundStyle(.tertiary).padding(.top, 4) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            PageGroup(title: "Effort") {
                ForEach(model.levels, id: \.id) { level in
                    Button {
                        pick(agent, model.id, level.id); dismiss()
                    } label: {
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
            Image("circle-check-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(Theme.knob).opacity(chosen ? 1 : 0)
            if more {
                Image("chevron-down-outline").resizable().frame(width: 10, height: 10).rotationEffect(.degrees(-90)).foregroundStyle(
                    .secondary)
            }
        }
        .frame(minHeight: 46).contentShape(Rectangle())
    }

    @ViewBuilder private func logo(_ name: String, size: CGFloat) -> some View {
        if ["claude", "openai"].contains(name) {
            Image("provider-" + name).resizable().scaledToFit().frame(width: size, height: size).clipShape(
                RoundedRectangle(cornerRadius: size * 0.22))
        }
    }

    /// Descriptions come with and without a full stop; here they all end in one.
    private func describe(_ row: PhoneModel.ModelChoice) -> String {
        let text = (row.detail.isEmpty ? row.provider : row.detail).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return text }
        return ".!?…".contains(last) ? text : text + "."
    }
}
