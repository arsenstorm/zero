import AppKit
import Observation
import SwiftUI
import ZeroCore

/// The active card sits on the bar's centre line. Half a panel of padding above and below the list lets any card
/// be scrolled to the centre, including the first and last.
struct InboxView: View {
    @Bindable var controller: InboxController
    @FocusState private var focus: String?
    /// Edge scrolling for the agent view; the ask list still centres by id through the reader.
    @State private var position = ScrollPosition()
    /// The stack's top within the bar's frame, kept while an opening grows it downward.
    @State private var heldTop: CGFloat = 0
    /// The bar's height as the workspaces' view opened: switching workspace changes the bar's (its tasks), and the
    /// view, laid out by it, moved with each switch. Held while it's open.
    @State private var barForWorkspaces: CGFloat?
    private var bar: CGFloat { barForWorkspaces ?? controller.barHeight }
    /// An agent's conversation stays at its end, its composer on the bar's centre line; the inbox and the
    /// new-agent composer simply centre on the bar. So the composer, or the empty inbox, is always in one place.
    private var pinsBottom: Bool { controller.agentFilter != nil }
    /// Each view starts from a fresh scroll position at its end: reusing the last view's carried its offset into
    /// the next, which showed it low for a moment before it settled.
    private var viewKey: String {
        controller.workspacesOpen ? "+workspaces" : controller.newAgentOpen ? "+new" : (controller.agentFilter ?? "inbox")
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                keptAtEnd(ScrollView(.vertical, showsIndicators: false) { cardStack(height: geo.size.height) })
                    .onChange(of: controller.cards.map(\.id)) { _, _ in cardsChanged(proxy) }
                    // Content dissolves into the edges instead of being sliced by them.
                    .softEdges(top: 40, bottom: 40)
                    .onAppear { center(proxy) }
                    .onChange(of: viewKey) { _, _ in
                        position = ScrollPosition(edge: pinsBottom ? .bottom : .top)
                        center(proxy)
                    }
                    .onChange(of: controller.scrollRequest) { scrollRequested(proxy) }
                    .onChange(of: controller.selected.flatMap { controller.store.ask($0)?.state }) { _, state in
                        if let state, state.isFinal, let id = controller.selected { controller.scheduleAdvance(after: id) }
                    }
            }
        }
        .frame(width: 380)
        .onChange(of: controller.workspacesOpen, initial: true) { _, open in barForWorkspaces = open ? controller.barHeight : nil }
        .onChange(of: controller.focusedReply) { _, id in focus = id }
        // The composers are text views outside SwiftUI's focus system: its nil for them is not a blur.
        .onChange(of: focus) { _, id in
            if id != nil || !(controller.focusedReply.map(InboxController.isComposerKey) ?? false) { controller.focusedReply = id }
        }
    }

    /// The new-agent composer, an agent's timeline, or the inbox's cards, on one surface; `height` is the panel's.
    private func cardStack(height: CGFloat) -> some View {
        VStack(spacing: 10) {
            if controller.workspacesOpen, let workspace = controller.workspace {
                WorkspacesCard(workspace: workspace)
            } else if controller.newAgentOpen {
                ComposerCard(controller: controller, focus: $focus, mode: .newAgent)
            } else if controller.agentFilter != nil {
                AgentTimeline(controller: controller, focus: $focus)
            } else {
                askCards
            }
        }
        // One frosted surface under the stack, so the gaps between cards never show raw desktop. Its
        // inset matches the 10 pt between cards, so the edges read as one more gap; concentric with the cards' 18.
        .padding(10)
        // Thin, not ultra-thin: in light mode the thinnest material took whatever colour sat behind it.
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            controller.surfaceFrame = $0
        }
        // The composer, or the empty inbox, sits on the bar's centre line in every view, whatever is above
        // it, so the eye never has to find it.
        // A conversation ends with its composer centred on the bar, where the new-agent composer and the
        // empty inbox sit; the 10 pt is the surface's inset around the composer.
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named("stack")).minY
        } action: { top in
            if !controller.holdTop { heldTop = top }
        }
        .padding(.bottom, pinsBottom ? max(0, bar / 2 - controller.composerHeight / 2 - 10) : 0)
        // Opening something in place: pinned at the top it had, so it grows downward only.
        .padding(.top, controller.holdTop ? heldTop : 0)
        .frame(minHeight: bar, alignment: controller.holdTop ? .top : (pinsBottom ? .bottom : .center))
        .coordinateSpace(name: "stack")
        // Padding equal to the gap between panel edge and bar edge: scrolled to either end, the list
        // stops level with the bar's top or bottom, and a list no taller than the bar cannot scroll.
        .padding(.vertical, max(0, (height - bar) / 2))
        // Outermost on purpose: the stack and its surface grow together when a card joins.
        // A view switch is excluded: that is a cut.
        .animation(
            controller.switching ? nil : Motion.animation(Motion.enter),
            value: controller.cards.map { "\($0.id)/\($0.state.rawValue)" })
    }

    @ViewBuilder private var askCards: some View {
        ForEach(controller.cards) { ask in
            CardView(ask: ask, controller: controller, focus: $focus)
                .id(ask.id)
                // The fade comes from the stack's animation, which a view switch turns off.
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
        }
        if controller.cards.isEmpty { QuietCard(controller: controller) }
    }

    /// An agent's conversation sits at its end and stays there as it grows or the Earlier list sizes
    /// itself. The ask list keeps centring its card.
    private func keptAtEnd(_ scroll: some View) -> some View {
        scroll
            .scrollPosition($position)
            .defaultScrollAnchor(pinsBottom ? .bottom : nil)
            .defaultScrollAnchor(pinsBottom && !controller.holdTop ? .bottom : nil, for: .sizeChanges)
            // A panel resize (another screen, say) drops the offset to the top; the conversation goes back to its end.
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.containerSize.height
            } action: { _, _ in
                if pinsBottom { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: controller.barHeight) { _, _ in if pinsBottom { position.scrollTo(edge: .bottom) } }
            // Content that settles its height after the switch (a card measuring itself, text laying out) would
            // otherwise leave the conversation short of its end until something else redrew it: pinned again
            // whenever its height changes, so the composer stays on the bar's bottom line throughout.
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height
            } action: { _, _ in
                if pinsBottom && !controller.holdTop { position.scrollTo(edge: .bottom) }
            }
    }

    /// A new card pushes the stack: re-centre so the cards above drift up as it takes its place.
    private func cardsChanged(_ proxy: ScrollViewProxy) {
        controller.holdTop = false
        controller.ensureSelection()
        if controller.switching || Motion.reduced {
            center(proxy)
        } else {
            withAnimation(Motion.enter) { center(proxy) }
        }
    }

    private func scrollRequested(_ proxy: ScrollViewProxy) {
        if controller.scrollAnimated && !Motion.reduced {
            withAnimation(Motion.enter) { center(proxy) }
        } else {
            center(proxy)
        }
    }

    /// The selected card goes to the bar's centre line, as far as the scroll limits allow; an agent's
    /// conversation goes to its end, the composer on the bar's bottom line.
    private func center(_ proxy: ScrollViewProxy) {
        if pinsBottom {
            // To the end, now and again once the conversation just switched in has been laid out. (Scrolling
            // to an id at the end through the reader never moved it; the edge request does.)
            position.scrollTo(edge: .bottom)
            DispatchQueue.main.async { position.scrollTo(edge: .bottom) }
            return
        }
        guard let id = controller.selected else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

/// The bar's workspaces, in the inbox's pane: each with its icon, the one shown ticked; a click shows that one, here and
/// in the window.
private struct WorkspacesCard: View {
    let workspace: Workspace
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workspaces").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
            ForEach(workspace.workspaces, id: \.id) { space in
                Button {
                    workspace.current = space.id
                } label: {
                    HStack(spacing: 10) {
                        WorkspaceGlyph(glyph: space.glyph, size: 15).foregroundStyle(.secondary).frame(width: 18)
                        Text(space.name).font(SelectorView.menuFont).lineLimit(1)
                        Spacer(minLength: 8)
                        NucleoIcon("check", size: 13).foregroundStyle(Theme.menuHot).opacity(space.id == workspace.current ? 1 : 0)
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(hovered == space.id ? Theme.menuHover : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in if inside { hovered = space.id } else if hovered == space.id { hovered = nil } }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
