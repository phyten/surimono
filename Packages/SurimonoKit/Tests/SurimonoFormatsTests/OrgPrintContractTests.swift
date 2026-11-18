import Foundation
import SurimonoFormats
import Testing

struct OrgPrintContractTests {
    @Test("後ろの表題も先に把握して見出しを下げ副題を続ける")
    func title() {
        #expect(
            OrgConverter.convert("* 章\n#+TITLE: 題\n#+SUBTITLE: 副題\n#+AUTHOR: 人\n#+DATE: 今日").body
                == "<header class=\"org-title-block\"><h1 class=\"org-title\">題</h1><p class=\"org-subtitle\">副題</p><p class=\"org-author\">人</p><p class=\"org-date\">今日</p></header>\n<h2>章</h2>\n"
        )
    }

    @Test("TODO定義を合算しアクセスキーを除き大文字小文字を区別する")
    func keywords() {
        #expect(
            OrgConverter.convert(
                "#+TODO: OPEN(o) WAIT(w@/!) | FIN(f)\n#+SEQ_TODO: START END\n#+TYP_TODO: REVIEW | ACCEPT\n* FIN 済\n* END 終\n* ACCEPT 可\n* OPEN 中\n* TODO 文字\n* open 小文字"
            ).body
                == "<h1 class=\"org-done-heading\"><span class=\"org-done\">FIN</span> 済</h1>\n<h1 class=\"org-done-heading\"><span class=\"org-done\">END</span> 終</h1>\n<h1 class=\"org-done-heading\"><span class=\"org-done\">ACCEPT</span> 可</h1>\n<h1><span class=\"org-todo\">OPEN</span> 中</h1>\n<h1>TODO 文字</h1>\n<h1>open 小文字</h1>\n"
        )
    }

    @Test("優先度とタグと統計を契約どおり包む")
    func headingDecorations() {
        #expect(
            OrgConverter.convert("* TODO [#A] 作業 [2/5] :a:b:").body
                == "<h1><span class=\"org-todo\">TODO</span> <span class=\"org-priority\">#A</span> 作業 <span class=\"org-cookie\">[2/5]</span> <span class=\"org-tags\"><span class=\"org-tag\">a</span> <span class=\"org-tag\">b</span></span></h1>\n"
        )
    }

    @Test("リストの両端の統計だけを装飾する")
    func cookies() {
        #expect(
            OrgConverter.convert("- [/] 作業 [%]\n- [40%]\n- 文 [2/5] 中").body
                == "<ul><li><p><span class=\"org-cookie\">[/]</span> 作業 <span class=\"org-cookie\">[%]</span></p>\n</li><li><p><span class=\"org-cookie\">[40%]</span></p>\n</li><li><p>文 [2/5] 中</p>\n</li></ul>\n"
        )
    }

    @Test("日時と繰り返しと期間をtimeに変え普通の角括弧を保持する")
    func timestamps() {
        #expect(
            OrgConverter.convert(
                "<2026-11-18 Wed 10:00-11:30 +1w -2d>--<2026-11-19 Thu .+1d> [2026-11-18 Wed ++1m] [普通] [fn:missing]"
            ).body
                == "<p><time class=\"org-timestamp\">2026-11-18 Wed 10:00-11:30 +1w -2d</time>–<time class=\"org-timestamp\">2026-11-19 Thu .+1d</time> <time class=\"org-timestamp org-timestamp-inactive\">2026-11-18 Wed ++1m</time> [普通] [fn:missing]</p>\n"
        )
    }

    @Test("予定行はラベル別のクラスを持ち通常文を巻き込まない")
    func planning() {
        #expect(
            OrgConverter.convert("SCHEDULED: <2026-11-18 Wed> CLOSED: [2026-11-19 Thu]").body
                == "<p class=\"org-planning\"><span class=\"org-planning-item org-scheduled\"><span class=\"org-planning-label\">SCHEDULED</span> <time class=\"org-timestamp\">2026-11-18 Wed</time></span> <span class=\"org-planning-item org-closed\"><span class=\"org-planning-label\">CLOSED</span> <time class=\"org-timestamp org-timestamp-inactive\">2026-11-19 Thu</time></span></p>\n"
        )
        #expect(OrgConverter.convert("SCHEDULED: 明日").body == "<p>SCHEDULED: 明日</p>\n")
    }

    @Test("名前付きと匿名のインライン脚注を解釈する")
    func inlineNotes() {
        #expect(
            OrgConverter.convert("先[fn:n]、[fn:n: 注]、[fn:: 別]").body
                == "<p>先<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>、<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-2\">1</a></sup>、<sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\">2</a></sup></p>\n<section class=\"footnotes\">\n<ol>\n<li id=\"fn-1\"><p>注</p>\n</li>\n<li id=\"fn-2\"><p>別</p>\n</li>\n</ol>\n</section>\n"
        )
    }

    @Test("コメントとexportを隠し未知のブロックはOrgとして読む")
    func blocks() {
        #expect(
            OrgConverter.convert(
                "#+begin_comment\n秘密\n#+end_comment\n#+begin_export html\n<script>x</script>\n#+end_export\n#+begin_Foo-bar\n*強調*\n#+end_Foo-bar"
            ).body == "<div class=\"org-block org-block-foo-bar\"><p><strong>強調</strong></p>\n</div>\n")
    }

    @Test("注意の囲みはMarkdownと同じHTMLになる")
    func callout() throws {
        let expected =
            "<div class=\"callout callout-note\" data-callout=\"note\">\n<p class=\"callout-title\"><svg class=\"callout-icon\" viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path d=\"M3 13l.6-2.6 6.8-6.8a1.1 1.1 0 0 1 1.6 0l.4.4a1.1 1.1 0 0 1 0 1.6l-6.8 6.8z M9.4 4.6l2 2\"/></svg>Note</p>\n<p><strong>本文</strong></p>\n</div>\n"
        #expect(try MarkdownConverter.convert(":::note\n**本文**\n:::").body == expected)
        #expect(OrgConverter.convert("#+begin_note\n*本文*\n#+end_note").body == expected)
    }

    @Test("固定幅行をひとまとまりの例にする")
    func fixedWidth() {
        #expect(
            OrgConverter.convert(": <x>\n:\n: *literal*\n本文").body
                == "<pre>&lt;x&gt;\n\n*literal*</pre>\n<p>本文</p>\n")
    }

    @Test("キャプションを表と画像のfigureに入れる")
    func captions() {
        #expect(
            OrgConverter.convert("#+CAPTION: 表 & 題\n#+NAME: x\n#+ATTR_HTML: x\n| a |\n\n#+CAPTION: 絵\n[[file:a.png]]")
                .body
                == "<figure class=\"org-figure org-table\"><figcaption>表 &amp; 題</figcaption><table><tbody><tr><td>a</td></tr></tbody></table></figure>\n<figure class=\"org-figure org-image\"><img src=\"a.png\" alt=\"a.png\"><figcaption>絵</figcaption></figure>\n"
        )
        #expect(
            OrgConverter.convert("#+CAPTION: 消す\n本文\n\n[[a.png]]").body
                == "<p>本文</p>\n<p><img src=\"a.png\" alt=\"a.png\"></p>\n")
    }

    @Test("表の配置指定を隠して数値列を右に揃える")
    func alignment() {
        #expect(
            OrgConverter.convert("| 名 | 数 | 中 |\n|---+---+---|\n| <l> | <r10> | <c> |\n| a | 12 | b |").body
                == "<table><thead><tr><th>名</th><th align=\"right\">数</th><th align=\"center\">中</th></tr></thead><tbody><tr><td>a</td><td align=\"right\">12</td><td align=\"center\">b</td></tr></tbody></table>\n"
        )
    }

    @Test("段落末尾の二重バックスラッシュを改行にする")
    func lineBreak() {
        #expect(OrgConverter.convert("一行\\\\\n次").body == "<p>一行<br>\n次</p>\n")
    }

    @Test("同じ名前の囲みも対応する終端まで入れ子にする")
    func nestedBlocks() {
        #expect(
            OrgConverter.convert("#+begin_foo\n外\n#+begin_foo\n内\n#+end_foo\n末\n#+end_foo").body
                == "<div class=\"org-block org-block-foo\"><p>外</p>\n<div class=\"org-block org-block-foo\"><p>内</p>\n</div>\n<p>末</p>\n</div>\n"
        )
    }

    @Test("表題内の匿名脚注と本文の匿名脚注を別々に番号付けする")
    func titleNotes() {
        let body = OrgConverter.convert("#+TITLE: 題[fn:: 表題注]\n本文[fn:: 本文注]").body
        #expect(body.contains("<li id=\"fn-1\"><p>表題注</p>\n</li>"))
        #expect(body.contains("<li id=\"fn-2\"><p>本文注</p>\n</li>"))
    }

    @Test("コード内の脚注と日時と統計を変換しない")
    func literalInline() {
        #expect(
            OrgConverter.convert("=[fn:: 注] <2026-11-18 Wed> [2/5]=").body
                == "<p><code>[fn:: 注] &lt;2026-11-18 Wed&gt; [2/5]</code></p>\n")
    }

    @Test("未閉鎖の脚注と強調20万文字を線形に扱う", .timeLimit(.minutes(1)))
    func pathologicalInline() {
        let notes = String(repeating: "[fn:", count: 50_000)
        #expect(OrgConverter.convert(notes).body == "<p>" + notes + "</p>\n")
        let emphasis = String(repeating: " *x", count: 66_666)
        #expect(OrgConverter.convert(emphasis).body == "<p>" + emphasis + "</p>\n")
    }

    @Test("脚注の連鎖と特殊ブロックの深さを32で制限する")
    func nestingBound() {
        let source = "参照[fn:n0]\n\n" + (0..<40).map { "[fn:n\($0)] 本文[fn:n\($0 + 1)]" }.joined(separator: "\n")
        let body = OrgConverter.convert(source).body
        #expect(body.contains("[fn:n32]"))
        #expect(!body.contains("id=\"fn-33\""))
        let blocks =
            String(repeating: "#+begin_foo\n", count: 40) + "本文\n" + String(repeating: "#+end_foo\n", count: 40)
        #expect(OrgConverter.convert(blocks).body.components(separatedBy: "<div ").count == 33)
    }

    @Test("数値が半数の列を右揃えにし明示的な左揃えを優先する")
    func numericColumns() {
        #expect(
            OrgConverter.convert(
                "| A | B |\n|---+---|\n| | <l> |\n| -3.5 | 1,000 |\n| 40% | 12 |\n| x | 4 |\n| y | 5 |"
            ).body
                == "<table><thead><tr><th align=\"right\">A</th><th>B</th></tr></thead><tbody><tr><td align=\"right\">-3.5</td><td>1,000</td></tr><tr><td align=\"right\">40%</td><td>12</td></tr><tr><td align=\"right\">x</td><td>4</td></tr><tr><td align=\"right\">y</td><td>5</td></tr></tbody></table>\n"
        )
    }

    @Test(
        "全既定TODO状態を大文字でのみ認識する", arguments: ["TODO", "NEXT", "WAITING", "WAIT", "HOLD", "DONE", "CANCELLED", "CANCELED"])
    func defaultKeywords(keyword: String) {
        let body = OrgConverter.convert("* " + keyword + " 作業\n* " + keyword.lowercased() + " 普通").body
        #expect(body.contains("</span> 作業</h1>"))
        #expect(body.contains("<h1>" + keyword.lowercased() + " 普通</h1>"))
    }

    @Test("インライン脚注の本文にもリンクと括弧を書ける")
    func noteBrackets() {
        #expect(
            OrgConverter.convert("注[fn:: [[https://example.com][参照]] と [文字]]").body
                == "<p>注<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup></p>\n<section class=\"footnotes\">\n<ol>\n<li id=\"fn-1\"><p><a href=\"https://example.com\">参照</a> と [文字]</p>\n</li>\n</ol>\n</section>\n"
        )
    }

    @Test("ブロック内のキーワードと副題は文書全体へ漏れない")
    func blockMetadata() {
        #expect(
            OrgConverter.convert("#+begin_foo\n#+TITLE: 隠す\n#+SUBTITLE: 隠す\n#+TODO: A | B\n#+end_foo\n* TODO 既定").body
                == "<div class=\"org-block org-block-foo\"></div>\n<h1><span class=\"org-todo\">TODO</span> 既定</h1>\n")
    }

    @Test("脚注内の後置インライン定義も先行参照を解決する")
    func nestedInlineDefinition() {
        let body = OrgConverter.convert("参照[fn:b]、[fn:a]\n\n[fn:a] 定義[fn:b: 内側]").body
        #expect(body.contains("参照<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"))
        #expect(body.contains("<li id=\"fn-1\"><p>内側</p>\n</li>"))
    }

    @Test("深いリンク表記でもインラインの深さ制限を守る", .timeLimit(.minutes(1)))
    func inlineDepth() {
        let source = String(repeating: "[[x][", count: 100) + "本文" + String(repeating: "]]", count: 100)
        #expect(!OrgConverter.convert(source).body.isEmpty)
    }

    @Test("チェックボックスの全状態をMarkdown互換の入力要素で表す")
    func checkboxHTML() {
        #expect(
            OrgConverter.convert("- [ ] 空\n- [X] 済\n- [-] 中").body
                == "<ul><li class=\"task-list-item\"><p><input type=\"checkbox\" disabled>空</p>\n</li><li class=\"task-list-item\"><p><input type=\"checkbox\" disabled checked>済</p>\n</li><li class=\"task-list-item\"><p><input type=\"checkbox\" disabled class=\"org-partial\">中</p>\n</li></ul>\n"
        )
    }

    @Test(
        "囲みの別名もMarkdownと同じ既定の札を使う",
        arguments: ["tip", "warning", "important", "caution", "info", "alert", "message", "details", "summary"])
    func calloutAliases(name: String) throws {
        let org = OrgConverter.convert("#+begin_\(name)\n本文\n#+end_\(name)").body
        #expect(org == (try MarkdownConverter.convert(":::\(name)\n本文\n:::").body))
    }

    @Test("表のキャプションの脚注をセルより先に番号付けする")
    func captionNotes() {
        let body = OrgConverter.convert("#+CAPTION: 題[fn:a]\n| セル[fn:b] |\n\n[fn:a] 先\n[fn:b] 後").body
        #expect(
            body.contains(
                "<figcaption>題<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup></figcaption>"))
        #expect(body.contains("<li id=\"fn-1\"><p>先</p>\n</li>"))
    }

    @Test("説明リストの用語の脚注は説明本文より先に番号を付ける")
    func definitionListNotes() {
        let body = OrgConverter.convert("- 用語[fn:a] :: 本文[fn:b]\n\n[fn:a] 先\n[fn:b] 後").body
        #expect(body.contains("<dt>用語<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup></dt>"))
        #expect(body.contains("<li id=\"fn-1\"><p>先</p>\n</li>"))
    }
}
