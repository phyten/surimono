import CryptoKit
import Foundation
import Testing

@testable import SurimonoFormats

struct ComputationalReadingTests {
    @Test("既定の読み方では従来の HTML 本文とバイト単位で一致する")
    func originalBytes() throws {
        // SHA-256 of each complete UTF-8 body from the converter at 472090ee.
        let examples: [(DocumentFormat, String, String)] = [
            (
                .quarto, "---\ntitle: Report\nlang: en\n---\n# One\n\nSome *text*.",
                "08fa978f30ee47a39b56daba374c86d1e4ee9b71bae040e627f864981b89f522"
            ),
            (
                .quarto, "---\ntoc: true\nnumber-sections: true\n---\n# One\n\n### Three\n\n[TOC]",
                "7164192c06b97233823c189919ccd87339259e309706531a60bac0b7a2b847ef"
            ),
            (
                .quarto, "# Code\n\n```{python}\n#| echo: true\nprint(3)\n```",
                "23a85844e4ecb0cd10738bbd39da3e4c50be20448f7d216592eb8a0e7769ced3"
            ),
            (
                .rMarkdown, "---\noutput: html_notebook\n---\n# Notes\n\n```{r}\nsummary(x)\n```\n\n[TOC]",
                "cfe406cb45a5a7f4a797cb6e89856a5d5ca26a8eec3e788cfd2d9e38f34cd2f4"
            ),
            (
                .rMarkdown, "---\noutput:\n  pdf_document: default\n---\n## Results\n\nA result.",
                "d0f16367042e0c017a01a0dec1066686125a357308265b84df8a7687e0ce96c3"
            ),
            (
                .rMarkdown, "---\ntoc: true\noutput:\n  html_document:\n    toc: true\n---\n# Notes\n\n## Results",
                "5e554dcb0269c09c41f9519b95923c5016d75903488f6bb08125d651ce3ef95e"
            ),
            (
                .notebook,
                ###"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":["# Notes\n","\n","[TOC]\n","\n","## Results"]}]}"###,
                "8bfe43ee6321cac3bb5caa60022621b67f67e3b9e4129c41eecf4d1bf1135a3a"
            ),
        ]
        for (format, source, expected) in examples {
            let fragment =
                format == .notebook
                ? try NotebookConverter.convert(source) : ComputationalMarkdown.convert(source, format: format)
            let digest = SHA256.hash(data: Data(fragment.body.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == expected, "\(format): \(source)")
        }
    }
}

extension ComputationalReadingTests {
    @Test("Quarto は先頭の形式が指定した成分だけを最上位に重ね、元の行を残す", arguments: ["html", "pdf"])
    func quartoOverrides(first: String) throws {
        let lines = [
            "---", "format:", "  \(first):", "    toc: false # quiet", "    number-depth: 2",
            "    theme:", "      toc-depth: 9", "  docx:", "    number-sections: false", "toc: true", "toc-depth: 1",
            "number-sections: true", "---", "# One", "## Two", "### Three",
        ]
        let source = "\u{FEFF}" + lines.joined(separator: "\r\n")
        let f = ComputationalMarkdown.convert(source, format: .quarto)
        #expect(f.contentsInstructions.present?.value == false)
        #expect(f.contentsInstructions.depth?.value == .levels(1))
        let number = try #require(f.numberInstructions.depth)
        #expect(f.numberInstructions.present?.value == true && number.value == .levels(2))
        #expect(number.source?.lineNumber == 5 && number.source?.rawText == "number-depth: 2")
        #expect(number.source?.excerpt?.line == lines[4] && number.source?.excerpt?.previous == lines[3])
        #expect(number.source?.excerpt?.tokenOffset == 4)
        #expect(f.body.contains(">1.1 Two</h2>") && f.body.contains(">Three</h3>"))
        #expect(!f.body.contains("<nav"))
    }

    @Test("R Markdown は最初の出力だけを読み、後続の形式や別の階層の指定を拾わない")
    func firstOutput() {
        let lines = [
            "---", "output:", "  bookdown::html_document2:", "    toc: true", "    toc_depth: 1",
            "    number_sections: TRUE", "    params:", "      toc: false", "  pdf_document:", "    toc_depth: 3",
            "---", "# One", "## Two", "[TOC]",
        ]
        let fragment = ComputationalMarkdown.convert("\u{FEFF}" + lines.joined(separator: "\r\n"), format: .rMarkdown)
        #expect(
            fragment.contentsInstructions.present?.value == true
                && fragment.contentsInstructions.depth?.value == .levels(1))
        #expect(fragment.numberInstructions.present?.source?.lineNumber == 6)
        #expect(fragment.numberInstructions.present?.source?.rawText == "number_sections: TRUE")
        #expect(fragment.numberInstructions.depth == nil)
        #expect(fragment.body.contains(">1.1 Two</h2>"))
        #expect(fragment.body.components(separatedBy: "</nav>").first?.contains("Two") == false)
    }

    @Test(
        "形式名だけの output と default の後の形式は読み方を固定しない",
        arguments: [
            "output: html_notebook", "toc: true\nnumber-sections: true\noutput: html_document",
            "output:\n  html_notebook: default\n  pdf_document:\n    toc: true",
            "format:\n  html:\n    number-sections: true\n    toc: true",
        ])
    func noOutputOptions(header: String) {
        let fragment = ComputationalMarkdown.convert("---\n" + header + "\n---\n# One", format: .rMarkdown)
        #expect(fragment.numberInstructions == .init() && fragment.contentsInstructions == .init())
        #expect(fragment.body.contains(">One</h1>") && !fragment.body.contains("<nav"))
    }

