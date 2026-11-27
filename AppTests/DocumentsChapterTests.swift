import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct DocumentsChapterTests {
    @Test("文書の章には設定できる九形式を決めた順に並べる")
    func formats() {
        #expect(SettingsGroup.opening.sections == [.clipboard, .documents])
        #expect(
            DocumentsChapter.formats == [
                .markdown, .quarto, .rMarkdown, .rst, .asciidoc, .mediawiki, .org, .html, .plainText,
            ])
        #expect(
            DocumentsChapter.rows(for: .markdown).map(\.id) == [.sectionNumbers, .tableOfContents, .preserveBreaks])
        for format in [DocumentFormat.quarto, .rMarkdown, .rst] {
            #expect(DocumentsChapter.rows(for: format).map(\.id) == [.sectionNumbers, .tableOfContents])
        }
        for format in [DocumentFormat.asciidoc, .mediawiki] {
            #expect(DocumentsChapter.rows(for: format).map(\.id) == [.tableOfContents])
        }
        #expect(CodeNumberRow.allCases.map(\.label.key) == ["Line Numbers", "Code Block Line Numbers"])
    }

    @Test("先頭の目次を変えた成分だけ覚え、形式ごとに初期値に戻す")
    func sparseChanges() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let prefs = AppPreferences(defaults: suite.defaults)
        let md = FormatDefaultsPane(format: .markdown, preferences: prefs)
        let wiki = FormatDefaultsPane(format: .mediawiki, preferences: prefs)
        #expect(md.defaults.status.key == "Surimono defaults")
        md.set(.outline(present: true, depth: .levels(3)), for: .tableOfContents)
        let bytes = try #require(suite.defaults.data(forKey: "formatReadingDefaults"))
        let saved = try JSONDecoder().decode([String: [String: [String: Bool]]].self, from: bytes)
        #expect(saved == ["markdown": ["tableOfContents": ["present": true]]])
        wiki.set(.outline(present: true, depth: .all), for: .tableOfContents)
        #expect(md.defaults.status.key == "Custom")
        md.reset()
        #expect(md.defaults.status.key == "Surimono defaults" && wiki.defaults.status.key == "Custom")
        #expect(AppPreferences(defaults: suite.defaults).formatReadingDefaults == prefs.formatReadingDefaults)
        wiki.reset()
        #expect(suite.defaults.object(forKey: "formatReadingDefaults") == nil)
    }

    @Test("Quarto と R Markdown の番号と目次の既定を別々に保存して戻せる")
    func computationalDefaults() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let quarto = FormatDefaultsPane(format: .quarto, preferences: preferences)
        let rmd = FormatDefaultsPane(format: .rMarkdown, preferences: preferences)
        quarto.set(.outline(present: true, depth: .levels(2)), for: .sectionNumbers)
        rmd.set(.toggle(true), for: .sectionNumbers)
        rmd.set(.outline(present: true, depth: .levels(1)), for: .tableOfContents)
        let saved = AppPreferences(defaults: suite.defaults).formatReadingDefaults
        guard case .outline(let present, let depth) = saved.resolve(.sectionNumbers, for: .quarto),
            case .toggle(let all) = saved.resolve(.sectionNumbers, for: .rMarkdown)
        else {
            Issue.record("見出し番号の選択がない")
            return
        }
        #expect(present.value && depth.value == .levels(2) && all.value)
        #expect(saved.leadContents(for: .quarto) == nil && saved.leadContents(for: .rMarkdown) == .levels(1))
        quarto.reset()
        #expect(quarto.defaults.status.key == "Surimono defaults" && rmd.defaults.status.key == "Custom")
        rmd.reset()
        #expect(preferences.formatReadingDefaults.isEmpty)
    }

    @Test("Markdown の新規文書とショートカットは設定画面の目次を引き継ぎ、文書に保存した選択は残る")
    func newDocument() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(defaults: suite.defaults)
        FormatDefaultsPane(format: .markdown, preferences: prefs).set(
            .outline(present: true, depth: .levels(2)), for: .tableOfContents)
        let markdownDefaults = prefs.formatReadingDefaults
        FormatDefaultsPane(format: .quarto, preferences: prefs).set(
            .outline(present: true, depth: .all), for: .tableOfContents)
        let library = UserLibrary(root: root)
        let model = DocumentViewModel(
            data: Data("# Title".utf8), fileURL: nil, format: .markdown, preferences: prefs, library: library)
        defer { model.stop() }
        #expect(model.leadContents == .levels(2))
        #expect(model.rememberedSettings.formatReading.isEmpty)
        let render = try #require(model.renderSettings)
        #expect(render.formatReadingDefaults == markdownDefaults && render.finish.legacyTOC == nil)
        let shortcut = try HeadlessExport(preferences: prefs, library: library).settings(
            format: .markdown, name: "Title", layoutID: nil, style: nil)
        #expect(shortcut.formatReadingDefaults == markdownDefaults && shortcut.finish.legacyTOC == nil)
        var saved = DocumentSettings()
        saved.formatReading.set(
            .outline(present: false, depth: .levels(2)), for: .tableOfContents, format: .markdown,
            defaults: prefs.formatReadingDefaults)
        model.restoreClosedDocument(saved)
        #expect(model.leadContents == .off && model.rememberedSettings.formatReading == saved.formatReading)
    }

    @Test("ソースと文書内の行番号は個別に永続化し、保存済みのコード設定を優先する")
    func codeDefaults() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(defaults: suite.defaults)
        #expect(prefs.codeLineNumbers.source == .all && prefs.codeLineNumbers.blocks == .none)
        prefs.codeLineNumbers = .init(source: .none, blocks: .everyFive)
        let restored = AppPreferences(defaults: suite.defaults)
        let library = UserLibrary(root: root)
        let source = DocumentViewModel(
            data: Data("let x = 1".utf8), fileURL: root.appendingPathComponent("reader.swift"),
            format: .plainText, preferences: restored, library: library)
        let md = DocumentViewModel(
            data: Data("# A".utf8), fileURL: nil, format: .markdown, preferences: restored, library: library)
        defer {
            source.stop()
            md.stop()
        }
        #expect(source.codeBlock.frame == .none && source.codeBlock.lineNumbers == .none)
        #expect(md.codeBlock.frame == .style && md.codeBlock.lineNumbers == .everyFive)
        #expect(source.rememberedSettings.codeBlock == nil && md.rememberedSettings.codeBlock == nil)
        let fragment = PlainTextConverter.convert("let x = 1", fileName: "reader.swift")
        let style = try #require(source.renderSettings).code
        #expect(
            !CodeBlockMarkup.apply(style, to: fragment.body, language: fragment.sourceLanguage).contains(
                "class=\"source-no\""))
        let block = try #require(md.renderSettings).code
        #expect(CodeBlockMarkup.apply(block, to: "<pre><code>a\nb\nc\nd\ne</code></pre>").contains("data-no=\"5\""))
        let saved = CodeBlockOptions(frame: .none, lineNumbers: .all)
        source.restoreClosedDocument(.init(codeBlock: saved))
        restored.codeLineNumbers = .init()
        #expect(source.rememberedSettings.codeBlock == saved)
        restored.codeLineNumbers.source = .everyFive
        #expect(source.codeBlock == saved)
        restored.codeLineNumbers = .init()
        #expect(
            suite.defaults.object(forKey: "sourceLineNumbers") == nil
                && suite.defaults.object(forKey: "codeBlockLineNumbers") == nil)
    }

    @Test("開いた Markdown は自分が継承する目次と行番号だけで再組版する", arguments: [false, true])
    func renderInheritedDefaults(storedCode: Bool) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(defaults: suite.defaults)
        var calls = 0
        let page = TestFixtures.pdf("Defaults", pages: 1)
        let renderer = DocumentRenderer(paginate: { _ in
            calls += 1
            return try #require(PDFDocument(data: page))
        })
        let model = DocumentViewModel(
            data: Data("# Heading\n\n```swift\nlet n = 1\n```".utf8), fileURL: nil, format: .markdown,
            preferences: prefs, library: UserLibrary(root: root), renderer: renderer)
        defer { model.stop() }
        if storedCode { model.restoreClosedDocument(.init(codeBlock: .init(lineNumbers: .everyFive))) }
        func settle() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while model.isRendering {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(model.isUpToDate)
        }
        model.render()
        try await settle()
        let original = try #require(model.renderSettings)
        let starts = model.renderStartCount
        prefs.formatReadingDefaults.set(.outline(present: true, depth: .all), for: .tableOfContents, format: .quarto)
        prefs.codeLineNumbers.source = .none
        #expect(model.renderSettings == original)
        model.renderForChangedSettings()
        #expect(model.renderStartCount == starts && calls == 1)

        prefs.codeLineNumbers.blocks = .all
        #expect((model.renderSettings == original) == storedCode)
        model.renderForChangedSettings()
        try await settle()
        #expect(model.renderStartCount == starts + (storedCode ? 0 : 1))
        #expect(calls == (storedCode ? 1 : 2))

        prefs.formatReadingDefaults.set(.outline(present: true, depth: .all), for: .tableOfContents, format: .markdown)
        model.renderForChangedSettings()
        try await settle()
        #expect(calls == (storedCode ? 2 : 3))
    }

    @Test("拡張子・原稿の指定・項目名で文書の章と形式と表示する行が決まる")
    func search() {
        let contents = "Table of Contents at the Top"
        let cases: [(String, DocumentFormat, String)] = [
            (".md", .markdown, "Heading Numbers"), (".qmd", .quarto, "Heading Numbers"),
            (".Rmd", .rMarkdown, "Heading Numbers"),
            (".rst", .rst, "Heading Numbers"), (".. sectnum::", .rst, "Heading Numbers"),
            (".adoc", .asciidoc, contents),
            (".wiki", .mediawiki, contents),
            (".mediawiki", .mediawiki, contents), (".org", .org, "Heading Numbers"),
            (".html", .html, "Default HTML Preset"), ("toc-depth", .markdown, contents),
            ("number-depth", .quarto, "Heading Numbers"), ("number_sections", .rMarkdown, "Heading Numbers"),
            ("toc_depth", .rMarkdown, contents), ("__NOTOC__", .mediawiki, contents),
            (":toclevels:", .asciidoc, contents),
            (":sectnums:", .asciidoc, "Defaults for New Documents"),
            ("Code Block Line Numbers", .plainText, "Code Block Line Numbers"), ("num:", .org, "Heading Numbers"),
        ]
        for (query, format, row) in cases {
            let results = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { $0 })
            #expect(results.bestSection(keeping: .general) == .documents, "\(query)")
            #expect(results.bestFormat(keeping: .markdown) == format, "\(query)")
            #expect(
                results.hits(for: .documents, format: format, query: query).scrollTarget(excluding: []) == row,
                "\(query)")
        }
    }

    @Test("検索で表示した Quarto を選び直したときだけ検索解除後もそのページに残る", arguments: [820, 1120])
    func reselectSearchFormat(width: CGFloat) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.settingsSection = .documents
        preferences.settingsDocumentFormat = .markdown
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = OrgReadingTestWindow(width: width, height: 540) {
            SettingsView(
                preferences: preferences, library: UserLibrary(root: root),
                arrangementEditor: BandArrangementEditorSession(preferences: preferences)
            ).environment(\.locale, Locale(identifier: "en"))
        }
        defer { screen.window.close() }

        func control<T: NSView>(_ type: T.Type, in view: NSView, matching: (T) -> Bool) -> T? {
            if let candidate = view as? T, matching(candidate) { return candidate }
            for child in view.subviews {
                if let found = control(type, in: child, matching: matching) { return found }
            }
            return nil
        }
        func list() -> NSTableView? {
            control(NSTableView.self, in: screen.host) { $0.accessibilityLabel() == "Format" }
        }
        func picker() -> NSPopUpButton? {
            control(NSPopUpButton.self, in: screen.host) { $0.accessibilityLabel() == "Format" }
        }
        func shows(_ title: String, filtered: Bool) -> Bool {
            if width == 820, let button = picker() {
                return button.titleOfSelectedItem == title && (button.numberOfItems == 1) == filtered
            }
            guard let table = list(), table.selectedRow >= 0,
                let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? NSTableCellView
            else { return false }
            return cell.textField?.stringValue == title && (table.numberOfRows == 1) == filtered
        }
        func query(_ text: String) throws {
            let field = try #require(control(NSTextField.self, in: screen.host) { $0.isEditable })
            field.stringValue = text
            field.delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field))
        }

        try await screen.wait("Markdown before search") { shows("Markdown", filtered: false) }
        for explicitlySelected in [false, true] {
            try query(".qmd")
            try await screen.wait("Quarto search hit") { shows("Quarto", filtered: true) }
            #expect(preferences.settingsDocumentFormat == .markdown)
            if explicitlySelected {
                if width == 820 {
                    let button = try #require(picker())
                    let menu = try #require(button.menu)
                    menu.performActionForItem(at: button.indexOfSelectedItem)
                } else {
                    let table = try #require(list())
                    let rect = table.convert(table.rect(ofRow: table.selectedRow), to: nil)
                    let point = CGPoint(x: rect.midX, y: rect.midY)
                    func event(_ type: NSEvent.EventType) throws -> NSEvent {
                        try #require(
                            NSEvent.mouseEvent(
                                with: type, location: point, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                pressure: type == .leftMouseDown ? 1 : 0))
                    }
                    // Native row tracking can consume mouse-up synchronously inside mouseDown.
                    screen.window.postEvent(try event(.leftMouseUp), atStart: true)
                    table.mouseDown(with: try event(.leftMouseDown))
                }
                try #require(preferences.settingsDocumentFormat == .quarto)
            }
            try query("")
            let expected = explicitlySelected ? "Quarto" : "Markdown"
            try await screen.wait("Page after clearing search") { shows(expected, filtered: false) }
        }
    }

    @Test("以前の Org と HTML の呼び出しは同じ章を開いて形式を切り替える")
    func deepLinks() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let prefs = AppPreferences(defaults: suite.defaults)
        let editor = BandArrangementEditorSession(preferences: prefs)
        for (section, format) in [(SettingsSection.org, DocumentFormat.org), (.html, .html), (.org, .org)] {
            BandArrangementEditorSession.showSection(section, preferences: prefs, editor: editor)
            #expect(prefs.settingsSection == .documents && prefs.settingsDocumentFormat == format)
        }
    }

    @Test("HTML はプリセットと JavaScript の両方が出荷時の値に戻ると初期値と示す")
    func htmlStatus() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let prefs = AppPreferences(defaults: suite.defaults)
        #expect(prefs.usesDefaultHTMLSettings)
        prefs.presetID = "reader"
        #expect(!prefs.usesDefaultHTMLSettings)
        prefs.allowsJavaScript = false
        prefs.presetID = "none"
        #expect(!prefs.usesDefaultHTMLSettings)
        prefs.allowsJavaScript = true
        #expect(prefs.usesDefaultHTMLSettings)
    }

    @Test("リセットの確認には選んだ形式の表示名が八言語それぞれで入る", arguments: UILanguage.supported)
    func resetQuestions(language: String) throws {
        let locale = Locale(identifier: language)
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let strings = try #require(Bundle(url: url))
        for format in DocumentsChapter.formats where format != .html {
            var question = DocumentsChapter.resetQuestion(for: format)
            question.locale = locale
            let title = DocumentsChapter.title(format)
            let name = strings.localizedString(forKey: title, value: title, table: nil)
            let template = strings.localizedString(forKey: question.key, value: "MISSING", table: nil)
            #expect(template != "MISSING")
            let expected = String(format: template, locale: locale, name)
            #expect(expected.contains(name))
            #expect(String(localized: question) == expected)
        }
    }

    @Test("形式一覧は各行を同じ高さとし、ソースコードの前だけ間隔を空ける", arguments: UILanguage.supported)
    func formatList(language: String) async throws {
        var selected = DocumentFormat.rst
        let selection = Binding(get: { selected }, set: { selected = $0 })
        let screen = OrgReadingTestWindow(width: 780, height: 540) {
            DocumentsChapterView(formats: DocumentsChapter.formats, selection: selection) { Color.clear }
                .environment(\.locale, Locale(identifier: language))
        }
        defer { screen.window.close() }
        func table(in view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try await screen.wait("format list") { table(in: screen.host)?.numberOfRows == 10 }
        let list = try #require(table(in: screen.host))
        let column = try #require(list.enclosingScrollView)
        #expect((176...180).contains(column.frame.width))
        let rects = (0..<10).map(list.rect(ofRow:))
        let ordinary = Array(rects.prefix(8)) + [rects[9]]
        #expect(ordinary.allSatisfy { (30...32).contains($0.height) }, "\(rects)")
        #expect((10...12).contains(rects[9].minY - rects[7].maxY), "\(rects)")
        let cell = try #require(list.view(atColumn: 0, row: 3, makeIfNecessary: false) as? NSTableCellView)
        let text = try #require(cell.textField)
        #expect(text.stringValue == "reStructuredText")
        #expect(text.frame.width >= text.intrinsicContentSize.width)
        let label = text.convert(text.bounds, to: nil)
        let bounds = column.convert(column.bounds, to: nil)
        #expect(bounds.maxX - label.maxX >= 16)
        let source = try #require(list.view(atColumn: 0, row: 9, makeIfNecessary: false) as? NSTableCellView)
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let strings = try #require(Bundle(url: url))
        #expect(source.textField?.stringValue == strings.localizedString(forKey: "Source Code", value: nil, table: nil))
        #expect(list.effectiveStyle == .sourceList && list.selectedRow == 3)
        #expect(list.delegate?.tableView?(list, shouldSelectRow: 8) == false)
        list.selectRowIndexes(IndexSet(integer: 9), byExtendingSelection: false)
        #expect(selected == .plainText)
    }

    @Test("最小幅の形式選択と広い窓の形式一覧で八言語の各ページが収まる", arguments: UILanguage.supported, [519, 720, 780])
    func layout(language: String, width: CGFloat) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let prefs = AppPreferences(defaults: suite.defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsView(
            preferences: prefs, library: UserLibrary(root: root),
            arrangementEditor: BandArrangementEditorSession(preferences: prefs))
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let strings = try #require(Bundle(url: url))
        let height = SettingsWindowPlacement.minimumContentSize.height
        let pages =
            DocumentsChapter.formats.map { ($0, "Surimono defaults") } + [(.org, "Emacs defaults"), (.org, "Custom")]
        for (format, status) in pages {
            if status == "Emacs defaults" { prefs.setOrgDefaults(.emacs) }
            if status == "Custom" {
                var custom = OrgReadingDefaults.surimono
                custom.headlineLevels = 5
                prefs.setOrgDefaults(custom)
            }
            let frames = SettingsRowFrames()
            var viewport = CGRect.null
            let screen = OrgReadingTestWindow(width: width, height: height) {
                DocumentsChapterView(formats: DocumentsChapter.formats, selection: .constant(format)) {
                    settings.documentSettingsPage(format)
                }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    viewport = $0
                }
                .environment(\.locale, Locale(identifier: language))
                .environment(\.settingsRowFrames, frames)
            }
            defer { screen.window.close() }
            let keys: [String] =
                switch format {
                case .org: ["Heading Numbers", "Use Emacs Defaults…", "Reset to Defaults…"]
                case .html: ["Default HTML Preset", "Allow JavaScript in HTML", "Open Presets Folder"]
                case .plainText: ["Line Numbers", "Code Block Line Numbers", "Reset to Defaults…"]
                case .quarto, .rMarkdown, .rst:
                    ["Heading Numbers", "Table of Contents at the Top", "Reset to Defaults…"]
                default: ["Table of Contents at the Top", "Reset to Defaults…"]
                }
            try await screen.wait("\(language), \(width), \(format), \(frames.rows)") {
                !viewport.isNull && keys.allSatisfy { frames.rows[$0] != nil }
            }
            #expect(viewport.size == CGSize(width: width, height: height))
            for key in keys {
                let frame = try #require(frames.rows[key])
                #expect(!frame.isEmpty && viewport.contains(frame), "\(key) \(frame), viewport=\(viewport)")
                #expect(frame.minX >= (width >= 720 ? viewport.minX + 178 : viewport.minX))
            }
            let left = try #require(frames.rows["Defaults for New Documents"])
            let right = try #require(frames.rows[status])
            #expect(!left.isEmpty && !right.isEmpty && left.maxX < right.minX)
            #expect(abs(left.midY - right.midY) <= 1)
            let title = DocumentsChapter.title(format)
            for (key, font, frame) in [(title, Font.headline, left), (status, Font.body, right)] {
                let label = strings.localizedString(forKey: key, value: key, table: nil)
                let host = NSHostingController(
                    rootView: Text(verbatim: label).font(font).fixedSize()
                        .environment(\.locale, Locale(identifier: language)))
                let intrinsic = host.sizeThatFits(in: CGSize(width: width, height: height))
                // Under a host language other than the tested one, the header falls back to another face about 3%
                // narrower than the lone label. A truncated label loses at least a whole character, far more than that.
                #expect(frame.width >= intrinsic.width * 0.95 - 1, "\(language) \(label) \(intrinsic) \(frame)")
            }
            if format == .org {
                let filter = try #require(frames.rows["Show Only Changed Settings"])
                #expect(filter.midY > left.midY)
            }
            let first = try #require(frames.rows[keys[0]])
            #expect((first.minX - viewport.minX > 178) == (width >= 720))
        }
    }
}
