import CryptoKit
import Foundation
import Testing

@testable import SurimonoFormats

struct AsciiDocReadingTests {
    @Test("既定の変換結果は移行前の本文とバイト単位で一致する")
    func manuscriptBytes() throws {
        let sections = "\n\n== One\n\n=== Two\n\n==== Three\n\n===== Four\n\n====== Five"
        let attributes = [
            "", ":sectnums:", ":sectnums!:", ":!sectnums:", ":sectnumlevels: 2", ":toc:", ":toc: auto",
            ":toc: left", ":toc: right", ":toc: preamble", ":toc!:", ":!toc:", ":toclevels: 1", ":toc-title: Map",
            ":toc:\n:toclevels: 5\n:toc-title: Map\n:sectnums:\n:sectnumlevels: 5", ":toc: macro",
        ]
        let sources =
            attributes.map { "= Book\n" + $0 + sections + "\n\ntoc::[]" } + [
                "= Book\n:sectnums:\n:toc:" + sections
                    + "\n\n[appendix]\n== Extra\n\n[discrete]\n== Aside\n\n[glossary]\n== Terms\n\n[bibliography]\n== Sources",
                "= Book" + sections + "\n\n:sectnums:\n\n== Start\n\n:sectnums!:\n\n== Stop",
            ]
        let hashes = try sources.map { source in
            let body = try AsciiDocConverter.convert(source).body
            return SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        // SHA-256 of the UTF-8 fragments at 60410171.
        #expect(
            hashes == [
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "d2dd0acf570bd3c39d996d0a434db1ec4f677a5393809d7dba3b247ef09a6763",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "177f7a01b0150d8007ef376d65e74502dfe45b6117bbadc625e41cea4a799412",
                "177f7a01b0150d8007ef376d65e74502dfe45b6117bbadc625e41cea4a799412",
                "177f7a01b0150d8007ef376d65e74502dfe45b6117bbadc625e41cea4a799412",
                "177f7a01b0150d8007ef376d65e74502dfe45b6117bbadc625e41cea4a799412",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "b86604fe1538ce75cfdd877e13aa982dd5479f6b97e7d75ca576a2fdce0ee6c5",
                "aad56fc1754913533c3ddbe7780b8cbd7579fc8d70c724728cc97ecdb2cb3ac8",
                "63481b2c0d23c7a7a582e8bc4a7f7e567df90a67fd45e005143507ced33af30e",
                "c480e7d7e42471e98fb2601c49969dd0e6ff0deac4bb76d4ca209b17d4728ed0",
                "83b0d1ce4d0ce0b04a752dde2da284eaf68175a269355f8885d029b2db5ea6b8",
            ])
    }
}

extension AsciiDocReadingTests {
    @Test("ヘッダーで最後に指定した成分には元の行と前後の文が付く", arguments: ["\n", "\r\n"], ["", "\u{feff}"])
    func reasons(newline: String, bom: String) throws {
        let lines = [
            "= Book", "Author", "v1.0", ":sectnums!:", ":sectnumlevels: 0", ":sectnums:", ":toc:", ":toclevels: 5",
            ":!toc:", "", "== A",
        ]
        let fragment = try AsciiDocConverter.convert(bom + lines.joined(separator: newline))
        let numbers = fragment.numberInstructions
        let contents = fragment.contentsInstructions
        #expect(numbers.present?.value == true && numbers.present?.source?.lineNumber == 6)
        #expect(numbers.depth?.value == .levels(0) && numbers.depth?.source?.lineNumber == 5)
        #expect(numbers.present?.source?.excerpt?.next == ":toc:")
        #expect(contents.present?.value == false && contents.present?.source?.rawText == ":!toc:")
        #expect(contents.depth?.value == .levels(5) && contents.depth?.source?.excerpt?.line == ":toclevels: 5")
    }

