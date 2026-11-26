import CryptoKit
import Foundation
import Testing

@testable import SurimonoFormats

struct RSTWikiReadingTests {
    @Test("既定の本文は従来の変換結果とバイト単位で一致する")
    func baseline() throws {
        let sections = "One\n===\n\nChild\n-----\n\nDeep\n~~~~\n\nTwo\n===\n"
        let rst = [
            sections,
            ".. sectnum::\n   :start: 4\n   :prefix: [\n   :suffix: ]\n   :depth: 2\n\n" + sections,
            ".. contents:: Map\n   :depth: 2\n\n" + sections,
            ".. sectnum::\n\n" + sections + "\n.. contents:: Later\n",
            sections.replacingOccurrences(of: "Child\n", with: ".. contents::\n   :local:\n\nChild\n"),
        ]
        let wiki = ["", "__TOC__", "__FORCETOC__", "__NOTOC__"]
        let bodies =
            rst.map { RSTConverter.convert($0).body }
            + wiki.map {
                MediaWikiConverter.convert("Intro\n" + $0 + "\n== One ==\n=== Child ===\n== Two ==").body
            }
        // UTF-8 bodies captured from 84d0c9e8, in the order above.
        let expected = [
            "5133a96e6e7274c21fc24646a534f38e35f2ba9943a60acea5bdacad31d57664",
            "a68114a15f7575ab30aa55023664ba62ec80315f0bc4b7a6e6f4015a15f10f5d",
            "c5acb9ad3ddb8a848c904e52500dacd76219163f4ee7c12d17523366fb88abcf",
            "2600701fb17c2ef407863f518ff4d482b74fa2d1353524af08f06c402b878d4b",
            "7497e8e957aea5700a87685deba2db4806e7286f8b566a70538defd16ce31615",
            "0ef9a1d827c0d11fd468be98ad421419281091ba59fd5e3e0c4d8f71ec338364",
            "854f0111e6fbbb1bb6bbe04aff8d94a1adfa195463d8b6904e5890cb7ec605ea",
            "854f0111e6fbbb1bb6bbe04aff8d94a1adfa195463d8b6904e5890cb7ec605ea",
            "0ef9a1d827c0d11fd468be98ad421419281091ba59fd5e3e0c4d8f71ec338364",
        ]
        #expect(bodies.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } == expected)
    }

    @Test("rST は実際に読んだ指示行と深さの行を別々に固定する")
    func rstInstructions() throws {
        let text = """
            Example::

               .. sectnum::
                  :depth: 6

            .. section-numbering::
               :depth: 1

            .. SeCtNuM::
               :prefix: [
               :depth: 2
               :depth: 3
               :suffix: ]

            One
            ===

            Two
            ===
            """
        let result = RSTConverter.convert("\u{feff}" + text.replacingOccurrences(of: "\n", with: "\r\n"))
        let file = result.numberInstructions
        #expect(file.present?.source?.lineNumber == 9)
        #expect(file.present?.source?.rawText == ".. SeCtNuM::")
        #expect(file.depth?.value == .levels(3))
        #expect(file.depth?.source?.lineNumber == 12)
        #expect(file.depth?.source?.excerpt?.line == "   :depth: 3")
        #expect(result.body.contains("[1] "))
        #expect(RSTConverter.convert("::\n\n   .. sectnum::\n   .. contents::").numberInstructions == .init())
        #expect(RSTConverter.convert(".. code:: rst\n\n   .. contents::").contentsInstructions == .init())
    }

    @Test("題と著者の後の目次は先頭の設定に入り、字下げされた引用の指示は原稿の行を指す")
    func rstFrontMatterAndQuote() throws {
        let title = "Book\n====\n\n:Author: Reader\n\n.. contents:: Map\n\nFirst\n-----\n\nSecond\n------"
        let contents = RSTConverter.convert(title)
        #expect(contents.contentsTitle == "Map" && contents.contentsKinds == [0: .lead])
        #expect(contents.contentsInstructions.present?.source?.lineNumber == 6)
        let quote = RSTConverter.convert("Example::\n\n   .. sectnum::\n\nText.\n\n   .. sectnum::\n      :depth: 2\n")
        #expect(quote.numberInstructions.present?.source?.lineNumber == 7)
        #expect(quote.numberInstructions.depth?.source?.lineNumber == 8)
        #expect(quote.numberInstructions.depth?.source?.excerpt?.line == "      :depth: 2")
    }

