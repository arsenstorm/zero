import AppKit
import SwiftUI

/// The output pane of a run card: the command as a highlighted first line, then the output, in one selectable
/// transcript. Wheel events never leave it, so reaching its top or bottom doesn't scroll the card list.
struct TerminalView: NSViewRepresentable {
    let command: String
    let output: String

    func makeNSView(context: Context) -> ContainedScrollView {
        let scroll = ContainedScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .mini
        scroll.verticalScrollElasticity = .none
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: ContainedScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        // The input line: an accent-coloured prompt and a semibold command; the output follows in regular weight.
        let transcript = NSMutableAttributedString(string: "$ ", attributes: [.font: bold, .foregroundColor: NSColor.controlAccentColor])
        transcript.append(NSAttributedString(string: command + "\n", attributes: [.font: bold, .foregroundColor: NSColor.labelColor]))
        transcript.append(NSAttributedString(string: output, attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        if text.attributedString() != transcript {
            text.textStorage?.setAttributedString(transcript)
            text.scrollToEndOfDocument(nil) // follow the newest line as it streams
        }
    }
}

/// An NSScrollView that hands a scroll on to the card list only when you clearly mean it.
/// Trackpad: within one gesture, momentum included, reaching the edge just stops; a new gesture at the edge
/// passes through. Wheels without gesture phases (a free-spinning MX Master, say): at the edge the card list
/// starts moving at a fraction of the wheel's strength and ramps to full over about 500 points of pushing,
/// so the hand-off is a blend rather than a stop and a jump. A pause or a reversal resets it.
final class ContainedScrollView: NSScrollView {
    private var lastEvent: TimeInterval = 0
    private var pushedIntoEdge: CGFloat = 0
    private var passingThrough = false

    override func scrollWheel(with event: NSEvent) {
        guard let document = documentView else { return }
        let visible = contentView.bounds
        let fits = document.frame.height <= visible.height
        let atTop = visible.minY <= 0
        let atBottom = visible.maxY >= document.frame.height - 0.5
        let delta = event.scrollingDeltaY
        let blocked = fits || (atTop && delta > 0) || (atBottom && delta < 0)
        let paused = event.timestamp - lastEvent > 0.4
        lastEvent = event.timestamp
        if paused { pushedIntoEdge = 0; passingThrough = false }

        guard blocked else {
            pushedIntoEdge = 0
            passingThrough = false
            super.scrollWheel(with: event)
            return
        }
        if fits { nextResponder?.scrollWheel(with: event); return }

        let hasPhases = event.phase != [] || event.momentumPhase != []
        if hasPhases {
            // Trackpad: only a gesture that starts at the edge leaves the pane.
            if event.phase == .began || event.phase == .mayBegin { passingThrough = true }
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended { passingThrough = false }
            if passingThrough { nextResponder?.scrollWheel(with: event) }
            return
        }
        pushedIntoEdge += abs(delta)
        let strength = min(1, pushedIntoEdge / 500)
        scrollOuter(by: delta * strength)
    }

    /// Moves the enclosing card list by a wheel delta, clamped to its bounds.
    private func scrollOuter(by delta: CGFloat) {
        var view = superview
        while let candidate = view, !(candidate is NSScrollView) { view = candidate.superview }
        guard let outer = view as? NSScrollView else { return }
        let clip = outer.contentView
        var origin = clip.bounds.origin
        origin.y -= delta
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: constrained)
        outer.reflectScrolledClipView(clip)
    }
}

/// SwiftUI rows inside a `ContainedScrollView`, `height` tall, opened at the bottom, with the same wheel
/// hand-off as a run's output and the edge fades. For the Earlier list. The height is the caller's to compute
/// (its rows are one line each): measured from AppKit it arrived a run loop late, and the outer list, having
/// just scrolled to its end, was thrown back to the top by the size change.
struct ContainedList<Content: View>: View {
    let height: CGFloat
    var fade: CGFloat = 20
    @ViewBuilder let content: () -> Content
    @State private var moreAbove = false
    @State private var moreBelow = false
    /// The fades take their first state as they are, without fading in: a list opening scrolled to its end should
    /// show its top fade at once, not draw the eye to it. Only scrolling after that animates them.
    @State private var settled = false

    var body: some View {
        HostedScroll(content: content(),
                     moreAbove: Binding(get: { moreAbove }, set: { value in quietly { moreAbove = value } }),
                     moreBelow: Binding(get: { moreBelow }, set: { value in quietly { moreBelow = value } }))
            .frame(height: height)
            .mask(EdgeFadeMask(above: moreAbove, below: moreBelow, fade: fade))
            .task { try? await Task.sleep(for: .milliseconds(400)); settled = true }
    }

    /// Without animation until the list has settled.
    private func quietly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = !settled
        withTransaction(transaction, change)
    }
}

private struct HostedScroll<Content: View>: NSViewRepresentable {
    let content: Content
    @Binding var moreAbove: Bool
    @Binding var moreBelow: Bool

    /// Flipped, so y grows downward like the text view and `ContainedScrollView`'s edge tests hold; the hosting
    /// view sits inside it (NSHostingView's own flippedness cannot be overridden).
    final class Document: NSView {
        override var isFlipped: Bool { true }
        var hosting: NSHostingView<Content>? { subviews.first as? NSHostingView<Content> }
    }

    /// The inbox panel never becomes key, so its first click must count, as it does for the panel's own view.
    final class Hosting: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    final class Coordinator {
        var observer: Any?
        var stuckToBottom = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ContainedScrollView {
        let scroll = ContainedScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .mini
        scroll.verticalScrollElasticity = .none
        let document = Document()
        let hosting = Hosting(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize] // the rows are one line each, so height needs no width
        document.addSubview(hosting)
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll] _ in
            guard let scroll else { return }
            report(scroll, context.coordinator)
        }
        return scroll
    }

    func updateNSView(_ scroll: ContainedScrollView, context: Context) {
        guard let document = scroll.documentView as? Document, let hosting = document.hosting else { return }
        hosting.rootView = content
        let width = scroll.contentView.bounds.width > 0 ? scroll.contentView.bounds.width : scroll.bounds.width
        hosting.layoutSubtreeIfNeeded()
        let height = max(0, hosting.intrinsicContentSize.height)
        if document.frame.size != NSSize(width: width, height: height) {
            document.frame = NSRect(x: 0, y: 0, width: width, height: height)
            hosting.frame = document.bounds
        }
        // New rows arrive at the bottom; stay there unless the list was scrolled away from it.
        if context.coordinator.stuckToBottom {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        DispatchQueue.main.async { report(scroll, context.coordinator) }
    }

    private func report(_ scroll: ContainedScrollView, _ coordinator: Coordinator) {
        guard let document = scroll.documentView as? Document else { return }
        // The clip's width is only known once the scroll view is laid out, after the last update: follow it here.
        let width = scroll.contentView.bounds.width
        if width > 0, document.frame.width != width {
            document.frame.size.width = width
            document.hosting?.frame = document.bounds
        }
        let visible = scroll.contentView.bounds
        let above = visible.minY > 1
        let below = visible.maxY < document.frame.height - 1
        coordinator.stuckToBottom = !below
        if moreAbove != above { moreAbove = above }
        if moreBelow != below { moreBelow = below }
    }
}
