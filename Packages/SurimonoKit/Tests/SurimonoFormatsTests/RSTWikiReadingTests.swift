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
            // __TOC__ now titles its contents (MediaWiki's own box has a title).
            "8707cf460dcd6ac1d354d5401389e24e629fba6e0a813a7c3ec994fc3f7a38ac",
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
               :start: 1
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

    @Test("指示行の末尾が空白やタブでも固定し、出典には元の行を残す", arguments: ["", " ", "\t"], [false, true])
    func rstTrailingWhitespace(suffix: String, hasDepth: Bool) {
        for directive in [".. sectnum::", ".. section-numbering::", ".. contents:: Map"] {
            let line = directive + suffix
            let fragment = RSTConverter.convert(line + (hasDepth ? "\n   :depth: 2" : "") + "\n\nOne\n===\n\nTwo\n===")
            let file = directive == ".. contents:: Map" ? fragment.contentsInstructions : fragment.numberInstructions
            #expect(file.present?.value == true)
            #expect(file.present?.source?.lineNumber == 1)
            #expect(file.present?.source?.excerpt?.line == line)
            #expect(file.depth?.value == (hasDepth ? .levels(2) : nil))
            #expect(file.depth?.source?.lineNumber == (hasDepth ? 2 : nil))
        }
    }

    @Test("定義リストで後の項目にある同名の指示は、その項目の行と深さで固定する", arguments: [1, 2])
    func rstDefinitionSource(secondDepth: Int) {
        let fragment = RSTConverter.convert(
            "First term\n   .. sectnum::\n      :depth: 1\n\nSecond term\n   .. sectnum::\n      :depth: \(secondDepth)"
        )
        #expect(fragment.numberInstructions.present?.source?.lineNumber == 6)
        #expect(fragment.numberInstructions.depth?.source?.lineNumber == 7)
        #expect(fragment.numberInstructions.depth?.value == .levels(secondDepth))
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
        #expect(expanded.contentsInstructions.present?.source?.lineNumber == 2)
        let marker = MediaWikiConverter.convert("__TOC__\n__TOC__\n== One ==")
        #expect(marker.inTextContentsMarker == "__TOC__" && marker.contentsInstructions == .init())
        #expect(marker.contentsKinds == [0: .text])
        let hidden = MediaWikiConverter.convert("== One ==\n__NOTOC__")
        #expect(
            hidden.contentsInstructions.present?.value == false
                && hidden.contentsInstructions.present?.source?.lineNumber == 2)
    }
}

extension RSTWikiReadingTests {
    @Test(
        "不正なオプションで原稿を固定せず、旧版で描いた目次と番号を残す",
        arguments: [
            "   :unknown: 1", "   :depth: no", "   :depth: 0", "   :depth: -2", "   :depth:",
            "   :depth: 2\n    :depth: 1", "    :depth: 2\n   :depth: 1",
            "   :depth: 2\n   :depth: 1", "   :depth:1", "   :depth: 1\n\n   text", "\t:depth: 1\n   :depth: 2",
        ])
    func malformedRST(_ options: String) {
        let sections = "\n\nOne\n===\n\nChild\n-----\n\nTwo\n==="
        let numbers = RSTConverter.convert(".. sectnum::\n" + options + sections)
        let contents = RSTConverter.convert(".. contents:: Map\n" + options + sections)
        #expect(!numbers.numberInstructions.hasInstructions && !contents.contentsInstructions.hasInstructions)
        #expect(contents.body.contains("<nav class=\"toc\"") && contents.body.contains(">Map</p>"))
        let zero = options == "   :depth: 0" || options == "   :depth: -2"
        #expect(numbers.body.contains("class=\"sectnum\"") == !zero)
    }

    @Test("同じ列にそろったタブは原稿の行を保ち、八段の見出しの番号と目次は従来の HTML にそろう")
    func rstNativeDepth() {
        let levels = Array("=-~^+`*#")
        let tree =
            levels.enumerated().map { "Level \($0.offset + 1)\n" + String(repeating: $0.element, count: 10) }
            .joined(separator: "\n\n") + "\n\nSibling\n======="
        let input = ".. sectnum::\n\t:depth:\t8\n        :start: 2\n\n.. contents:: Map\n\t:depth: 8\n\n" + tree
        let fragment = RSTConverter.convert(input)
        #expect(fragment.numberInstructions.depth?.source?.excerpt?.line == "\t:depth:\t8")
        #expect(fragment.contentsInstructions.depth?.source?.lineNumber == 6)
        #expect(fragment.body.contains("class=\"sectnum\">2.1.1.1.4 </span>Level 8"))
        #expect(fragment.body.contains(">2.1.1.1.4 Level 8</a>"))
    }

