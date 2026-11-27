import SurimonoCore
import SwiftUI

/// Revoking a reveal must not update the hidden form just to cancel its pending scroll.
final class SettingsSearchVisit: Equatable {
    private(set) var isCurrent = true
    func cancel() { isCurrent = false }
    nonisolated static func == (lhs: SettingsSearchVisit, rhs: SettingsSearchVisit) -> Bool { lhs === rhs }
}

struct SettingsSearchHits: Equatable {
    var query = ""
    var anchors: [String] = []
    var format: DocumentFormat?
    var visit: SettingsSearchVisit?
    var canReveal: Bool { visit?.isCurrent != false }

    func scrollTarget(excluding fixedAnchors: Set<String>) -> String? {
        guard let first = anchors.first, !fixedAnchors.contains(first) else { return nil }
        return first
    }
}

// Read the last layout when a query changes. Scrolling by hand must not trigger another reveal.
final class SettingsRowFrames {
    var viewport = CGRect.null
    var scroll: ScrollGeometry?
    var rows: [String: CGRect] = [:]
    var inspectDocumentHeader: (([Text.LayoutKey.AnchoredLayout]) -> Void)?

    func fullyShows(_ anchor: String) -> Bool {
        guard let row = rows[anchor], !row.isEmpty, !viewport.isEmpty else { return false }
        // The negative top content margin exposes part of the scroll view above the form's layout frame.
        let top = min(viewport.minY, viewport.maxY - (scroll?.containerSize.height ?? 0))
        return row.minY >= top && row.maxY <= viewport.maxY
    }

    func bottomRoom(toReveal anchor: String) -> CGFloat {
        guard let row = rows[anchor], let scroll else { return viewport.height * 2 / 3 }
        let targetY = viewport.minY + viewport.height / 3
        let remaining = scroll.contentSize.height - scroll.visibleRect.maxY + scroll.contentInsets.bottom
        return max(0, row.minY - targetY - remaining)
    }
}

extension EnvironmentValues {
    @Entry var settingsSearchHits = SettingsSearchHits()
    @Entry var settingsRowVerticalInset: CGFloat = 0
    @Entry var highlightedSettings: Set<String> = []
    @Entry var settingsRowFrames: SettingsRowFrames?
}

/// Matches can be anywhere in the pane, including controls outside the scrolling viewport.
struct SettingsSearchHighlights: ViewModifier {
    @Environment(\.settingsSearchHits) private var hits
    @State private var highlighted: Set<String> = []

    func body(content: Content) -> some View {
        content
            .environment(\.highlightedSettings, highlighted)
            .task(id: hits) {
                guard hits.canReveal else { return }
                highlighted = Set(hits.anchors)
                guard !highlighted.isEmpty else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, hits.canReveal else { return }
                withAnimation(.easeOut(duration: 0.25)) { highlighted = [] }
            }
    }
}

struct SettingsSearchReveal: ViewModifier {
    let proxy: ScrollViewProxy
    var isForm = true
    var fixedAnchors: Set<String> = []
    @Environment(\.settingsSearchHits) private var hits
    @Environment(\.settingsRowFrames) private var providedFrames
    @State private var localFrames = SettingsRowFrames()
    @State private var bottomRoom: CGFloat?

    func body(content: Content) -> some View {
        let frames = providedFrames ?? localFrames
        content
            .environment(\.settingsRowFrames, frames)
            // Grouped forms leave ten points above and below each row's content on macOS.
            .environment(\.settingsRowVerticalInset, isForm ? 10 : 0)
            .contentMargins(.bottom, hits.anchors.isEmpty ? nil : bottomRoom, for: .scrollContent)
            .onScrollGeometryChange(for: ScrollGeometry.self) {
                $0
            } action: { _, geometry in
                frames.scroll = geometry
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                frames.viewport = $0
            }
            .task(id: hits) {
                guard hits.canReveal else { return }
                guard let first = hits.scrollTarget(excluding: fixedAnchors) else {
                    if hits.anchors.isEmpty { bottomRoom = nil }
                    return
                }
                // The Form needs a layout pass when searching takes the reader to another section.
                await Task.yield()
                guard !Task.isCancelled, hits.canReveal else { return }
                if !frames.fullyShows(first) {
                    // A match near the end needs room below it to reach the requested position.
                    bottomRoom = frames.bottomRoom(toReveal: first)
                    await Task.yield()
                    guard !Task.isCancelled, hits.canReveal else { return }
                    proxy.scrollTo(first, anchor: UnitPoint(x: 0.5, y: 1.0 / 3))
                }
            }
    }
}

private struct SettingsSearchHighlight: ViewModifier {
    let anchor: String
    let fillsRow: Bool
    let additionalHighlights: [String]
    @Environment(\.settingsRowVerticalInset) private var verticalInset
    @Environment(\.highlightedSettings) private var highlighted
    @Environment(\.settingsRowFrames) private var frames

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: fillsRow ? .infinity : nil, alignment: .leading)
            .background {
                if highlighted.contains(anchor) || !highlighted.isDisjoint(with: additionalHighlights) {
                    CornerRole.control.shape
                        .fill(
                            DisplayAccessibility.shared.options.fill(
                                .accentColor, opacity: 0.12, over: PrintPalette.raised)
                        )
                        .overlay(alignment: .leading) {
                            if DisplayAccessibility.shared.options.increasedContrast {
                                Rectangle().fill(PrintPalette.ink2).frame(width: 2)
                            }
                        }
                        .padding(.vertical, -verticalInset)
                }
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                frames?.rows[anchor] = $0.insetBy(dx: 0, dy: -verticalInset)
            }
            .onDisappear { frames?.rows.removeValue(forKey: anchor) }
            .id(anchor)
    }
}

extension View {
    func settingSearchRow(_ anchor: String, fillsRow: Bool = true, additionalHighlights: [String] = []) -> some View {
        modifier(
            SettingsSearchHighlight(anchor: anchor, fillsRow: fillsRow, additionalHighlights: additionalHighlights))
    }
}
