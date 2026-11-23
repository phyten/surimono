import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.timeLimit(.minutes(1)))
struct SourceCodeRenderingTests {
    private func source(_ name: String?, _ data: Data) -> DocumentSource {
        DocumentSource(
            data: data, fileURL: name.map { URL(fileURLWithPath: "/tmp/surimono-tests/" + $0) }, format: .plainText)
    }

    private func utf16(_ text: String) -> Data {
        Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
    }

    @Test("拡張子のない Makefile は紙の上でも Makefile として色が付く")
    func makefile() throws {
        let text = "# Build\nOUT := build\nall: $(OUT)\n\tmkdir -p $(OUT)\n"
        let html = try #require(DocumentRenderer.structureHTML(of: source("Makefile", Data(text.utf8))))
        #expect(
            html == """
                <pre class="surimono-source"><span class="hl-comment"># Build</span>
                <span class="hl-section">OUT </span>:= build
                <span class="hl-section">all</span>: <span class="hl-variable">$(OUT)</span>
                \tmkdir -p <span class="hl-variable">$(OUT)</span>
                </pre>
                """)
        #expect(DocumentRenderer.sourceLanguage(of: source("Makefile", Data(text.utf8)))?.id == "makefile")
    }

    @Test("拡張子のないスクリプトは紙の上でも shebang の言語で色が付く")
    func shebang() throws {
        let script = source("tool", Data("#!/usr/bin/env python3\nimport sys\n".utf8))
        let html = try #require(DocumentRenderer.structureHTML(of: script))
        #expect(html.contains("<span class=\"hl-keyword\">import</span> sys"))
        #expect(DocumentRenderer.sourceLanguage(of: script)?.id == "python")
    }

    @Test("UTF-16 の .m が % で始まるとき、紙も言語の名前も MATLAB になる")
    func utf16MATLAB() throws {
        let file = source("solve.m", utf16("% 連立方程式を解く\nx = A \\ b;\n"))
        let html = try #require(DocumentRenderer.structureHTML(of: file))
        #expect(html.hasPrefix("<pre class=\"surimono-source\"><span class=\"hl-comment\">% 連立方程式を解く</span>\n"))
        #expect(DocumentRenderer.sourceLanguage(of: file)?.id == "matlab")
    }

    @Test("UTF-16 の .m が #import で始まるとき、紙も言語の名前も Objective-C になる")
    func utf16ObjectiveC() throws {
        let file = source("View.m", utf16("#import <Foundation/Foundation.h>\n% 5;\n"))
        let html = try #require(DocumentRenderer.structureHTML(of: file))
        #expect(html.hasPrefix("<pre class=\"surimono-source\"><span class=\"hl-meta\">#import"))
        #expect(!html.contains("hl-comment"))
        #expect(DocumentRenderer.sourceLanguage(of: file)?.id == "objectivec")
    }

    @Test("BOM 付き UTF-8 と UTF-16 のスクリプトは、紙も言語の名前も shebang の言語になる")
    func scriptsWithByteOrderMarks() throws {
        let text = "#!/usr/bin/env ruby\nputs 1\n"
        for data in [Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), utf16(text)] {
            let file = source("tool", data)
            let html = try #require(DocumentRenderer.structureHTML(of: file))
            #expect(html.contains("<span class=\"hl-builtin\">puts</span>"))
            #expect(DocumentRenderer.sourceLanguage(of: file)?.id == "ruby")
        }
    }

    @Test("ASCII でない長い最初の行は文字数で数え、紙と言語の名前が同じ答えになる")
    func longNonASCIIFirstLine() throws {
        // 211 characters but 611 bytes: counting bytes would cut the interpreter's name off.
        let fits = "#!/" + String(repeating: "紙", count: 200) + "/python3\nimport sys\n"
        let short = source("tool", Data(fits.utf8))
        let colored = try #require(DocumentRenderer.structureHTML(of: short))
        #expect(colored.contains("<span class=\"hl-keyword\">import</span>"))
        #expect(DocumentRenderer.sourceLanguage(of: short)?.id == "python")
        // The name ends at the 256th character and may go on, so neither the page nor the name takes a language.
        let cut = "#!/" + String(repeating: "紙", count: 246) + "/python3-config\nimport sys\n"
        let long = source("tool", Data(cut.utf8))
        let plain = try #require(DocumentRenderer.structureHTML(of: long))
        #expect(!plain.contains("hl-"))
        #expect(DocumentRenderer.sourceLanguage(of: long) == nil)
    }

    @Test("ファイルのないメモリの文書は、渡されたファイル名の言語で色が付く")
    func namedMemoryDocument() throws {
        let data = Data("const pages: number = 2;\n".utf8)
        let memory = DocumentSource(data: data, format: .plainText).named("main.ts")
        let html = try #require(DocumentRenderer.structureHTML(of: memory))
        #expect(html.contains("<span class=\"hl-keyword\">const</span>"))
        #expect(DocumentRenderer.sourceLanguage(of: memory)?.id == "typescript")
        // A file under a temporary URL with a name of its own is told by that name, not the URL's.
        let temporary = source("0C1F-temporary", data).named("main.ts")
        #expect(temporary.name == "main.ts")
        #expect(DocumentRenderer.sourceLanguage(of: temporary)?.id == "typescript")
        #expect(DocumentRenderer.sourceLanguage(of: source("0C1F-temporary", data)) == nil)
    }

    @Test("同じバイト列でも名前の違うメモリの文書は別の文書で、同じレンダラーでもそれぞれの言語で組む", .timeLimit(.minutes(1)))
    @MainActor
    func sameBytesUnderTwoNames() async throws {
        let data = Data("let pages = 2\n".utf8)
        let typeScript = DocumentSource(data: data, format: .plainText).named("a.ts")
        let swift = DocumentSource(data: data, format: .plainText).named("a.swift")
        let unnamed = DocumentSource(data: data, format: .plainText)
        #expect(typeScript != swift)
        #expect(typeScript != unnamed)
        #expect(typeScript == DocumentSource(data: data, format: .plainText).named("a.ts"))
        // One renderer, which keeps the pages of the last document it laid out.
        var layouts = 0
        let renderer = DocumentRenderer(paginate: { _ in
            layouts += 1
            return try RenderingFixtures.pdf()
        })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let first = try await renderer.prepare(typeScript, settings: settings)
        #expect(first.facts?.sourceLanguage?.id == "typescript")
        let second = try await renderer.prepare(swift, settings: settings)
        #expect(second.facts?.sourceLanguage?.id == "swift")
        let third = try await renderer.prepare(unnamed, settings: settings)
        #expect(third.facts?.sourceLanguage == nil)
        #expect(layouts == 3)
        // The same document again is the one case that reuses the pages.
        _ = try await renderer.prepare(unnamed, settings: settings)
        #expect(layouts == 3)
    }

    @Test("合本は同じ内容でも子の名前と shebang で行番号の既定を決め、明示した設定を優先する")
    @MainActor
    func binderPageKinds() async throws {
        let bytes = Data("#!/bin/sh\necho paper\n".utf8)
        let child = DocumentSource(data: bytes, format: .plainText)
        let binder = DocumentSource.binder([child.named("script"), child.named("script.log")])
        var numbered: [Bool] = []
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source { numbered.append(html.contains("class=\"source-no\"")) }
            return try RenderingFixtures.pdf()
        })
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        _ = try await renderer.prepare(binder, settings: settings)
        #expect(numbered == [true, false])
        numbered.removeAll()
        settings.code = CodeStyle(block: CodeBlockOptions())
        _ = try await renderer.prepare(binder, settings: settings)
        #expect(numbered == [false, false])
    }

    @Test("文章と名前のないテキストは、紙も言語の名前も色なしのまま")
    func plain() throws {
        let data = Data("#!/bin/sh\necho 1\n".utf8)
        for file in [source("notes.txt", data), source(nil, data), source("Dockerfile.txt", data)] {
            #expect(
                DocumentRenderer.structureHTML(of: file) == "<pre class=\"surimono-plain\">#!/bin/sh\necho 1\n</pre>")
            #expect(DocumentRenderer.sourceLanguage(of: file) == nil)
        }
        let markdown = DocumentSource(
            data: data, fileURL: URL(fileURLWithPath: "/tmp/surimono-tests/tool"), format: .markdown)
        #expect(DocumentRenderer.sourceLanguage(of: markdown) == nil)
    }
}
