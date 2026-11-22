import Foundation
import Testing

@testable import SurimonoFormats

struct RSTReferenceTests {
    @Test("脚注の戻り先を複製する置換は原文のまま残す")
    func repeatedSubstitutionNotes() {
        let fragment = RSTConverter.convert(
            """
            Mark |edge|, then |edge| again.

            .. |edge| replace:: the rim [Rim]_.

            .. [Rim] Use the edge of the gauge.
            """)
        #expect(!fragment.readingIssues.isEmpty)
        #expect(fragment.body.contains("Mark |edge|, then |edge| again."))
        #expect(fragment.body.contains(".. |edge| replace:: the rim [Rim]_."))
        #expect(!fragment.body.contains("citation-reference-1"))
    }

    @Test("置換付きの匿名リンクも本文に現れる順に行き先を決める")
    func substitutedAnonymousLink() {
        let fragment = RSTConverter.convert(
            """
            Try |ridge|__, then rim__.

            .. |ridge| replace:: the *high* ridge

            __ https://example.org/high
            __ https://example.org/rim
            """)
        #expect(fragment.body.contains("<a href=\"https://example.org/high\">the <em>high</em> ridge</a>"))
        #expect(fragment.body.contains("<a href=\"https://example.org/rim\">rim</a>"))
    }

    @Test("循環する置換は原文に戻し、その後の段落を残す")
    func cyclicSubstitutions() {
        let fragment = RSTConverter.convert(
            """
            The |first| cut.

            .. |first| replace:: |second|
            .. |second| replace:: |first|

            Last panel.
            """)
        #expect(fragment.body.contains("|first|"))
        #expect(fragment.body.contains("<p>Last panel.</p>"))
        #expect(!fragment.readingIssues.isEmpty)
    }

    @Test("括弧に挟まれた記号は後の強調の始まりにならない")
    func quotedDelimiters() {
        let fragment = RSTConverter.convert("On “*” and *glue*. Next、**紙**。")
        #expect(fragment.body.contains("“*” and <em>glue</em>. Next、<strong>紙</strong>。"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("置換名は大文字小文字が一致する定義を先に使う")
    func substitutionCase() {
        let fragment = RSTConverter.convert(
            "See |rim| / |Rim| / |RIM|.\n\n.. |rim| replace:: left\n.. |Rim| replace:: right")
        #expect(fragment.body == "<p>See left / right / right.</p>")
    }

    @Test("引用した名前のコロンと改行を含む別名を結ぶ")
    func quotedTargetName() {
        let fragment = RSTConverter.convert(
            """
            Try slot_.

            .. _slot: `Upper:
               rail`_
            .. _`Upper: rail`: https://example.org/top
            """)
        #expect(fragment.body.contains("<a href=\"https://example.org/top\">slot</a>"))
    }

    @Test("長い未完成のアドレスや区切りが続いても本文を末尾まで読める", .timeLimit(.minutes(1)))
    func longUnmatchedDelimiters() {
        let address = String(repeating: "+", count: 50_000) + "@bad"
        let name = String(repeating: "ink-", count: 25_000) + "_rim"
        let openers = String(repeating: " |bank ", count: 10_000)
        let text = "Address " + address + "\n\nMark " + name + "\n\nLift " + openers + "|last|\n\nLast panel."
        let fragment = RSTConverter.convert(text)
        #expect(fragment.body.contains(address))
        #expect(fragment.body.contains(name))
        #expect(fragment.body.contains("<p>Last panel.</p>"))
    }
}

extension RSTReferenceTests {
    @Test("紙には目次・脚注・引用からの戻りリンクを付けず、本文からの参照と原稿のリンクは残す")
    func forwardLinksOnPaper() {
        let html = RSTConverter.convert(
            """
            .. contents:: Tide record

            First watch
            ===========

            See [1]_, again [1]_, and [Chart]_. Read the `log <https://example.org/log>`_.

            Second watch
            ============

            .. [1] Compare the `map <https://example.org/map>`_.
            .. [Chart] Soundings.

            .. target-notes::
            """
        ).body
        #expect(html.contains("<h2 id=\"first-watch\">First watch</h2>"))
        #expect(html.contains("href=\"#first-watch\""))
        #expect(html.contains("<p class=\"topic-title\">Tide record</p>"))
        #expect(html.contains("href=\"#footnote-1\""))
        #expect(html.contains("href=\"#chart\""))
        #expect(html.contains("<span class=\"label\">[1]</span>"))
        #expect(html.contains("<span class=\"label\">[Chart]</span>"))
        #expect(html.contains("href=\"https://example.org/map\""))
        #expect(!html.contains("doc-backlink"))
        #expect(!html.contains("class=\"backrefs\""))
        #expect(!html.contains("href=\"#toc-entry-"))
    }
}
