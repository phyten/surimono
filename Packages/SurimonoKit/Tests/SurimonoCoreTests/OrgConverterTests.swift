import SurimonoCore
import Testing

struct OrgConverterTests {
    @Test("見出しは最大H6にしTODOと優先度とタグを装飾する")
    func headings() {
        let body = OrgConverter.convert("* TODO [#A] 見出し :work:print:\n******* DONE 深い").body
        #expect(body.contains("<h1>"))
        #expect(body.contains("class=\"org-todo\">TODO"))
        #expect(body.contains("class=\"org-priority\">[#A]"))
        #expect(body.contains("class=\"org-tag\">work"))
        #expect(body.contains("class=\"org-tag\">print"))
        #expect(body.contains("<h6><span class=\"org-done\">DONE"))
    }

    @Test(
        "各種強調をHTML要素に変換する",
        arguments: [
            ("*太字*", "<strong>太字</strong>"), ("/斜体/", "<em>斜体</em>"),
            ("_下線_", "<u>下線</u>"), ("=x < y=", "<code>x &lt; y</code>"),
            ("~x & y~", "<code>x &amp; y</code>"), ("+削除+", "<del>削除</del>"),
        ])
    func emphasis(source: String, expected: String) {
        #expect(OrgConverter.convert(source).body == "<p>\(expected)</p>\n")
    }

    @Test("強調の入れ子を扱いコード内の強調は解釈しない")
    func nestedEmphasis() {
        let body = OrgConverter.convert("*bold /italic/* =*literal*=").body
        #expect(body.contains("<strong>bold <em>italic</em></strong>"))
        #expect(body.contains("<code>*literal*</code>"))
    }

    @Test("単語内の記号とURLと未閉鎖の強調は保持する")
    func literalPunctuation() {
        let body = OrgConverter.convert("foo_bar_baz https://example.com/a/b *open").body
        #expect(body.contains("foo_bar_baz https://example.com/a/b *open"))
    }

    @Test("リンクと相対画像を出し属性をエスケープする")
    func links() {
        let body = OrgConverter.convert("[[https://example.com/?a=1&b=2][説明 & 紙]] [[file:images/a.png]] [[note.txt]]")
            .body
        #expect(body.contains("href=\"https://example.com/?a=1&amp;b=2\">説明 &amp; 紙</a>"))
        #expect(body.contains("<img src=\"images/a.png\""))
        #expect(body.contains("href=\"note.txt\">note.txt</a>"))
    }

    @Test("説明付き画像リンクは代替文を持つ")
    func imageDescription() {
        #expect(OrgConverter.convert("[[photo.JPG][写真]]").body.contains("alt=\"写真\""))
    }

