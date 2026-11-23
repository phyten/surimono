import AppKit
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

    @Test("固定名でも中身がバイナリなら、テキストとして開く道を選ばない")
    func binaryUnderFixedName() async throws {
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        try await withFile("Dockerfile", machO) { #expect(SourceFileOpening.route(for: $0) == .document) }
        try await withFile("Gemfile", video) { #expect(SourceFileOpening.route(for: $0) == .document) }
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
            model.readReloadData = { _ in binary }
            model.reload()
            try await wait("読み直しの失敗を知らせる") { model.toast?.detail == SourceFileError.notText.localizedDescription }
            #expect(model.data == xml)
            #expect(model.result?.logicalDocument === pages)
            #expect(!model.isRendering)
        }
    }

    @Test("合本は、読んだ中身が動画やバイナリの plist だった子を除いて一覧へ伝える")
    func binderReads() async throws {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }
        let video = video
        let binary = try binaryPropertyList()
        let model = BinderModel(
            urls: [url("a.md"), url("b.ts"), url("c.ts"), url("d.plist")],
            read: {
                switch $0.lastPathComponent {
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

    @Test("ショートカットから渡されたバイト列も同じ決め方で断る")
    func shortcutInput() throws {
        #expect(!ShortcutFiles.accepts(video, named: "clip.ts"))
        #expect(!ShortcutFiles.accepts(try binaryPropertyList(), named: "Info.plist"))
        #expect(ShortcutFiles.accepts(Data("let a = 1\n".utf8), named: "main.ts"))
        #expect(ShortcutFiles.accepts(try xmlPropertyList(), named: "Info.plist"))
        #expect(ShortcutFiles.accepts(Data("# a".utf8), named: "notes.md"))
    }
}
