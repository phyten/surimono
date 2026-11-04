import AppKit
import SurimonoCore
import Testing

@testable import Surimono

/// Saving what opened from memory, and offering a parent file's documents as a binder.
@MainActor
struct IntakeDocumentTests {
    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }

        func file(_ name: String, _ text: String = "本文") throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }

        func model(
            _ bytes: Data, fileURL: URL?, format: DocumentFormat, title: String? = nil, binder: BinderModel? = nil
        ) -> DocumentViewModel {
            DocumentViewModel(
                data: bytes, fileURL: fileURL, format: format, preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: root.appendingPathComponent("Library")), title: title, binder: binder)
        }
    }

    private func settle(_ model: DocumentViewModel) async throws {
        for _ in 0..<500 where model.isRendering || model.includePlan == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("メモリ上の文書は選んだ場所へ新しいファイルとして保存する")
    func saves() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data("# 下書き".utf8)
        let model = fixture.model(bytes, fileURL: nil, format: .markdown, title: "Clipboard 0:13")
        defer { model.stop() }
        #expect(model.canSaveAsFile)
        let destination = fixture.root.appendingPathComponent("saved.md")
        var suggested: String?
        model.chooseSaveDestination = { name, finish in
            suggested = name
            finish(destination)
        }
        model.saveAsFile()
        #expect(suggested == "Clipboard 0-13.md")
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(model.toast?.title.contains("saved.md") == true)
        #expect(model.fileURL == nil)
    }

    @Test("クリップボードの画像は中身に合う拡張子で保存を勧める")
    func imageName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model(TestFixtures.png(red: 0.5), fileURL: nil, format: .image, title: "Clipboard")
        defer { model.stop() }
        var suggested: String?
        model.chooseSaveDestination = { name, _ in suggested = name }
        model.saveAsFile()
        #expect(suggested == "Clipboard.png")
    }

    @Test("保存パネルを閉じたら何も書かない")
    func cancelled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model(Data("本文".utf8), fileURL: nil, format: .plainText)
        defer { model.stop() }
        model.chooseSaveDestination = { _, finish in finish(nil) }
        model.saveAsFile()
        #expect(model.toast == nil)
    }

    @Test("書けなかったら理由を見せる")
    func failure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model(Data("本文".utf8), fileURL: nil, format: .plainText)
        defer { model.stop() }
        model.chooseSaveDestination = { _, finish in
            finish(fixture.root.appendingPathComponent("no-such-folder/a.txt"))
        }
        model.saveAsFile()
        #expect(model.toast?.systemImage == "exclamationmark.triangle")
    }

    @Test("ファイルから開いた文書・合本・画像の束には保存を出さない")
    func notForFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.file("a.md")
        let file = fixture.model(Data("本文".utf8), fileURL: url, format: .markdown)
        defer { file.stop() }
        #expect(!file.canSaveAsFile)
        file.chooseSaveDestination = { _, _ in Issue.record("保存先を聞かない") }
        file.saveAsFile()
        let binder = fixture.model(Data(), fileURL: nil, format: .pdf, binder: BinderModel(urls: [url]))
        defer { binder.stop() }
        #expect(!binder.canSaveAsFile)
    }

    @Test("読める文書が 2 つ以上ある親はトーストで合本へ誘う", .timeLimit(.minutes(1)))
    func offers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("a.md")
        _ = try fixture.file("b.md")
        let text = "# 親\n\n<<[a.md]\n\n<<[b.md]\n\n<<[gone.md]\n"
        let parent = try fixture.file("index.md", text)
        let model = fixture.model(Data(text.utf8), fileURL: parent, format: .markdown)
        defer { model.stop() }
        model.start()
        try await settle(model)
        let plan = try #require(model.includePlan)
        #expect(plan.documents.map(\.lastPathComponent) == ["a.md", "b.md"])
        #expect(plan.missing == ["gone.md"])
        #expect(model.toast?.action == .openIncludes)
        #expect(model.toast?.title.contains("2") == true)
    }

    @Test("読める文書が 1 つの親と普通の文書は誘わず、原文のまま開く", .timeLimit(.minutes(1)))
    func noOffer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("a.md")
        let text = "本文\n\n<<[a.md]\n"
        let parent = try fixture.file("index.md", text)
        let model = fixture.model(Data(text.utf8), fileURL: parent, format: .markdown)
        defer { model.stop() }
        model.start()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.includePlan == nil)
        #expect(model.toast == nil)
        #expect(model.themedSource?.data == Data(text.utf8))
    }

    @Test("メモリ上の文書の記法は親のフォルダーがないので読まない", .timeLimit(.minutes(1)))
    func noOfferForMemory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model(Data("<<[a.md]\n<<[b.md]\n".utf8), fileURL: nil, format: .markdown)
        defer { model.stop() }
        model.start()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.includePlan == nil)
    }

    @Test("合本は親の本文を前書きにして並びの順に読み、親のファイルは変えない", .timeLimit(.minutes(1)))
    func binderOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let names = ["z.md", "a.md", "m.pdf"]
        for name in names { _ = try fixture.file(name) }
        let text = "# 親\n\n<<[z.md]\n{{a.md}}\n/m.pdf\n<<[gone.md]\n"
        let parent = try fixture.file("index.md", text)
        let plan = try #require(MarkdownIncludes(markdown: text)).plan(parent: parent)
        let binder = BinderModel(plan: plan)
        defer { binder.stop() }
        #expect(binder.items.map(\.url.lastPathComponent) == ["index.md", "z.md", "a.md", "m.pdf"])
        #expect(binder.items.first?.isPreface == true)
        #expect(binder.items.first?.name == String(format: String(localized: "%@ (Preface)"), "index.md"))
        #expect(binder.missingPaths == ["gone.md"])
        let source = try await binder.source()
        let preface = try #require(source.children?.first)
        #expect(preface.data == Data("# 親\n\n".utf8))
        #expect(preface.fileURL == plan.parent)
        #expect(try Data(contentsOf: parent) == Data(text.utf8))
    }

    @Test("親の並びのままなら順序を設定として覚えず、読者が変えた順序だけ覚える", .timeLimit(.minutes(1)))
    func startingOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("z.md", "最後の名前")
        _ = try fixture.file("a.md", "最初の名前")
        let text = "<<[z.md]\n<<[a.md]\n"
        let parent = try fixture.file("index.md", text)
        let binder = BinderModel(plan: try #require(MarkdownIncludes(markdown: text)).plan(parent: parent))
        let model = fixture.model(Data(), fileURL: nil, format: .pdf, binder: binder)
        defer { model.stop() }
        _ = try await binder.source()
        #expect(!binder.isSortedByName)
        #expect(model.rememberedSettings.binderOrder == nil)
        binder.moveSelection(by: 1)
        #expect(model.rememberedSettings.binderOrder?.count == 2)
    }

    @Test("目次の文書は前書きを持たず、読み直しても前書きの規則を保つ", .timeLimit(.minutes(1)))
    func summaryBinder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("1.md")
        _ = try fixture.file("2.md")
        let text = "# 目次\n\n- [一](1.md)\n- [二](2.md)\n"
        let parent = try fixture.file("SUMMARY.md", text)
        let binder = BinderModel(plan: try #require(MarkdownIncludes(markdown: text)).plan(parent: parent))
        defer { binder.stop() }
        #expect(binder.urls.map(\.lastPathComponent) == ["1.md", "2.md"])
        #expect(binder.items.allSatisfy { !$0.isPreface })
    }

    @Test("「合本で開く」はルーターを通して親の窓と入れ替える", .timeLimit(.minutes(1)))
    func routerOpensPlan() throws {
        var opened: [MarkdownIncludes.Plan] = []
        let router = OpenRouter(
            openDocument: { _, _ in }, openBundle: { _, _ in }, openBinder: { _, _ in }, warn: { _ in },
            hasOpenWindows: { false }, showWelcome: {}, openIncludes: { opened.append($0) })
        let plan = try #require(MarkdownIncludes(markdown: "<<[a.md]\n"))
            .plan(parent: URL(fileURLWithPath: "/fixtures/index.md"), exists: { _ in true })
        router.open(includes: plan)
        #expect(opened == [plan])
    }
}
