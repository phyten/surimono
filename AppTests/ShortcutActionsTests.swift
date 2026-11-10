import AppIntents
import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
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
        private let fileAccess = ShortcutEnvironment.fileAccess
        /// The security-scoped accesses started and stopped, in order.
        private(set) var accessLog: [String] = []
        /// Whether a URL counts as security-scoped, as every file does in the sandboxed build.
        var isScoped = false

        init(router: OpenRouter? = nil) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ShortcutEnvironment.preferences = AppPreferences(defaults: suite.defaults)
            ShortcutEnvironment.library = UserLibrary(root: directory.appendingPathComponent("Library"))
            if let router { ShortcutEnvironment.router = router }
            ShortcutEnvironment.fileAccess = ShortcutFileAccess(
                backend: ShortcutFileAccess.Backend(
                    start: { [unowned self] url in
                        if isScoped { accessLog.append("start " + url.lastPathComponent) }
                        return isScoped
                    },
                    stop: { [unowned self] url in accessLog.append("stop " + url.lastPathComponent) }))
        }

        func restore() {
            ShortcutEnvironment.preferences = preferences
            ShortcutEnvironment.library = library
            ShortcutEnvironment.router = router
            ShortcutEnvironment.fileAccess = fileAccess
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

    private func memoryRouter(_ opened: @escaping (Data, DocumentFormat, String?, Bool) -> Void) -> OpenRouter {
        OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") },
            openBundle: { _, _ in
                Issue.record("束は開かない")
                return nil
            },
            openBinder: { _, _ in
                Issue.record("合本は開かない")
                return nil
            }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { true },
            showWelcome: {}, openMemory: opened)
    }

    @Test("場所のないファイル 1 つは、元のファイル名を題名にして、メモリから印刷モードで開く")
    func openDataInPrintMode() async throws {
        var opened: [(Data, DocumentFormat, String?, Bool)] = []
        let environment = try Environment(router: memoryRouter { opened.append(($0, $1, $2, $3)) })
        defer { environment.restore() }
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(data: Data("# a".utf8), filename: "made.md")]
        _ = try await intent.perform()
        #expect(opened.count == 1)
        #expect(opened.first?.0 == Data("# a".utf8))
        #expect(opened.first?.1 == .markdown)
        #expect(opened.first?.2 == "made.md")
        #expect(opened.first?.3 == true)
    }

    @Test("ショートカットが終わると消えるファイル 1 つは、返る前に読んでメモリから開き、消えたあとも中身が残る")
    func openTemporaryFile() async throws {
        var opened: [(Data, DocumentFormat, String?, Bool)] = []
        let environment = try Environment(router: memoryRouter { opened.append(($0, $1, $2, $3)) })
        defer { environment.restore() }
        environment.isScoped = true
        let url = try environment.write("made.md", Data("# 途中の成果".utf8))
        var file = IntentFile(fileURL: url)
        file.removedOnCompletion = true
        var intent = OpenInPrintModeIntent()
        intent.files = [file]
        _ = try await intent.perform()
        try FileManager.default.removeItem(at: url)
        #expect(opened.count == 1)
        #expect(opened.first?.0 == Data("# 途中の成果".utf8))
        #expect(opened.first?.2 == "made.md")
        #expect(opened.first?.3 == true)
        // The bytes were read inside the access, and nothing goes on reading the file.
        #expect(environment.accessLog == ["start made.md", "stop made.md"])
    }

    @Test("ショートカットが終わると消えるファイルが複数あるときは、開かずに「先に保存する」と断る")
    func openSeveralTemporaryFiles() async throws {
        let environment = try Environment(router: memoryRouter { _, _, _, _ in Issue.record("メモリからは開かない") })
        defer { environment.restore() }
        var first = IntentFile(fileURL: try environment.write("1.png", TestFixtures.png(red: 0.1)))
        first.removedOnCompletion = true
        let second = IntentFile(fileURL: try environment.write("2.png", TestFixtures.png(red: 0.9)))
        var intent = OpenInPrintModeIntent()
        intent.files = [first, second]
        let failure = await #expect(throws: ShortcutFailure.self) { _ = try await intent.perform() }
        #expect(failure?.message.contains("Save") == true || failure?.message.contains("保存") == true)
    }

    @Test("ショートカットが終わると消える ZIP は、開かずに「先に保存する」と断る")
    func openTemporaryArchive() async throws {
        let environment = try Environment(router: memoryRouter { _, _, _, _ in Issue.record("メモリからは開かない") })
        defer { environment.restore() }
        var file = IntentFile(fileURL: try environment.write("images.zip", Data([0x50, 0x4B, 0x05, 0x06])))
        file.removedOnCompletion = true
        var intent = OpenInPrintModeIntent()
        intent.files = [file]
        await #expect(throws: ShortcutFailure.self) { _ = try await intent.perform() }
    }

    @Test("開き方は、残るファイルか、消えるファイルか、その数と種類で決まる")
    func plans() {
        let a = URL(fileURLWithPath: "/fixtures/a.md")
        let b = URL(fileURLWithPath: "/fixtures/b.pdf")
        func input(_ url: URL?, temporary: Bool = false, _ format: DocumentFormat?) -> ShortcutFiles.Input {
            ShortcutFiles.Input(
                url: url, isTemporary: temporary, name: url?.lastPathComponent ?? "made", format: format)
        }
        #expect(ShortcutFiles.plan([]) == .none)
        #expect(ShortcutFiles.plan([input(a, .markdown), input(b, .pdf)]) == .files([a, b]))
        #expect(ShortcutFiles.plan([input(a, temporary: true, .markdown)]) == .memory(0, .markdown))
        #expect(ShortcutFiles.plan([input(nil, .pdf)]) == .memory(0, .pdf))
        #expect(ShortcutFiles.plan([input(nil, nil)]) == .none)
        #expect(ShortcutFiles.plan([input(nil, .zipArchive)]) == .saveFirst)
        #expect(ShortcutFiles.plan([input(a, .markdown), input(nil, .pdf)]) == .saveFirst)
        #expect(ShortcutFiles.plan([input(a, .markdown), input(b, temporary: true, .pdf)]) == .saveFirst)
    }

    /// A router whose single documents get a real window before the open is reported as finished.
    private func windowRouter(
        _ environment: Environment, opens: Bool = true, made: @escaping (MemoryDocumentWindowController) -> Void
    ) -> OpenRouter {
        OpenRouter(
            openDocument: { url, completion in
                guard opens else { return completion(false) }
                // An open document is only brought forward.
                if DocumentWindows.shared.openModels.contains(where: { $0.fileURL == url }) { return completion(true) }
                let model = DocumentViewModel(
                    data: TestFixtures.pdf("access", pages: 1), fileURL: url, format: .pdf,
                    preferences: AppPreferences(defaults: environment.suite.defaults),
                    library: UserLibrary(root: environment.directory.appendingPathComponent("Library")))
                made(MemoryDocumentWindowController(model: model) {})
                completion(true)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in }, hasOpenWindows: { true },
            showWelcome: {}, openWindows: { DocumentWindows.shared.openModels })
    }

    @Test("残る PDF を印刷モードで開くと、その窓がアクセスを持ち、その窓を閉じるだけで手放す")
    func accessEndsWithWindow() async throws {
        var controllers: [MemoryDocumentWindowController] = []
        let environment = try Environment()
        defer { environment.restore() }
        ShortcutEnvironment.router = windowRouter(environment) { controllers.append($0) }
        environment.isScoped = true
        let url = try environment.write("paper.pdf", TestFixtures.pdf("access", pages: 1))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: url)]
        _ = try await intent.perform()
        #expect(controllers.count == 1)
        #expect(environment.accessLog == ["start paper.pdf"])
        controllers.first?.window?.close()
        #expect(environment.accessLog == ["start paper.pdf", "stop paper.pdf"])
    }

    @Test("文書を開き終えたあとで窓ができ、組版が終わる前に閉じても、アクセスを 1 回ずつ始めて手放す", .timeLimit(.minutes(1)))
    func accessWhenClosedBeforeRender() async throws {
        let router = OpenRouter(
            // The document reports that it opened before its window exists, as a document group's does.
            openDocument: { _, completion in completion(true) }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil }, warn: { _ in }, hasOpenWindows: { true }, showWelcome: {},
            openWindows: { DocumentWindows.shared.openModels })
        let environment = try Environment(router: router)
        let windowsRouter = DocumentWindows.shared.router
        DocumentWindows.shared.router = router
        defer {
            DocumentWindows.shared.router = windowsRouter
            environment.restore()
        }
        environment.isScoped = true
        let url = try environment.write("slow.md", Data("# a".utf8))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: url)]
        _ = try await intent.perform()
        #expect(router.pendingOpens == 0)
        #expect(environment.accessLog == ["start slow.md"])
        // The pages never get done.
        let renderer = DocumentRenderer(paginate: { _ in
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        })
        let model = DocumentViewModel(
            data: Data("# a".utf8), fileURL: url, format: .markdown,
            preferences: AppPreferences(defaults: environment.suite.defaults),
            library: UserLibrary(root: environment.directory.appendingPathComponent("Library")), renderer: renderer)
        let controller = MemoryDocumentWindowController(model: model) {}
        controller.showWindow(nil)
        for _ in 0..<500 where !model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.isRendering)
        #expect(model.result == nil)
        #expect(environment.accessLog == ["start slow.md"])
        controller.window?.close()
        #expect(environment.accessLog == ["start slow.md", "stop slow.md"])
    }

    @Test("窓がアクセスを受け取る前になくなったら、待っているアクセスを手放す")
    func accessWhenModelStopsUnregistered() async throws {
        let router = OpenRouter(
            openDocument: { _, completion in completion(true) }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil }, warn: { _ in }, hasOpenWindows: { true }, showWelcome: {})
        let environment = try Environment(router: router)
        let windowsRouter = DocumentWindows.shared.router
        DocumentWindows.shared.router = router
        defer {
            DocumentWindows.shared.router = windowsRouter
            environment.restore()
        }
        environment.isScoped = true
        let url = try environment.write("gone.md", Data("# a".utf8))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: url)]
        _ = try await intent.perform()
        let model = DocumentViewModel(
            data: Data("# a".utf8), fileURL: url, format: .markdown,
            preferences: AppPreferences(defaults: environment.suite.defaults),
            library: UserLibrary(root: environment.directory.appendingPathComponent("Library")))
        model.stop()
        #expect(environment.accessLog == ["start gone.md", "stop gone.md"])
    }

    @Test("閉じていく前の窓は、同じファイルを開き直す要求が待たせているアクセスを手放さない")
    func accessOfALaterRequestSurvivesTheOldWindow() async throws {
        let router = OpenRouter(
            openDocument: { _, completion in completion(true) }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil }, warn: { _ in }, hasOpenWindows: { true }, showWelcome: {})
        let environment = try Environment(router: router)
        let windowsRouter = DocumentWindows.shared.router
        DocumentWindows.shared.router = router
        defer {
            DocumentWindows.shared.router = windowsRouter
            environment.restore()
        }
        environment.isScoped = true
        let url = try environment.write("again.md", Data("# a".utf8))
        func model() -> DocumentViewModel {
            DocumentViewModel(
                data: Data("# a".utf8), fileURL: url, format: .markdown,
                preferences: AppPreferences(defaults: environment.suite.defaults),
                library: UserLibrary(root: environment.directory.appendingPathComponent("Library")))
        }
        // The old window registered long ago, when nothing waited for its file.
        let old = model()
        router.handAccess(to: old)
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: url)]
        _ = try await intent.perform()
        old.stop()
        #expect(environment.accessLog == ["start again.md"])
        let new = model()
        router.handAccess(to: new)
        new.stop()
        #expect(environment.accessLog == ["start again.md", "stop again.md"])
    }

    @Test("同じファイルを 2 回開くと、2 回目のアクセスはすぐ手放し、窓を閉じると 1 回目も手放す")
    func accessForOpenFile() async throws {
        var controllers: [MemoryDocumentWindowController] = []
        let environment = try Environment()
        defer { environment.restore() }
        ShortcutEnvironment.router = windowRouter(environment) { controllers.append($0) }
        environment.isScoped = true
        let url = try environment.write("paper.pdf", TestFixtures.pdf("access", pages: 1))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: url)]
        _ = try await intent.perform()
        _ = try await intent.perform()
        #expect(controllers.count == 1)
        #expect(environment.accessLog == ["start paper.pdf", "start paper.pdf", "stop paper.pdf"])
        controllers.first?.window?.close()
        #expect(environment.accessLog == ["start paper.pdf", "start paper.pdf", "stop paper.pdf", "stop paper.pdf"])
    }

    @Test("開けなかったファイルのアクセスは、すぐ手放す")
    func accessAfterFailedOpen() async throws {
        let environment = try Environment()
        defer { environment.restore() }
        ShortcutEnvironment.router = windowRouter(environment, opens: false) { _ in Issue.record("窓は作らない") }
        environment.isScoped = true
        let url = try environment.write("paper.pdf", TestFixtures.pdf("access", pages: 1))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: url)]
        _ = try await intent.perform()
        #expect(environment.accessLog == ["start paper.pdf", "stop paper.pdf"])
    }

    @Test("対応する文書がない選択は、警告を出してアクセスをすべて手放す")
    func accessAfterWarning() async throws {
        var warnings = 0
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil }, warn: { _ in warnings += 1 }, hasOpenWindows: { true }, showWelcome: {})
        let environment = try Environment(router: router)
        defer { environment.restore() }
        environment.isScoped = true
        let archive = try environment.write("a.zip", Data([0x50, 0x4B, 0x05, 0x06]))
        let other = try environment.write("b.zip", Data([0x50, 0x4B, 0x05, 0x06]))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: archive), IntentFile(fileURL: other)]
        _ = try await intent.perform()
        #expect(warnings == 1)
        #expect(environment.accessLog == ["start a.zip", "start b.zip", "stop a.zip", "stop b.zip"])
    }

    @Test("2 つの画像を束で開くと、束の窓を閉じたときに両方のアクセスを手放す")
    func accessEndsWithBundleWindow() async throws {
        let environment = try Environment()
        defer { environment.restore() }
        let windows = ImageBundleWindows()
        windows.preferences = AppPreferences(defaults: environment.suite.defaults)
        windows.library = UserLibrary(root: environment.directory.appendingPathComponent("Library"))
        var bundle: DocumentViewModel?
        ShortcutEnvironment.router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") },
            openBundle: { urls, excluded in
                bundle = windows.open(urls, excluded: excluded)
                return bundle
            }, openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { true },
            showWelcome: {})
        environment.isScoped = true
        let first = try environment.write("1.png", TestFixtures.png(red: 0.1))
        let second = try environment.write("2.png", TestFixtures.png(red: 0.9))
        var intent = OpenInPrintModeIntent()
        intent.files = [IntentFile(fileURL: first), IntentFile(fileURL: second)]
        _ = try await intent.perform()
        #expect(environment.accessLog == ["start 1.png", "start 2.png"])
        let window = try #require(bundle?.window)
        window.close()
        #expect(environment.accessLog.sorted() == ["start 1.png", "start 2.png", "stop 1.png", "stop 2.png"])
    }

    @Test("書き出しは、組版が終わるまでファイルへのアクセスを持ち、終わったら手放す", .timeLimit(.minutes(1)))
    func exportAccess() async throws {
        let environment = try Environment()
        defer { environment.restore() }
        environment.isScoped = true
        let url = try environment.write("memo.md", Data("# a".utf8))
        var intent = ExportPDFIntent()
        intent.file = IntentFile(fileURL: url)
        intent.layout = .a4Single
        _ = try await intent.perform()
        #expect(environment.accessLog == ["start memo.md", "stop memo.md"])
    }

    @Test("書き出しが失敗しても、ファイルへのアクセスを手放す", .timeLimit(.minutes(1)))
    func exportAccessAfterFailure() async throws {
        let environment = try Environment()
        defer { environment.restore() }
        environment.isScoped = true
        let url = try environment.write("broken.pdf", Data("PDF ではない".utf8))
        var intent = ExportPDFIntent()
        intent.file = IntentFile(fileURL: url)
        await #expect(throws: ShortcutFailure.self) { _ = try await intent.perform() }
        #expect(environment.accessLog == ["start broken.pdf", "stop broken.pdf"])
    }

    private func launchRouter(
        active: @escaping () -> Bool, hasWindows: @escaping () -> Bool = { false }, welcome: @escaping () -> Void
    ) -> OpenRouter {
        OpenRouter(
            openDocument: { _, _ in }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: hasWindows, showWelcome: welcome, isActive: active)
    }

    @Test("裏で起動されたアプリは、起動時の確認が書き出しの途中でも直後でもウェルカム画面を出さない", .timeLimit(.minutes(1)))
    func noWelcomeForBackgroundExport() async throws {
        var welcomes = 0
        var duringExport = 0
        let router = launchRouter(active: { false }, welcome: { welcomes += 1 })
        let environment = try Environment(router: router)
        defer { environment.restore() }
        let url = try environment.write("memo.md", Data("# a".utf8))
        var intent = ExportPDFIntent()
        intent.file = IntentFile(fileURL: url)
        intent.layout = .a4Single
        // The launch's check comes while the pages are laid out.
        let check = Task { @MainActor in
            while router.headlessWork == 0 { await Task.yield() }
            duringExport = router.headlessWork
            router.showWelcomeAfterLaunch()
        }
        _ = try await intent.perform()
        await check.value
        #expect(duringExport == 1)
        #expect(router.headlessWork == 0)
        router.showWelcomeAfterLaunch()
        #expect(welcomes == 0)
    }

    @Test("裏で起動されたアプリは、起動時の確認が書き出しより先でもウェルカム画面を出さない", .timeLimit(.minutes(1)))
    func noWelcomeBeforeBackgroundExport() async throws {
        var welcomes = 0
        let router = launchRouter(active: { false }, welcome: { welcomes += 1 })
        let environment = try Environment(router: router)
        defer { environment.restore() }
        router.showWelcomeAfterLaunch()
        #expect(welcomes == 0)
        let url = try environment.write("memo.md", Data("# a".utf8))
        var intent = ExportPDFIntent()
        intent.file = IntentFile(fileURL: url)
        intent.layout = .a4Single
        _ = try await intent.perform()
        #expect(welcomes == 0)
    }

    @Test("前面で起動して何も開いていなければ、起動時の確認がウェルカム画面を 1 回出す")
    func welcomeForInteractiveLaunch() {
        var welcomes = 0
        let router = launchRouter(active: { true }, welcome: { welcomes += 1 })
        router.showWelcomeAfterLaunch()
        #expect(welcomes == 1)
        // Coming back to the app later shows nothing more.
        router.showWelcomeOnArrival()
        #expect(welcomes == 1)
    }

    @Test("裏で起動されたアプリへ利用者が来て、何も開いていなければ、ウェルカム画面を 1 回出す")
    func welcomeOnArrival() {
        var welcomes = 0
        let router = launchRouter(active: { false }, welcome: { welcomes += 1 })
        router.showWelcomeAfterLaunch()
        router.showWelcomeOnArrival()
        #expect(welcomes == 1)
        router.showWelcomeOnArrival()
        #expect(welcomes == 1)
    }

    @Test("裏で起動されたアプリへ来たとき、書き出しが走っている間はウェルカム画面を出さない")
    func noWelcomeOnArrivalDuringExport() {
        var welcomes = 0
        let router = launchRouter(active: { false }, welcome: { welcomes += 1 })
        router.showWelcomeAfterLaunch()
        router.beginHeadlessWork()
        router.showWelcomeOnArrival()
        router.showWelcomeIfIdle()
        router.endHeadlessWork()
        #expect(welcomes == 0)
    }

    @Test("裏で起動されたアプリへ、開いている途中の文書とともに来たときは、ウェルカム画面を出さない")
    func noWelcomeOnArrivalWithPendingOpen() {
        var welcomes = 0
        let router = launchRouter(active: { false }, welcome: { welcomes += 1 })
        router.showWelcomeAfterLaunch()
        router.open([URL(fileURLWithPath: "/fixtures/a.md")])
        #expect(router.pendingOpens == 1)
        router.showWelcomeOnArrival()
        #expect(welcomes == 0)
    }

    @Test("裏で起動されたアプリへ来たとき、窓が開いていればウェルカム画面を出さない")
    func noWelcomeOnArrivalWithWindow() {
        var welcomes = 0
        let router = launchRouter(active: { false }, hasWindows: { true }, welcome: { welcomes += 1 })
        router.showWelcomeAfterLaunch()
        router.showWelcomeOnArrival()
        #expect(welcomes == 0)
    }

    @Test("前面で起動したアプリで最後の窓を閉じたあとは、アプリへ戻ってもウェルカム画面を出さない")
    func noWelcomeOnReturn() {
        var welcomes = 0
        var hasWindows = true
        let router = launchRouter(active: { true }, hasWindows: { hasWindows }, welcome: { welcomes += 1 })
        router.showWelcomeAfterLaunch()
        hasWindows = false
        router.showWelcomeOnArrival()
        #expect(welcomes == 0)
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