    @Test("目次の位置は有無だけを固定する", arguments: ["", " auto", " preamble", " left", " right"])
    func tocPlacement(_ value: String) throws {
        let result = try AsciiDocConverter.convert("= Book\n:toc:\(value)\n:toc-title: Map\n\nIntro\n\n== A")
        #expect(result.contentsInstructions.present?.value == true)
        #expect(result.contentsInstructions.present?.source?.lineNumber == 2)
        #expect(result.contentsInstructions.depth == nil && result.contentsTitle == "Map")
    }

    @Test("属性を解除する二つの書き方は「なし」だけを固定する", arguments: [true, false])
    func unset(prefix: Bool) throws {
        let lines = prefix ? ":!sectnums:\n:!toc:" : ":sectnums!:\n:toc!:"
        let result = try AsciiDocConverter.convert(lines + "\n\n== A")
        #expect(
            result.numberInstructions.present?.value == false && result.contentsInstructions.present?.value == false)
        #expect(result.numberInstructions.depth == nil && result.contentsInstructions.depth == nil)
    }

    @Test("不明な値・不正な深さは先に書いた行を固定の理由にしない", arguments: ["6", "-1", "2.0", "two", "{limit}"])
    func invalid(_ value: String) throws {
        let result = try AsciiDocConverter.convert(
            "= Book\n:limit: 2\n:toc:\n:sectnums:\n:toclevels: 2\n:sectnumlevels: 1\n:toc: mystery\n:sectnums: no\n:toclevels: \(value)\n:sectnumlevels: \(value)\n\n== A"
        )
        #expect(!result.numberInstructions.hasInstructions && !result.contentsInstructions.hasInstructions)
    }

    @Test("区切りブロックとコメントの属性は固定に使わない", arguments: ["----", "....", "++++", "////"], ["\n", "\n\n"])
    func delimited(fence: String, gap: String) throws {
        let result = try AsciiDocConverter.convert(
            "= Book" + gap + fence + "\n:sectnums:\n:toc:\n:toclevels: 4\n" + fence + "\n\n== A")
        #expect(!result.numberInstructions.hasInstructions && !result.contentsInstructions.hasInstructions)
    }

    @Test("本文の属性は節ごとに効き、目次マクロと番号の切替は注記になる")
    func regional() throws {
        let result = try AsciiDocConverter.convert(
            "= Book\n:toc: macro\n\n== First\n\ntoc::[]\n\n:sectnums:\n:toclevels: 1\n:sectnumlevels: 1\n\n== Second\n\n:!sectnums:\n\n== Third"
        )
        #expect(!result.numberInstructions.hasInstructions && !result.contentsInstructions.hasInstructions)
        #expect(result.inTextContentsMarker == "toc::[]" && result.inTextNumberMarker == ":sectnums:")
        #expect(
            result.body.contains(">First</h2>") && result.body.contains(">1. Second</h2>")
                && result.body.contains(">Third</h2>"))
        let absent = try AsciiDocConverter.convert("= Book\n:toc: macro\n\n== A")
        #expect(absent.inTextContentsMarker == nil && !absent.contentsInstructions.hasInstructions)
    }

    @Test("題なし・下線の題・コメントを挟んだヘッダーでも実際の指定行を使う")
    func headerForms() throws {
        let bare = try AsciiDocConverter.convert("\u{feff}:sectnums:\r\n:toclevels: 0\r\n\r\n== A")
        #expect(bare.numberInstructions.present?.source?.rawText == ":sectnums:")
        #expect(bare.contentsInstructions.depth?.value == .levels(0))
        let underlined = try AsciiDocConverter.convert("Book\n====\n:sectnums:\n\n== A")
        #expect(underlined.numberInstructions.present?.source?.lineNumber == 3)
        let comments = try AsciiDocConverter.convert("= Book\n// :toc!:\n////\n:toc:\n////\n:sectnums:\n\n== A")
        #expect(
            comments.numberInstructions.present?.source?.lineNumber == 6
                && !comments.contentsInstructions.hasInstructions)
        let ambiguous = try AsciiDocConverter.convert(":toc:\n:!toc!:\n:sectnums:\n:!sectnums!:\n\n== A")
        #expect(!ambiguous.numberInstructions.hasInstructions && !ambiguous.contentsInstructions.hasInstructions)
        let afterBlank = try AsciiDocConverter.convert(":lang: en\n\n:toc:\n:sectnums:\n\n== A")
        #expect(!afterBlank.contentsInstructions.hasInstructions && !afterBlank.numberInstructions.hasInstructions)
        #expect(afterBlank.body.contains(">1. A</h2>") && afterBlank.inTextNumberMarker == ":sectnums:")
    }

    @Test("先頭の目次を切り替えても本文のマクロは原稿の位置と深さを保つ", arguments: [true, false])
    func independentMacro(nativeLead: Bool) throws {
        let text = "= Book\n:toc:" + (nativeLead ? "" : " macro") + "\n:toclevels: 2\n\n== One\n\ntoc::[]\n\n=== Two"
        var reading = FormatReadingSettings()
        let original = try AsciiDocConverter.convert(text)
        reading.document.setAllowsFileChanges(true, for: .asciidoc)
        reading.document.set(
            .outline(present: !nativeLead, depth: .levels(1)), for: .tableOfContents, format: .asciidoc,
            file: original.contentsInstructions)
        let edited = try AsciiDocConverter.convert(text, contentsDepth: 1, reading: reading)
        #expect(edited.contentsKinds.values.contains(.lead) == !nativeLead)
        let inline = DocumentOutline.contentsHeadings(in: edited.body, navIndex: nativeLead ? 0 : 1)
        #expect(inline.map(\.text) == ["One", "Two"])
        #expect(edited.body.components(separatedBy: "<nav ").count == (nativeLead ? 2 : 3))
    }

    @Test("深さゼロの先頭目次は記事なら最上位の節、複数部の本なら部だけを載せる")
    func partsOnly() throws {
        var reading = FormatReadingSettings()
        reading.document.set(.outline(present: true, depth: .levels(0)), for: .tableOfContents, format: .asciidoc)
        let article = try AsciiDocConverter.convert("= Book\n\n== One\n\n=== Child", reading: reading)
        #expect(DocumentOutline.contentsHeadings(in: article.body, navIndex: 0).map(\.text) == ["One"])
        let book = try AsciiDocConverter.convert(
            "= Book\n:doctype: book\n\n= Part One\n\n== First\n\n= Part Two\n\n== Next", reading: reading)
        #expect(DocumentOutline.contentsHeadings(in: book.body, navIndex: 0).map(\.text) == ["Part One", "Part Two"])
    }

    @Test("本文で番号の深さが変わっても目次と参照は参照先の見出しに従う")
    func regionalDepth() throws {
        let source = """
            = Book
            :sectnums:
            :toc:
            :xrefstyle: short

            == One

            === Early

            <<late>>

            :sectnumlevels: 1

            [[late]]
            === Late

            <<_early>>
            """
        let result = try AsciiDocConverter.convert(source)
        #expect(result.body.contains(">1.1. Early</h3>") && result.body.contains(">Late</h3>"))
        #expect(
            DocumentOutline.contentsHeadings(in: result.body, navIndex: 0).map(\.text) == [
                "1. One", "1.1. Early", "Late",
            ])
        #expect(result.body.contains("<p><a href=\"#late\">Late</a></p>"))
        #expect(result.body.contains("<p><a href=\"#_early\">Section 1.1</a></p>"))
    }

    @Test("深さから外れた節への短い参照は元の節名になる")
    func unnumberedReference() throws {
        let result = try AsciiDocConverter.convert(
            "= Book\n:sectnums:\n:sectnumlevels: 1\n:xrefstyle: short\n\n== One\n\n[[child]]\n=== Child\n\n<<child>>")
        #expect(result.body.contains(">Child</h3>") && result.body.contains("href=\"#child\">Child</a>"))
    }
}
