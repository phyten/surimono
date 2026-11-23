import PDFKit
import SurimonoCore
import SwiftUI

/// The measuring copy draws only this rail; input and preview belong to the visible band.
struct PageScrubberRail: View {
    let current: CGFloat
    let hover: CGFloat?
    let ticks: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            context.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 2)), with: .color(PrintPalette.line2))
            for x in ticks {
                context.fill(Path(CGRect(x: x - 0.5, y: y - 3, width: 1, height: 6)), with: .color(PrintPalette.ink2))
            }
            let x = max(3.5, min(size.width - 3.5, current * size.width))
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(.primary))
            if let hover {
                context.fill(
                    Path(ellipseIn: PageTrack.hoverMark(fraction: hover, size: size)), with: .color(PrintPalette.ai))
            }
        }
        .frame(height: ViewerWindow.bandHeight)
    }
}

struct PageScrubber: View {
    let model: DocumentViewModel
    @FocusState private var focused: Bool
    @AccessibilityFocusState(for: .voiceOver) private var voiceOver: Bool

    var body: some View {
        let session = model.scrubber
        let track = model.pageTrack
        let page = model.logicalReadingPage
        let sections = model.scrubSections
        let ticks = track.ticks(
            chapters: sections.compactMap { $0.title == nil ? nil : $0.pages.lowerBound }, width: session.frame.width)
        let value = PageIndicator.text(pages: [page + 1], pageCount: model.pageCount)
        ScrubMarks(session: session, current: track.fraction(for: page), ticks: ticks)
            // The input area spans the band's full height, where the system ring would be cut off by the window's
            // edge, so the ring is drawn around the track instead.
            .overlay { if focused { ScrubFocusRing() } }
            .overlay { ScrubPointer(model: model) }
            // Like a slider, the track takes keyboard focus only through keyboard navigation: a ring after every
            // click would be noise in the band. A press still ends field editing (see `ScrubPointer`).
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: focused) { _, value in session.keyboardFocus = value }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { press in
                let responder = model.window?.firstResponder
                guard focused, model.window?.attachedSheet == nil,
                    (responder as? NSTextView)?.isEditable != true,
                    (responder as? NSTextInputClient)?.hasMarkedText() != true,
                    press.modifiers.isDisjoint(with: [.control, .command, .shift, .option]),
                    let key = ShortcutMenuKey.named(String(press.key.character))
                else { return .ignored }
                return model.handleScrubKey(key) ? .handled : .ignored
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page")
            .accessibilityValue(
                Text(
                    verbatim: [value, sections.first(where: { $0.pages.contains(page) })?.title].compactMap { $0 }
                        .joined(separator: ", "))
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.scrubToPage(model.logicalReadingPage + 1)
                case .decrement: model.scrubToPage(model.logicalReadingPage - 1)
                @unknown default: break
                }
            }
            .accessibilityFocused($voiceOver)
            .onChange(of: voiceOver) { _, value in session.voiceOverFocus = value }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(BandAnchors.coordinateSpace))
            } action: { frame in
                session.frame = frame
            }
            .onDisappear {
                session.cancel()
                session.keyboardFocus = false
                session.voiceOverFocus = false
                session.frame = .zero
            }
    }
}

/// Isolate fast pointer updates from the chapter lookup and key/accessibility configuration.
private struct ScrubMarks: View {
    let session: PageScrubSession
    let current: CGFloat
    let ticks: [CGFloat]
    var body: some View { PageScrubberRail(current: current, hover: session.fraction, ticks: ticks) }
}

/// AppKit sends dragged/up to the view that received down, including outside its tracking area.
private struct ScrubFocusRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            .frame(height: 28)
            .allowsHitTesting(false)
    }
}

struct ScrubPointer: NSViewRepresentable {
    let model: DocumentViewModel

    func makeNSView(context: Context) -> Input { Input() }
    func updateNSView(_ view: Input, context: Context) { view.model = model }