    @Test("真偽値以外の有無指定と不正な深さは固定しない", arguments: [DocumentFormat.quarto, .rMarkdown])
    func invalidScalars(format: DocumentFormat) {
        let header =
            format == .quarto
            ? "toc: perhaps\nnumber-sections: 1\ntoc-depth: -1\nnumber-depth: nope"
            : "output:\n  pdf_document:\n    toc: [unknown]\n    number_sections: yes-please\n    toc_depth: 1.5"
        let fragment = ComputationalMarkdown.convert("---\n" + header + "\n---\n# One", format: format)
        #expect(fragment.contentsInstructions == .init() && fragment.numberInstructions == .init())
    }

    @Test(
        "引用やリストに入った真は先頭の目次だけを有効にし、BOM のある原稿でも行を保つ",
        arguments: [DocumentFormat.quarto, .rMarkdown], ["'true'", "\"true\"", "True", "[true]", "'false'", "yes"])
    func contentsValues(format: DocumentFormat, value: String) {
        let options =
            format == .quarto
            ? "format:\n  pdf:\n    toc: \(value)\n    number-sections: \(value)"
            : "output:\n  pdf_document:\n    toc: \(value)\n    number_sections: \(value)"
        let source = "\u{FEFF}---\n" + options + "\n---\n# Heading"
        let fragment = ComputationalMarkdown.convert(source, format: format)
        let expected: Bool? = value == "yes" ? nil : value != "'false'"
        #expect(fragment.contentsInstructions.present?.value == expected)
        #expect(fragment.body.contains("<nav ") == (expected == true))
        #expect(fragment.numberInstructions.present?.value == (value == "True" ? true : nil))
        #expect(fragment.contentsInstructions.present?.source?.lineNumber == (expected == nil ? nil : 4))
        #expect(!fragment.body.contains("pdf") && !fragment.body.contains("toc:"))
    }

    @Test("目次のリストは直下の値を読み、別のキーのリストは読まない", arguments: [DocumentFormat.quarto, .rMarkdown])
    func contentsList(format: DocumentFormat) {
        let parent = format == .quarto ? "format:\n  pdf:" : "output:\n  pdf_document:"
        for (children, expected) in [("    - true", true), ("      nested:\n        - true", false)] {
            let text = "---\n" + parent + "\n    toc:\n" + children + "\n---\n# Title"
            let fragment = ComputationalMarkdown.convert(text, format: format)
            #expect(fragment.contentsInstructions.present?.value == (expected ? true : nil))
            #expect(fragment.body.contains("<nav ") == expected)
        }
    }

    @Test("一行の出力形式でも宣言順と指定の行を保つ")
    func flowMapping() {
        let source = "---\noutput: {pdf_document: {toc: true, toc_depth: 2}, html_document: {toc: false}}\n---\n# One"
        let file = ComputationalMarkdown.convert(source, format: .rMarkdown).contentsInstructions
        #expect(file.present?.value == true && file.depth?.value == .levels(2))
        #expect(file.depth?.source?.lineNumber == 2)
    }
}

extension ComputationalReadingTests {
    @Test("文書で追加した先頭の目次は変換結果にも含まれ、本文の目次を残す", arguments: [DocumentFormat.quarto, .rMarkdown])
    func documentLead(format: DocumentFormat) {
        var reading = MarkdownReadingSettings()
        reading.document.set(.outline(present: true, depth: .levels(1)), for: .tableOfContents, format: format)
        let fragment = ComputationalMarkdown.convert("# One\n\n## Two\n\n[TOC]", format: format, reading: reading)
        #expect(fragment.body.hasPrefix("<nav") && fragment.body.components(separatedBy: "</nav>").count == 3)
    }

    @Test("Quarto の番号の深さだけを原稿が決めたときは有無だけを変更できる")
    func numberDepthLock() throws {
        let source = "---\nnumber-depth: 1\n---\n# One\n\n## Two"
        let file = ComputationalMarkdown.convert(source).numberInstructions
        var reading = MarkdownReadingSettings()
        let state = try #require(reading.document.resolve(.sectionNumbers, for: .quarto, file: file))
        #expect(state.allowsOutline(present: true, depth: .levels(1)))
        #expect(state.allowsOutline(present: false, depth: .all))
        #expect(!state.allowsOutline(present: true, depth: .all))
        reading.document.set(
            .outline(present: true, depth: .levels(1)), for: .sectionNumbers, format: .quarto, file: file)
        let body = ComputationalMarkdown.convert(source, reading: reading).body
        #expect(body.contains(">1 One</h1>") && body.contains(">Two</h2>"))
    }

    @Test("下線見出しも同じ順で数え、番号を外した節は後続の番号を進めない")
    func setextHeadings() {
        let source =
            "---\nnumber-sections: true\ntoc: true\n---\nBook\n====\n\n## Skip {.unnumbered}\n\nChapter\n-------\n\n## Last {#sec-end}\n\n@sec-end"
        let html = ComputationalMarkdown.convert(source).body
        #expect(html.contains(">1 Book</h1>") && html.contains(">1.1 Chapter</h2>") && html.contains(">1.2 Last</h2>"))
        #expect(html.contains(">1.1 Chapter</a>") && html.contains(">Section 1.2</a>"))
    }
}
