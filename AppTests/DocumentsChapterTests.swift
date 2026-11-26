import SurimonoCore
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
        for format in DocumentsChapter.formats.prefix(6) {
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

    @Test("Markdown の新規文書とショートカットは設定画面の目次を引き継ぎ、文書に保存した選択は残る")
    func newDocument() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(defaults: suite.defaults)
        FormatDefaultsPane(format: .markdown, preferences: prefs).set(
            .outline(present: true, depth: .levels(2)), for: .tableOfContents)
        let library = UserLibrary(root: root)
        let model = DocumentViewModel(
            data: Data("# Title".utf8), fileURL: nil, format: .markdown, preferences: prefs, library: library)
        defer { model.stop() }
        #expect(model.leadContents == .levels(2))
        #expect(model.rememberedSettings.formatReading.isEmpty)
        let render = try #require(model.renderSettings)
        #expect(render.formatReadingDefaults == prefs.formatReadingDefaults && render.finish.legacyTOC == nil)
        let shortcut = try HeadlessExport(preferences: prefs, library: library).settings(
            format: .markdown, name: "Title", layoutID: nil, style: nil)
        #expect(shortcut.formatReadingDefaults == prefs.formatReadingDefaults && shortcut.finish.legacyTOC == nil)
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

    @Test("拡張子・原稿の指定・項目名で文書の章と形式と表示する行が決まる")
    func search() {
        let contents = "Table of Contents at the Top"
        let cases: [(String, DocumentFormat, String)] = [
            (".md", .markdown, contents), (".qmd", .quarto, contents), (".Rmd", .rMarkdown, contents),
            (".rst", .rst, contents), (".adoc", .asciidoc, contents), (".wiki", .mediawiki, contents),
            (".mediawiki", .mediawiki, contents), (".org", .org, "Heading Numbers"),
            (".html", .html, "Default HTML Preset"), ("toc-depth", .markdown, contents),
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

    @Test("最小幅の形式選択と広い窓の形式一覧で八言語の各ページが収まる", arguments: UILanguage.supported, [519, 780])
    func layout(language: String, width: CGFloat) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let prefs = AppPreferences(defaults: suite.defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsView(
            preferences: prefs, library: UserLibrary(root: root),
            arrangementEditor: BandArrangementEditorSession(preferences: prefs))
        let height = SettingsWindowPlacement.minimumContentSize.height
        for format in DocumentsChapter.formats {
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
                default: ["Table of Contents at the Top", "Reset to Defaults…"]
                }
            try await screen.wait("\(language), \(width), \(format), \(frames.rows)") {
                !viewport.isNull && keys.allSatisfy { frames.rows[$0] != nil }
            }
            #expect(viewport.size == CGSize(width: width, height: height))
            for key in keys {
                let frame = try #require(frames.rows[key])
                #expect(!frame.isEmpty && viewport.contains(frame), "\(key) \(frame), viewport=\(viewport)")
                #expect(frame.minX >= (width == 780 ? viewport.minX + 156 : viewport.minX))
            }
            let first = try #require(frames.rows[keys[0]])
            #expect((first.minX - viewport.minX > 156) == (width == 780))
        }
    }
}
