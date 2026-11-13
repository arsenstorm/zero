import SwiftUI

// Zero's own dialog, in place of a sheet: drawn over the workspace window in a short fade (no slide, no native chrome), a
// card on a dimmed backdrop, closed with Escape, a click outside or its own buttons. Its controls are Zero's too:
// fields on the row grey, a choice track, checkboxes and capsule buttons.

/// The dialog shown, if any, and what closing it does to whoever opened it.
@MainActor @Observable final class Dialogs {
    static let shared = Dialogs()
    private(set) var content: AnyView?
    @ObservationIgnored private var closed: (() -> Void)?
    @ObservationIgnored private var owner: String?
    /// Where its card is, in the window (top-left origin): while it's open, only what's on the card shows tips.
    @ObservationIgnored var card: CGRect = .zero

    /// Whether a tip at `point` (in the window, top-left origin) may show: always without a dialog, else on its card.
    func allowsTip(at point: CGPoint) -> Bool { content == nil || card.contains(point) }

    func show(_ view: AnyView, owner: String, closed: @escaping () -> Void) {
        content = view
        self.owner = owner
        self.closed = closed
    }

    /// Closed from inside (Cancel, Escape, a click outside): its opener hears of it.
    func close() {
        let closed = closed
        content = nil; owner = nil; self.closed = nil
        closed?()
    }

    /// Its opener let it go: nothing to tell.
    func dismiss(owner: String) {
        guard self.owner == owner else { return }
        content = nil; self.owner = nil; closed = nil
    }
}

/// Where dialogs are drawn: over the whole window, the workspace view's root. Shown and gone at once, as Zero's
/// popovers and cards are.
struct DialogHost: View {
    var body: some View {
        ZStack {
            if let content = Dialogs.shared.content {
                Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture { Dialogs.shared.close() }
                // Escape closes it, whatever its buttons are called.
                Button("") { Dialogs.shared.close() }.keyboardShortcut(.cancelAction).hidden()
                content
                    .padding(22)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.stroke))
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.16), radius: 28, y: 10)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        Dialogs.shared.card = $0
                    }
                    .environment(\.closeDialog, CloseDialog { Dialogs.shared.close() })
            }
        }
        .ignoresSafeArea()
    }
}

/// How a form in a dialog closes it (the sheet's `dismiss`, for Zero's dialog).
struct CloseDialog { let close: () -> Void; func callAsFunction() { close() } }
extension EnvironmentValues { @Entry var closeDialog = CloseDialog {} }

extension View {
    /// Shows `content` in Zero's dialog while `item` is set; closing it clears `item`.
    func zeroDialog<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View
    {
        modifier(
            DialogOpener(shown: item.wrappedValue.map { "\($0.id)" }, content: { item.wrappedValue.map { AnyView(content($0)) } }) {
                item.wrappedValue = nil
            })
    }

    func zeroDialog<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(
            DialogOpener(shown: isPresented.wrappedValue ? "shown" : nil, content: { isPresented.wrappedValue ? AnyView(content()) : nil })
            { isPresented.wrappedValue = false })
    }
}

private struct DialogOpener: ViewModifier {
    let shown: String?
    let content: () -> AnyView?
    let closed: () -> Void
    @State private var owner = UUID().uuidString

    func body(content view: Content) -> some View {
        view.onChange(of: shown, initial: true) { _, shown in
            if shown != nil, let content = content() {
                Dialogs.shared.show(content, owner: owner, closed: closed)
            } else {
                Dialogs.shared.dismiss(owner: owner)
            }
        }
        .onDisappear { Dialogs.shared.dismiss(owner: owner) }
    }
}

/// A dialog's title, and what the dialog is for 4 pt under it.
struct DialogTitle: View {
    let text: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A labelled part of a dialog: a small grey heading, then its controls.
struct DialogPart<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// A dialog's buttons: the one to save filled, the rest on the row grey; Delete in red.
struct DialogButton: View {
    enum Kind { case primary, secondary, destructive }
    let title: String
    var kind = Kind.secondary
    var enabled = true
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    kind == .primary
                        ? AnyShapeStyle(Theme.onKnob) : kind == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary)
                )
                .padding(.horizontal, 14).frame(height: 30)
                .background(kind == .primary ? Theme.knob : Theme.row, in: Capsule())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PressableStyle()).disabled(!enabled)
        if kind == .primary { button.keyboardShortcut(.defaultAction) } else { button }
    }
}

/// A dialog's first field, focused as it opens with its words selected (an edit's are replaced by typing): typing goes
/// to the dialog, not to what's behind it.
private struct FirstField: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).onAppear {
            focused = true
        }
    }
}

extension View { func firstField() -> some View { modifier(FirstField()) } }

/// Text fields on the row grey, as Zero's composer and forms have them.
struct DialogFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension TextFieldStyle where Self == DialogFieldStyle { static var dialog: DialogFieldStyle { DialogFieldStyle() } }

/// One of a few, on a track: the chosen one raised on the card's colour.
struct DialogChoice<Value: Hashable>: View {
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(on ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2).background(Theme.row, in: RoundedRectangle(cornerRadius: 8)).fixedSize()
    }
}

/// A checkbox in Zero's colours: black when on (a soft grey in dark); faded when it can't be changed.
struct DialogCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Box(configuration: configuration) }

    private struct Box: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? Theme.checkOn : Theme.row)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(configuration.isOn ? .clear : Theme.stroke))
                        .overlay { if configuration.isOn { NucleoIcon("check", size: 10).foregroundStyle(Theme.checkMark) } }
                        .frame(width: 16, height: 16)
                    configuration.label.font(.system(size: 13))
                }
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

extension ToggleStyle where Self == DialogCheckbox { static var dialogCheckbox: DialogCheckbox { DialogCheckbox() } }
