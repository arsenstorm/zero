import AppKit
import SwiftUI
import ZeroCore

// A conversation read as Codex shows one: your messages, then each turn's work folded into "Worked for 2m 37s ›" with
// only its answer in full. Hovering a message shows when it was sent, a copy button and a menu. A rail on the left
// has a tick for each of your messages, bright for those on screen; hovering one previews it, clicking goes there.

/// One thing in the timeline: a message of yours, a turn's work, an answer, or a step that shows on its own (a notice).
enum TimelineBlock: Identifiable {
    case user(ConversationItem)
    case work(id: String, items: [ConversationItem], start: Date?, end: Date?, live: Bool)
    case answer(ConversationItem)
    case step(ConversationItem)

    var id: String {
        switch self {
        case let .user(item), let .answer(item), let .step(item): item.id
        case let .work(id, _, _, _, _): id
        }
    }

    /// The items as blocks: everything between your message and the agent's answer is the turn's work. The work still
    /// going at the end is live while the agent is at it.
    static func of(_ items: [ConversationItem], working: Bool) -> [TimelineBlock] {
        var blocks: [TimelineBlock] = []
        var work: [ConversationItem] = []
        var start: Date?
        func flush(end: Date?, live: Bool) {
            guard let first = work.first else { return }
            blocks.append(.work(id: "work-" + first.id, items: work, start: start ?? first.date, end: end ?? work.last?.date, live: live))
            work = []
        }
        for item in items {
            switch item.kind {
            case .user:
                flush(end: nil, live: false)
                blocks.append(.user(item))
                start = item.date
            case .agent(_, finalAnswer: true):
                flush(end: item.date, live: false)
                blocks.append(.answer(item))
            case .notice:
                // Something went wrong (or right) that you should see without opening anything.
                blocks.append(.step(item))
            default:
                work.append(item)
            }
        }
        flush(end: nil, live: working)
        return blocks
    }

    /// The message of yours each block answers to, for the rail.
    static func turns(_ blocks: [TimelineBlock]) -> [String: String] {
        var owner: [String: String] = [:]
        var current: String?
        for block in blocks {
            if case let .user(item) = block { current = item.id }
            if let current { owner[block.id] = current }
        }
        return owner
    }
}

/// "2m 37s", "45s", "1h 3m".
func workedFor(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}

/// A turn's work: "Worked for 2m 37s ›" (or "Working for 12s" while it goes, its latest step under it), opening onto
/// every step.
struct WorkBlock: View {
    let items: [ConversationItem]
    let start: Date?
    let end: Date?
    let live: Bool
    let cwd: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    if live {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(start.map { "Working for " + workedFor(context.date.timeIntervalSince($0)) } ?? "Working")
                        }
                    } else {
                        Text(start.flatMap { start in end.map { "Worked for " + workedFor($0.timeIntervalSince(start)) } } ?? "Worked")
                    }
                    NucleoIcon("chevron-down", size: 9).rotationEffect(.degrees(open ? 0 : -90))
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1).offset(y: 6) }
            .help(open ? "Hide the steps" : "Show every step")
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { ItemView(item: $0, cwd: cwd) }
                }
                .padding(.top, 4)
                .transition(.opacity)
            } else if live, let last = items.last {
                // While it works, where it is: its latest step, quietly.
                ItemView(item: last, cwd: cwd).opacity(0.7).allowsHitTesting(false).lineLimit(1)
            }
        }
        .padding(.top, 4)
    }
}

/// A message of yours or an answer, with what shows under it on hover: copy, a menu, and when it was sent.
struct MessageBlock<Content: View>: View {
    let text: String
    let date: Date?
    /// Yours: on the right, as your bubble is.
    let mine: Bool
    let quote: (String) -> Void
    let save: (String) -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            content()
            HStack(spacing: 4) {
                CopyButton(text: text)
                Menu {
                    Button("Copy") { copy() }
                    Button("Quote in reply") { quote(text) }
                    Button("Save to a scratchpad") { save(text) }
                } label: {
                    NucleoIcon("dots", size: 13).foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22, height: 22)
                if let date { Text(Self.stamp(date)).font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.leading, 4) }
            }
            // Always laid out, shown on hover: nothing moves as the pointer passes.
            .opacity(hovered ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "5:39 PM" today, "Oct 7, 5:39 PM" before, with the year when it isn't this one.
    static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.month(.abbreviated).day().year().hour().minute())
    }
}

/// A tick for each message of yours, down the left, as Codex has them: brighter for those on screen. Hovering grows the
/// tick under the pointer and, a little, its neighbours, dims the rest, and shows that message with the start of its
/// answer; a click goes there.
struct MessageRail: View {
    struct Mark: Identifiable {
        let id: String
        let text: String
        let answer: String?
    }
    let marks: [Mark]
    let visible: Set<String>
    let go: (String) -> Void
    @State private var hovered: Int?