    @Test("先頭の全体目次だけが固定され、本文の目次には元の深さと題が残る")
    func rstContents() throws {
        let text =
            ".. contents:: Map\n   :depth: 1\n\nOne\n===\n\n.. contents:: Local\n   :local:\n\nChild\n-----\n\n.. contents:: Other\n\nTwo\n==="
        let result = RSTConverter.convert(text)
        #expect(result.contentsTitle == "Map")
        #expect(result.contentsInstructions.present?.source?.rawText == ".. contents:: Map")
        #expect(result.contentsInstructions.depth?.source?.lineNumber == 2)
        #expect(result.contentsInstructions.depth?.value == .levels(1))
        #expect(result.contentsKinds == [0: .lead, 1: .text, 2: .text])
        #expect(result.inTextContentsMarker?.contains(":local:") == true)
        let local = RSTConverter.convert(".. contents::\n   :depth: 1\n   :local:\n\nOne\n===\n\nTwo\n===")
        #expect(local.contentsInstructions == .init() && local.inTextContentsMarker != nil)
        let bare = RSTConverter.convert(".. sectnum::\n\n.. contents:: Map")
        #expect(bare.numberInstructions.present?.value == true && bare.numberInstructions.depth == nil)
        #expect(bare.contentsInstructions.present?.value == true && bare.contentsInstructions.depth == nil)
    }

    @Test("Wiki は nowiki・pre・コメントの指定を除き、順序によらず強制を優先する", arguments: [true, false])
    func wikiInstructions(forceFirst: Bool) throws {
        let force = "原稿 __FORCETOC__"
        let hide = "__NOTOC__"
        let lines = [
            "<nowiki>", "__FORCETOC__", "</nowiki>", "<pre>__NOTOC__</pre>", "<!--__FORCETOC__-->",
            forceFirst ? force : hide, forceFirst ? hide : force, "__FORCETOC__", "== One ==",
        ]
        let result = MediaWikiConverter.convert("\u{feff}" + lines.joined(separator: "\r\n"))
        let instruction = try #require(result.contentsInstructions.present)
        #expect(instruction.value && instruction.source?.rawText == "__FORCETOC__")
        #expect(instruction.source?.lineNumber == (forceFirst ? 6 : 7))
        #expect(instruction.source?.excerpt?.line == force && instruction.source?.excerpt?.tokenOffset == 3)
        #expect(result.contentsInstructions.depth == nil)
        #expect(result.contentsKinds == [0: .lead])
        let literal = MediaWikiConverter.convert("<nowiki>__FORCETOC__ __TOC__</nowiki>\n<pre>__NOTOC__</pre>")
        #expect(literal.contentsInstructions == .init() && literal.inTextContentsMarker == nil)
        let ignored = MediaWikiConverter.convert("{{clear|__NOTOC__}}\n__NOTOC__")
        #expect(ignored.contentsInstructions.present?.source?.lineNumber == 2)
        let expanded = MediaWikiConverter.convert("{{nowrap|__FORCETOC__}}\n__FORCETOC__")
        #expect(expanded.contentsInstructions.present?.source?.lineNumber == 1)
        let marker = MediaWikiConverter.convert("__TOC__\n__TOC__\n== One ==")
        #expect(marker.inTextContentsMarker == "__TOC__" && marker.contentsInstructions == .init())
        #expect(marker.contentsKinds == [0: .text])
        let hidden = MediaWikiConverter.convert("== One ==\n__NOTOC__")
        #expect(
            hidden.contentsInstructions.present?.value == false
                && hidden.contentsInstructions.present?.source?.lineNumber == 2)
    }
}
