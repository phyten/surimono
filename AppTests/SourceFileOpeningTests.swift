import AppKit
import SurimonoCore
import Testing
import UniformTypeIdentifiers

@testable import Surimono

@MainActor
struct SourceFileOpeningTests {
    /// Seven transport stream packets: each starts with the sync byte and carries a payload full of zeros.
    private var video: Data {
        var data = Data()
        for _ in 0..<7 { data += Data([0x47, 0x40, 0x00, 0x10]) + Data(repeating: 0, count: 184) }
        return data
    }

    private func document(_ name: String, _ data: Data, type: UTType) throws -> SurimonoDocument {
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        return try SurimonoDocument(file: file, contentType: type)
    }

    private func withFile(_ name: String, _ data: Data, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        try body(url)
    }

    @Test(
        "ソースコードの拡張子の型は、どれも読み取れる型に準拠する",
        arguments: [
            "swift", "py", "rb", "js", "ts", "tsx", "go", "rs", "kt", "cs", "lua", "jl", "hs", "vue", "plist", "css",
            "ini", "java", "c", "h", "cpp", "m", "php", "sh", "sql", "diff", "mk", "scss", "jsx", "sty",
        ])
    func readableTypes(suffix: String) throws {
        let type = try #require(UTType(filenameExtension: suffix))
        #expect(SurimonoDocument.readableContentTypes.contains { type.conforms(to: $0) }, "\(type.identifier)")
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
        #expect(extensions.isDisjoint(with: ["ts", "plist", "swift", "py", "css", "ini"]))
        #expect(UTType.surimonoSourceCode.identifier == "app.surimono.source-code")
        #expect(UTType.surimonoSourceCode.conforms(to: .sourceCode))
    }

    @Test("動画の型で届いた TypeScript の .ts をテキストとして読み、バイト列を保持する")
    func typeScript() throws {
        let bytes = Data("const pages: number = 2;\n".utf8)
        let read = try document("layout.ts", bytes, type: .mpeg2TransportStream)
        #expect(read.format == .plainText)
        #expect(read.data == bytes)
    }

    @Test("本物のトランスポートストリームの .ts は、テキストではないと断って開かない")
    func transportStream() {
        #expect(throws: SourceFileError.notText) { try document("clip.ts", video, type: .mpeg2TransportStream) }
        #expect(throws: SourceFileError.notText) { try document("clip.ts", video, type: .plainText) }
        #expect(throws: SourceFileError.notText) { try document("clip.m2t", video, type: .mpeg2TransportStream) }
    }

    @Test("XML の .plist はテキストとして読み、バイナリの .plist は開かない")
    func propertyList() throws {
        let xml = Data("<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict/></plist>\n".utf8)
        #expect(try document("Info.plist", xml, type: .propertyList).format == .plainText)
        #expect(throws: SourceFileError.notText) {
            try document("Info.plist", Data("bplist00".utf8) + Data([0xD0, 0x08]), type: .propertyList)
        }
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

    @Test(
        "拡張子がなく名前か shebang で言語が分かるファイルは、テキストとして開く",
        arguments: [
            ("Dockerfile", "FROM scratch\n"), ("Gemfile", "source \"https://example.com\"\n"), (".env", "A=1\n"),
            (".env.local", "A=1\n"), ("tool", "#!/usr/bin/env python3\nprint(1)\n"), ("Cargo.lock", "version = 3\n"),
        ])
    func extensionless(name: String, text: String) throws {
        try withFile(name, Data(text.utf8)) { url in
            #expect(SourceFileOpening.readsAsPlainText(url))
        }
    }

    @Test(
        "言語の分からない拡張子なしのファイルや、自分の型を持つファイルは、テキストとして開かない",
        arguments: [
            ("LICENSE", "Permission is granted.\n"), ("notes", "plain words\n"), ("clip.mts", "#!/bin/sh\n"),
            ("main.swift", "let a = 1\n"), ("archive.zip", "#!/bin/sh\n"), ("data.bin", "#!/bin/sh\n"),
        ])
    func notOverridden(name: String, text: String) throws {
        try withFile(name, Data(text.utf8)) { url in
            #expect(!SourceFileOpening.readsAsPlainText(url))
        }
    }

    @Test("内容を表さない型だけをテキストとして読み直す")
    func untypedOnly() {
        #expect(SourceFileOpening.isUntyped(.data))
        #expect(SourceFileOpening.isUntyped(.unixExecutable))
        #expect(!SourceFileOpening.isUntyped(.mpeg2TransportStream))
        #expect(!SourceFileOpening.isUntyped(.plainText))
        #expect(!SourceFileOpening.isUntyped(.zip))
    }

    @Test("拡張子のない Dockerfile から、文書の仕組みでテキストの文書を作れる")
    func makesDocument() throws {
        try withFile("Dockerfile", Data("FROM scratch\n".utf8)) { url in
            let (document, isNew) = try SourceFileOpening.document(for: url)
            defer { document.close() }
            #expect(isNew)
            #expect(document.fileURL?.standardizedFileURL == url.standardizedFileURL)
            #expect(document.fileType == UTType.plainText.identifier)
        }
    }
}
