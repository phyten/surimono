import AppKit
import Darwin
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing
import UniformTypeIdentifiers

@testable import Surimono

@MainActor
struct SourceFileOpeningTests {
    /// Thirty transport stream packets: each starts with the sync byte and carries a payload full of zeros.
    private var video: Data {
        var data = Data()
        for _ in 0..<30 { data += Data([0x47, 0x40, 0x00, 0x10]) + Data(repeating: 0, count: 184) }
        return data
    }

    private func binaryPropertyList() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["pages": 12], format: .binary, options: 0)
    }

    private func xmlPropertyList() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["pages": 12], format: .xml, options: 0)
    }

    private func document(_ name: String, _ data: Data, type: UTType) throws -> SurimonoDocument {
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        return try SurimonoDocument(file: file, contentType: type)
    }

    private func withFile(_ name: String, _ data: Data, _ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        try await body(url)
    }

    private func wait(_ reason: Comment, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), reason)
    }

    // MARK: Declared types

    @Test(
        "ソースコードの拡張子の型は、どれも読み取れる型に準拠する",
        arguments: [
            "swift", "py", "rb", "js", "ts", "tsx", "go", "rs", "kt", "cs", "lua", "jl", "hs", "vue", "plist", "css",
            "ini", "java", "c", "h", "cpp", "m", "php", "sh", "sql", "diff", "mk", "scss", "jsx", "sty",
        ])
    func readableTypes(suffix: String) throws {
        let type = try #require(UTType(filenameExtension: suffix))
        #expect(SourceFileOpening.reads(type), "\(type.identifier)")
    }

    @Test("macOS が型を持たない拡張子は、取り込みの宣言でソースコードの型になる")
    func importedDeclaration() throws {
        let imported = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        let declaration = try #require(
            imported.first { $0["UTTypeIdentifier"] as? String == "app.surimono.source-code" })
        #expect(declaration["UTTypeConformsTo"] as? [String] == ["public.source-code"])
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: [String]])
        let extensions = Set(tags["public.filename-extension"] ?? [])
        #expect(extensions.isSuperset(of: ["go", "rs", "kt", "cs", "lua", "jl", "hs", "vue"]))
        // Every one of them is an extension the app opens, and none is one macOS already gives a type.
        #expect(extensions.isSubset(of: DocumentFormat.sourceCodeExtensions))
        #expect(extensions.isDisjoint(with: ["ts", "mts", "plist", "swift", "py", "css", "ini"]))
        #expect(UTType.surimonoSourceCode.identifier == "app.surimono.source-code")
        #expect(UTType.surimonoSourceCode.conforms(to: .sourceCode))
    }

    // MARK: The document's own check

    @Test("動画の型で届いた TypeScript の .ts をテキストとして読み、バイト列を保持する")
    func typeScript() throws {
        let bytes = Data("const pages: number = 2;\n".utf8)
        let read = try document("layout.ts", bytes, type: .mpeg2TransportStream)
        #expect(read.format == .plainText)
        #expect(read.data == bytes)
    }

    @Test("動画の型で届いた TypeScript の .mts と、型のない Dockerfile も、テキストの文書になる")
    func textUnderOtherTypes() throws {
        let avchd = try #require(UTType(filenameExtension: "mts"))
        let module = try document("module.mts", Data("export const a = 1\n".utf8), type: avchd)
        #expect(module.format == .plainText)
        #expect(module.contentType == .plainText)
        #expect(try document("Dockerfile", Data("FROM scratch\n".utf8), type: .data).format == .plainText)
    }

    @Test("トランスポートストリームは、.ts でもほかの拡張子でも、テキストではないと断って開かない")
    func transportStream() {
        #expect(throws: SourceFileError.notText) { try document("clip.ts", video, type: .mpeg2TransportStream) }
        #expect(throws: SourceFileError.notText) { try document("clip.ts", video, type: .plainText) }
        #expect(throws: SourceFileError.notText) { try document("clip.m2t", video, type: .mpeg2TransportStream) }
        #expect(throws: SourceFileError.notText) { try document("clip.mts", video, type: .plainText) }
    }

    @Test("テキストとして開く道で読み込むまでに Dockerfile の中身がバイナリに替わっていたら、開かない")
    func changedBetweenGateAndLoad() throws {
        // What the router asks the document controller for: the file's own name under the plain text type. The
        // bytes are the ones found at the path when the framework read it, after the router's look.
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        #expect(throws: SourceFileError.notText) { try document("Dockerfile", machO, type: .plainText) }
        #expect(throws: SourceFileError.notText) { try document("Gemfile", video, type: .plainText) }
        #expect(throws: SourceFileError.notText) { try document("tool", video, type: .plainText) }
        #expect(throws: SourceFileError.notText) { try document(".env", try binaryPropertyList(), type: .plainText) }
        let text = try document("Dockerfile", Data("FROM scratch\n".utf8), type: .plainText)
        #expect(text.format == .plainText)
        #expect(text.isGatedText)
        // A name with a format of its own is not the gate's, under the plain text type as under any.
        #expect(try document("notes.txt", video, type: .plainText).format == .plainText)
    }

    @Test("ウインドウに出す形式は、門がテキストと決めた文書ではプレーンテキストのままで、拡張子では直さない")
    func formatShown() throws {
        let url = URL(fileURLWithPath: "/fixtures/notes.md")
        // Text that arrived under a video's type: the gate looked at it, and its answer stands everywhere.
        let gated = try document("notes.md", Data("# words\n".utf8), type: .mpeg2TransportStream)
        #expect(gated.isGatedText)
        #expect(gated.format == .plainText)
        #expect(gated.format(at: url) == .plainText)
        // Where the gate had nothing to say, the extension still corrects the type.
        let markdown = try document("notes.md", Data("# words\n".utf8), type: .plainText)
        #expect(!markdown.isGatedText)
        #expect(markdown.format(at: url) == .markdown)
        let feed = try document("feed.xml", Data("<a/>".utf8), type: .html)
        #expect(feed.format(at: URL(fileURLWithPath: "/fixtures/feed.xml")) == .html)
        let script = try document("main.ts", Data("let a = 1\n".utf8), type: .mpeg2TransportStream)
        #expect(script.format(at: URL(fileURLWithPath: "/fixtures/main.ts")) == .plainText)
        #expect(try document("a.pdf", Data("%PDF-1.4".utf8), type: .pdf).format(at: nil) == .pdf)
    }

    @Test("名前のないまま plist の型で届いたバイナリの plist は開かない")
    func namelessPropertyList() throws {
        let binary = try binaryPropertyList()
        #expect(throws: SourceFileError.notText) {
            try SurimonoDocument(file: FileWrapper(regularFileWithContents: binary), contentType: .propertyList)
        }
        let xml = try SurimonoDocument(
            file: FileWrapper(regularFileWithContents: try xmlPropertyList()), contentType: .propertyList)
        #expect(xml.format == .plainText)
    }

    @Test("XML の .plist はテキストとして読み、Foundation が作ったバイナリの .plist は開かない")
    func propertyList() throws {
        #expect(try document("Info.plist", try xmlPropertyList(), type: .propertyList).format == .plainText)
        let binary = try binaryPropertyList()
        #expect(throws: SourceFileError.notText) { try document("Info.plist", binary, type: .propertyList) }
    }

    @Test("macOS が型を持たない .go や .rs をテキストとして読む", arguments: ["go", "rs", "kt", "cs", "lua", "jl", "hs", "vue"])
    func untypedExtensions(suffix: String) throws {
        let bytes = Data("x = 1\n".utf8)
        let type = UTType(filenameExtension: suffix) ?? .surimonoSourceCode
        let read = try document("sample." + suffix, bytes, type: type)
        #expect(read.format == .plainText)
        #expect(read.data == bytes)
    }

    @Test("テキスト以外の型の文書は今までどおりの形式で読む")
    func otherTypesUnchanged() throws {
        #expect(try document("a.md", Data("# a".utf8), type: .surimonoMarkdown).format == .markdown)
        #expect(try document("a.pdf", Data("%PDF-1.4".utf8), type: .pdf).format == .pdf)
        #expect(try document("a.txt", video, type: .plainText).format == .plainText)
    }

    // MARK: The way a single file takes

    @Test(
        "型のないテキストは、名前か shebang で言語が分かればテキストとして開く道を選ぶ",
        arguments: [
            ("Dockerfile", "FROM scratch\n"), ("Gemfile", "source \"https://example.com\"\n"), (".env", "A=1\n"),
            (".env.local", "A=1\n"), ("tool", "#!/usr/bin/env python3\nprint(1)\n"), ("Cargo.lock", "version = 3\n"),
        ])
    func routesAsText(name: String, text: String) async throws {
        try await withFile(name, Data(text.utf8)) { url in
            #expect(SourceFileOpening.route(for: url) == .asText)
        }
    }

    @Test("動画の .ts と .mts、バイナリの .plist は、中身を読み込む前に断る道を選ぶ")
    func routesToRefusal() async throws {
        try await withFile("clip.ts", video) { #expect(SourceFileOpening.route(for: $0) == .refuse) }
        try await withFile("clip.mts", video) { #expect(SourceFileOpening.route(for: $0) == .refuse) }
        let binary = try binaryPropertyList()
        try await withFile("Info.plist", binary) { #expect(SourceFileOpening.route(for: $0) == .refuse) }
    }

    @Test(
        "型のある文書と、テキストとして開けないファイルは、今までどおり文書を開く処理に任せる",
        arguments: [
            ("main.ts", "let a = 1\n"), ("module.mts", "export const a = 1\n"),
            ("Info.plist", "<plist/>\n"), ("main.swift", "let a = 1\n"),
            ("notes.md", "# a\n"), ("Makefile", "all:\n"), ("LICENSE", "Permission is granted.\n"),
            ("archive.zip", "#!/bin/sh\n"), ("clip.txt", "words\n"),
        ])
    func routesToDocument(name: String, text: String) async throws {
        try await withFile(name, Data(text.utf8)) { url in
            #expect(SourceFileOpening.route(for: url) == .document)
        }
    }

    @Test("固定名でも中身がバイナリなら、テキストとして開かずに断る")
    func binaryUnderFixedName() async throws {
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        try await withFile("Dockerfile", machO) { #expect(SourceFileOpening.route(for: $0) == .refuse) }
        try await withFile("Gemfile", video) { #expect(SourceFileOpening.route(for: $0) == .refuse) }
    }

    @Test("実際の型が動画のファイルは、中身が shebang つきのテキストでも、テキストとして開く道を選ばない")
    func knownTypeIsNotText() async throws {
        try await withFile("clip.mp4", Data("#!/bin/sh\necho 1\n".utf8)) { url in
            let type = try #require(try url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            #expect(type.conforms(to: .movie))
            #expect(SourceFileOpening.route(for: url) == .document)
        }
    }

    @Test("ないファイルと読む許可のないファイルは、文書を開く処理に任せる")
    func missingAndUnreadable() async throws {
        #expect(SourceFileOpening.route(for: URL(fileURLWithPath: "/fixtures/missing.ts")) == .document)
        try await withFile("locked.ts", video) { url in
            #expect(chmod(url.path, 0o000) == 0)
            defer { chmod(url.path, 0o600) }
            #expect(SourceFileOpening.route(for: url) == .document)
        }
    }

    @Test("ページに組める大きさを超えるテキストは、読み込む前に「大きすぎる」として断る道を選ぶ")
    func tooLarge() async throws {
        let limit = PageLayoutLimits.plainTextBytes
        try await withFile("main.ts", Data(repeating: 0x61, count: limit + 1)) { url in
            #expect(SourceFileOpening.route(for: url) == .tooLarge(limit + 1))
            var refusals: [DocumentRenderer.RenderingError] = []
            var opened = 0
            let router = OpenRouter(
                openDocument: { _, _ in opened += 1 }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil },
                warn: { _ in }, hasOpenWindows: { true }, showWelcome: {},
                openAsText: { _, _ in opened += 1 },
                refuse: { if let error = $0 as? DocumentRenderer.RenderingError { refusals.append(error) } })
            router.open([url])
            #expect(opened == 0)
            #expect(refusals == [.tooLarge(bytes: limit + 1)])
            #expect(router.refusesSingle(url))
        }
        try await withFile("main.ts", Data(repeating: 0x61, count: limit)) { url in
            #expect(SourceFileOpening.route(for: url) == .document)
        }
        try await withFile("Dockerfile", Data("FROM a\n".utf8) + Data(repeating: 0x61, count: limit)) { url in
            #expect(SourceFileOpening.route(for: url) == .tooLarge(limit + 7))
        }
    }

    @Test("ショートカットに失敗を返すために、1 つのファイルが窓なしで断られるかを先に答える")
    func refusedSingleFile() async throws {
        let router = OpenRouter(
            openDocument: { _, _ in }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: { true }, showWelcome: {})
        try await withFile("clip.ts", video) { #expect(router.refusesSingle($0)) }
        try await withFile("main.ts", Data("let a = 1\n".utf8)) { #expect(!router.refusesSingle($0)) }
        try await withFile("Dockerfile", Data("FROM a\n".utf8)) { #expect(!router.refusesSingle($0)) }
        try await withFile("notes.md", video) { #expect(!router.refusesSingle($0)) }
    }

    @Test("読み直しと合本の読み取りは、動画を読み込まずに断り、テキストはそのまま読む")
    func gatedRead() async throws {
        try await withFile("clip.ts", video) { url in
            #expect(throws: SourceFileError.notText) { try SourceFileOpening.read(url, format: .plainText) }
        }
        let binary = try binaryPropertyList()
        try await withFile("Info.plist", binary) { url in
            #expect(throws: SourceFileError.notText) { try SourceFileOpening.read(url, format: .plainText) }
        }
        try await withFile("Dockerfile", video) { url in
            #expect(throws: SourceFileError.notText) { try SourceFileOpening.read(url, format: .plainText) }
        }
        try await withFile("main.ts", Data("let a = 1\n".utf8)) { url in
            let read = try SourceFileOpening.read(url, format: .plainText)
            #expect(read == Data("let a = 1\n".utf8))
        }
        // A format of its own is read as it always was, whatever is inside.
        try await withFile("notes.md", video) { url in
            let read = try SourceFileOpening.read(url, format: .markdown)
            #expect(read == video)
        }
    }

    @Test("拡張子のない Dockerfile から、文書の仕組みでテキストの文書を作れる")
    func makesDocument() async throws {
        try await withFile("Dockerfile", Data("FROM scratch\n".utf8)) { url in
            let (document, isNew) = try SourceFileOpening.document(for: url)
            defer { document.close() }
            #expect(isNew)
            #expect(document.fileURL?.standardizedFileURL == url.standardizedFileURL)
            #expect(document.fileType == UTType.plainText.identifier)
        }
    }

    // MARK: Bytes that arrive later

    @Test("開いている .plist がバイナリで保存し直されても、最後に表示できたページを残して知らせる", .timeLimit(.minutes(1)))
    func reloadKeepsLastGoodDocument() async throws {
        let xml = try xmlPropertyList()
        let binary = try binaryPropertyList()
        try await withFile("Info.plist", xml) { url in
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            let directory = url.deletingLastPathComponent()
            let renderer = DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Plist", pages: 1))! })
            let model = DocumentViewModel(
                data: xml, fileURL: url, format: .plainText, preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: directory.appendingPathComponent("Library")), renderer: renderer,
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
            model.start()
            defer { model.stop() }
            try await wait("組版が終わる") { model.result != nil && !model.isRendering }
            let pages = try #require(model.result?.logicalDocument)
            model.readReloadData = { _, _ in binary }
            model.reload()
            try await wait("読み直しの失敗を知らせる") { model.toast?.detail == SourceFileError.notText.localizedDescription }
            #expect(model.data == xml)
            #expect(model.result?.logicalDocument === pages)
            #expect(!model.isRendering)
        }
    }

    @Test("開いている Dockerfile がバイナリに替わっても、最後に表示できたページを残して知らせる", .timeLimit(.minutes(1)))
    func reloadOfUntypedFile() async throws {
        let text = Data("FROM scratch\n".utf8)
        let video = video
        try await withFile("Dockerfile", text) { url in
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            let directory = url.deletingLastPathComponent()
            let renderer = DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Text", pages: 1))! })
            let model = DocumentViewModel(
                data: text, fileURL: url, format: .plainText, preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: directory.appendingPathComponent("Library")), renderer: renderer,
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
            model.start()
            defer { model.stop() }
            try await wait("組版が終わる") { model.result != nil && !model.isRendering }
            let pages = try #require(model.result?.logicalDocument)
            // The file itself is replaced, and the window's own reading finds out before loading it.
            try video.write(to: url, options: .atomic)
            model.reload()
            try await wait("読み直しの失敗を知らせる") { model.toast?.detail == SourceFileError.notText.localizedDescription }
            #expect(model.data == text)
            #expect(model.result?.logicalDocument === pages)
        }
    }

    private func png(side: Int) throws -> Data {
        let image = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(image.representation(using: .png, properties: [:]))
    }

    @Test("拡張子のない画像の文書は、読み直しても門に断られない", .timeLimit(.minutes(1)))
    func imageWithoutExtensionReloads() async throws {
        let first = try png(side: 4)
        let second = try png(side: 6)
        #expect(first != second)
        try await withFile("illustration", first) { url in
            // By its name alone this is an untyped file full of control bytes. It is an image document, and the
            // gate is asked about plain text only.
            #expect(TextFileGate.refuses(fileName: "illustration", data: second))
            #expect(!SourceFileOpening.refuses(second, at: url, format: .image))
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            let directory = url.deletingLastPathComponent()
            let model = DocumentViewModel(
                data: first, fileURL: url, format: .image, preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: directory.appendingPathComponent("Library")),
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
            model.start()
            defer { model.stop() }
            try await wait("組版が終わる") { model.result != nil && !model.isRendering }
            try second.write(to: url, options: .atomic)
            model.reload()
            try await wait("読み直した画像を採る") { model.data == second }
            #expect(model.toast?.detail != SourceFileError.notText.localizedDescription)
        }
    }

    @Test("合本の画像の子も、拡張子がなくても門に断られない")
    func binderImageChild() async throws {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }
        let image = try png(side: 4)
        try await withFile("illustration", image) { file in
            let binder = BinderModel(urls: [])
            defer { binder.stop() }
            binder.putBack(.init(url: file, format: .image), at: 0)
            let source = try await binder.source()
            #expect(source.children?.first?.data == image)
            #expect(binder.unreadableURLs.isEmpty)
        }
        #expect(!SourceFileOpening.refuses(image, at: url("illustration"), format: .image))
        #expect(!SourceFileOpening.refuses(video, at: url("notes.md"), format: .markdown))
        #expect(SourceFileOpening.refuses(video, at: url("Dockerfile"), format: .plainText))
        #expect(SourceFileOpening.refuses(video, at: url("clip.ts"), format: .plainText))
        #expect(!SourceFileOpening.refuses(Data("echo 1\n".utf8), at: url("tool"), format: .plainText))
    }

    @Test("合本は、読んだ中身が動画やバイナリだった子を除いて一覧へ伝える")
    func binderReads() async throws {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }
        let video = video
        let binary = try binaryPropertyList()
        let model = BinderModel(
            urls: [url("a.md"), url("b.ts"), url("c.ts"), url("d.plist")],
            read: { url, _ in
                switch url.lastPathComponent {
                case "c.ts": video
                case "d.plist": binary
                case "b.ts": Data("let b = 1\n".utf8)
                default: Data("# A".utf8)
                }
            })
        let source = try await model.source()
        #expect(source.children?.count == 2)
        #expect(model.unreadableURLs == [url("c.ts"), url("d.plist")])
        model.stop()
    }

    @Test("Markdown から取り込む合本は、計画のあとで子が外の動画へのリンクに替わっても、子を調べ直さず外を読まない", .timeLimit(.minutes(1)))
    func plannedChildIsNotAskedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("book")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "<<[main.ts]\n<<[notes.md]\n"
        let parent = folder.appendingPathComponent("index.md")
        try Data(text.utf8).write(to: parent)
        try Data("let a = 1\n".utf8).write(to: folder.appendingPathComponent("main.ts"))
        try Data("# notes".utf8).write(to: folder.appendingPathComponent("notes.md"))
        try video.write(to: outside.appendingPathComponent("clip.ts"))
        let plan = try #require(MarkdownIncludes(markdown: text)).plan(parent: parent)
        #expect(plan.documents.map(\.lastPathComponent) == ["main.ts", "notes.md"])
        // After the plan the child becomes a link to a video outside the folder.
        let child = folder.appendingPathComponent("main.ts")
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(
            at: child, withDestinationURL: outside.appendingPathComponent("clip.ts"))
        let binder = BinderModel(plan: plan)
        defer { binder.stop() }
        // Asking the file again, outside the root, would find a video and drop the child from the list. The plan's
        // own answer keeps it, and the read under the root then refuses it without touching the target.
        #expect(binder.items.map(\.url.lastPathComponent) == ["main.ts", "notes.md"])
        let source = try await binder.source()
        #expect(source.children?.map(\.fileURL?.lastPathComponent) == ["notes.md"])
        #expect(binder.unreadableURLs.map(\.lastPathComponent) == ["main.ts"])
    }

    // MARK: Files that exist only in memory

    @Test("ショートカットがメモリで渡すファイルの形式は、名前・型・先頭から一度に決める")
    func shortcutFormats() throws {
        func format(_ name: String, _ data: Data, _ type: UTType? = nil) -> DocumentFormat? {
            ShortcutFiles.format(name: name, type: type, data: data)
        }
        #expect(format("main.ts", Data("let a = 1\n".utf8), .mpeg2TransportStream) == .plainText)
        #expect(format("module.mts", Data("export const a = 1\n".utf8), UTType(filenameExtension: "mts")) == .plainText)
        #expect(format("tool", Data("#!/bin/sh\necho 1\n".utf8), .data) == .plainText)
        #expect(format("Dockerfile", Data("FROM scratch\n".utf8), .data) == .plainText)
        #expect(format("clip.ts", video, .mpeg2TransportStream) == nil)
        #expect(format("clip.mts", video, UTType(filenameExtension: "mts")) == nil)
        #expect(format("Info.plist", try binaryPropertyList(), .propertyList) == nil)
        #expect(format("Info.plist", try xmlPropertyList(), .propertyList) == .plainText)
        #expect(format("notes.md", Data("# a".utf8), .surimonoMarkdown) == .markdown)
        #expect(format("clip.mp4", Data("#!/bin/sh\n".utf8), .mpeg4Movie) == nil)
        #expect(format("LICENSE", Data("Free.\n".utf8), .data) == nil)
        #expect(format("tool", Data([0xCF, 0xFA, 0xED, 0xFE, 0x00]), .data) == nil)
    }

    @Test("メモリのファイルは元のファイル名と一緒に渡り、名前のないテキストとは別の入口を通る")
    func memoryFileKeepsItsName() {
        var files: [String] = []
        var texts: [String?] = []
        let router = OpenRouter(
            openDocument: { _, _ in }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: { true }, showWelcome: {},
            openMemory: { _, _, title, _ in texts.append(title) },
            openMemoryFile: { _, format, fileName, printing in
                #expect(format == .plainText)
                #expect(printing)
                files.append(fileName)
            })
        #expect(
            router.open(memoryFile: Data("let a = 1\n".utf8), format: .plainText, fileName: "main.ts", printing: true))
        #expect(
            router.open(.document(data: Data("x".utf8), format: .plainText), printing: true, title: "Selected Text"))
        #expect(files == ["main.ts"])
        #expect(texts == ["Selected Text"])
    }

    @Test("ファイル名つきのメモリの文書は、その名前の言語で色が付き、形式バッジもその言語になる", .timeLimit(.minutes(1)))
    func memoryFileIsColored() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func model(_ name: String?, _ text: String) -> DocumentViewModel {
            DocumentViewModel(
                data: Data(text.utf8), fileURL: nil, format: .plainText,
                preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: directory.appendingPathComponent("Library")),
                renderer: DocumentRenderer(paginate: { _ in PDFDocument(data: TestFixtures.pdf("Memory", pages: 1))! }),
                title: name ?? "Clipboard", sourceFileName: name)
        }
        let named = model("main.ts", "const pages: number = 2;\n")
        named.start()
        defer { named.stop() }
        #expect(named.shortFormatBadge == "TypeScript")
        try await wait("組版が終わる") { named.result != nil && !named.isRendering }
        #expect(named.result?.facts?.sourceLanguage?.id == "typescript")
        let script = model("tool", "#!/usr/bin/env ruby\nputs 1\n")
        script.start()
        defer { script.stop() }
        try await wait("組版が終わる") { script.result != nil && !script.isRendering }
        #expect(script.shortFormatBadge == "Ruby")
        // Text from the clipboard has no file name, and stays as it was.
        let clipboard = model(nil, "#!/usr/bin/env ruby\nputs 1\n")
        clipboard.start()
        defer { clipboard.stop() }
        try await wait("組版が終わる") { clipboard.result != nil && !clipboard.isRendering }
        #expect(clipboard.shortFormatBadge == "TXT")
        #expect(clipboard.result?.facts?.sourceLanguage == nil)
    }

    @Test("同じバイト列を a.ts・a.swift・名前なしで順に開くと、それぞれの窓・形式バッジ・言語になる", .timeLimit(.minutes(1)))
    func memoryFilesGetTheirOwnWindows() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = ClipboardWindows(
            openFiles: { _, _, _ in Issue.record("ファイルは開かない") },
            warn: { _ in Issue.record("警告しない") }, closeWelcome: {})
        let presentation = ClipboardWindowFixture(windows)
        defer { presentation.close() }
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: directory)
        let data = Data("let pages = 2\n".utf8)
        // The clipboard's text first: a named file of the same bytes must not take its uncolored window.
        let clipboard = windows.open(data, format: .plainText, title: "Clipboard")
        let typeScript = windows.open(data, format: .plainText, title: "a.ts", fileName: "a.ts")
        let swift = windows.open(data, format: .plainText, title: "a.swift", fileName: "a.swift")
        defer { for controller in [clipboard, typeScript, swift] { controller.window?.close() } }
        #expect(clipboard !== typeScript)
        #expect(typeScript !== swift)
        #expect(clipboard !== swift)
        #expect(typeScript.model.sourceFileName == "a.ts")
        #expect(swift.model.sourceFileName == "a.swift")
        #expect(clipboard.model.sourceFileName == nil)
        #expect(typeScript.model.shortFormatBadge == "TypeScript")
        #expect(swift.model.shortFormatBadge == "Swift")
        #expect(clipboard.model.shortFormatBadge == "TXT")
        // The same file again comes back to its own window.
        #expect(windows.open(data, format: .plainText, title: "a.ts", fileName: "a.ts") === typeScript)
        #expect(windows.open(data, format: .plainText, title: "Clipboard") === clipboard)
        #expect(ClipboardWindows.key(data, format: .plainText, fileName: nil) == ContentHash.of(data))
        #expect(
            ClipboardWindows.key(data, format: .plainText, fileName: "a.ts")
                != ClipboardWindows.key(data, format: .markdown, fileName: "a.ts"))
        // Each is laid out in its own language.
        for controller in [typeScript, swift, clipboard] {
            try await wait("組版が終わる") { controller.model.result != nil && !controller.model.isRendering }
        }
        #expect(typeScript.model.result?.facts?.sourceLanguage?.id == "typescript")
        #expect(swift.model.result?.facts?.sourceLanguage?.id == "swift")
        #expect(clipboard.model.result?.facts?.sourceLanguage == nil)
        // A closed window remembers the name it was shown under.
        let closed = ClosedClipboardDocuments.Entry(
            model: swift.model, hash: ClipboardWindows.key(data, format: .plainText, fileName: "a.swift"), data: data,
            date: Date())
        #expect(closed.fileName == "a.swift")
        let decoded = try JSONDecoder().decode(
            ClosedClipboardDocuments.Entry.self, from: try JSONEncoder().encode(closed))
        #expect(decoded.fileName == "a.swift")
    }

    @Test("ファイルのある文書でも、渡された元のファイル名で言語を見分ける")
    func nameIndependentOfURL() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: Data("let a = 1\n".utf8), fileURL: directory.appendingPathComponent("0C1F-temporary"),
            format: .plainText, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory), sourceFileName: "main.ts")
        #expect(model.sourceFileName == "main.ts")
        #expect(model.shortFormatBadge == "TypeScript")
    }
}
