import Foundation
import SurimonoCore
import Testing
import UniformTypeIdentifiers

struct SourceCodeOpeningTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }

    /// Seven transport stream packets: each starts with the sync byte and carries a payload full of zeros.
    private var video: Data {
        var data = Data()
        for _ in 0..<7 { data += Data([0x47, 0x40, 0x00, 0x10]) + Data(repeating: 0, count: 184) }
        return data
    }

    private func withFiles(_ files: [String: Data], _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        try body(directory)
    }

    @Test(
        "macOS が型を持たない、または別の型を与えるソースコードの拡張子をテキストとして開く",
        arguments: [
            "ts", "TS", "go", "rs", "kt", "cs", "lua", "jl", "hs", "vue", "plist", "py", "swift", "rb", "m", "h",
        ])
    func sourceExtensions(_ suffix: String) {
        #expect(DocumentFormat(fileExtension: suffix) == .plainText)
    }

    @Test("言語を見分ける拡張子は、AVCHD の動画と重なる .mts を除いてどれも開ける")
    func everyLanguageExtensionOpens() {
        let structured: Set<String> = ["json", "jsonl", "ndjson", "yaml", "yml", "toml", "xml"]
        #expect(
            DocumentFormat.sourceCodeExtensions
                == SourceLanguage.fileExtensions.subtracting(structured).subtracting(["mts"]))
        for suffix in SourceLanguage.fileExtensions.subtracting(["mts"]) {
            #expect(DocumentFormat(fileExtension: suffix) == .plainText, "\(suffix)")
        }
        #expect(DocumentFormat(fileExtension: "mts") == nil)
    }

    @Test("文章や画像の拡張子の形式は変わらない")
    func otherFormatsUnchanged() {
        #expect(DocumentFormat(fileExtension: "md") == .markdown)
        #expect(DocumentFormat(fileExtension: "html") == .html)
        #expect(DocumentFormat(fileExtension: "tex") == .latex)
        #expect(DocumentFormat(fileExtension: "org") == .org)
        #expect(DocumentFormat(fileExtension: "csv") == .csv)
        #expect(DocumentFormat(fileExtension: "svg") == .image)
        #expect(DocumentFormat(fileExtension: "conf") == nil)
    }

    @Test("ソースコードの型と、macOS が .ts と .plist に与える型をテキストとして読む")
    func contentTypes() {
        #expect(DocumentFormat(contentType: .surimonoSourceCode) == .plainText)
        #expect(DocumentFormat(contentType: .mpeg2TransportStream) == .plainText)
        #expect(DocumentFormat(contentType: .propertyList) == .plainText)
        #expect(DocumentFormat(contentType: .sourceCode) == .plainText)
        #expect(DocumentFormat(contentType: .mpeg4Movie) == nil)
    }

    @Test("トランスポートストリームの .ts は動画、TypeScript の .ts はテキストと見分ける")
    func transportStream() {
        #expect(BinaryLookalike.isBinary(video, fileExtension: "ts"))
        #expect(BinaryLookalike.isBinary(Data([0, 0, 0, 0]) + video, fileExtension: "TS"))
        // Packets whose payload has no zero byte still carry header bytes no text has.
        var dense = Data()
        for _ in 0..<3 { dense += Data([0x47, 0x01, 0x11, 0x10]) + Data(repeating: 0xFF, count: 184) }
        #expect(BinaryLookalike.isBinary(dense, fileExtension: "ts"))
        #expect(!BinaryLookalike.isBinary(Data("const a: number = 1;\n".utf8), fileExtension: "ts"))
        // TypeScript may start with "G" and even have one 188 characters later.
        let source = "G" + String(repeating: "a", count: 186) + "\nG = 1\n"
        #expect(Array(source.utf8)[188] == 0x47)
        #expect(!BinaryLookalike.isBinary(Data(source.utf8), fileExtension: "ts"))
        #expect(!BinaryLookalike.isBinary(Data(), fileExtension: "ts"))
        let utf16 = Data([0xFF, 0xFE]) + ("let a = 1\n".data(using: .utf16LittleEndian) ?? Data())
        #expect(!BinaryLookalike.isBinary(utf16, fileExtension: "ts"))
        #expect(BinaryLookalike.isBinary(Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 1]), fileExtension: "ts"))
    }

    @Test("バイナリの .plist はテキストとして読まない")
    func propertyList() {
        #expect(BinaryLookalike.isBinary(Data("bplist00".utf8) + Data([0xD1, 1, 2]), fileExtension: "plist"))
        #expect(!BinaryLookalike.isBinary(Data("<?xml version=\"1.0\"?>\n<plist/>".utf8), fileExtension: "plist"))
    }

    @Test("ほかの拡張子は中身によらずバイナリと見なさない")
    func otherExtensions() {
        #expect(!BinaryLookalike.isBinary(video, fileExtension: "txt"))
        #expect(!BinaryLookalike.isBinary(video, fileExtension: "go"))
    }

    @Test("ソースコードは文章と一緒に合本にできる")
    func binder() {
        let names = ["1.md", "2.go", "3.rs", "4.kt", "5.swift", "6.py"]
        #expect(OpenRequest(urls: names.reversed().map(url)) == .binder(names.map(url), excluded: []))
    }

    @Test("決まった名前の拡張子のないファイルは合本にでき、知らない名前のファイルは除く")
    func extensionlessNames() {
        #expect(
            OpenRequest(urls: [url("Dockerfile"), url("notes.md"), url("LICENSE"), url(".env")])
                == .binder([url(".env"), url("Dockerfile"), url("notes.md")], excluded: [url("LICENSE")]))
    }

    @Test("動画の .ts は合本から除き、TypeScript の .ts は含める")
    func transportStreamInBinder() throws {
        try withFiles(["a.md": Data("# a".utf8), "b.ts": Data("let b = 1\n".utf8), "c.ts": video]) { directory in
            let urls = ["a.md", "b.ts", "c.ts"].map { directory.appendingPathComponent($0).standardizedFileURL }
            #expect(OpenRequest(urls: urls) == .binder([urls[0], urls[1]], excluded: [urls[2]]))
            #expect(OpenRequest.binderFormat(urls[1]) == .plainText)
            #expect(OpenRequest.binderFormat(urls[2]) == nil)
        }
    }

    @Test("バイナリの .plist は合本から除く")
    func binaryPropertyListInBinder() throws {
        let files = ["a.md": Data("# a".utf8), "b.plist": Data("bplist00".utf8), "c.plist": Data("<plist/>".utf8)]
        try withFiles(files) { directory in
            #expect(OpenRequest.binderFormat(directory.appendingPathComponent("b.plist")) == nil)
            #expect(OpenRequest.binderFormat(directory.appendingPathComponent("c.plist")) == .plainText)
        }
    }
}
