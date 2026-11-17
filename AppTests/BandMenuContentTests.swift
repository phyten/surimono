import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BandMenuContentTests {
    private typealias ID = BandMenuContent.ID

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = BandTestDefaultsSuite()
        let preferences: AppPreferences
        var models: [DocumentViewModel] = []

        init() { preferences = AppPreferences(defaults: defaults.defaults) }

        func make(_ format: DocumentFormat, memory: Bool = false, bundle: Bool = false, issues: Bool = false) throws
            -> DocumentViewModel
        {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data: Data
            switch format {
            case .pdf: data = TestFixtures.textPDF(["First Chapter", "Second Chapter"])
            case .image: data = TestFixtures.png(red: 0.2)
            case .html: data = Data("<h1>First Chapter</h1><h1>Second Chapter</h1>".utf8)
            default: data = Data("# First Chapter\n\n# Second Chapter\n".utf8)
            }
            let url = directory.appendingPathComponent(UUID().uuidString + "." + (format == .html ? "html" : "fixture"))
            if !memory { try data.write(to: url) }
            var images: ImageBundleModel?
            if bundle {
                let second = directory.appendingPathComponent("second.png")
                try data.write(to: second)
                images = ImageBundleModel(urls: [url, second])
            }
            let renderer = DocumentRenderer(paginateWithResult: { _ in
                WebPaginator.Result(
                    document: try #require(
                        PDFDocument(data: TestFixtures.textPDF(["First Chapter", "Second Chapter"]))),
                    preparationResult: issues
                        ? #"{"previous":null,"issues":[{"id":"0","kind":"math","detail":"x"},{"id":"1","kind":"math","detail":"y"}]}"#
                        : #"{"previous":null,"issues":[]}"#)
            })
            let model = DocumentViewModel(
                data: data, fileURL: memory || bundle ? nil : url, format: format,
                preferences: preferences, library: UserLibrary(root: directory.appendingPathComponent("Library")),
                renderer: renderer, imageBundle: images,
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")),
                title: "Menu Fixture")
            model.isolateBandTestOutput()
            model.viewOptions.layout = .single
            models.append(model)
            return model
        }

        func cleanUp() {
            for model in models { model.stop() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func render(_ model: DocumentViewModel, outline: Bool = false) async throws {
        model.render()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if model.isUpToDate && !model.isRendering && (!outline || model.hasOutline) { return }
            await Task.yield()
        }
        Issue.record("組版または目次の準備が期限内に終わりませんでした")
        #expect(model.error == nil)
        #expect(model.isUpToDate)
    }

    /// Literal expectations are independent of the production group's catalog.
    private func verify(_ model: DocumentViewModel, _ expected: [[ID]]) throws {
        let content = BandMenuContent(model: model)
        #expect(content.groups.map { $0.entries.map(\.id) } == expected)
        let entries = content.groups.flatMap(\.entries)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(content.groups.allSatisfy { !$0.entries.isEmpty })
        #expect(content.rows.first == .header(content.header))
        #expect(content.rows.last != .divider)
        #expect(content.rows.filter { $0 == .divider }.count == expected.count)
        #expect(!zip(content.rows, content.rows.dropFirst()).contains { $0 == .divider && $1 == .divider })
        #expect(!content.header.contains(model.fileURL?.path ?? "impossible-path-marker"))
    }

    private let markdown: [[ID]] = [
        [.outline, .previousPage, .nextPage, .documentInfo],
        [.layout, .transition],
        [.readingDirection, .scrollDirection, .selectText],
        [.style, .paperOrientation, .paperSeries, .margins],
        [.floatOnTop, .alwaysShowToolbar, .viewOptions],
        [.printSettings, .print],
        [.keysAndGestures],
    ]

    /// Exercise both actual plan construction and the index after each preference change.
    private func verifyArrangements(_ model: DocumentViewModel, expected: [[ID]]) throws {
        let original = BandMenuContent(model: model).rows
        var allUnused = BandArrangementVariants()
        for mode in MenuArrangement.allCases {
            var arrangement = BandArrangement.standard(for: mode)
            for part in BandLayout.Item.allCases where part != .print {
                arrangement = try arrangement.moving(part, to: .unused, for: mode)
            }
            if mode == .top { allUnused.top = arrangement } else { allUnused.split = arrangement }
        }
        let custom = try #require(DebugSnapshot.bandArrangementFixture(named: "reordered"))
        let customized = try #require(custom.sets.first)
        for mode in MenuArrangement.allCases {
            model.preferences.menuArrangement = mode
            for layouts in [BandArrangementVariants(), customized.layouts, allUnused] {
                if layouts == BandArrangementVariants() {
                    try model.preferences.selectBandArrangement(.standard)
                } else {
                    try model.preferences.saveBandArrangement(
                        BandArrangementSet(name: UUID().uuidString, layouts: layouts))
                }
                for width: CGFloat in [2000, 140] {
                    let menu = OverlayMenuState()
                    menu.bandWidth = width
                    menu.bandWidths = [.name: 120, .more: 24]
                    for part in BandLayout.Item.allCases {
                        menu.bandWidths[.item(part, .full)] = 90
                        menu.bandWidths[.item(part, .compact)] = 30
                    }
                    let plan = BandPlans(model: model, menu: menu)
                    #expect(plan.top.minimumWidth > 0)
                    try verify(model, expected)
                    #expect(BandMenuContent(model: model).rows == original)
                }
            }
        }
    }

    @Test("見出しと複数ページの索引は配置と窓幅と上下の組み方によらず、見開きでは表紙だけ増える")
    func markdownIndex() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.make(.markdown)
        try await render(model, outline: true)
        model.viewOptions.layout = .single
        try verifyArrangements(model, expected: markdown)
        #expect(BandMenuContent(model: model).header == "Menu Fixture · MD · 1 / 2")
        model.viewOptions.layout = .spread
        var spread = markdown
        spread[2] = [.readingDirection, .scrollDirection, .cover, .selectText]
        try verifyArrangements(model, expected: spread)
    }

    @Test("PDFと画像と画像の束の索引は文字選択と一覧と余白を文書に合わせる")
    func fixedFormats() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let pdf = try fixture.make(.pdf)
        try await render(pdf)
        pdf.viewOptions.layout = .single
        try verifyArrangements(
            pdf,
            expected: [
                [.previousPage, .nextPage, .documentInfo], [.layout, .transition],
                [.readingDirection, .scrollDirection, .selectText], [.paperOrientation],
                [.floatOnTop, .alwaysShowToolbar, .viewOptions], [.printSettings, .print], [.keysAndGestures],
            ])
        let image = try fixture.make(.image)
        try await render(image)
        image.viewOptions.layout = .single
        try verifyArrangements(
            image,
            expected: [
                [.documentInfo], [.layout, .transition], [.readingDirection, .scrollDirection],
                [.paperOrientation, .margins], [.floatOnTop, .alwaysShowToolbar, .viewOptions],
                [.printSettings, .print], [.keysAndGestures],
            ])
        let bundle = try fixture.make(.image, bundle: true)
        try await render(bundle)
        bundle.viewOptions.layout = .single
        try verifyArrangements(
            bundle,
            expected: [
                [.thumbnails, .previousPage, .nextPage, .documentInfo], [.layout, .transition],
                [.readingDirection, .scrollDirection], [.paperOrientation, .margins],
                [.floatOnTop, .alwaysShowToolbar, .viewOptions], [.printSettings, .print], [.keysAndGestures],
            ])
        BandMenuContent(model: bundle).perform(.thumbnails)
        #expect(BandMenuContent(model: bundle).entry(.thumbnails).isChecked == true)
    }

    @Test("HTMLの紙とウェブと検出したスライドは対象の操作とヘッダーを示す")
    func htmlIndex() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.make(.html)
        let web: [[ID]] = [
            [.presentation], [.margins], [.floatOnTop, .alwaysShowToolbar, .viewOptions],
            [.printSettings, .print], [.keysAndGestures],
        ]
        try verifyArrangements(model, expected: web)
        #expect(BandMenuContent(model: model).header == "Menu Fixture · HTML")
        #expect(BandMenuContent(model: model).moreHelp() == String(localized: "More · View Options"))
        model.slideDeckDidChange(SlideDeck(size: CGSize(width: 1280, height: 720), count: 6, currentIndex: 2))
        try verifyArrangements(
            model,
            expected: [
                [.presentation], [.margins, .ignoreSlides], [.floatOnTop, .alwaysShowToolbar, .viewOptions],
                [.printSettings, .print], [.keysAndGestures],
            ])
        #expect(
            BandMenuContent(model: model).header == "Menu Fixture · HTML · "
                + DocumentViewModel.slideIndicator(3, of: 6))
        #expect(BandMenuContent(model: model).entry(.ignoreSlides).isChecked == true)
        BandMenuContent(model: model).perform(.ignoreSlides)
        #expect(BandMenuContent(model: model).entry(.ignoreSlides).isChecked == false)
        #expect(model.detectedSlideDeck != nil)
        model.setHTMLPresentation(.paper)
        try await render(model, outline: true)
        model.viewOptions.layout = .single
        try verifyArrangements(
            model,
            expected: [
                [.outline, .previousPage, .nextPage, .documentInfo], [.presentation, .layout, .transition],
                [.readingDirection, .scrollDirection, .selectText],
                [.style, .paperOrientation, .paperSeries, .margins, .ignoreSlides],
                [.floatOnTop, .alwaysShowToolbar, .viewOptions], [.printSettings, .print], [.keysAndGestures],
            ])
    }

    @Test("メモリ上の原文と問題件数と拡大率だけが保存と確認と拡大解除を増やす")
    func memoryIssuesAndZoom() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        for issues in [false, true] {
            let model = try fixture.make(.markdown, memory: true, issues: issues)
            try await render(model, outline: true)
            model.viewOptions.layout = .single
            var expected = markdown
            expected[5] =
                issues
                ? [.printSettings, .beforePrinting, .print, .saveAsFile] : [.printSettings, .print, .saveAsFile]
            #expect(model.printIssueCount == (issues ? 2 : 0))
            try verifyArrangements(model, expected: expected)
            if issues {
                #expect(
                    BandMenuContent(model: model).entry(.beforePrinting).title
                        == String(localized: "Before Printing (\(2))…"))
            }
            model.zoom = 2
            expected[1] = [.layout, .transition, .zoom]
            try verifyArrangements(model, expected: expected)
            #expect(
                BandMenuContent(model: model).entry(.zoom).title
                    == String(format: String(localized: "Fit to Window (%@)"), "200%"))
        }
        let html = try fixture.make(.html)
        html.webZoom = 1.5
        try verifyArrangements(
            html,
            expected: [
                [.presentation, .zoom], [.margins], [.floatOnTop, .alwaysShowToolbar, .viewOptions],
                [.printSettings, .print], [.keysAndGestures],
            ])
    }

    @Test("選択値とチェックと無効状態は実メニューの項目に反映する")
    func states() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.make(.markdown)
        model.viewOptions.layout = .spread
        model.viewOptions.transition = .instant
        model.viewOptions.direction = .rightToLeft
        model.viewOptions.scrollAxis = .horizontal
        model.viewOptions.showsCoverAlone = false
        model.isBandAlwaysVisible = false
        let content = BandMenuContent(model: model)
        #expect(content.entry(.layout).value == String(localized: "Spread"))
        #expect(content.entry(.transition).value == ViewOptions.Transition.instant.name)
        #expect(content.entry(.readingDirection).value == String(localized: "Right to Left"))
        #expect(content.entry(.scrollDirection).value == String(localized: "Horizontal"))
        #expect(!content.entry(.scrollDirection).isEnabled)
        model.viewOptions.transition = .scroll
        #expect(content.entry(.scrollDirection).isEnabled)
        for id: ID in [.cover, .selectText, .floatOnTop, .alwaysShowToolbar] {
            #expect(content.entry(id).isChecked == false)
            content.perform(id)
            #expect(content.entry(id).isChecked == true)
            content.perform(id)
            #expect(content.entry(id).isChecked == false)
        }
        model.paperOrientation = .portrait
        #expect(content.entry(.paperOrientation).value == String(localized: "Portrait"))
        #expect(
            content.entry(.paperOrientation).title
                == choice(String(localized: "Paper Orientation"), String(localized: "Portrait")))
        #expect(content.entry(.paperOrientation).isEnabled)
        model.layoutID = PrintLayout.a4BookletA5.id
        #expect(!content.entry(.paperOrientation).isEnabled)
        #expect(content.entry(.paperOrientation).value == String(localized: "Landscape"))
        #expect(content.entry(.paperSeries).value == PaperSeries.a.name)
        #expect(content.entry(.style).value == model.styleName)
        model.printOptions.margins = PageMargins(top: 1, left: 2, bottom: 3, right: 4)
        #expect(content.entry(.margins).value == String(localized: "Mixed"))
        let html = try fixture.make(.html)
        #expect(BandMenuContent(model: html).entry(.presentation).value == String(localized: "Web"))
        html.setHTMLPresentation(.paper)
        #expect(BandMenuContent(model: html).entry(.presentation).value == String(localized: "Paper"))
        #expect(
            BandMenuContent(model: html).entry(.style).title == choice(String(localized: "HTML Preset"), html.styleName)
        )
    }

    @Test("その他のヒントは割当変更と解除に従いウェブでは紙用のキーを示さない")
    func shortcutHint() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.make(.markdown)
        let hotKeys = GlobalHotKeys(register: { _, _ in
            Issue.record("グローバルキーを登録してはいけません")
            return nil
        })
        defer { hotKeys.stop() }
        let controller = ShortcutController(
            hotKeys: hotKeys, reservations: { [] },
            keyboardLayout: { ShortcutKeyboardLayout.project { code, _ in code == 40 ? "k" : nil } })
        controller.start(preferences: fixture.preferences)
        try controller.edit(.viewOptions, keys: [.init(key: .character("k"), modifiers: .command)])
        let content = BandMenuContent(model: model)
        #expect(content.moreHelp(controller: controller).contains("⌘K"))
        try controller.edit(.viewOptions, keys: [])
        #expect(content.moreHelp(controller: controller) == String(localized: "More · View Options"))
        controller.setExternalMenuKeys([.viewOptions: .init(key: .character("k"), modifiers: .command)])
        #expect(content.moreHelp(controller: controller).contains("⌘K"))
        let html = try fixture.make(.html)
        #expect(
            BandMenuContent(model: html).moreHelp(controller: controller) == String(localized: "More · View Options"))
    }

    @Test("索引の印刷は印刷画面を開くだけで再度呼ばれても送信しない")
    func printAction() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.make(.markdown)
        var submissions = 0
        var outputs = 0
        model.printSubmit = { _, _, _ in submissions += 1 }
        model.outputOverride = { _, _ in outputs += 1 }
        try await render(model, outline: true)
        let content = BandMenuContent(model: model)
        let printEntry = try #require(content.groups.flatMap(\.entries).first { $0.id == .print })
        #expect(model.mode == .view)
        content.perform(printEntry.id)
        #expect(model.mode == .print)
        try await render(model)
        content.perform(printEntry.id)
        #expect(submissions == 0)
        #expect(outputs == 0)
    }
}
