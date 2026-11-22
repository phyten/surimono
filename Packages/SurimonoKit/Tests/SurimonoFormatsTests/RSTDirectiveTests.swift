import Foundation
import Testing

@testable import SurimonoFormats

struct RSTDirectiveTests {
    @Test("取り込みは原稿のフォルダと許可の両方を守り、循環しても次の段落を残す")
    func includes() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("draft")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let outside = base.appendingPathComponent("comment.inc")
        try Data("Outside text".utf8).write(to: outside)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("alias.inc"), withDestinationURL: outside)
        let local = folder.appendingPathComponent("loop.inc")
        try Data("Present here.\n\n.. include:: loop.inc".utf8).write(to: local)
        let source = """
            .. include:: loop.inc

            .. include:: ../comment.inc

            .. include:: alias.inc

            Final paragraph.
            """
        let result = RSTConverter.convert(source, directory: folder)
        #expect(result.body.components(separatedBy: "Present here.").count == 2)
        #expect(!result.body.contains("Outside text"))
        #expect(result.body.contains("Final paragraph."))
        #expect(!result.readingIssues.isEmpty)
        let denied = RSTConverter.convert(source, directory: folder, permitsFile: { _ in false })
        #expect(!denied.body.contains("Present here."))
    }

    @Test("生の HTML は静的な本文を残し、自動読み込みと実行属性を除く")
    func raw() {
        let result = RSTConverter.convert(
            """
            .. raw:: html

               <p onclick="evaluate()">A <em>red</em> gauge.</p><img src="https://example.org/gauge" alt="Far gauge">
               <script>evaluate()</script><iframe src="https://example.org/"></iframe>
            """)
        #expect(result.body.contains("<em>red</em>"))
        #expect(!result.body.contains("evaluate()"))
        #expect(result.body.contains("Far gauge"))
        #expect(!result.body.contains("src="))
        #expect(!result.body.contains("<iframe"))
    }
    @Test("Sphinx のコードには見出しと指定された行の番号と強調が付く")
    func codeOptions() {
        let fragment = RSTConverter.convert(
            """
            .. code-block:: text
               :linenos:
               :caption: Evening tally
               :emphasize-lines: 2

               blue
               white
            """)
        #expect(fragment.body.contains("<figcaption>Evening tally</figcaption>"))
        #expect(fragment.body.contains("<small class=\"ln\">2 </small><mark>white</mark>"))
    }

    @Test("入れ子の取り込みで読むファイルと画像は取り込み元から探す")
    func nestedRelativePaths() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("notes")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try Data(".. include:: next.inc".utf8).write(to: folder.appendingPathComponent("watch.inc"))
        try Data(".. image:: dock.svg\n   :alt: Stone pier".utf8).write(to: folder.appendingPathComponent("next.inc"))
        try Data("<svg></svg>".utf8).write(to: folder.appendingPathComponent("dock.svg"))
        let fragment = RSTConverter.convert(".. include:: notes/watch.inc", directory: root)
        #expect(fragment.body.contains("src=\"notes/dock.svg\""))
        #expect(fragment.body.contains("alt=\"Stone pier\""))
        #expect(fragment.readingIssues.isEmpty)
    }
    @Test("生の HTML と SVG は静的な書式や図形と文字を保つ")
    func rawDrawing() {
        let fragment = RSTConverter.convert(
            """
            .. raw:: html

               <p style="color:teal;padding:3px">Bench <em>mark</em></p>
               <svg viewBox="0 0 20 20"><title>Gauge</title><rect x="2" width="3" height="9" fill="#456"/></svg>
            """)
        #expect(fragment.body.contains("color:teal;padding:3px"))
        #expect(fragment.body.contains("viewBox=\"0 0 20 20\""))
        #expect(fragment.body.contains("<title>Gauge</title>"))
        #expect(fragment.body.contains("<rect "))
        #expect(fragment.body.contains("fill=\"#456\""))
    }

    @Test("名前不明の命令でも、無視する命令を含む原文を失わない")
    func unknown() {
        let fragment = RSTConverter.convert(
            """
            .. tide-reader:: Evening
               :bank: east

               .. footer:: Low water at noon.
            """)
        for text in ["tide-reader", "Evening", ":bank: east", "Low water at noon."] {
            #expect(fragment.body.contains(text))
        }
        #expect(!fragment.readingIssues.isEmpty)
    }

    @Test("Sphinx の条件と用語を読める本文として残し、索引と見出しだけの注記を紙から除く")
    func sphinxBody() {
        let fragment = RSTConverter.convert(
            """
            .. only:: printed

               .. glossary::

                  shoal
                     A shallow shelf.

            .. index:: invisible keyword

            .. seealso:: Neighbouring *banks*.
            """)
        #expect(fragment.body.contains("<dt>shoal</dt>"))
        #expect(fragment.body.contains("A shallow shelf."))
        #expect(fragment.body.contains("See also"))
        #expect(fragment.body.contains("<em>banks</em>"))
        #expect(!fragment.body.contains("invisible keyword"))
    }

    @Test("class の指定は入れ子の書式を保ったまま次の本文に付く")
    func classes() {
        let fragment = RSTConverter.convert(
            """
            .. class:: shoreline

            Short *waves*.

            Still water.
            """)
        #expect(fragment.body.contains("<p class=\"shoreline\">Short <em>waves</em>.</p>"))
        #expect(fragment.body.contains("<p>Still water.</p>"))
        let siblings = RSTConverter.convert(".. class:: wave\n\n   First.\n\n   Second.")
        #expect(siblings.body.contains("<p class=\"wave\">First.</p><p class=\"wave\">Second.</p>"))
    }
    @Test("パスの確認後にリンクが差し替わっても、フォルダ外の本文を取り込まない")
    func validatesOpenedInclude() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("notes")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let outside = root.appendingPathComponent("private.inc")
        let inside = folder.appendingPathComponent("log.inc")
        try Data("Outer reading.".utf8).write(to: outside)
        try Data("Inner reading.".utf8).write(to: inside)
        var changed = false
        let result = RSTConverter.convert(".. include:: log.inc", directory: folder) { _ in
            if !changed {
                do {
                    try files.removeItem(at: inside)
                    try files.createSymbolicLink(at: inside, withDestinationURL: outside)
                    changed = true
                } catch { Issue.record("テスト用リンクを作れなかった") }
            }
            return true
        }
        #expect(changed)
        #expect(!result.body.contains("Outer reading."))
        #expect(!result.readingIssues.isEmpty)
    }
}