    final class Input: NSView {
        weak var model: DocumentViewModel?
        private var area: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(
                rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self, userInfo: nil)
            addTrackingArea(next)
            area = next
        }
        private func fraction(_ event: NSEvent) -> CGFloat {
            convert(event.locationInWindow, from: nil).x / max(1, bounds.width)
        }
        override func mouseEntered(with event: NSEvent) { model?.scrubber.point(fraction(event)) }
        override func mouseMoved(with event: NSEvent) { model?.scrubber.point(fraction(event)) }
        override func mouseExited(with event: NSEvent) { model?.scrubber.leave() }
        override func mouseDown(with event: NSEvent) {
            // End field editing synchronously, so that Escape during the drag reaches the scrubber, not the field. The
            // keys then go to the paper, as after a click on it: the window itself is no target for the arrows.
            if let window, let editor = window.firstResponder as? NSTextView, editor.isEditable {
                guard window.makeFirstResponder(nil) else { return }
                model?.paper.focus()
            }
            model?.scrubber.press(fraction(event))
        }
        override func mouseDragged(with event: NSEvent) {
            if model?.scrubber.dragging == true { model?.scrubber.point(fraction(event), immediately: true) }
        }
        override func mouseUp(with event: NSEvent) {
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            guard let model, let fraction = model.scrubber.release(fraction(event), inside: inside),
                let page = model.pageTrack.page(at: fraction)
            else { return }
            model.scrubToPage(page)
        }
    }
}

struct PageScrubPreview: View {
    let model: DocumentViewModel
    @Environment(\.displayScale) private var scale

    private var aspect: CGFloat {
        if let size = model.slideDeck?.size, size.height > 0 { return size.width / size.height }
        guard let first = model.result?.viewDocument.page(at: 0) else { return 0.707 }
        let size = first.bounds(for: .cropBox).size
        return first.rotation.isMultiple(of: 180) ? size.width / size.height : size.height / size.width
    }

    var body: some View {
        let session = model.scrubber
        let track = model.pageTrack
        let sections = model.scrubSections
        // Keep PDFKit and the document's render-settings comparison off the pointer update path.
        let ratio = aspect
        let generation = model.thumbnailGeneration
        return GeometryReader { proxy in
            if session.showsPreview, let fraction = session.fraction, let page = track.page(at: fraction),
                session.frame.width > 0
            {
                let available = CGSize(width: proxy.size.width - 24, height: session.frame.minY - 48)
                let size = PageTrack.previewPaper(aspect: ratio, available: available)
                let pointer = session.frame.minX + fraction * session.frame.width
                let center = PageTrack.previewCenter(pointer: pointer, width: size.width, window: proxy.size.width)
                let pixels = min(1024, max(32, Int(ceil(max(size.width, size.height) * scale / 32)) * 32))
                let request = generation.map { PageScrubImageKey(generation: $0, page: page, pixels: pixels) }
                VStack(spacing: 0) {
                    Color.white.overlay {
                        if let request, let loaded = session.bitmap, request == loaded.0 {
                            Image(decorative: loaded.1, scale: scale).resizable().scaledToFit()
                                #if DEBUG
                                    .id(request)
                                    .onAppear { model.scrubThumbnailReady?(request.generation, request.page) }
                                #endif
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    let chapter = sections.first(where: { $0.pages.contains(page) })?.title
                    Text(verbatim: PageTrack.previewCaption(page: page, chapter: chapter))
                        .monospacedDigit().font(.caption).lineLimit(1).padding(.horizontal, 3)
                        .frame(width: size.width, height: 20)
                }
                .paperOverlayBackground(nil)
                .overlay { Rectangle().strokeBorder(PrintPalette.previewEdge, lineWidth: 1) }
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .position(x: center, y: session.frame.minY - 6 - (size.height + 20) / 2)
                .task(id: request) {
                    let cache = request.flatMap { model.thumbnails(for: $0.generation) }
                    await session.load(request, from: cache)
                }
                Path { path in
                    path.move(to: CGPoint(x: pointer - 4, y: session.frame.minY - 6))
                    path.addLine(to: CGPoint(x: pointer + 4, y: session.frame.minY - 6))
                    path.addLine(to: CGPoint(x: pointer, y: session.frame.minY))
                    path.closeSubpath()
                }.fill(PrintPalette.raised)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