    @Test("箇条書きと番号付きリストをインデントで入れ子にする")
    func lists() {
        let body = OrgConverter.convert("- 親\n  1. 子\n  2) 子2\n+ 次").body
        #expect(
            body.contains(
                "<ul><li><p>親</p>\n<ol start=\"1\"><li><p>子</p>\n</li><li><p>子2</p>\n</li></ol>\n</li><li><p>次</p>\n</li></ul>"
            ))
    }

    @Test("番号付きリストの開始番号を保持する")
    func listStart() {
        #expect(OrgConverter.convert("3) 三\n4) 四").body.contains("<ol start=\"3\">"))
    }

    @Test("チェックボックスの未完了と完了と途中を区別する")
    func checkboxes() {
        let body = OrgConverter.convert("- [ ] 未完\n- [X] 完了\n- [-] 途中").body
        #expect(body.contains("class=\"org-checkbox unchecked\""))
        #expect(body.contains("class=\"org-checkbox checked\""))
        #expect(body.contains("class=\"org-checkbox partial\""))
    }

    @Test("説明リストをdtとddで表現する")
    func definitions() {
        #expect(
            OrgConverter.convert("- 用語 :: 説明\n- 次 :: *定義*").body.contains(
                "<dl><dt>用語</dt><dd><p>説明</p>\n</dd><dt>次</dt><dd><p><strong>定義</strong></p>\n</dd></dl>"))
    }

    @Test("最初の表区切りより前を表見出しにする")
    func table() {
        let body = OrgConverter.convert("| 名前 | 値 |\n|---+---|\n| 紙 | <&> |\n|---+---|\n| 本 | 2 |").body
        #expect(body.contains("<thead><tr><th>名前</th><th>値</th></tr></thead>"))
        #expect(body.contains("<td>&lt;&amp;&gt;</td>"))
        #expect(!body.contains("---"))
    }

    @Test("区切りのない表はすべて本文になる")
    func tableWithoutHeader() {
        let body = OrgConverter.convert("| a | b |").body
        #expect(!body.contains("<thead>"))
        #expect(body.contains("<tbody><tr><td>a</td><td>b</td></tr></tbody>"))
    }

    @Test("ソースブロックは言語を付け本文を解釈しない")
    func source() {
        let body = OrgConverter.convert("#+BEGIN_SRC swift\nlet x = \"<&>\"\n* text\n#+END_SRC").body
        #expect(
            body.contains("<pre><code class=\"language-swift\">let x = &quot;&lt;&amp;&gt;&quot;\n* text</code></pre>"))
    }

    @Test("EXAMPLEブロックは特殊文字をエスケープする")
    func example() {
        #expect(OrgConverter.convert("#+BEGIN_EXAMPLE\n<x>\n#+END_EXAMPLE").body.contains("<pre>&lt;x&gt;</pre>"))
    }

    @Test("QUOTEブロックは本文の装飾を保つ")
    func quote() {
        #expect(
            OrgConverter.convert("#+BEGIN_QUOTE\n*強調*\n#+END_QUOTE").body.contains(
                "<blockquote><p><strong>強調</strong></p>"))
    }

    @Test("VERSEは改行を保持しCENTERはクラスを持つ")
    func verseAndCenter() {
        let body = OrgConverter.convert("#+BEGIN_VERSE\n一行\n二行\n#+END_VERSE\n#+BEGIN_CENTER\n中央\n#+END_CENTER").body
        #expect(body.contains("class=\"org-verse\">一行\n二行"))
        #expect(body.contains("class=\"org-center\"><p>中央</p>"))
    }

    @Test("ブロック内のメタデータを文書の表題にしない")
    func literalMetadata() {
        let fragment = OrgConverter.convert("#+BEGIN_SRC\n#+TITLE: コード\n#+END_SRC")
        #expect(fragment.title == nil)
        #expect(fragment.body.contains("#+TITLE: コード"))
    }

    @Test("表題と著者と日付を冒頭にまとめる")
    func metadata() {
        let result = OrgConverter.convert("#+title: 本 & 紙\n#+AUTHOR: 著者\n#+DATE: 2026-10-28\n\n本文")
        #expect(result.title == "本 & 紙")
        #expect(result.body.hasPrefix("<header class=\"org-title-block\">"))
        #expect(result.body.contains("<h1 class=\"org-title\">本 &amp; 紙</h1>"))
        #expect(result.body.contains("class=\"org-author\">著者"))
        #expect(result.body.contains("class=\"org-date\">2026-10-28"))
    }

    @Test("ディレクティブとコメントとdrawerを隠す")
    func hidden() {
        let body = OrgConverter.convert(
            "#+OPTIONS: toc:nil\n# comment\n:PROPERTIES:\n:ID: secret\n:END:\n:LOGBOOK:\nsecret2\n:END:\n本文"
        ).body
        #expect(body == "<p>本文</p>\n")
    }

    @Test("予定と期限を注記として出す")
    func planning() {
        let body = OrgConverter.convert("SCHEDULED: <2026-10-28 Wed> DEADLINE: <2026-10-29 Thu>").body
        #expect(body.contains("<small class=\"org-planning\">"))
        #expect(body.contains("&lt;2026-10-28 Wed&gt;"))
    }

    @Test("水平線と段落を区別する")
    func paragraphs() {
        #expect(OrgConverter.convert("一行\n二行\n\n-----\n\n末尾").body == "<p>一行\n二行</p>\n<hr>\n<p>末尾</p>\n")
    }

    @Test("未対応構文と未閉鎖ブロックはテキストとして残す")
    func unsupported() {
        let body = OrgConverter.convert(": 未対応\n#+BEGIN_SRC swift\n残す <text>").body
        #expect(body.contains("#+BEGIN_SRC swift"))
        #expect(body.contains("残す &lt;text&gt;"))
    }

    @Test("Orgの空セル行は区切り線にならず3行の本文表に残る")
    func emptyTableRow() {
        let body = OrgConverter.convert("| A | B |\n|   |   |\n| C | D |").body
        #expect(
            body
                == "<table><tbody><tr><td>A</td><td>B</td></tr><tr><td></td><td></td></tr><tr><td>C</td><td>D</td></tr></tbody></table>\n"
        )
    }

    @Test("Orgの記号だけのセル行も表データとして残る")
    func symbolTableRow() {
        let body = OrgConverter.convert("| A | B |\n| - | + |\n| C | D |").body
        #expect(
            body
                == "<table><tbody><tr><td>A</td><td>B</td></tr><tr><td>-</td><td>+</td></tr><tr><td>C</td><td>D</td></tr></tbody></table>\n"
        )
    }

    @Test("Orgの1列の区切り線は表見出しを区切る")
    func singleColumnDivider() {
        #expect(
            OrgConverter.convert("| A |\n|---|\n| B |").body
                == "<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>B</td></tr></tbody></table>\n")
    }

    @Test("Orgのリスト項目内もコメントとdrawerを隠してSRCを解析する")
    func listBlocks() {
        let body = OrgConverter.convert(
            """
            - 項目
              # hidden comment
              :LOGBOOK:
              hidden log
              :END:
              #+BEGIN_SRC text
              *literal*
              #+END_SRC
            - 次
            """
        ).body
        #expect(
            body
                == "<ul><li><p>項目</p>\n<pre><code class=\"language-text\">*literal*</code></pre>\n</li><li><p>次</p>\n</li></ul>\n"
        )
    }

    @Test("Orgの入れ子リストと説明リストでも共通のブロック解析を使う")
    func nestedListBlocks() {
        let body = OrgConverter.convert(
            """
            - 親
              - 用語 :: 説明
                # hidden
                #+BEGIN_SRC
                  *literal*
                #+END_SRC
            """
        ).body
        #expect(
            body
                == "<ul><li><p>親</p>\n<dl><dt>用語</dt><dd><p>説明</p>\n<pre><code>  *literal*</code></pre>\n</dd></dl>\n</li></ul>\n"
        )
    }

    @Test("Orgの未閉鎖リンク20万文字を時間内に原文のまま出力する", .timeLimit(.minutes(1)))
    func unclosedLinkStress() {
        let body = OrgConverter.convert(String(repeating: "[", count: 200_000)).body
        #expect(body == "<p>" + String(repeating: "[", count: 200_000) + "</p>\n")
    }

    @Test("Orgのリスト内の空行とチェックボックス継続行を保ち外の段落を巻き込まない")
    func listParagraphBoundaries() {
        let body = OrgConverter.convert("- [X] 完了\n  続き\n\n  次の段落\n\n外の本文").body
        #expect(
            body
                == "<ul><li><p><span class=\"org-checkbox checked\">☑</span> 完了\n続き</p>\n<p>次の段落</p>\n</li></ul>\n<p>外の本文</p>\n"
        )
    }

    @Test("Orgの順序付きリストは2行以上の空行で別のリストになる", arguments: ["\n\n\n", "\n\n\n\n", "\n  \n\t\n"])
    func orderedListBlankLineBoundary(separator: String) {
        let body = OrgConverter.convert("1. 最初のリスト" + separator + "1. 別のリスト").body
        #expect(
            body == "<ol start=\"1\"><li><p>最初のリスト</p>\n</li></ol>\n"
                + "<ol start=\"1\"><li><p>別のリスト</p>\n</li></ol>\n")
    }

    @Test("Orgの順序なしリストは2行以上の空行で別のリストになる", arguments: ["\n\n\n", "\n\n\n\n", "\n  \n\t\n"])
    func unorderedListBlankLineBoundary(separator: String) {
        let body = OrgConverter.convert("- 最初のリスト" + separator + "- 別のリスト").body
        #expect(
            body == "<ul><li><p>最初のリスト</p>\n</li></ul>\n"
                + "<ul><li><p>別のリスト</p>\n</li></ul>\n")
    }

    @Test("Orgの1行の空行は同じリストの項目を分離しない")
    func singleBlankLineBetweenItems() {
        let body = OrgConverter.convert("1. 最初の項目\n\n2. 次の項目").body
        #expect(body == "<ol start=\"1\"><li><p>最初の項目</p>\n</li><li><p>次の項目</p>\n</li></ol>\n")
    }

    @Test("Orgの2行の空行は入れ子を含む全リスト項目を閉じる")
    func nestedListBlankLineBoundary() {
        let body = OrgConverter.convert("- 親\n  - 子\n\n\n- 別のリスト").body
        #expect(
            body == "<ul><li><p>親</p>\n<ul><li><p>子</p>\n</li></ul>\n</li></ul>\n"
                + "<ul><li><p>別のリスト</p>\n</li></ul>\n")
    }

    @Test(
        "Orgのリスト内SRCは2行と3行の空行を保持して同じリストへ戻る",
        arguments: [
            (
                "\n\n\n",
                "<ul><li><p>項目</p>\n<pre><code class=\"language-text\">before\n\n\n*literal*</code></pre>\n</li><li><p>次</p>\n</li></ul>\n"
            ),
            (
                "\n\n\n\n",
                "<ul><li><p>項目</p>\n<pre><code class=\"language-text\">before\n\n\n\n*literal*</code></pre>\n</li><li><p>次</p>\n</li></ul>\n"
            ),
        ])
    func sourceBlockBlankLines(separator: String, expected: String) {
        let body = OrgConverter.convert(
            "- 項目\n  #+BEGIN_SRC text\n  before" + separator + "  *literal*\n  #+END_SRC\n- 次"
        ).body
        #expect(body == expected)
    }

    @Test(
        "Orgのリスト内EXAMPLEは2行と3行の空行を保持して同じリストへ戻る",
        arguments: [
            ("\n\n\n", "<ul><li><p>項目</p>\n<pre>before\n\n\n*literal*</pre>\n</li><li><p>次</p>\n</li></ul>\n"),
            ("\n\n\n\n", "<ul><li><p>項目</p>\n<pre>before\n\n\n\n*literal*</pre>\n</li><li><p>次</p>\n</li></ul>\n"),
        ])
    func exampleBlockBlankLines(separator: String, expected: String) {
        let body = OrgConverter.convert(
            "- 項目\n  #+BEGIN_EXAMPLE\n  before" + separator + "  *literal*\n  #+END_EXAMPLE\n- 次"
        ).body
        #expect(body == expected)
    }

    @Test("Orgのリスト内drawerは空行と浅いインデントの内部行もまとめて隠す", arguments: ["LOGBOOK", "PROPERTIES", "logbook"])
    func drawerBlankLines(name: String) {
        let body = OrgConverter.convert(
            "- 項目\n  :\(name):\n  hidden before\n\n\n- hidden item\n  hidden after\n  :END:\n- 次"
        ).body
        #expect(body == "<ul><li><p>項目</p>\n</li><li><p>次</p>\n</li></ul>\n")
    }

    @Test("Orgの入れ子リスト内SRCは空行と項目に見える行をコードとして保持する")
    func nestedSourceBlockBlankLines() {
        let body = OrgConverter.convert(
            "- 親\n  - 子\n    #+BEGIN_SRC text\n    before\n\n\n*literal*\n- code item\n    #+END_SRC\n  - 次の子\n- 次の親"
        ).body
        #expect(
            body
                == "<ul><li><p>親</p>\n<ul><li><p>子</p>\n<pre><code class=\"language-text\">before\n\n\n*literal*\n- code item</code></pre>\n</li><li><p>次の子</p>\n</li></ul>\n</li><li><p>次の親</p>\n</li></ul>\n"
        )
    }

    @Test("Orgのブロックとdrawerの外側の2行の空行はリストを終了する")
    func blankLinesAfterRegions() {
        let body = OrgConverter.convert(
            "- 項目\n  #+BEGIN_SRC\n  code\n  #+END_SRC\n  :LOGBOOK:\n  hidden\n\n\n  :END:\n\n\n- 別のリスト"
        ).body
        #expect(
            body == "<ul><li><p>項目</p>\n<pre><code>code</code></pre>\n</li></ul>\n<ul><li><p>別のリスト</p>\n</li></ul>\n")
    }

    @Test("Orgのリスト内の未閉鎖ブロックはリスト外の段落を飲み込まない")
    func unclosedListBlock() {
        let body = OrgConverter.convert("- 項目\n  #+BEGIN_SRC text\n  残す <text>\n外の段落\n\n- 新項目").body
        #expect(
            body
                == "<ul><li><p>項目</p>\n<p>#+BEGIN_SRC text</p>\n<p>残す &lt;text&gt;</p>\n</li></ul>\n<p>外の段落</p>\n<ul><li><p>新項目</p>\n</li></ul>\n"
        )
    }

    @Test("Orgのリスト内の未閉鎖ブロックでも外側の空行境界を守る")
    func unclosedBlockBlankLineBoundary() {
        let body = OrgConverter.convert("- 項目\n  #+BEGIN_SRC\n  code\n\n\n- 別のリスト\n外の段落").body
        #expect(
            body
                == "<ul><li><p>項目</p>\n<p>#+BEGIN_SRC</p>\n<p>code</p>\n</li></ul>\n<ul><li><p>別のリスト</p>\n</li></ul>\n<p>外の段落</p>\n"
        )
    }

    @Test("Orgのリスト内の未閉鎖drawerは原文を残し外の段落を飲み込まない")
    func unclosedListDrawer() {
        let body = OrgConverter.convert("- 項目\n  :LOGBOOK:\n  残す\n外の段落").body
        #expect(body == "<ul><li><p>項目\n:LOGBOOK:\n残す</p>\n</li></ul>\n<p>外の段落</p>\n")
    }

    @Test("OrgのSRCは別種の終端を本文として保持し対応する終端で閉じる")
    func matchingBlockEnd() {
        let body = OrgConverter.convert("- 項目\n  #+begin_src text\n  #+END_EXAMPLE\n\n\n  *literal*\n  #+end_src\n- 次")
            .body
        #expect(
            body
                == "<ul><li><p>項目</p>\n<pre><code class=\"language-text\">#+END_EXAMPLE\n\n\n*literal*</code></pre>\n</li><li><p>次</p>\n</li></ul>\n"
        )
    }

    @Test("Orgの未対応ブロックもリスト内では終端まで一まとまりとして保持する")
    func unknownListBlock() {
        let body = OrgConverter.convert("- 項目\n  #+BEGIN_CUSTOM\n  before\n\n\n  after\n  #+END_CUSTOM\n- 次").body
        #expect(
            body
                == "<ul><li><p>項目</p>\n<pre>#+BEGIN_CUSTOM\nbefore\n\n\nafter\n#+END_CUSTOM</pre>\n</li><li><p>次</p>\n</li></ul>\n"
        )
    }

    @Test("Orgの項目と同じインデントのブロックはリストの外に出す")
    func blockOutsideList() {
        let body = OrgConverter.convert("- 項目\n#+BEGIN_SRC\ncode\n\n\n*literal*\n#+END_SRC\n- 別のリスト").body
        #expect(
            body
                == "<ul><li><p>項目</p>\n</li></ul>\n<pre><code>code\n\n\n*literal*</code></pre>\n<ul><li><p>別のリスト</p>\n</li></ul>\n"
        )
    }
}
