import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

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
                <pre class="surimono-plain"><span class="hl-comment"># Build</span>
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
        #expect(html.hasPrefix("<pre class=\"surimono-plain\"><span class=\"hl-comment\">% 連立方程式を解く</span>\n"))
        #expect(DocumentRenderer.sourceLanguage(of: file)?.id == "matlab")
    }

    @Test("UTF-16 の .m が #import で始まるとき、紙も言語の名前も Objective-C になる")
    func utf16ObjectiveC() throws {
        let file = source("View.m", utf16("#import <Foundation/Foundation.h>\n% 5;\n"))
        let html = try #require(DocumentRenderer.structureHTML(of: file))
        #expect(html.hasPrefix("<pre class=\"surimono-plain\"><span class=\"hl-meta\">#import"))
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
