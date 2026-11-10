import AppIntents
import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

private let languages = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"]

/// The actions read what they work with from one shared place, so these tests take turns.
@MainActor
@Suite(.serialized)
struct ShortcutActionsTests {
    /// Puts a test's own settings in the actions' place and gives the app's back afterwards.
    @MainActor
    private final class Environment {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private let preferences = ShortcutEnvironment.preferences
        private let library = ShortcutEnvironment.library
        private let router = ShortcutEnvironment.router

        init(router: OpenRouter? = nil) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ShortcutEnvironment.preferences = AppPreferences(defaults: suite.defaults)
            ShortcutEnvironment.library = UserLibrary(root: directory.appendingPathComponent("Library"))
            if let router { ShortcutEnvironment.router = router }
        }

        func restore() {
            ShortcutEnvironment.preferences = preferences
            ShortcutEnvironment.library = library
            ShortcutEnvironment.router = router
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }

        func write(_ name: String, _ data: Data) throws -> URL {
            let folder = directory.appendingPathComponent("Input")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        var export: HeadlessExport {
            HeadlessExport(
                preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: directory.appendingPathComponent("Library")))
        }
    }

    private func catalog(_ name: String) throws -> [String: [String: Any]] {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/\(name).xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any]
        return try #require(json?["strings"] as? [String: [String: Any]])
    }

    private func siblings(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    }

    private func table(_ language: String) throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }

    @Test("ショートカットのレイアウトは、刷り台のレイアウトと同じ並びですべてそろっている")
    func layoutsFollowPresets() {
        #expect(ShortcutLayout.allCases.map(\.rawValue) == PrintLayout.presets.map(\.id))
        #expect(Set(ShortcutLayout.caseDisplayRepresentations.keys) == Set(ShortcutLayout.allCases))
    }

    @Test("ショートカットのレイアウトの名前は、刷り台と同じ名前になる", arguments: languages)
    func layoutNames(language: String) throws {
        let bundle = try table(language)
        for layout in PrintLayout.presets {
            let key = layout.displayName(language: "en")
            #expect(
                bundle.localizedString(forKey: key, value: "MISSING", table: "Shortcuts")
                    == layout.displayName(language: language))
        }
    }

    @Test("ショートカットの文言と呼び出しの言葉は 8 言語に訳してある", arguments: ["Shortcuts", "AppShortcuts"])
    func translated(name: String) throws {
        let strings = try catalog(name)
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: [String: Any]]] ?? [:]
            for language in languages {
                let unit = localizations[language]?["stringUnit"] ?? localizations[language]?["stringSet"]
                let values = (unit?["values"] as? [String]) ?? [unit?["value"] as? String ?? ""]
                #expect(unit?["state"] as? String == "translated", "\(key): \(language)")
                #expect(values.allSatisfy { !$0.isEmpty }, "\(key): \(language)")
                // A placeholder the translation drops would leave the action without its parameter or its app.
                for placeholder in key.matches(of: /\$\{[A-Za-z]+\}|%@/) {
                    #expect(values.allSatisfy { $0.contains(placeholder.output) }, "\(key): \(language)")
                }
            }
        }
    }

    @Test("呼び出しの言葉はどれもアプリの名前を含む")
    func phrasesNameTheApp() throws {
        let strings = try catalog("AppShortcuts")
        #expect(strings.count == 2)
        #expect(strings.keys.allSatisfy { $0.contains("${applicationName}") })
    }

    @Test("PDF の書き出しは窓を開かずに A4 片面の 1 枚を返し、元のファイルもその隣も変えない", .timeLimit(.minutes(1)))
    func exportSingleSided() async throws {
        let environment = try Environment()
        defer { environment.restore() }
        let source = Data("# 見出し\n\n本文です。\n".utf8)
        let url = try environment.write("memo.md", source)
        let documents = NSDocumentController.shared.documents.count
        let windows = DocumentWindows.shared.openModels.count
        var intent = ExportPDFIntent()
        intent.file = IntentFile(fileURL: url)
        intent.layout = .a4Single
        let file = try #require(try await intent.perform().value)
        let pdf = try #require(PDFDocument(data: file.data))
        #expect(pdf.pageCount == 1)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 595.28) < 0.5)
        #expect(abs(box.height - 841.89) < 0.5)
        #expect(file.filename.hasPrefix("memo"))
        #expect(file.filename.hasSuffix(".pdf"))
        #expect(file.fileURL == nil)
        #expect(try siblings(of: url) == ["memo.md"])
        #expect(try Data(contentsOf: url) == source)
        #expect(NSDocumentController.shared.documents.count == documents)
        #expect(DocumentWindows.shared.openModels.count == windows)
    }

    @Test("PDF の書き出しで A4 の冊子を選ぶと、1 ページの文書は横向きの A4 の表と裏になる", .timeLimit(.minutes(1)))
    func exportBooklet() async throws {
        let environment = try Environment()
        defer { environment.restore() }
        let url = try environment.write("memo.md", Data("# 見出し\n\n本文です。\n".utf8))
        var intent = ExportPDFIntent()
        intent.file = IntentFile(fileURL: url)
        intent.layout = .a4BookletA5
        let file = try #require(try await intent.perform().value)
        let pdf = try #require(PDFDocument(data: file.data))
        #expect(pdf.pageCount == 2)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 841.89) < 0.5)
        #expect(abs(box.height - 595.28) < 0.5)
        #expect(try siblings(of: url) == ["memo.md"])
    }

    @Test("レイアウトを選ばない書き出しは、アプリの既定のレイアウトを使う")
    func defaultLayout() throws {
        let environment = try Environment()
        defer { environment.restore() }
        let preferences = AppPreferences(defaults: environment.suite.defaults)
        preferences.layoutID = "b5Duplex"
        let export = HeadlessExport(preferences: preferences, library: environment.export.library)
        #expect(try export.settings(format: .markdown, name: "a", layoutID: nil, style: nil).layout == .b5Duplex)
        #expect(
            try export.settings(format: .markdown, name: "a", layoutID: "a3TwoUp", style: nil).layout == .a3TwoUp)
    }

    @Test("スタイルは、識別子でも英語の名前でも日本語の名前でも選べる", arguments: ["compact", "Compact", "コンパクト", " COMPACT "])
    func styleByName(name: String) throws {
        let environment = try Environment()
        defer { environment.restore() }
        let settings = try environment.export.settings(format: .markdown, name: "a", layoutID: nil, style: name)
        #expect(settings.theme.id == "compact")
    }

    @Test("スタイルを選ばない書き出しは、アプリの既定のスタイルを使う")
    func defaultStyle() throws {
        let environment = try Environment()
        defer { environment.restore() }
        let preferences = AppPreferences(defaults: environment.suite.defaults)
        preferences.themeID = "modern"
        let export = HeadlessExport(preferences: preferences, library: environment.export.library)
        #expect(try export.settings(format: .org, name: "a", layoutID: nil, style: nil).theme.id == "modern")
    }

    @Test("知らない名前のスタイルは、別のスタイルで書き出さずに断る")
    func unknownStyle() throws {
        let environment = try Environment()
        defer { environment.restore() }
        #expect(throws: HeadlessExport.Failure.self) {
            try environment.export.settings(format: .markdown, name: "a", layoutID: nil, style: "no-such-style")
        }
    }

    @Test("スタイルを使わない形式では、スタイルの指定を無視する")
    func styleIgnoredForPDF() throws {
        let environment = try Environment()
        defer { environment.restore() }
        let settings = try environment.export.settings(format: .pdf, name: "a", layoutID: nil, style: "no-such-style")
        #expect(settings.theme.id == "standard")
    }

    @Test("ZIP と知らない種類のファイルは書き出さずに断る", arguments: ["images.zip", "data.unknown"])
    func unsupportedExport(name: String) async throws {
        let environment = try Environment()
        defer { environment.restore() }
        let url = try environment.write(name, Data([0x50, 0x4B, 0x05, 0x06]))
        var intent = ExportPDFIntent()
        intent.file = IntentFile(fileURL: url)
        await #expect(throws: ShortcutFailure.self) { _ = try await intent.perform() }
    }

    @Test("「印刷モードで開く」は、ファイルをルーターへ渡し、その文書の窓が刷り台を頼まれる")
    func openInPrintMode() async throws {
        var opened: [URL] = []
        let router = OpenRouter(
            openDocument: { url, completion in
                opened.append(url)
                completion(true)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") },
            hasOpenWindows: { true }, showWelcome: {})
        let environment = try Environment(router: router)
        defer { environment.restore() }
        let url = try environment.write("memo.md", Data("# a".utf8))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: url)]
        _ = try await intent.perform()
        #expect(opened == [url])
        let model = DocumentViewModel(
            data: Data("# a".utf8), fileURL: url, format: .markdown,
            preferences: AppPreferences(defaults: environment.suite.defaults),
            library: UserLibrary(root: environment.directory.appendingPathComponent("Library")))
        defer { model.stop() }
        router.printIfRequested(model)
        #expect(model.isPrintModeRequested)
    }

    @Test("「印刷モードで開く」に渡した複数の画像は、画像の束として開く")
    func openImagesInPrintMode() async throws {
        var opened: [URL] = []
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") },
            openBundle: { urls, _ in
                opened = urls
                return nil
            }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { true },
            showWelcome: {})
        let environment = try Environment(router: router)
        defer { environment.restore() }
        let first = try environment.write("1.png", TestFixtures.png(red: 0.1))
        let second = try environment.write("2.png", TestFixtures.png(red: 0.9))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: second), IntentFile(fileURL: first)]
        _ = try await intent.perform()
        #expect(opened.map(\.lastPathComponent) == ["1.png", "2.png"])
    }

    @Test("場所のないファイル 1 つは、メモリから印刷モードで開く")
    func openDataInPrintMode() async throws {
        var opened: [(Data, DocumentFormat, Bool)] = []
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { true },
            showWelcome: {}, openMemory: { opened.append(($0, $1, $2)) })
        let environment = try Environment(router: router)
        defer { environment.restore() }
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(data: Data("# a".utf8), filename: "made.md")]
        _ = try await intent.perform()
        #expect(opened.count == 1)
        #expect(opened.first?.0 == Data("# a".utf8))
        #expect(opened.first?.1 == .markdown)
        #expect(opened.first?.2 == true)
    }

    @Test("場所のないファイルが複数あるときは、何も開かずに断る")
    func openSeveralDataFiles() {
        let content = ShortcutFiles.content(
            urls: [nil, URL(fileURLWithPath: "/fixtures/a.md")],
            single: {
                Issue.record("中身は読まない")
                return nil
            })
        #expect(content == .empty)
    }

    @Test("ファイルを渡さない「印刷モードで開く」は、理由を返す")
    func openNothing() async throws {
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { true },
            showWelcome: {})
        let environment = try Environment(router: router)
        defer { environment.restore() }
        var intent = OpenInPrintModeIntent()
        intent.files = []
        await #expect(throws: ShortcutFailure.self) { _ = try await intent.perform() }
    }

    @Test("書き出しは前面に出ず、印刷モードで開くときはアプリを前面に出す")
    func foreground() {
        #expect(!ExportPDFIntent.openAppWhenRun)
        #expect(OpenInPrintModeIntent.openAppWhenRun)
    }
}
