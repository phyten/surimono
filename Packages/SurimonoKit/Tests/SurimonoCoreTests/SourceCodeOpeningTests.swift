import Darwin
import Foundation
import SurimonoCore
import Testing
import UniformTypeIdentifiers

struct SourceCodeOpeningTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }

    /// Transport stream packets: each starts with the sync byte; `payload` fills the rest.
    private func stream(packets: Int = 30, payload: UInt8 = 0, header: [UInt8] = [0x47, 0x40, 0x00, 0x10]) -> Data {
        var data = Data()
        for _ in 0..<packets { data += Data(header) + Data(repeating: payload, count: 184) }
        return data
    }

    private func binaryPropertyList() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["name": "Surimono", "pages": 12], format: .binary, options: 0)
    }

    private func xmlPropertyList() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["name": "Surimono"], format: .xml, options: 0)
    }

    private func withFiles(_ files: [String: Data], _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        try body(directory.standardizedFileURL)
    }

    private func decision(_ name: String, _ data: Data) -> TextFileGate.Decision {
        TextFileGate.decide(fileName: name, head: data.prefix(TextFileGate.headLength))
    }

    private func language(_ decision: TextFileGate.Decision) -> String? {
        if case .text(let language) = decision { return language?.id }
        return nil
    }

    // MARK: Formats

    @Test(
        "macOS が型を持たない、または別の型を与えるソースコードの拡張子をテキストとして開く",
        arguments: [
            "ts", "TS", "go", "rs", "kt", "cs", "lua", "jl", "hs", "vue", "plist", "py", "swift", "rb", "m", "h",
        ])
    func sourceExtensions(_ suffix: String) {
        #expect(DocumentFormat(fileExtension: suffix) == .plainText)
    }

    @Test("言語を見分ける拡張子は、AVCHD の動画と重なる .mts を除いてどれも拡張子だけで開ける")
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

    @Test("ソースコードの型はテキストとして読み、動画の型はどの拡張子でもテキストにしない")
    func contentTypes() throws {
        #expect(DocumentFormat(contentType: .surimonoSourceCode) == .plainText)
        #expect(DocumentFormat(contentType: .propertyList) == .plainText)
        #expect(DocumentFormat(contentType: .sourceCode) == .plainText)
        #expect(DocumentFormat(contentType: .mpeg2TransportStream) == nil)
        #expect(DocumentFormat(contentType: .mpeg4Movie) == nil)
        let avchd = try #require(UTType(filenameExtension: "mts"))
        #expect(DocumentFormat(contentType: avchd) == nil)
    }

    // MARK: The gate's decision

    @Test("TypeScript の .ts と .mts はテキスト、言語は TypeScript と決める")
    func typeScript() {
        let source = Data("const pages: number = 2;\n".utf8)
        #expect(language(decision("layout.ts", source)) == "typescript")
        #expect(language(decision("layout.mts", source)) == "typescript")
        #expect(language(decision("LAYOUT.TS", source)) == "typescript")
        #expect(decision("empty.ts", Data()) == .text(SourceLanguage.detect(fileName: "empty.ts")))
        // TypeScript may start with "G" and have another 188 bytes later; two are not a stream.
        let lookalike = "G" + String(repeating: "a", count: 186) + "\nG = 1\n"
        #expect(Array(lookalike.utf8)[188] == 0x47)
        #expect(language(decision("g.ts", Data(lookalike.utf8))) == "typescript")
        #expect(language(decision("ja.ts", Data("// 日本語のコメント\nlet a = 1\n".utf8))) == "typescript")
    }

    @Test("トランスポートストリームは、ゼロがなくても、途中から始まっても、動画と決める")
    func transportStream() {
        #expect(decision("clip.ts", stream()) == .refused)
        #expect(decision("clip.mts", stream()) == .refused)
        // No zero byte and no control byte anywhere: only the spacing of the sync bytes tells.
        let dense = stream(payload: 0xFF, header: [0x47, 0x41, 0x21, 0x30])
        #expect(!dense.contains { $0 < 0x20 })
        #expect(decision("clip.ts", dense) == .refused)
        // The file starts 100 bytes into a packet.
        #expect(decision("clip.ts", dense.dropFirst(100)) == .refused)
        // 192-byte packets with a timestamp in front, and 204-byte packets with error correction behind.
        var m2ts = Data()
        for _ in 0..<25 {
            m2ts += Data([0x21, 0x22, 0x23, 0x24, 0x47, 0x41, 0x21, 0x30]) + Data(repeating: 0xFF, count: 184)
        }
        #expect(decision("clip.ts", m2ts) == .refused)
        var long = Data()
        for _ in 0..<25 { long += Data([0x47, 0x41, 0x21, 0x30]) + Data(repeating: 0xFF, count: 200) }
        #expect(decision("clip.ts", long) == .refused)
    }

    @Test("短い入力は、テキストとして読めるかどうかで決める")
    func shortInputs() {
        // One packet: too short to show the spacing, but its header bytes are not text.
        #expect(decision("clip.ts", stream(packets: 1)) == .refused)
        #expect(decision("clip.ts", stream(packets: 1, payload: 0xFF, header: [0x47, 0x01, 0x11, 0x10])) == .refused)
        #expect(decision("clip.ts", Data([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x02])) == .refused)
        #expect(decision("clip.ts", Data([0x00])) == .refused)
        #expect(language(decision("a.ts", Data("G".utf8))) == "typescript")
    }

    @Test("BOM があっても中身がテキストでなければ断り、UTF-16 のテキストは受け入れる")
    func byteOrderMarks() {
        let utf16 = Data([0xFF, 0xFE]) + ("let a = 1\n".data(using: .utf16LittleEndian) ?? Data())
        #expect(language(decision("a.ts", utf16)) == "typescript")
        let big = Data([0xFE, 0xFF]) + ("let a = 1\n".data(using: .utf16BigEndian) ?? Data())
        #expect(language(decision("a.ts", big)) == "typescript")
        #expect(decision("clip.ts", Data([0xFF, 0xFE]) + stream()) == .refused)
        #expect(decision("clip.ts", Data([0xFF, 0xFE, 0x01, 0x00, 0x02, 0x00])) == .refused)
        #expect(decision("clip.ts", Data([0xEF, 0xBB, 0xBF]) + stream()) == .refused)
    }

    @Test("Foundation が作ったバイナリの plist は断り、XML と旧形式の plist は受け入れる")
    func propertyLists() throws {
        let binary = try binaryPropertyList()
        #expect(binary.starts(with: Data("bplist00".utf8)))
        #expect(decision("Info.plist", binary) == .refused)
        #expect(language(decision("Info.plist", try xmlPropertyList())) == "xml")
        // An old-style text property list whose first key begins with "bplist".
        #expect(language(decision("Cache.plist", Data("bplistCache = { size = 12; };\n".utf8))) == "xml")
        #expect(language(decision("Cache.plist", Data("{ bplist00 = 1; }\n".utf8))) == "xml")
        // A binary property list of strings alone has no control byte in it; the version header still tells.
        #expect(decision("a.plist", Data("bplist00".utf8) + Data([0xD1, 0x51, 0x61, 0x51, 0x62])) == .refused)
        #expect(decision("a.plist", Data("bplist15".utf8) + Data(repeating: 0x41, count: 20)) == .refused)
    }

    @Test(
        "型のない名前は、テキストとして読め、名前か shebang で言語が分かるときだけ受け入れる",
        arguments: [
            ("Dockerfile", "FROM scratch\n", "dockerfile"), ("Gemfile", "source \"https://example.com\"\n", "ruby"),
            (".env", "A=1\n", "ini"), (".env.local", "A=1\n", "ini"), ("Cargo.lock", "version = 3\n", "toml"),
            ("tool", "#!/usr/bin/env python3\nprint(1)\n", "python"), ("tool", "#!/bin/sh\necho 1\n", "shell"),
            ("Makefile", "all:\n\techo 1\n", "makefile"), ("Dockerfile", "", "dockerfile"),
        ])
    func untypedNames(name: String, text: String, id: String) {
        #expect(language(decision(name, Data(text.utf8))) == id)
    }

    @Test("型のない名前でも、中身がテキストでなければ受け入れない")
    func untypedBinaries() throws {
        // A Mach-O header, a stream and a binary property list under names that promise text.
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        #expect(decision("Dockerfile", machO) == .unrelated)
        #expect(decision("Gemfile", stream()) == .unrelated)
        #expect(decision(".env", try binaryPropertyList()) == .unrelated)
        #expect(decision("tool", Data("#!/bin/sh\n".utf8) + Data([0x00, 0x01, 0x02])) == .unrelated)
        // Text, but nothing names a language.
        #expect(decision("LICENSE", Data("Permission is granted.\n".utf8)) == .unrelated)
        #expect(decision("notes", Data("plain words\n".utf8)) == .unrelated)
    }

    @Test("自分の形式や型を持つ名前は、中身によらず門の対象にしない")
    func unrelatedNames() {
        #expect(decision("clip.txt", stream()) == .unrelated)
        #expect(decision("main.go", stream()) == .unrelated)
        #expect(decision("notes.md", Data("#!/bin/sh\n".utf8)) == .unrelated)
        #expect(decision("archive.zip", Data("#!/bin/sh\n".utf8)) == .unrelated)
        #expect(decision("photo.psd", Data("#!/bin/sh\n".utf8)) == .unrelated)
    }

    @Test("メモリ上のバイト列も同じ決め方で断る")
    func bytesInMemory() throws {
        #expect(TextFileGate.refuses(fileName: "clip.ts", data: stream()))
        #expect(TextFileGate.refuses(fileName: "Info.plist", data: try binaryPropertyList()))
        #expect(!TextFileGate.refuses(fileName: "main.ts", data: Data("let a = 1\n".utf8)))
        #expect(!TextFileGate.refuses(fileName: "notes.md", data: stream()))
        #expect(!TextFileGate.refuses(fileName: "Dockerfile", data: stream()))
    }

    // MARK: Reading the file

    @Test("ファイルからは先頭だけを読み、大きな動画でも同じ答えを出す")
    func readsOnlyTheHead() throws {
        // 2 MB of stream: the decision is the one for its first 4096 bytes.
        try withFiles(["clip.ts": stream(packets: 11_000), "main.ts": Data("let a = 1\n".utf8)]) { directory in
            #expect(TextFileGate.decide(directory.appendingPathComponent("clip.ts")) == .refused)
            #expect(language(TextFileGate.decide(directory.appendingPathComponent("main.ts"))) == "typescript")
        }
        #expect(TextFileGate.headLength == 4096)
    }

    @Test("開けないファイルは門の対象にせず、名前だけで決める今までの扱いに任せる")
    func unreadableFiles() {
        #expect(TextFileGate.decide(url("missing.ts")) == .unrelated)
        #expect(TextFileGate.decide(url("Dockerfile")) == .unrelated)
        #expect(OpenRequest.binderFormat(url("missing.ts")) == .plainText)
        #expect(OpenRequest.binderFormat(url("Dockerfile")) == nil)
    }

    @Test("名前つきパイプは待たずに断る", .timeLimit(.minutes(1)))
    func namedPipes() throws {
        try withFiles([:]) { directory in
            for name in ["pipe.ts", "pipe.plist", "Dockerfile"] {
                let pipe = directory.appendingPathComponent(name)
                #expect(mkfifo(pipe.path, 0o600) == 0)
                // Nothing ever writes to the pipe: a blocking open would never return.
                #expect(TextFileGate.decide(pipe) == (name == "Dockerfile" ? .unrelated : .refused))
                #expect(OpenRequest.binderFormat(pipe) == nil)
            }
        }
    }

    @Test("フォルダーの外を指すリンクは、フォルダーの中に限った判定では受け入れない")
    func linksOutOfTheFolder() throws {
        try withFiles(["outside.ts": Data("let a = 1\n".utf8)]) { outside in
            try withFiles(["inside.ts": Data("let b = 1\n".utf8)]) { folder in
                let link = folder.appendingPathComponent("link.ts")
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: outside.appendingPathComponent("outside.ts"))
                let root = try ConfinedFile.canonicalPath(folder)
                #expect(OpenRequest.binderFormat(link, within: root) == nil)
                #expect(
                    OpenRequest.binderFormat(folder.appendingPathComponent("inside.ts"), within: root) == .plainText)
                #expect(OpenRequest.binderFormat(link) == .plainText)
            }
        }
    }

    // MARK: Binders and drops

    @Test("ソースコードは文章と一緒に合本にできる")
    func binder() {
        let names = ["1.md", "2.go", "3.rs", "4.kt", "5.swift", "6.py"]
        #expect(OpenRequest(urls: names.reversed().map(url)) == .binder(names.map(url), excluded: []))
    }

    @Test("合本は、テキストの .ts・.mts・拡張子のないスクリプトを含め、動画とバイナリを除く")
    func binderOfRealFiles() throws {
        let files = [
            "a.md": Data("# a".utf8), "b.ts": Data("let b = 1\n".utf8), "c.ts": stream(),
            "d.mts": Data("export const d = 1\n".utf8), "e.mts": stream(), "tool": Data("#!/bin/sh\necho 1\n".utf8),
            "Dockerfile": Data("FROM scratch\n".utf8), "Gemfile": stream(), "LICENSE": Data("Free.\n".utf8),
            "f.plist": try binaryPropertyList(), "g.plist": try xmlPropertyList(),
        ]
        try withFiles(files) { directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            #expect(
                OpenRequest(urls: files.keys.map(file))
                    == .binder(
                        ["a.md", "b.ts", "d.mts", "Dockerfile", "g.plist", "tool"].map(file),
                        excluded: ["c.ts", "e.mts", "f.plist", "Gemfile", "LICENSE"].map(file)))
        }
    }

    @Test("文書のウインドウへのドロップも、単独で開くときと同じファイルを受け入れる")
    func dropsOnADocument() throws {
        let files = [
            "own.md": Data("# own".utf8), "tool": Data("#!/bin/sh\necho 1\n".utf8), "clip.mts": stream(),
            "clip.ts": stream(), "main.ts": Data("let a = 1\n".utf8), "Dockerfile": Data("FROM scratch\n".utf8),
            "binary": Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01]),
        ]
        try withFiles(files) { directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            func plan(_ names: [String]) -> DropPlan {
                DropPlan(urls: names.map(file), receiver: .document(file("own.md")))
            }
            for name in ["tool", "main.ts", "Dockerfile"] {
                let accepted = plan([name])
                #expect(accepted.choice == .joinOrOpen(.newBinder), "\(name)")
                #expect(accepted.adding == [file(name)], "\(name)")
                #expect(accepted.opening == .single(file(name)), "\(name)")
            }
            for name in ["clip.mts", "clip.ts", "binary"] {
                let refused = plan([name])
                #expect(refused.choice == .refuse(.unsupported), "\(name)")
                #expect(refused.adding.isEmpty, "\(name)")
                #expect(refused.leftOut == [file(name)], "\(name)")
            }
            let mixed = plan(["tool", "clip.mts", "main.ts"])
            #expect(mixed.adding == [file("main.ts"), file("tool")])
            #expect(mixed.leftOut == [file("clip.mts")])
        }
    }

    @Test("フォルダーの中に限った判定でも、動画を除き TypeScript を含める")
    func confinedDecisions() throws {
        try withFiles(["main.ts": Data("let a = 1\n".utf8), "clip.ts": stream()]) { directory in
            let root = try ConfinedFile.canonicalPath(directory)
            #expect(OpenRequest.binderFormat(directory.appendingPathComponent("clip.ts"), within: root) == nil)
            #expect(OpenRequest.binderFormat(directory.appendingPathComponent("main.ts"), within: root) == .plainText)
        }
    }
}
