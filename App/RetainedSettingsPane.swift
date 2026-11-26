import SwiftUI

/// The split view always sees the same representable, including when a search has no results.
struct SettingsDetail<Content: View>: NSViewRepresentable {
    let section: SettingsSection?
    let hits: SettingsSearchHits
    @ViewBuilder let content: (SettingsSection) -> Content

    func makeNSView(context: Context) -> SettingsPaneContainer { SettingsPaneContainer() }

    func updateNSView(_ container: SettingsPaneContainer, context: Context) {
        let inputs = SettingsPaneContainer.Inputs(
            hits: hits, locale: context.environment.locale, direction: context.environment.layoutDirection,
            scheme: context.environment.colorScheme)
        container.update(section: section, inputs: inputs) { section, scopedHits in
            let sectionView = content(section)
            // An NSHostingView can center a root larger than its frame even with sizingOptions disabled.
            // Let the viewport accept the host's bounds and propose that exact size to the Form or ScrollView.
            let pane = GeometryReader { viewport in
                sectionView.frame(width: viewport.size.width, height: viewport.size.height)
            }
            .modifier(SettingsSearchHighlights())
            .environment(\.settingsSearchHits, scopedHits)
            .environment(\.locale, inputs.locale)
            .environment(\.layoutDirection, inputs.direction)
            .environment(\.colorScheme, inputs.scheme)
            #if DEBUG
                return AnyView(pane.modifier(SnapshotSettingsSurface(sidebar: false)).snapshotControlAppearance())
            #else
                return AnyView(pane)
            #endif
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsPaneContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class SettingsPaneContainer: NSView {
    struct Inputs: Equatable {
        var hits: SettingsSearchHits
        let locale: Locale
        let direction: LayoutDirection
        let scheme: ColorScheme
    }

    private enum Slot {
        case form, shortcuts, toolbar
        init(_ section: SettingsSection) {
            switch section {
            case .keyboardShortcuts: self = .shortcuts
            case .toolbarArrangement: self = .toolbar
            default: self = .form
            }
        }
    }

    private struct Page {
        let view: NSHostingView<AnyView>
        let section: SettingsSection
        let inputs: Inputs
        let reveal: SettingsSearchVisit?
    }

    private var pages: [Slot: Page] = [:]
    private var visible: Slot?

    func update(section: SettingsSection?, inputs: Inputs, content: (SettingsSection, SettingsSearchHits) -> AnyView) {
        let slot = section.map { Slot($0) }
        if visible != slot, let visible, let previous = pages[visible] {
            previous.reveal?.cancel()
            if let window, ownsFocus(in: window, host: previous.view) { window.makeFirstResponder(nil) }
            previous.view.isHidden = true
            previous.view.setAccessibilityHidden(true)
        }
        visible = slot
        guard let section, let slot else { return }

        // Keep one ordinary Form and one host per visited editor. Changing selection never reorders these siblings.
        let existing = pages[slot]
        if let existing, existing.section == section, existing.inputs == inputs, existing.reveal?.isCurrent != false {
            show(existing.view)
            return
        }
        existing?.reveal?.cancel()
        var hits = inputs.hits
        if !hits.anchors.isEmpty { hits.visit = SettingsSearchVisit() }
        let root = content(section, hits)
        let host: NSHostingView<AnyView>
        if let existing {
            host = existing.view
            host.rootView = root
        } else {
            host = NSHostingView(rootView: root)
            host.sizingOptions = []
            // The container sets frames. Surplus space belongs to the margins, even when a hidden host is wider.
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.maxXMargin, .maxYMargin]
            host.frame = bounds
            addSubview(host)
        }
        pages[slot] = Page(view: host, section: section, inputs: inputs, reveal: hits.visit)
        show(host)
    }

    private func show(_ view: NSView) {
        if view.frame != bounds { view.frame = bounds }
        if view.isHidden {
            view.isHidden = false
            view.setAccessibilityHidden(false)
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        // This container owns all child frames. Hidden hosts keep their last laid-out size during a live resize.
        fitVisibleHost()
    }

    override func layout() {
        super.layout()
        // SwiftUI can also assign the container's final bounds in an AppKit constraint-based layout pass.
        fitVisibleHost()
    }

    private func fitVisibleHost() {
        if let visible, let host = pages[visible]?.view, host.frame != bounds { host.frame = bounds }
    }

    private func ownsFocus(in window: NSWindow, host: NSView) -> Bool {
        // SwiftUI can put a responder ahead of the view, and text fields borrow the window's field editor.
        var current = window.firstResponder
        while let responder = current, responder !== window {
            if let view = responder as? NSView, view.isDescendant(of: host) { return true }
            if let field = (responder as? NSTextView)?.delegate as? NSView, field.isDescendant(of: host) { return true }
            current = responder.nextResponder
        }
        return false
    }
}
