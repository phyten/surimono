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

    /// A stream with no zero byte and no control byte: only its packets tell that it is not text.
    private func dense(packets: Int = 30) -> Data {
        stream(packets: packets, payload: 0xFF, header: [0x47, 0x41, 0x21, 0x30])
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

    private func verdict(_ name: String, _ data: Data, type: UTType? = nil) -> TextFileGate.Verdict {
        TextFileGate.verdict(fileName: name, type: type, data: data)
    }

    private func language(_ verdict: TextFileGate.Verdict) -> String? {
        if case .text(let language) = verdict { return language?.id }
        return nil
    }

    private func isText(_ verdict: TextFileGate.Verdict) -> Bool {
        if case .text = verdict { return true }
        return false
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

    // MARK: Transport streams

    @Test("TypeScript の .ts と .mts はテキスト、言語は TypeScript と決める")
    func typeScript() {
        let source = Data("const pages: number = 2;\n".utf8)
        #expect(language(verdict("layout.ts", source)) == "typescript")
        #expect(language(verdict("layout.mts", source)) == "typescript")
        #expect(language(verdict("LAYOUT.TS", source)) == "typescript")
        #expect(language(verdict("empty.ts", Data())) == "typescript")
        #expect(language(verdict("ja.ts", Data("// 日本語のコメント\nlet a = 1\n".utf8))) == "typescript")
        #expect(language(verdict("a.ts", Data("G".utf8))) == "typescript")
    }

    @Test("同じ桁に G が並ぶ規則的な ASCII のソースは、パケットの並びに見えてもテキストと決める")
    func sourceWithSyncColumn() {
        // Thirty lines of exactly 188 bytes, each starting with "G": a sync byte and a passable header at every
        // packet's place, in clean UTF-8.
        let line = "G" + String(repeating: "a", count: 186) + "\n"
        let source = Data(String(repeating: line, count: 30).utf8)
        #expect(source.count == 188 * 30)
        #expect(language(verdict("grid.ts", source)) == "typescript")
        #expect(language(verdict("grid.ts", source.prefix(188))) == "typescript")
        // The same with a comment in Japanese, still UTF-8.
        let japanese = "G" + String(repeating: "あ", count: 62) + "\n"
        #expect(japanese.utf8.count == 188)
        #expect(language(verdict("grid.ts", Data(String(repeating: japanese, count: 30).utf8))) == "typescript")
    }

    @Test("トランスポートストリームは、ゼロがなくても、途中から始まっても、前に別のバイトがあっても、動画と決める")
    func transportStream() {
        #expect(verdict("clip.ts", stream()) == .binary)
        #expect(verdict("clip.mts", stream()) == .binary)
        #expect(!dense().contains { $0 < 0x20 })
        #expect(verdict("clip.ts", dense()) == .binary)
        // The file starts 100 bytes into a packet.
        #expect(verdict("clip.ts", dense().dropFirst(100)) == .binary)
        // 700 bytes of something else come first, more than three packets of it.
        #expect(verdict("clip.ts", Data(repeating: 0x41, count: 700) + dense()) == .binary)
        // 192-byte packets with a timestamp in front, and 204-byte packets with error correction behind.
        var m2ts = Data()
        for _ in 0..<25 {
            m2ts += Data([0x21, 0x22, 0x23, 0x24, 0x47, 0x41, 0x21, 0x30]) + Data(repeating: 0xFF, count: 184)
        }
        #expect(verdict("clip.ts", m2ts) == .binary)
        var long = Data()
        for _ in 0..<25 { long += Data([0x47, 0x41, 0x21, 0x30]) + Data(repeating: 0xFF, count: 200) }
        #expect(verdict("clip.ts", long) == .binary)
    }

    @Test("短い本物のパケットも動画と決め、短いテキストはテキストと決める")
    func shortInputs() {
        // One whole packet with no zero and no control byte: a file that is nothing but packets.
        #expect(dense(packets: 1).count == 188)
        #expect(verdict("clip.ts", dense(packets: 1)) == .binary)
        #expect(verdict("clip.ts", dense(packets: 3)) == .binary)
        // One packet of zeros: its bytes are not text.
        #expect(verdict("clip.ts", stream(packets: 1)) == .binary)
        #expect(verdict("clip.ts", Data([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x02])) == .binary)
        #expect(verdict("clip.ts", Data([0x00])) == .binary)
        // Bytes that only begin like a packet, in an encoding of high bytes: text as far as anyone can tell.
        #expect(isText(verdict("a.ts", Data([0x47, 0x41, 0x21, 0x30, 0x82, 0xA0, 0x0A]))))
    }

    // MARK: Encodings

    @Test("BOM つきの UTF-16 と UTF-32 のテキストは受け入れ、BOM があっても中身が壊れていれば断る")
    func byteOrderMarks() {
        let utf16 = Data([0xFF, 0xFE]) + ("let a = 1 // 紙𠮷\n".data(using: .utf16LittleEndian) ?? Data())
        #expect(language(verdict("a.ts", utf16)) == "typescript")
        let big = Data([0xFE, 0xFF]) + ("let a = 1\n".data(using: .utf16BigEndian) ?? Data())
        #expect(language(verdict("a.ts", big)) == "typescript")
        let utf32 = Data([0xFF, 0xFE, 0, 0]) + ("let a = 1\n".data(using: .utf32LittleEndian) ?? Data())
        #expect(language(verdict("a.ts", utf32)) == "typescript")
        #expect(verdict("clip.ts", Data([0xFF, 0xFE]) + stream()) == .binary)
        #expect(verdict("clip.ts", Data([0xEF, 0xBB, 0xBF]) + stream()) == .binary)
        // A control character, an unpaired surrogate, a file that ends inside a character.
        #expect(verdict("a.ts", Data([0xFF, 0xFE, 0x01, 0x00, 0x02, 0x00])) == .binary)
        #expect(verdict("a.ts", Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00])) == .binary)
        #expect(verdict("a.ts", Data([0xFF, 0xFE, 0x41, 0x00, 0x00, 0xD8])) == .binary)
        #expect(verdict("a.ts", Data([0xFF, 0xFE, 0x41, 0x00, 0x42])) == .binary)
        // A value beyond Unicode, and a surrogate, in UTF-32.
        #expect(verdict("a.ts", Data([0xFF, 0xFE, 0, 0, 0x00, 0x00, 0x11, 0x00])) == .binary)
        #expect(verdict("a.ts", Data([0xFF, 0xFE, 0, 0, 0x00, 0xD8, 0x00, 0x00])) == .binary)
        #expect(verdict("a.ts", Data([0xFF, 0xFE, 0, 0, 0x41, 0x00, 0x00])) == .binary)
        // Bytes that are not UTF-8 after a UTF-8 mark.
        #expect(verdict("a.ts", Data([0xEF, 0xBB, 0xBF, 0x41, 0xFF, 0x42])) == .binary)
    }

    @Test("4096 バイトで切った試料が文字の途中で終わっても断らず、本当に途中で終わるファイルは断る")
    func cutSamples() {
        func head(_ data: Data, whole: Bool) -> TextFileGate.Verdict {
            TextFileGate.verdict(fileName: "a.ts", head: data, isWhole: whole)
        }
        // 4096 bytes after the mark leave a UTF-16 text one byte into a character, with a high surrogate before.
        var utf16 = Data([0xFF, 0xFE])
        while utf16.count < 4092 { utf16 += Data([0x41, 0x00]) }
        utf16 += Data([0x3D, 0xD8, 0x00])
        #expect(utf16.count == 4095)
        #expect(isText(head(utf16, whole: false)))
        #expect(head(utf16, whole: true) == .binary)
        // UTF-8 with a mark, cut after the first byte of a three-byte character.
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data(repeating: 0x41, count: 4092) + Data([0xE3])
        #expect(utf8.count == 4096)
        #expect(isText(head(utf8, whole: false)))
        #expect(head(utf8, whole: true) == .binary)
        // The whole file, read as bytes in memory, is known to be whole.
        #expect(TextFileGate.verdict(fileName: "a.ts", data: utf16) == .binary)
    }

    @Test("BOM のない UTF-16 は断る。組版も UTF-16 として読まず、文字ごとにヌル文字が入るため")
    func utf16WithoutByteOrderMark() throws {
        let data = try #require("let a = 1\n".data(using: .utf16LittleEndian))
        #expect(!data.starts(with: [0xFF, 0xFE]))
        #expect(verdict("a.ts", data) == .binary)
        // What the page would show: the text decoder takes these bytes for UTF-8, null characters and all.
        let decoded = TextDecoding.decode(data)
        #expect(decoded.encoding == .utf8)
        #expect(decoded.text == "l\0e\0t\0 \0a\0 \0=\0 \01\0\n\0")
    }

    @Test("Shift_JIS・EUC-JP・Latin-1 の上位バイトだけでは断らない")
    func legacyEncodings() throws {
        let text = "// 日本語のコメント\nlet a = 1\n"
        #expect(language(verdict("a.ts", try #require(text.data(using: .shiftJIS)))) == "typescript")
        #expect(language(verdict("a.ts", try #require(text.data(using: .japaneseEUC)))) == "typescript")
        #expect(
            language(verdict("a.ts", try #require("// café\nlet a = 1\n".data(using: .isoLatin1))))
                == "typescript")
        #expect(language(verdict("a.ts", try #require(text.data(using: .iso2022JP)))) == "typescript")
    }

    // MARK: Property lists

    @Test("Foundation が作ったバイナリの plist は断り、XML と旧形式の plist は受け入れる")
    func propertyLists() throws {
        let binary = try binaryPropertyList()
        #expect(binary.starts(with: Data("bplist00".utf8)))
        #expect(verdict("Info.plist", binary) == .binary)
        #expect(language(verdict("Info.plist", try xmlPropertyList())) == "xml")
        // An old-style text property list whose first key begins with "bplist".
        #expect(language(verdict("Cache.plist", Data("bplistCache = { size = 12; };\n".utf8))) == "xml")
        #expect(language(verdict("Cache.plist", Data("{ bplist00 = 1; }\n".utf8))) == "xml")
        // A binary property list of strings alone has no control byte in it; the version header still tells.
        #expect(verdict("a.plist", Data("bplist00".utf8) + Data([0xD1, 0x51, 0x61, 0x51, 0x62])) == .binary)
        #expect(verdict("a.plist", Data("bplist15".utf8) + Data(repeating: 0x41, count: 20)) == .binary)
    }

    @Test("名前のないバイト列でも、型が plist ならバイナリの plist を断り、XML は受け入れる")
    func namelessPropertyList() throws {
        #expect(verdict("", try binaryPropertyList(), type: .propertyList) == .binary)
        #expect(isText(verdict("", try xmlPropertyList(), type: .propertyList)))
        #expect(verdict("settings", try binaryPropertyList(), type: .propertyList) == .binary)
    }

    // MARK: Names and types

    @Test(
        "型のない名前は、テキストとして読め、名前か shebang で言語が分かるときだけテキストと決める",
        arguments: [
            ("Dockerfile", "FROM scratch\n", "dockerfile"), ("Gemfile", "source \"https://example.com\"\n", "ruby"),
            (".env", "A=1\n", "ini"), (".env.local", "A=1\n", "ini"), ("Cargo.lock", "version = 3\n", "toml"),
            ("tool", "#!/usr/bin/env python3\nprint(1)\n", "python"), ("tool", "#!/bin/sh\necho 1\n", "shell"),
            ("Makefile", "all:\n\techo 1\n", "makefile"), ("Dockerfile", "", "dockerfile"),
        ])
    func untypedNames(name: String, text: String, id: String) {
        #expect(language(verdict(name, Data(text.utf8))) == id)
        #expect(language(verdict(name, Data(text.utf8), type: .data)) == id)
        #expect(language(verdict(name, Data(text.utf8), type: .unixExecutable)) == id)
    }

    @Test("型のない名前の中身がバイナリなら「調べたらバイナリ」、言語の分からないテキストなら「対象外」と分ける")
    func untypedVerdicts() throws {
        // A Mach-O header, a stream and a binary property list under names that promise text.
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        #expect(verdict("Dockerfile", machO) == .binary)
        #expect(verdict("Gemfile", stream()) == .binary)
        #expect(verdict(".env", try binaryPropertyList()) == .binary)
        #expect(verdict("tool", Data("#!/bin/sh\n".utf8) + Data([0x00, 0x01, 0x02])) == .binary)
        #expect(verdict("notes", machO) == .binary)
        // Text, but nothing names a language: a script that lost its `#!` line is still text someone may show.
        #expect(verdict("LICENSE", Data("Permission is granted.\n".utf8)) == .notConcerned)
        #expect(verdict("tool", Data("echo 1\n".utf8)) == .notConcerned)
    }

    @Test("実際の型が別の意味を持つファイルは、中身がテキストでも門の対象にしない")
    func knownTypes() throws {
        let script = Data("#!/bin/sh\necho 1\n".utf8)
        // A real movie type, given or told from the extension.
        #expect(verdict("clip.mp4", script, type: .mpeg4Movie) == .notConcerned)
        #expect(verdict("clip.mp4", script) == .notConcerned)
        #expect(verdict("clip", script, type: .mpeg4Movie) == .notConcerned)
        #expect(verdict("archive.zip", script) == .notConcerned)
        #expect(verdict("photo.psd", script) == .notConcerned)
        #expect(verdict("notes.md", stream()) == .notConcerned)
        #expect(verdict("clip.txt", stream()) == .notConcerned)
        #expect(verdict("main.go", stream()) == .notConcerned)
        #expect(!TextFileGate.concerns(fileName: "clip.mp4", type: .mpeg4Movie))
        #expect(!TextFileGate.concerns(fileName: "notes.md"))
        #expect(TextFileGate.concerns(fileName: "Dockerfile", type: .data))
        #expect(TextFileGate.concerns(fileName: "main.ts"))
    }

    @Test("動画の型のファイルは、拡張子が何でも、名前がなくても、ストリームなら断る")
    func transportStreamTypes() throws {
        #expect(verdict("clip.m2t", stream(), type: .mpeg2TransportStream) == .binary)
        #expect(verdict("", stream(), type: .mpeg2TransportStream) == .binary)
        let avchd = try #require(UTType(filenameExtension: "mts"))
        #expect(verdict("clip", dense(), type: avchd) == .binary)
        // Text under the type of a video is text, in no language the name tells.
        #expect(verdict("notes.m2t", Data("words\n".utf8), type: .mpeg2TransportStream) == .text(nil))
        // A `.ts` that some app has given a text type is still looked at.
        #expect(verdict("clip.ts", stream(), type: .plainText) == .binary)
    }

    @Test("使うバイト列を採る所では、調べてバイナリだったものだけを断る")
    func adoptingBytes() throws {
        #expect(TextFileGate.refuses(fileName: "clip.ts", data: stream()))
        #expect(TextFileGate.refuses(fileName: "Info.plist", data: try binaryPropertyList()))
        // A Dockerfile that was text when it opened and is a binary now.
        #expect(TextFileGate.refuses(fileName: "Dockerfile", data: stream()))
        #expect(TextFileGate.refuses(fileName: "tool", data: Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01])))
        // A script that only lost its `#!` line is still text.
        #expect(!TextFileGate.refuses(fileName: "tool", data: Data("echo 1\n".utf8)))
        #expect(!TextFileGate.refuses(fileName: "main.ts", data: Data("let a = 1\n".utf8)))
        #expect(!TextFileGate.refuses(fileName: "notes.md", data: stream()))
    }

    // MARK: Reading the file

    @Test("ファイルからは先頭の 4096 バイトまでしか読まない")
    func readsOnlyTheHead() throws {
        #expect(TextFileGate.headLength == 4096)
        // 2 MB of stream. After the verdict the descriptor stands 4096 bytes in: nothing beyond was read.
        try withFiles(["clip.ts": stream(packets: 11_000), "main.ts": Data("let a = 1\n".utf8)]) { directory in
            let descriptor = try ConfinedFile.open(directory.appendingPathComponent("clip.ts"))
            defer { Darwin.close(descriptor) }
            #expect(try TextFileGate.inspect(descriptor: descriptor, fileName: "clip.ts") == .binary)
            #expect(lseek(descriptor, 0, SEEK_CUR) == 4096)
            let short = try ConfinedFile.open(directory.appendingPathComponent("main.ts"))
            defer { Darwin.close(short) }
            #expect(language(try TextFileGate.inspect(descriptor: short, fileName: "main.ts")) == "typescript")
            #expect(lseek(short, 0, SEEK_CUR) == 10)
            #expect(TextFileGate.inspect(directory.appendingPathComponent("clip.ts")) == .decided(.binary))
        }
    }

    @Test("門の対象でない名前のファイルは開きもしない")
    func doesNotOpenOtherFiles() throws {
        try withFiles([:]) { directory in
            // A pipe nobody writes to: opening it for a look would be noticed as a refusal.
            let pipe = directory.appendingPathComponent("notes.md")
            #expect(mkfifo(pipe.path, 0o600) == 0)
            #expect(TextFileGate.inspect(pipe) == .decided(.notConcerned))
        }
    }

    @Test("ないファイルは「ない」と答え、名前だけで決める今までの扱いに任せる")
    func missingFiles() {
        #expect(TextFileGate.inspect(url("missing.ts")) == .missing)
        #expect(TextFileGate.inspect(url("Dockerfile")) == .missing)
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
                let verdict = TextFileGate.inspect(pipe)
                // The system has a type of its own for a pipe, so one without an extension is none of the gate's
                // kinds and is not even opened; either way it is never text.
                #expect(verdict == .refused || (name == "Dockerfile" && verdict == .decided(.notConcerned)))
                #expect(OpenRequest.binderFormat(pipe) == nil)
                #expect(throws: (any Error).self) { try TextFileGate.read(pipe, maximumSize: 1000) }
            }
        }
    }

    @Test("読む許可のないファイルは「未判定」の候補として残し、読めるようになってから決める")
    func undecidedUntilReadable() throws {
        let files = [
            "secret.ts": stream(), "main.ts": Data("let a = 1\n".utf8), "Dockerfile": Data("FROM scratch\n".utf8),
            "Gemfile": stream(), "own.md": Data("# own".utf8),
        ]
        try withFiles(files) { directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            let locked = ["secret.ts", "main.ts", "Dockerfile", "Gemfile"]
            for name in locked { #expect(chmod(file(name).path, 0o000) == 0) }
            defer { for name in locked { chmod(file(name).path, 0o600) } }
            for name in locked {
                #expect(TextFileGate.inspect(file(name)) == .undecided, "\(name)")
                // Not turned away and not taken for certain: a candidate.
                #expect(OpenRequest.binderFormat(file(name)) == .plainText, "\(name)")
            }
            let before = DropPlan(urls: locked.map(file), receiver: .document(file("own.md")))
            #expect(before.undecided == ["Dockerfile", "Gemfile", "main.ts", "secret.ts"].map(file))
            #expect(before.adding == before.undecided)
            #expect(before.choice == .joinOrOpen(.newBinder))
            // The drop gives access: now each is read and decided.
            for name in locked { #expect(chmod(file(name).path, 0o600) == 0) }
            let after = before.decided()
            #expect(after.undecided.isEmpty)
            #expect(after.adding == ["Dockerfile", "main.ts"].map(file))
            #expect(after.leftOut == ["Gemfile", "secret.ts"].map(file))
            // A plan with nothing undecided is not made again.
            #expect(after.decided() == after)
        }
    }

    @Test("未判定の候補だけのドロップは、読めるようになって全部が動画なら断る")
    func undecidedThenRefused() throws {
        try withFiles(["secret.ts": stream(), "own.md": Data("# own".utf8)]) { directory in
            let secret = directory.appendingPathComponent("secret.ts")
            #expect(chmod(secret.path, 0o000) == 0)
            let before = DropPlan(urls: [secret], receiver: .document(directory.appendingPathComponent("own.md")))
            #expect(before.choice == .joinOrOpen(.newBinder))
            #expect(chmod(secret.path, 0o600) == 0)
            #expect(before.decided().choice == .refuse(.unsupported))
        }
    }

    @Test("一つの記述子で確かめてから本文を読み、動画・大きすぎるテキスト・フォルダーの外は読み込む前に断る")
    func readsThroughOneDescriptor() throws {
        let text = Data(String(repeating: "let a = 1\n", count: 1000).utf8)
        try withFiles(["main.ts": text, "clip.ts": stream(packets: 11_000), "Dockerfile": Data("FROM a\n".utf8)]) {
            directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            #expect(try TextFileGate.read(file("main.ts"), maximumSize: 1_000_000) == text)
            #expect(try TextFileGate.read(file("Dockerfile"), maximumSize: 1_000_000) == Data("FROM a\n".utf8))
            #expect(try TextFileGate.read(file("main.ts"), maximumSize: text.count) == text)
            #expect(throws: TextFileGate.Refusal.self) { try TextFileGate.read(file("clip.ts"), maximumSize: 1 << 30) }
            // Over the limit by one byte: told before anything of the body is read.
            #expect(throws: CocoaError.self) { try TextFileGate.read(file("main.ts"), maximumSize: text.count - 1) }
            let root = try ConfinedFile.canonicalPath(directory)
            #expect(try TextFileGate.read(file("main.ts"), within: root, maximumSize: 1_000_000) == text)
            #expect(throws: CocoaError.self) {
                try TextFileGate.read(file("main.ts"), within: root + "/elsewhere", maximumSize: 1_000_000)
            }
            #expect(throws: POSIXError.self) { try TextFileGate.read(file("gone.ts"), maximumSize: 1_000_000) }
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
                #expect(TextFileGate.inspect(link, within: root) == .refused)
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
            "h.mp4": Data("#!/bin/sh\necho 1\n".utf8),
        ]
        try withFiles(files) { directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            #expect(
                OpenRequest(urls: files.keys.map(file))
                    == .binder(
                        ["a.md", "b.ts", "d.mts", "Dockerfile", "g.plist", "tool"].map(file),
                        excluded: ["c.ts", "e.mts", "f.plist", "Gemfile", "h.mp4", "LICENSE"].map(file)))
        }
    }

    @Test("文書のウインドウへのドロップも、単独で開くときと同じファイルを受け入れる")
    func dropsOnADocument() throws {
        let files = [
            "own.md": Data("# own".utf8), "tool": Data("#!/bin/sh\necho 1\n".utf8), "clip.mts": stream(),
            "clip.ts": stream(), "main.ts": Data("let a = 1\n".utf8), "Dockerfile": Data("FROM scratch\n".utf8),
            "binary": Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01]), "clip.mp4": Data("#!/bin/sh\n".utf8),
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
                #expect(accepted.undecided.isEmpty, "\(name)")
            }
            for name in ["clip.mts", "clip.ts", "binary", "clip.mp4"] {
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

    @Test("一つの計画は、断る 1 ファイルでも複数でも、1 ファイルにつき 1 回だけ門に聞く")
    func oneDecisionPerFile() {
        final class Counter: @unchecked Sendable {
            // Only used from the test's own thread.
            var asked: [String: Int] = [:]
        }
        func plan(_ names: [String], _ counter: Counter) -> DropPlan {
            let formats = FileFormats(inspect: { url, _ in
                counter.asked[url.lastPathComponent, default: 0] += 1
                switch url.lastPathComponent {
                case "clip.ts": return .decided(.binary)
                case "Dockerfile": return .decided(.text(nil))
                case "locked.ts": return .undecided
                default: return .decided(.notConcerned)
                }
            })
            return DropPlan(urls: names.map(url), receiver: .document(url("own.md")), formats: formats)
        }
        // A single refused file: the question of whether it is an archive is answered from the same decision.
        let single = Counter()
        #expect(plan(["clip.ts"], single).choice == .refuse(.unsupported))
        #expect(single.asked == ["clip.ts": 1])
        let archive = Counter()
        #expect(plan(["photos.zip"], archive).choice == .open)
        #expect(archive.asked == ["photos.zip": 1])
        let several = Counter()
        let mixed = plan(["clip.ts", "Dockerfile", "notes.md", "photo.png", "photos.zip", "locked.ts"], several)
        #expect(mixed.adding == ["Dockerfile", "locked.ts", "notes.md", "photo.png"].map(url))
        #expect(mixed.leftOut == ["clip.ts", "photos.zip"].map(url))
        #expect(mixed.undecided == [url("locked.ts")])
        #expect(several.asked.values.allSatisfy { $0 == 1 })
        #expect(several.asked.count == 6)
    }

    @Test("Markdown から取り込む計画は、フォルダーの中で確かめた形式を子ごとに持つ")
    func includePlanCarriesFormats() throws {
        let text = "<<[main.ts]\n<<[clip.ts]\n<<[notes.md]\n<<[Dockerfile]\n"
        let files = [
            "book.md": Data(text.utf8), "main.ts": Data("let a = 1\n".utf8), "clip.ts": stream(),
            "notes.md": Data("# a".utf8), "Dockerfile": Data("FROM scratch\n".utf8),
        ]
        try withFiles(files) { directory in
            func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
            let plan = try #require(MarkdownIncludes(markdown: text)).plan(parent: file("book.md"))
            #expect(plan.documents == ["main.ts", "notes.md", "Dockerfile"].map(file))
            #expect(plan.excluded == [file("clip.ts")])
            #expect(
                plan.formats == [
                    file("main.ts"): .plainText, file("notes.md"): .markdown, file("Dockerfile"): .plainText,
                ]
            )
        }
    }
}
