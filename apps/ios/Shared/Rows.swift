import SwiftUI
import UIKit

// A task's row and its parts, as the app's Tasks list draws them: shared with the share sheet, which lists the same
// tasks to send to, and Zero's own list to pick from (New task's places, the share sheet's).

/// A task's state, as the Mac's sidebar shows it: the same icons and colours.
struct StateGlyph: View {
    /// The terminal app the Mac opens tasks in, by its name ("In Ghostty"): the app's, read as its views draw (the
    /// share sheet has none, and says Terminal).
    @MainActor static var terminal: () -> String = { "Terminal" }
    let state: BoardRow.State
    var size: CGFloat = 16
    var body: some View {
        let look = Self.look(state)
        if state == .working {
            Spinner().frame(width: size - 2, height: size - 2).frame(width: size, height: size)
        } else {
            Image(look.icon).resizable().frame(width: size, height: size).foregroundStyle(look.color)
        }
    }

    static func look(_ state: BoardRow.State) -> (icon: String, color: Color, name: String) {
        switch state {
        case .needsYou: ("hand-3-glyph", .blue, "Needs you")
        case .trouble: ("triangle-warning-glyph", .orange, "In trouble")
        case .blocked: ("circle-minus-glyph", .red, "Blocked")
        case .working: ("arrow-rotate-clockwise-glyph", .blue, "Working")
        case .handed: ("hand-holding-box-glyph", .teal, "Over to you")
        case .waiting: ("hourglass-glyph", .secondary, "Waiting")
        case .answered: ("message-check-glyph", .indigo, "Replied")
        case .done: ("badge-check-glyph", .purple, "Done")
        case .paused: ("circle-pause-glyph", .secondary, "Paused")
        case .inTerminal: ("terminal-outline", .blue, "In \(terminal())")
        case .read: ("message-check-glyph", .secondary, "Replied")
        case .idle: ("moon-glyph", .secondary, "Idle")
        case .offline: ("power-off-glyph", .secondary, "Offline")
        }
    }
}

/// What a task says under its name, as Linear's inbox: up to two lines, the end of the last fading out under how long
/// ago it moved.
struct Described: View {
    let text: String?
    let at: Int?
    var font: Font = .subheadline
    /// In the primary colour (a note saved for later is the row itself), not the secondary of what a task says.
    var primary = false
    @State private var timeWidth: CGFloat = 0
    @State private var lineHeight: CGFloat = 18

    var body: some View {
        let ago = at.map { Ago.short($0) }
        if let text, !text.isEmpty {
            // Left-aligned: inside a button (a task's row), lines are centred otherwise.
            Text(text).font(font).foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)).lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask {
                    // Whole, but the last line's end: fading out, then nothing where the time is.
                    VStack(spacing: 0) {
                        Color.black
                        HStack(spacing: 0) {
                            Color.black
                            if ago != nil {
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                                Color.clear.frame(width: timeWidth + 4)
                            }
                        }
                        .frame(height: lineHeight)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let ago {
                        Text(ago).font(font).foregroundStyle(.secondary).monospacedDigit()
                            .onGeometryChange(for: CGSize.self) {
                                $0.size
                            } action: {
                                timeWidth = $0.width; lineHeight = $0.height
                            }
                    }
                }
        }
    }

    /// Nothing to say: the row has a single line, the time beside its name (TimeBeside), centred on its icon.
    static func says(_ text: String?) -> Bool { !(text ?? "").isEmpty }
}

/// One line of text at its own width when it fits; when it doesn't, as wide as there's room for, fading out at its end
/// rather than ending in "…". It takes its room as any one-line label does (the hidden text, which the row lays out),
/// and draws the whole line over it, clipped: the line itself never makes the row wider.
struct FadingLine: View {
    let text: String
    let font: Font
    @State private var whole: CGFloat = 0
    @State private var room: CGFloat = 0

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                room = $0
            }
            .overlay(alignment: .leading) {
                Text(text).font(font).lineLimit(1).fixedSize()
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        whole = $0
                    }
            }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    if whole > room + 0.5 {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                    }
                }
            }
    }
}

