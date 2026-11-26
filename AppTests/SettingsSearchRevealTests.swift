import SurimonoCore
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

    @Test("Org の変更だけを表示中は、検索した行が未変更のときだけ絞り込みを外し、末尾の行全体まで送る")
    func changedOnlySearch() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        var defaults = OrgReadingDefaults.surimono
        defaults.scripts = .all
        preferences.setOrgDefaults(defaults)

        let locale = Locale(identifier: "en")
        let bundle = try #require(Bundle.main.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let search = FilterSearch()
        let screen = OrgReadingTestWindow(width: 560, height: 320) {
            FilteredPane(preferences: preferences, search: search).environment(\.locale, locale)
        }
        defer { screen.window.close() }
        let frames = search.frames
        let changed = ReadingSettingID.scripts.label.key
        let last = ReadingSettingID.archived.label.key
        func enter(_ anchor: String, canReveal: Bool) async throws {
            func translate(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
            let query = translate(anchor)
            let results = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: translate)
            let anchors = results.rows.filter { $0.format == .org }.map(\.anchor)
            try #require(anchors.first == anchor)
            let visit = SettingsSearchVisit()
            if !canReveal { visit.cancel() }
            search.hits = SettingsSearchHits(query: query, anchors: anchors, visit: visit)
            try await screen.wait("Expected query \(query), canReveal=\(canReveal)") {
                search.received?.query == query && search.received?.canReveal == canReveal
            }
        }
        let rowKeys = Set(OrgReadingGroup.allCases.flatMap(\.settings).map { $0.label.key })
        func shown() -> Set<String> { rowKeys.intersection(frames.rows.keys) }
        try await screen.wait("Only the changed row should be present: \(frames.rows) viewport=\(frames.viewport)") {
            frames.fullyShows(changed) && shown() == [changed] && frames.scroll != nil
        }
        let origin = frames.scroll?.visibleRect.origin
        try await enter(last, canReveal: false)
        #expect(shown() == [changed])
        #expect(frames.scroll?.visibleRect.origin == origin)

        try await enter(changed, canReveal: true)
        #expect(shown() == [changed])
        #expect(frames.fullyShows(changed))

        try await enter(last, canReveal: true)
        try await screen.wait(
            "Expected \(last) in \(frames.viewport): row=\(String(describing: frames.rows[last])) scroll=\(String(describing: frames.scroll))"
        ) {
            guard let row = frames.rows[last], let scroll = frames.scroll else { return false }
            return row.height > 0 && frames.viewport.contains(row) && scroll.visibleRect.minY > (origin?.y ?? 0)
        }
    }

    @MainActor @Observable fileprivate final class FilterSearch {
        var hits = SettingsSearchHits()
        let frames = SettingsRowFrames()
        @ObservationIgnored var received: SettingsSearchHits?
    }

    private struct FilteredPane: View {
        let preferences: AppPreferences
        let search: FilterSearch

        var body: some View {
            SettingsDetail(section: .documents, hits: search.hits) { _ in
                OrgReadingDefaultsPane(preferences: preferences, filter: .init(isOn: true))
                    .overlay { ReceivedQuery(search: search) }
                    .environment(\.settingsRowFrames, search.frames)
                    .transformEnvironment(\.settingsSearchHits) { hits in
                        // The container grants a fresh visit when it shows a pane. Exercise a revoked visit too.
                        if !search.hits.canReveal { hits.visit = search.hits.visit }
                    }
            }
        }
    }

    private struct ReceivedQuery: View {
        let search: FilterSearch
        @Environment(\.settingsSearchHits) private var hits

        var body: some View {
            Color.clear.task(id: hits) {
                await Task.yield()
                if !Task.isCancelled { search.received = hits }
            }
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
            SettingsDetail(section: .documents, hits: search.hits) { _ in
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
