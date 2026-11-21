import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXSocietyTitleTests {
    @Test("和英の題名、著者、受付日、概要を表題内に置き、所属とメールを左段の注に移す")
    func bilingual() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[submit]{ipsj}
            \受付{2026}{3}{4}\再受付{2026}{5}{10}\採録{2026}{8}{1}
            \begin{document}\title{実験}\etitle{Trials}
            \affiliate{old-lab}{旧所属\\Old Lab}\paffiliate{new-lab}{新所属\\New Lab}
            \author{試験 太郎}{Taro Test}{old-lab,new-lab}[fixture@example.org]
            \begin{abstract}和抄録。\end{abstract}\begin{jkeyword}試験\end{jkeyword}
            \begin{eabstract}English abstract.\end{eabstract}\begin{ekeyword}cards\end{ekeyword}
            \maketitle\maketitle 本文。\end{document}
            """#)
        let parts = fragment.body.components(separatedBy: "</header>")
        try #require(parts.count == 2)
        let head = parts[0]
        let body = parts[1]
        for text in [
            "data-latex-wide", "実験", "試験 太郎", "受付日 2026年3月4日", "再受付日 2026年5月10日", "採録日 2026年8月1日",
            "概要：</strong>和抄録。", "キーワード：</strong>試験", "Trials", "Taro Test", "1,†1,a)", "Received: March 4, 2026",
            "Accepted: August 1, 2026", "Abstract:</strong> English abstract.", "Keywords:</strong> cards",
        ] { #expect(head.contains(text), "\(text)") }
        for text in ["旧所属<br>Old Lab", "現在，新所属<br>New Lab", "fixture@example.org"] {
            #expect(!head.contains(text))
            #expect(body.contains(text))
        }
        #expect(body.contains(#"<template data-latex-column-notice="first">"#))
        #expect(head.contains(#"Taro Test<sup class="latex-front-mark">1,†1,a)</sup>"#))
        #expect(body.contains(#"<sup class="latex-note-mark">a)</sup>fixture@example.org"#))
        #expect(body.contains("本文。"))
        #expect(!fragment.body.contains("old-lab"))
        #expect(!fragment.body.contains("new-lab"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("英文誌の二引数の著者と英文キーワードを読み、次の命令を引数にしない")
    func englishJournal() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass[JIP]{ipsj}\begin{document}\title{Paper}
            \affiliate{lab}{Workshop}\author{Ada Doe}{lab}[a@example.org]\author{John Roe}{lab}
            \begin{abstract}Overview.\end{abstract}\begin{keyword}paper\end{keyword}
            \maketitle Text.\end{document}
            """#
        ).body
        for text in [
            "Ada Doe", "John Roe", "Workshop", "a@example.org", "Abstract:</strong> Overview.",
            "Keywords:</strong> paper", "Text.",
        ] {
            #expect(html.contains(text), "\(text)")
        }
        #expect(!html.contains("概要："))
    }

    @Test("和文論文誌は日英の著者、所属、DOIを読み、英文抄録を本文後の新しい単段に組む")
    func insetTitle() throws {
        let fragment = LaTeXConverter.convert(Self.insetSource(options: "paper"))
        let sections = fragment.body.components(separatedBy: "</header>")
        try #require(sections.count == 2)
        let head = sections[0]
        for token in ["全題", "Long Title", "Aya TEST", "和文の概要", "あらまし</strong>", "キーワード</strong>"] {
            #expect(head.contains(token))
        }
        let nativeName = #"<span class="latex-japanese-name"><span>試験</span> <span>太郎</span></span>"#
        #expect(head.contains(nativeName + #"<sup class="latex-front-mark">"#))
        #expect(!head.contains("English summary"))
        let body = sections[1].components(separatedBy: #"data-latex-break="clear""#)
        try #require(body.count == 2)
        for text in ["本文です", "所属<br>Workshop", "別所属", "E-mail: fixture@example.org", "DOI:10.14923/transcomj.test"] {
            #expect(body[0].contains(text), "\(text)")
        }
        for text in [
            #"data-latex-columns="1""#, #"data-latex-page-action="journalSupplement""#,
            "Abstract</strong> English summary", "Key words</strong> cards",
        ] {
            #expect(body[1].contains(text), "\(text)")
        }
        #expect(!fragment.body.contains("one-label"))
        #expect(!fragment.body.contains("1234567"))
        var pages = try #require(fragment.latexClass?.pageNumbers)
        pages.advance()
        pages.advance()
        #expect(pages.header[0] == "論文／短題")
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("著者の姓名を最初の空白だけで分け、単名と所属の上付き印をそのまま残す")
    func nativeNameFields() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass[paper]{ieicej}
            \authorlist{\authorentry[a@b]{模型 線路}{Model Desk}{one}
              \authorentry{長い姓 {複合 名}}{Long Name}{two}\authorentry{単名}{Name}{two}}
            \affiliate[one]{甲}{One}\affiliate[two]{乙}{Two}
            \begin{document}\jtitle{試験}\maketitle\end{document}
            """#
        ).body
        let mark = #"<sup class="latex-front-mark">"#
        #expect(html.contains("<span>模型</span> <span>線路</span></span>" + mark + "†a)</sup>"))
        #expect(html.contains("<span>長い姓</span> <span>複合 名</span></span>" + mark + "††</sup>"))
        #expect(html.contains(#"<span class="latex-front-author">単名"# + mark + "††</sup>"))
    }

    @Test("和文表題・著者・あらまし・脚注・文献を欧文のポイント数と別の級数で組む")
    func japaneseDesignSizes() throws {
        let info = LaTeXDocumentClassInfo(name: "ieicej", options: "paper")
        let scales = try #require(info.profile.page.fixedGrid?.japaneseScales)
        for (scale, points, millimetres) in [
            (scales.title, 12.0, 4.5), (scales.author, 10.95, 3.75), (scales.abstract, 8, 2.75),
            (scales.note, 6, 2.25), (scales.caption, 7, 2.5),
        ] {
            #expect(abs(scale * points * 25.4 / 72.27 - millimetres) < 0.001)
        }
        let journal = try #require(info.pageNumbers.journalPage)
        #expect(journal.japaneseFooterFace == "HiraginoSans-W5")
        #expect(journal.footerFont?.family == "Helvetica")
        #expect(journal.copyrightFont?.family == "Times New Roman")
        let ipsj = LaTeXDocumentClassInfo(name: "ipsj", options: "submit")
        #expect(ipsj.pageNumbers.journalPage?.japaneseHeaderFace == "HiraginoSans-W5")
        #expect(ipsj.pageNumbers.journalPage?.copyrightFont?.family == "Times New Roman")
    }

    @Test("和文の最終稿は英文抄録用の改ページを挿入しない")
    func cameraReady() {
        let html = LaTeXConverter.convert(Self.insetSource(options: "paper,cameraready")).body
        #expect(html.contains("本文です"))
        #expect(!html.contains("English summary"))
        #expect(!html.contains("latex-english-supplement"))
        #expect(!html.contains(#"data-latex-break="clear""#))
    }

    @Test("和英入力を併用した英文誌で第二題と第二著者名を保つ")
    func mixedNames() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass[JIP]{ipsj}\begin{document}\title{和題}\etitle{Second title}
            \affiliate{a-lab}{所属}\author{試験 太郎}{Taro Test}{a-lab}
            \begin{abstract}和抄録。\end{abstract}\begin{eabstract}English summary.\end{eabstract}
            \maketitle\end{document}
            """#
        ).body
        for token in ["和題", "Second title", "試験 太郎", "Taro Test", "和抄録。", "English summary."] {
            #expect(html.contains(token), "\(token)")
        }
        #expect(!html.contains("a-lab"))
    }

    @Test("和文の研究速報は段内の表題に続けて概要を組み、受付日は本文末にまとめる")
    func letterTitle() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[letter]{ieicej}\typeofletter{問題提起}\jtitle{和題}\etitle{English title}
            \authorlist{\authorentry{試験 太郎}{Taro Test}{m}{lab}}\affiliate[lab]{工房}{Workshop}
            \received{2026}{1}{3}\revised{2026}{2}{4}
            \begin{document}\maketitle\begin{abstract}和文概要\end{abstract}
            本文。\begin{eabstract}English summary.\end{eabstract}\end{document}
            """#)
        let parts = fragment.body.components(separatedBy: "</header>")
        try #require(parts.count == 2)
        #expect(parts[0].contains("data-latex-in-column"))
        #expect(parts[0].contains("Member"))
        #expect(!parts[0].contains("data-latex-wide"))
        #expect(!parts[0].contains("和文概要"))
        var tail = parts[1][...]
        for token in ["和文概要", "本文。", "2026年1月3日受付，2月4日再受付", "latex-english-supplement", "English summary."] {
            let range = try #require(tail.range(of: token), "\(token)")
            tail = tail[range.upperBound...]
        }
    }

    @Test("技術研究報告は和英の概要を表題に収める")
    func technicalReport() throws {
        let parts = LaTeXConverter.convert(Self.insetSource(options: "technicalreport")).body.components(
            separatedBy: "</header>")
        try #require(parts.count == 2)
        #expect(parts[0].contains("和文の概要"))
        #expect(parts[0].contains("English summary"))
        #expect(!parts[1].contains("latex-english-supplement"))
    }

    @Test("査読用の単段では題注・現在所属・公開日を残し、本文の注を続きから数える")
    func refereeNotes() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[referee]{ieice}\title[Short]{Full title}\titlenote{Title note.}\SpecialIssue{Rail models}
            \authorlist{\authorentry{Jane Doe}{m}{lab}[current]}\affiliate[lab]{Main lab.}\paffiliate[current]{Current lab.}
            \jalcdoi{DOI: 10.1587/custom}\onlinefirst{2026}{7}{16}
            \begin{document}\maketitle Body.\footnote{A body note.}\end{document}
            """#)
        let parts = fragment.body.components(separatedBy: "</header>")
        try #require(parts.count == 2)
        #expect(!parts[0].contains("data-latex-wide"))
        #expect(parts[0].contains("Special Issue on Rail models"))
        #expect(parts[0].contains(#"<sup class="latex-front-mark">**</sup>"#))
        for token in [
            "Title note.", "Main lab.", "Current lab.", "Manuscript publicized July 16, 2026.", "DOI: 10.1587/custom",
            "A body note.",
        ] {
            #expect(parts[1].contains(token), "\(token)")
        }
        #expect(!parts[1].contains("DOI: DOI:"))
        #expect(fragment.readingIssues.isEmpty)
    }

    private static func insetSource(options: String) -> String {
        #"""
        \documentclass[\#(options)]{ieicej}\field{B}\vol{100}\no{3}
        \jtitle[短題]{全題}\etitle{Long Title}\jalcdoi{test}
        \authorlist{\authorentry[fixture@example.org]{試験 太郎}{Aya Test}{one-label}[new]\MembershipNumber{1234567}}
        \affiliate[one-label]{所属}{Workshop}\paffiliate[new]{別所属}
        \begin{document}\begin{abstract}和文の概要\end{abstract}\begin{keyword}紙\end{keyword}
        \begin{eabstract}English summary\end{eabstract}\begin{ekeyword}cards\end{ekeyword}
        \maketitle 本文です。\end{document}
        """#
    }

    @Test("英文誌は所属記号と会員種別を著者名に添え、受領日を左段注、要約を本文側に置く")
    func framedTitle() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[paper]{ieice}\field{A}\title[Short title]{A long title}
            \authorlist{\authorentry[fixture@example.org]{Given One}{m}{lab-b}
            \authorentry{Given Two}{m}{lab-a}}
            \affiliate[lab-a]{Second workshop.}\affiliate[lab-b]{First workshop.}
            \received{2025}{11}{1}\revised{2026}{1}{3}
            \begin{document}\maketitle
            \begin{summary}The summary.\end{summary}\begin{keywords}paper\end{keywords}
            Body.\end{document}
            """#)
        let parts = fragment.body.components(separatedBy: "</header>")
        try #require(parts.count == 2)
        for token in [
            "latex-framed-title", "PAPER", "A long title", "Given ONE", "Given TWO", "†a)", "††", "<em>and</em>",
            "<em>Members</em>",
        ] {
            #expect(parts[0].contains(token), "\(token)")
        }
        for token in [
            "Second workshop.", "First workshop.", "Manuscript received November 1, 2025.",
            "Manuscript revised January 3, 2026.",
            "E-mail: fixture@example.org", "DOI: 10.1587/transfun.E0.A.1", "SUMMARY</strong> The summary.",
            "key words:</strong> paper", "Body.",
        ] {
            #expect(!parts[0].contains(token))
            #expect(parts[1].contains(token), "\(token)")
        }
        #expect(!fragment.body.contains("lab-b"))
        var pages = try #require(fragment.latexClass?.pageNumbers)
        pages.advance()
        pages.advance()
        #expect(pages.header[0] == "ONE and TWO: SHORT TITLE")
        #expect(fragment.readingIssues.isEmpty)
    }
}