    @Test("番号を付けない節は本文の参照にも目次にも見出しの文字で出る", arguments: [true, false])
    func unnumberedReferences(limited: Bool) {
        var reading = FormatReadingSettings()
        reading.document.set(.outline(present: false, depth: .all), for: .sectionNumbers, format: .rst)
        let header = limited ? ".. sectnum::\n   :depth: 1\n\n" : ""
        let fragment = RSTConverter.convert(
            header + ".. contents::\n\nOne\n===\n\nSee Child_.\n\nChild\n-----\n\nTwo\n===", reading: reading)
        #expect(fragment.body.contains("<a href=\"#child\">Child</a>"))
        #expect(
            DocumentOutline.contentsHeadings(in: fragment.body, navIndex: 0).map(\.text)
                == (limited ? ["1 One", "Child", "2 Two"] : ["One", "Child", "Two"]))
        #expect(fragment.decidesHeadingNumbers)
    }

    @Test("コロンに密着した目次の題は従来通り表示し、原稿の固定には使わない")
    func joinedTitle() {
        let fragment = RSTConverter.convert(".. contents::Map\n\nOne\n===\n\nTwo\n===")
        #expect(!fragment.contentsInstructions.hasInstructions)
        #expect(fragment.body.contains(">Map</p>"))
    }

    @Test("Wiki の展開・不完全な記法は従来どおり読み、文書の設定は固定しない")
    func wikiManuscript() {
        let headings = "\n== One ==\n== Two =="
        let expanded = [
            "{{nowrap|__FORCETOC__}}", "{{nowrap|{{small|__FORCETOC__}}}}",
            "{{Unknown|key=__FORCETOC__}}", "<nowiki>__FORCETOC__", "<!-- __FORCETOC__",
            "{{open|__FORCETOC__", "__FOR<!-- split -->CETOC__",
        ]
        let inert = [
            "<NoWiki>__FORCETOC__</NoWiki>", "<pRe>__FORCETOC__</PRE>", "<!-- __FORCETOC__ -->",
            "{{clear|__FORCETOC__}}", "{{nowrap|ok|__FORCETOC__}}", "{{{key|__FORCETOC__}}}", "__forcetoc__",
            "__ForceTOC__",
        ]
        for word in expanded + inert {
            let result = MediaWikiConverter.convert(word + headings)
            #expect(!result.contentsInstructions.hasInstructions, "\(word)")
            #expect(result.body.contains("<nav ") == expanded.contains(word), "\(word)")
        }
        let conflict = "{{nowrap|__FORCETOC__}}\n__NOTOC__" + headings
        let fallback = MediaWikiConverter.convert(conflict)
        #expect(!fallback.contentsInstructions.hasInstructions && fallback.contentsKinds == [0: .lead])
        var reading = FormatReadingSettings()
        reading.document.set(
            .outline(present: false, depth: .all), for: .tableOfContents, format: .mediawiki,
            file: fallback.contentsInstructions)
        #expect(MediaWikiConverter.convert(conflict, reading: reading).contentsKinds.isEmpty)
        let table = "{| class=\"__NOTOC__\"\n| data-role=\"__NOTOC__\" | Visible\n|}\n"
        let cell = MediaWikiConverter.convert(table + "__NOTOC__" + headings)
        #expect(cell.contentsInstructions.present?.source?.lineNumber == 4)
        let nested = MediaWikiConverter.convert(table + "{{nowrap|__NOTOC__}}" + headings)
        #expect(!nested.contentsInstructions.hasInstructions)
        for word in ["{{open|<ref>__NOTOC__</ref>", "<nowiki><poem>__NOTOC__</poem>"] {
            #expect(!MediaWikiConverter.convert(word + headings).contentsInstructions.hasInstructions)
        }
    }
}

extension RSTWikiReadingTests {
    @Test("読めない指定とテンプレートの既定の本文が移行前のバイト列と一致する")
    func manuscriptBytes() {
        let sections = "\n\nOne\n===\n\nChild\n-----\n\nTwo\n==="
        let rst = [
            ".. sectnum::\n   :unknown: yes", ".. sectnum::\n    :depth: 0", ".. contents:: Map\n   :depth: -1",
            ".. contents:: Map\n   :depth: two", ".. sectnum::\n   :prefix: [\n     :depth: 1",
            ".. contents:: :depth: 1",
        ]
        let wiki = ["{{nowrap|__FORCETOC__}}", "{{clear|__FORCETOC__}}", "<nowiki>__FORCETOC__", "__ForceTOC__"]
        let bodies =
            rst.map { RSTConverter.convert($0 + sections).body }
            + wiki.map { MediaWikiConverter.convert($0 + "\n== One ==\n== Two ==").body }
        // UTF-8 bodies from the converters at 8a0e51ad.
        let expected = [
            "968c0835be9acf12a6dafeceeaf7ffeeabbfe44633f85c04d046df789d9b3c8e",
            "3456b89c5f1df6e488e34c970c4c98feefa912f2b2c7d2f794b61c60a19bfa1f",
            "324852267087d09cdc22d4a0c5fafa415fd1ce96c1832475602932addc78da32",
            "25865834e6e4273f3a9a59ebc464093ff5f7b2c2e1648782534548d19cff7e83",
            "9e533efeef83008863de7886cd4e5b2d180f62c3036313513c66161135eace82",
            "f1e968c9b4c4bdabf4b24bbf552ad792f54070eeb85452971ad8c9892404e3f2",
            "f8e57af187aafc9299054f269847a9d1c3380e2b335b21d5d0b150951fc8012c",
            "428d9eb2a611d2c13c859826ac48744ba3294ad970270369457c7d542e86ce18",
            "be2e741943639eacd00ead25ba2fd8b6bf5a9a36277795c39f35217c739fff32",
            "92e800c666f054511266494292f2bb052bb81b9ecb24bd58dc0d12143360c1d1",
        ]
        #expect(bodies.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } == expected)
    }
}