    /// How long a tick is, by how far it is from the one hovered.
    private static let lengths: [CGFloat] = [24, 17, 13]
    private static let rest: CGFloat = 10

    var body: some View {
        GeometryReader { space in
            // Ten points apart, closer when there are more than fit.
            let pitch = max(3, min(10, space.size.height * 0.8 / CGFloat(max(marks.count, 1))))
            let top = (space.size.height - pitch * CGFloat(marks.count)) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                    let distance = hovered.map { abs($0 - index) }
                    let length = distance.flatMap { $0 < Self.lengths.count ? Self.lengths[$0] : nil } ?? Self.rest
                    let bright = hovered.map { $0 == index } ?? visible.contains(mark.id)
                    Capsule().fill(Color.primary.opacity(bright ? 0.85 : 0.25))
                        .frame(width: length, height: 1.5)
                        .offset(x: 0, y: top + pitch * (CGFloat(index) + 0.5) - 0.75)
                }
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    let index = Int(((point.y - top) / pitch).rounded(.down))
                    let inside = point.y >= top - pitch && point.y <= top + pitch * CGFloat(marks.count) + pitch
                    withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? min(max(index, 0), marks.count - 1) : nil }
                case .ended:
                    withAnimation(.easeOut(duration: 0.12)) { hovered = nil }
                }
            }
            .onTapGesture { if let hovered { go(marks[hovered].id) } }
            .overlay {
                if let hovered {
                    // Centred on its tick, kept inside the view near its ends.
                    let y = min(max(top + pitch * (CGFloat(hovered) + 0.5), 60), space.size.height - 60)
                    preview(marks[hovered])
                        .fixedSize()
                        .position(x: 40 + 160, y: y)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 30)
    }

    private func preview(_ mark: Mark) -> some View {
        let inline = { (text: String) in (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text) }
        let firstLine = mark.text.split(separator: "\n").first.map(String.init) ?? mark.text
        return VStack(alignment: .leading, spacing: 5) {
            Text(firstLine).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
            if let answer = mark.answer {
                Text(inline(answer.replacingOccurrences(of: "\n", with: " "))).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// A scrollbar as arsenstorm.com has one: a thin rounded thumb on no track, the full height of what scrolls; it
/// widens under the pointer and drags.
struct ThinScrollbar: View {
    let geometry: ScrollGeometry?
    let scrollTo: (CGFloat) -> Void
    @State private var hovered = false
    @State private var dragFrom: CGFloat?

    /// rgb(161 161 170 / 70%) light, rgb(113 113 122 / 70%) dark: the site's zinc.
    static let thumb = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 113 / 255, green: 113 / 255, blue: 122 / 255, alpha: 0.7)
            : NSColor(srgbRed: 161 / 255, green: 161 / 255, blue: 170 / 255, alpha: 0.7)
    })

    var body: some View {
        GeometryReader { space in
            if let geometry {
                // What's on screen against the whole conversation; past either end (insets, a bounce) counts as the end.
                let total = geometry.contentSize.height
                let visible = min(geometry.visibleRect.height, total)
                if total > visible + 1 {
                    let track = space.size.height - 8
                    let length = max(32, track * visible / total)
                    let room = total - visible
                    let offset = min(max(geometry.visibleRect.minY, 0), room)
                    let y = 4 + (track - length) * offset / room
                    Capsule().fill(Self.thumb)
                        .frame(width: hovered || dragFrom != nil ? 6 : 4, height: length)
                        .frame(width: 12, height: length)
                        .contentShape(Rectangle())
                        .position(x: space.size.width - 6, y: y + length / 2)
                        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let start = dragFrom ?? offset
                                if dragFrom == nil { dragFrom = start }
                                let moved = drag.translation.height * room / max(track - length, 1)
                                scrollTo(min(max(start + moved, 0), room))
                            }
                            .onEnded { _ in dragFrom = nil })
                }
            }
        }
        .frame(width: 12)
    }
}

/// Rows standing in for older messages while they're fetched: a message of yours and an answer, as bars.
struct SkeletonTurns: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14).fill(Theme.chip).frame(width: 260, height: 36).frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach([0.92, 0.78, 0.86, 0.45], id: \.self) { fraction in
                        GeometryReader { space in RoundedRectangle(cornerRadius: 4).fill(Theme.chip).frame(width: space.size.width * fraction, height: 10) }
                            .frame(height: 10)
                    }
                }
            }
        }
        .opacity(0.7)
    }
}