/// How long ago a row moved, beside its name: for a row with nothing under its name.
struct TimeBeside: View {
    let at: Int?
    var body: some View {
        if let at { Text(Ago.short(at)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
    }
}

/// A task's agent as an avatar, Linear's way: its mark in a circle, its state at the corner.
struct AgentAvatar: View {
    let provider: Provider?
    let state: BoardRow.State

    var body: some View {
        Image(Self.mark(provider)).resizable().frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .background(Color(.secondarySystemFill), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                StateGlyph(state: state).scaleEffect(0.8)
                    .frame(width: 20, height: 20)
                    .background(Color(.systemBackground), in: Circle())
                    .offset(x: 3, y: 3)
                    .accessibilityLabel(StateGlyph.look(state).name)
            }
    }

    static func mark(_ provider: Provider?) -> String {
        switch provider {
        case .claude: "provider-claude"
        case .codex: "provider-openai"
        default: "terminal-outline"
        }
    }
}

/// A task as the Mac's sidebar lists it: its name, then (a lead with workers) the chevron that folds them, then its
/// state. A worker's is a step in and smaller.
/// A task's row, the same in the inbox and the task list, as Linear shows an issue in its inbox: its agent's mark with
/// its state at the corner, its name (a dot before it while its reply is unread) and how long ago it moved, then what
/// it says in up to two lines.
struct TaskRow: View {
    let row: BoardRow
    /// What it says under its name: its reply, or the step that's the user's.
    let said: String?
    /// Picked, in a list to pick from (the share sheet): ticked at its end. Nil in the Tasks list, which opens it.
    var picked: Bool? = nil
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(alignment: .center, spacing: 12) {
                AgentAvatar(provider: row.provider, state: row.ownState)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Its name, then the unread dot right after it; a name too long for the line fades out at its
                        // end before the dot, as what it says fades before the time.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            FadingLine(text: row.task, font: .body.weight(.semibold))
                            // Centred on the name's capitals (about 12 pt tall at this size), not sat on its baseline
                            // like a full stop.
                            if row.ownState == .answered {
                                Circle().fill(.indigo).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) {
                                    $0[VerticalAlignment.center] + 6
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !Described.says(said) { TimeBeside(at: row.at) }
                    }
                    if Described.says(said) { Described(text: said, at: row.at) }
                }
                if let picked {
                    Image("circle-check-glyph").resizable().frame(width: 20, height: 20).foregroundStyle(Theme.knob)
                        .opacity(picked ? 1 : 0)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Its avatar's edge under the page title's T (20.7 pt in): the circle fills its frame, unlike a padded icon.
        .listRowInsets(EdgeInsets(top: 6, leading: 20.5, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

/// Zero's own list to pick from, not the system menu: the tick at the right edge, where it's read last.
struct ChoiceList: View {
    let rows: [(id: String, title: String)]
    let selected: String
    /// A line under a row's title, by its id (what a permission lets the agent do).
    var details: [String: String] = [:]
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(rows, id: \.id) { row in
                Button {
                    pick(row.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).lineLimit(1)
                            if let detail = details[row.id] { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 16)
                        Image("circle-check-glyph").resizable().frame(width: 18, height: 18).foregroundStyle(Theme.knob).opacity(
                            row.id == selected ? 1 : 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, details.isEmpty ? 0 : 8).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 260)
        .presentationCompactAdaptation(.popover)
    }
}

/// The Mac's surfaces (its Theme), in both appearances: the same ink, code, choice and done colours on both apps.
enum Theme {
    static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    /// Zero's ink, solid: black in light, white in dark. The app's tint (its caret, ticks, primary buttons).
    static let knob = dynamic(dark: .white, light: .black)
    /// Words on the ink (your messages, a primary button's label).
    static let onKnob = dynamic(dark: .black, light: .white)
    static let code = dynamic(dark: UIColor(white: 0, alpha: 0.35), light: UIColor(white: 0, alpha: 0.05))
    /// An answer's row: a tint over whatever it sits on.
    static let choice = dynamic(dark: UIColor(white: 1, alpha: 0.07), light: UIColor(white: 0, alpha: 0.05))
    /// "Done" as words on their own: the system green reads pale as small text; this one has weight.
    static let done = dynamic(
        dark: UIColor(red: 0.40, green: 0.82, blue: 0.50, alpha: 1), light: UIColor(red: 0.09, green: 0.50, blue: 0.22, alpha: 1))
    /// A card's radius, as the Mac's card(); an option row or a box inside it, 10.
    static let cardRadius: CGFloat = 18
}

/// A sheet's send or start button (New task, Record's, the share sheet's): a glass circle, filled with the ink once it
/// can go and while it's going, its spinner in the words' colour on it.
struct SendCircle: View {
    let ready: Bool
    let sending: Bool
    var label = "Send"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if sending {
                    Spinner(color: Theme.onKnob).frame(width: 18, height: 18)
                } else {
                    Image("arrow-up-outline").resizable().frame(width: 20, height: 20)
                        .foregroundStyle(ready ? AnyShapeStyle(Theme.onKnob) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 44, height: 44)
            .background { if ready || sending { Circle().fill(Theme.knob) } }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
        .disabled(!ready || sending)
        .accessibilityLabel(label)
    }
}

extension Permissions {
    /// The two choices as the Mac lists them: what each is called, and what it lets the agent do.
    static func choices(_ provider: Provider?) -> [(Permissions, String, String)] {
        [
            (.auto, "Auto", "\(provider?.title ?? "The agent") decides what's safe, and asks you the rest"),
            (.unrestricted, "Unrestricted", "Anything, without asking"),
        ]
    }
}
