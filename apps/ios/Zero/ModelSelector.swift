import SwiftUI
import UIKit

/// The Mac's model selector (ZeroApp's SelectorView) for the phone: the provider, its models with a tick on the one
/// chosen, and the chosen one's logo, purpose, context and effort, set on the same warming slider.
struct ModelSelector: View {
    let provider: Provider
    let models: [PhoneModel.ModelChoice]
    /// The model and effort in effect: the task's, or what was picked here.
    let current: (model: String?, effort: String?)
    let pick: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var shown: String?

    private var row: PhoneModel.ModelChoice? { models.first { $0.id == (shown ?? current.model) } ?? models.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                logo(provider == .claude ? "claude" : provider == .codex ? "openai" : "", size: 18)
                Text(provider.title).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(models) { model in
                        let chosen = model.id == current.model
                        Button {
                            shown = model.id
                            // The level it had, if it can take it; else its own default.
                            let level = model.levels.contains { $0.id == current.effort } ? current.effort : model.defaultLevel ?? model.levels.first?.id
                            pick(model.id, level)
                        } label: {
                            HStack(spacing: 10) {
                                Text(model.name).font(.body.weight(chosen ? .semibold : .regular)).lineLimit(1)
                                Spacer(minLength: 8)
                                Image("circle-check-glyph").resizable().frame(width: 16, height: 16).foregroundStyle(Color.accentColor).opacity(chosen ? 1 : 0)
                            }
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(model.id == row?.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                if let row { details(row).padding(.top, 14) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The model's logo, name, purpose and context, centred; its effort under them.
    private func details(_ row: PhoneModel.ModelChoice) -> some View {
        let effort = row.id == current.model ? current.effort ?? row.defaultLevel : row.defaultLevel
        return VStack(spacing: 0) {
            logo(row.icon, size: 40).padding(.bottom, 10)
            Text(row.name).font(.subheadline.weight(.semibold))
            Text(describe(row)).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
            if !row.context.isEmpty { Text(row.context).font(.footnote).foregroundStyle(.tertiary).padding(.top, 4) }
            if !row.levels.isEmpty {
                HStack {
                    Text("Effort").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(effort.map { id in row.levels.first { $0.id == id }?.name ?? id.capitalized } ?? "").font(.footnote.weight(.medium))
                        .contentTransition(.numericText())
                }
                .padding(.top, 18)
                EffortSlider(levels: row.levels.map(\.id), picked: effort) { level in
                    shown = row.id
                    pick(row.id, level)
                }
                .padding(.top, 8)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16).padding(.bottom, 20)
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

/// The Mac's effort slider: a thick track warming from amber to red as the level rises, points that grow with the
/// level, a knob that swells while held and snaps to the nearest point, with a tick of the haptics at each.
struct EffortSlider: View {
    let levels: [String]
    let picked: String?
    let onPick: (String) -> Void
    @State private var held = false

    private let trackHeight: CGFloat = 12
    private let knob: CGFloat = 24
    private let heat = [Color(red: 0.95, green: 0.72, blue: 0.25), Color(red: 0.95, green: 0.45, blue: 0.15), Color(red: 0.90, green: 0.22, blue: 0.18)]

    var body: some View {
        let index = picked.flatMap { levels.firstIndex(of: $0) } ?? 0
        GeometryReader { geo in
            let inset = trackHeight / 2
            let step = levels.count > 1 ? (geo.size.width - trackHeight) / CGFloat(levels.count - 1) : 0
            let x = inset + step * CGFloat(index)
            let mid = geo.size.height / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: trackHeight)
                Capsule().fill(LinearGradient(colors: heat, startPoint: .leading, endPoint: .trailing)).frame(height: trackHeight)
                    .mask(alignment: .leading) { Capsule().frame(width: x + trackHeight / 2) }
                ForEach(levels.indices, id: \.self) { i in
                    let size = 3 + CGFloat(i) * 4 / CGFloat(max(levels.count - 1, 1))
                    Circle().fill(i <= index ? Color.white.opacity(0.6) : Color.primary.opacity(0.22))
                        .frame(width: size, height: size)
                        .position(x: inset + step * CGFloat(i), y: mid)
                }
                Circle().fill(.white).shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .frame(width: knob, height: knob)
                    .scaleEffect(held ? 1.15 : 1)
                    .position(x: x, y: mid)
            }
            .animation(.snappy(duration: 0.2), value: index)
            .animation(.snappy(duration: 0.15), value: held)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    held = true
                    guard step > 0 else { return }
                    let i = Int(((value.location.x - inset) / step).rounded())
                    let level = levels[max(0, min(levels.count - 1, i))]
                    if level != picked {
                        UISelectionFeedbackGenerator().selectionChanged()
                        onPick(level)
                    }
                }
                .onEnded { _ in held = false })
        }
        .frame(height: knob + 6)
    }
}