extension RSTDirectiveTests {
    @Test("目次への参照と各項目の戻り先は明示したアンカーと衝突しない")
    func contentsAnchors() {
        let html = RSTConverter.convert(
            """
            .. _toc-entry-1:

            An earlier reference.

            .. contents:: この記録

            Bay
            ===

            See `この記録`_.

            Tide
            ===

            Low water.
            """
        ).body
        #expect(html.contains("id=\"topic-1\""))
        #expect(html.contains("href=\"#topic-1\""))
        #expect(html.components(separatedBy: "id=\"toc-entry-1\"").count == 2)
    }
}

extension RSTDirectiveTests {
    @Test("言語を指定したコードだけを色付けし、整形済み本文の空白と著者の強調は残す")
    func plainListings() throws {
        let fixtures = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/RST/directives"))
        for source in [
            "Tide::\n\n   let tide = 17",
            ".. code::\n\n   let tide = 17",
            ".. code-block::\n   :linenos:\n\n   let tide = 17",
            ".. include:: assets/measure.inc\n   :literal:",
            ">>> tide = 17\n17", "| First bell\n|   Second bell",
            ".. parsed-literal::\n\n   17:00   *west*",
        ] {
            let fragment = RSTConverter.convert(source, directory: fixtures)
            #expect(fragment.readingIssues.isEmpty)
            #expect(!fragment.body.contains("hl-"))
            if source.contains("*west*") { #expect(fragment.body.contains("17:00   <em>west</em>")) }
        }
        for name in ["code", "code-block", "sourcecode"] {
            #expect(RSTConverter.convert(".. \(name):: swift\n\n   let tide = 17").body.contains("hl-keyword"))
        }
        #expect(SyntaxHighlighter.canonicalLanguage(for: "pycon") == nil)
    }
}
