import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct SettingsSearchRevealTests {
    @Test("フッターにかかる行は未表示、一行全体が一覧に収まった位置で表示済みと判定する")
    func formViewport() {
        let frames = SettingsRowFrames()
        frames.viewport = CGRect(x: 0, y: 0, width: 560, height: 440)
        frames.rows["target"] = CGRect(x: 20, y: 430, width: 520, height: 40)
        #expect(!frames.fullyShows("target"))
        frames.rows["target"] = CGRect(x: 20, y: 400, width: 520, height: 40)
        #expect(frames.fullyShows("target"))
    }

    @Test("固定フッターが先頭で一致したら一覧の行も一致していてもスクロールを要求しない")
    func fixedActions() {
        let defaults = OrgReadingDefaultsPane.defaults(.emacs)
        for action in ["Use Emacs Defaults…", "Reset to Defaults…"] {
            let hits = SettingsSearchHits(query: action, anchors: [action, "Heading Numbers"])
            #expect(hits.scrollTarget(excluding: defaults.fixedSearchAnchors) == nil)
            let rowFirst = SettingsSearchHits(query: action, anchors: ["Heading Numbers", action])
            #expect(rowFirst.scrollTarget(excluding: defaults.fixedSearchAnchors) == "Heading Numbers")
        }
        let many = ReadingDefaults(
            builtIn: 0,
            alternatives: [
                .init(values: 1, status: "One", action: "Use One…", confirmation: "Use One", question: "Use One?"),
                .init(values: 2, status: "Two", action: "Use Two…", confirmation: "Use Two", question: "Use Two?"),
            ], current: 0)
        #expect(many.fixedSearchAnchors == ["Other Defaults", "Use One…", "Use Two…", "Reset to Defaults…"])
    }

    @Test("一覧の下端とフッターの間に隠れた行は全体を表示し、固定操作の検索では位置を保つ")
    func clippedRowAndFooter() async throws {
        let search = Search()
        let screen = OrgReadingTestWindow(width: 560, height: 320) { Pane(search: search) }
        defer { screen.window.close() }

        // Window coordinates grow upwards. Include the same ten-point row insets as the grouped Form.
        func clippedRow() -> String? {
            let panelBottom = screen.host.convert(screen.host.bounds, to: nil).minY
            return search.rows.keys.sorted().first { key in
                guard let row = search.rows[key], row.window === screen.window, !row.bounds.isEmpty,
                    let clip = row.enclosingScrollView?.contentView
                else { return false }
                let frame = row.convert(row.bounds, to: nil).insetBy(dx: 0, dy: -10)
                let viewport = clip.convert(clip.bounds, to: nil)
                return frame.minY >= panelBottom && frame.minY < viewport.minY && frame.maxY < viewport.maxY
            }
        }
        try await screen.wait("Expected a row clipped by the fixed footer") { clippedRow() != nil }
        let target = try #require(clippedRow())
        search.anchor = target
        try await screen.wait("Expected the whole row (\(target)) inside the Form") {
            guard let row = search.rows[target], row.window === screen.window,
                let clip = row.enclosingScrollView?.contentView
            else { return false }
            return clip.bounds.contains(clip.convert(row.bounds, from: row).insetBy(dx: 0, dy: -10))
        }

        let clip = try #require(search.rows[target]?.enclosingScrollView?.contentView)
        let position = clip.bounds.origin
        for action in ["Use Emacs Defaults…", "Reset to Defaults…"] {
            search.anchor = action
            try await screen.wait("Expected highlight outside the Form") { search.highlighted == [action] }
            try await screen.wait("Expected search reveal to finish") { search.highlighted.isEmpty }
            let currentClip = try #require(search.rows[target]?.enclosingScrollView?.contentView)
            #expect(currentClip.window === screen.window && currentClip.bounds.origin == position)
        }
    }

    @MainActor @Observable fileprivate final class Search {
        var anchor = ""
        var hits: SettingsSearchHits { SettingsSearchHits(query: anchor, anchors: anchor.isEmpty ? [] : [anchor]) }
        @ObservationIgnored var rows: [String: NSView] = [:]
        @ObservationIgnored var highlighted: Set<String> = []
    }

    private struct Pane: View {
        let search: Search

        var body: some View {
            SettingsDetail(section: .org, hits: search.hits) { _ in
                ReadingDefaultsControls(
                    defaults: OrgReadingDefaultsPane.defaults(.surimono),
                    resetQuestion: "Reset Org settings to defaults?",
                    differences: OrgReadingDefaultsPane.differences, apply: { _ in },
                    header: { Text("Org") },
                    rows: {
                        VStack(spacing: 2) {
                            ForEach(0..<40, id: \.self) { index in
                                let key = "row-\(index)"
                                Text(verbatim: key).frame(height: 18)
                                    .background { RowProbe { search.rows[key] = $0 } }
                                    .settingSearchRow(key)
                            }
                        }
                    }
                )
                .overlay { HighlightProbe(search: search) }
            }
        }
    }

    private struct RowProbe: NSViewRepresentable {
        let record: (NSView) -> Void
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) { record(view) }
    }

    private struct HighlightProbe: View {
        let search: Search
        @Environment(\.highlightedSettings) var highlighted

        var body: some View {
            Color.clear.onChange(of: highlighted, initial: true) { search.highlighted = highlighted }
        }
    }
}
