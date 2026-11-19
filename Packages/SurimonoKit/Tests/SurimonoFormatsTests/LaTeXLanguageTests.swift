import Foundation
import Testing

@testable import SurimonoFormats

@Suite("LaTeX の本文言語と見出し名")
struct LaTeXLanguageTests {
    // TeX Live babel locale/<language>/babel-<tag>.ini, [captions]. The source beside each
    // fixture identifies the table independently of the reader's alias and file lookup.
    @Test("本文と手書きの文献項目でも、その場所の言語と再定義に従う名称を出す")
    func captionCommandsInProse() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass{article}\usepackage[english]{babel}
            \begin{document}\figurename~4, \tablename~5, \appendixname~A, \refname.
            \foreignlanguage{ngerman}{\chaptername~3}
            \renewcommand{\tablename}{Plate}\tablename~7.
            \begin{thebibliography}{1}\bibitem{x}\chaptername~2.\end{thebibliography}\end{document}
            """#
        ).body
        for text in [
            "Figure&nbsp;4", "Table&nbsp;5", "Appendix&nbsp;A", "References.", "Kapitel&nbsp;3", "Plate&nbsp;7",
            "Chapter&nbsp;2",
        ] {
            #expect(html.contains(text))
        }
    }

    @Test(
        "babel の言語ごとの図・表・参考文献名を出す",
        arguments: [
            ("english", "en", "Figure", "Table", "References"),  // babel-en.ini
            ("british", "en-GB", "Figure", "Table", "References"),  // babel-en-GB.ini
            ("american", "en-US", "Figure", "Table", "References"),  // babel-en-US.ini
            ("ngerman", "de", "Abbildung", "Tabelle", "Literatur"),  // babel-de.ini
            ("french", "fr", "Figure", "Table", "Références"),  // babel-fr.ini
            ("spanish", "es", "Figura", "Cuadro", "Referencias"),  // babel-es.ini
            ("italian", "it", "Figura", "Tabella", "Riferimenti bibliografici"),  // babel-it.ini
            ("portuguese", "pt", "Figura", "Tabela", "Referências"),  // babel-pt.ini
            ("pt-PT", "pt-PT", "Figura", "Tabela", "Referências"),  // babel-pt-PT.ini
            ("brazilian", "pt-BR", "Figura", "Tabela", "Referências"),  // babel-pt-BR.ini
            ("dutch", "nl", "Figuur", "Tabel", "Referenties"),  // babel-nl.ini
            ("russian", "ru", "Рис.", "Таблица", "Список литературы"),  // babel-ru.ini
            ("ukrainian", "uk", "Рис.", "Табл.", "Література"),  // babel-uk.ini
            ("polish", "pl", "Rysunek", "Tabela", "Literatura"),  // babel-pl.ini and babel-polish/polish.ldf
            ("czech", "cs", "Obrázek", "Tabulka", "Reference"),  // babel-cs.ini
            ("swedish", "sv", "Figur", "Tabell", "Referenser"),  // babel-sv.ini
            ("turkish", "tr", "Şekil", "Tablo", "Kaynaklar"),  // babel-tr.ini
            ("greek", "el", "Σχήμα", "Πίνακας", "Αναφορές"),  // babel-el.ini
            ("arabic", "ar", "شكل", "جدول", "المراجع"),  // babel-ar.ini
            ("hebrew", "he", "איור", "טבלה", "מקורות"),  // babel-he.ini
            ("chinese-simplified", "zh-Hans", "图", "表", "参考文献"),  // babel-zh-Hans.ini
            ("chinese-traditional", "zh-Hant", "圖", "表", "參 考 資 料"),  // babel-zh-Hant.ini
            ("korean", "ko", "그림", "표", "참고 문헌"),  // babel-ko.ini
            ("japanese", "ja", "図", "表", "参考文献"),  // babel-ja.ini
        ])
    func captions(_ example: (String, String, String, String, String)) {
        let (name, tag, figure, table, references) = example
        let source = #"""
            \documentclass{article}\usepackage[\#(name)]{babel}
            \begin{document}
            \begin{figure}\caption{X}\end{figure}\begin{table}\caption{Y}\end{table}
            \begin{thebibliography}{1}\bibitem{a}Z\end{thebibliography}
            \end{document}
            """#
        let fragment = LaTeXConverter.convert(source)
        #expect(fragment.language == tag)
        #expect(LaTeXConverter.documentClassInfo(source).mainLanguage == tag)
        #expect(fragment.body.contains(">\(figure) 1</span>"))
        #expect(fragment.body.contains(">\(table) 1</span>"))
        #expect(fragment.body.contains(">\(references)</h2>"))
        #expect(fragment.readingIssues.isEmpty)
    }

    // Japanese class definitions: jsclasses.dtx, ltjsclasses.dtx, bxjscls.dtx, jlreq.cls and jclasses.dtx.
    // The ctex class and package share ctex-scheme.dtx (ctex-name-utf8.cfg).
    @Test(
        "クラスの既定名は本文の文字種に左右されず横書きの旧和文クラスは名称の字間を保つ",
        arguments: [
            ("article", "en", "Abstract"), ("report", "en", "Abstract"), ("book", "en", "Abstract"),
            ("jsarticle", "ja", "概要"), ("jsbook", "ja", "概要"), ("ltjsarticle", "ja", "概要"),
            ("ltjsreport", "ja", "概要"), ("ltjsbook", "ja", "概要"), ("jlreq", "ja", "概要"),
            ("bxjsarticle", "ja", "概要"), ("ujarticle", "ja", "概 要"), ("tarticle", "ja", "概 要"),
            ("ctexart", "zh-Hans", "摘要"), ("ctexrep", "zh-Hans", "摘要"), ("ctexbook", "zh-Hans", "摘要"),
            ("oblivoir", "ko", "요약"),
        ])
    func classDefaults(_ example: (String, String, String)) {
        let (name, tag, abstract) = example
        let fragment = LaTeXConverter.convert(
            #"\documentclass{\#(name)}\begin{document}\begin{abstract}本の話\end{abstract}\end{document}"#)
        #expect(fragment.language == tag)
        #expect(fragment.body.contains(">\(abstract)</p>"))
    }

    @Test("指定された章・部・付録・証明・定理・文献の名称と日付を各見出しに反映する")
    func renamedHeadings() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass{report}
            \renewcommand{\chaptername}{Unit}\def\appendixname{Supplement}
            \def\partname{Volume}\providecommand{\partname}{Unused}
            \renewcommand{\bibname}{Sources}\def\proofname{Reason}
            \def\lemmaheading{Observation}\newtheorem{observation}{\lemmaheading}
            \def\today{Event day}
            \begin{document}\title{Notes}\maketitle\part{One}\chapter{Two}
            \begin{observation}A\end{observation}\begin{proof}B\end{proof}
            \appendix\chapter{Details}\begin{thebibliography}{1}\bibitem{a}C\end{thebibliography}\end{document}
            """#
        ).body
        for value in ["Unit 1", "Volume I", "Supplement A", "Sources", "Reason.", "Observation 1", "Event day"] {
            #expect(html.contains(value))
        }
        #expect(!html.contains("Unused"))
    }

    @Test("図表の短い題と付録参照と追加した目次項目を前方の一覧に載せる")
    func lists() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass{article}
            \renewcommand{\listfigurename}{Plates}\def\listtablename{Data register}
            \numberwithin{figure}{section}\renewcommand{\thefigure}{\arabic{section}.\arabic{figure}}
            \counterwithin{table}{section}
            \begin{document}\tableofcontents\listoffigures\listoftables
            \section{Start}\begin{figure}\caption[Tiny]{Long figure title}\label{f}\end{figure}
            \begin{table}\caption{Panel}\end{table}\addcontentsline{toc}{section}{After table}\section*{Credits}\addcontentsline{toc}{section}{Credits}
            \addtocontents{toc}{Hidden}\appendix\section{More}\label{a}付録\ref{a}
            \end{document}
            """#
        ).body
        let lists = html.components(separatedBy: "</nav>")
        #expect(lists.count == 4)
        #expect(lists[0].contains("Credits"))
        #expect(lists[0].contains(##"href="#toc-entry-2">After table</a>"##))
        #expect(lists[3].contains(#"<span id="toc-entry-2"></span>"#))
        #expect(!html.contains("Hidden"))
        #expect(lists[1].contains("Plates") && lists[1].contains(">1.1</span>Tiny"))
        #expect(!lists[1].contains("Long figure title"))
        #expect(lists[2].contains("Data register") && lists[2].contains(">1.1</span>Panel"))
        #expect(lists[3].contains("Figure 1.1") && lists[3].contains("Table 1.1"))
        #expect(html.contains(##"付録<a class="latex-number-ref" href="#sec-A">A</a>"##))
    }

    @Test("選択した言語だけの名称定義を使い引用と局所的な言語を復元する")
    func switches() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{article}\usepackage[french,ngerman]{babel}
            \addto\captionsfrench{\renewcommand{\figurename}{Planche}}
            \setlocalecaption{ngerman}{table}{Raster}
            \begin{document}\enquote{"a "o "u "s}\glqq X\grqq
            \foreignlanguage{french}{\og Est-ce vrai ?\fg}\foreignlanguage{hebrew}{\figurename}
            \begin{otherlanguage}{french}\figurename\end{otherlanguage}
            \begin{table}\caption{a}\end{table}\selectlanguage{french}\begin{figure}\caption{b}\end{figure}
            \end{document}
            """#)
        #expect(fragment.language == "de")
        #expect(fragment.body.contains("„ä ö ü ß“"))
        #expect(fragment.body.contains("«\u{00A0}Est-ce vrai\u{202F}?\u{00A0}»"))
        #expect(fragment.body.contains(#"<span lang="he" dir="rtl">איור</span>"#))
        #expect(fragment.body.contains("Raster 1"))
        #expect(fragment.body.contains("Planche 1"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("babelprovide と polyglossia は前置きで指定した主言語を公開し副言語宣言は主言語を変えない")
    func mainLanguages() {
        for (preamble, tag) in [
            (#"\babelprovide[import,main]{arabic}\babelprovide[import]{french}"#, "ar"),
            (#"\setdefaultlanguage[variant=british]{english}\setotherlanguage{japanese}"#, "en-GB"),
            (#"\setmainlanguage{hebrew}"#, "he"),
            (#"\usepackage{ctex}"#, "zh-Hans"), (#"\usepackage{kotex}"#, "ko"),
            (#"\usepackage{babel}"#, "fr"),
        ] {
            let fragment = LaTeXConverter.convert(
                #"\documentclass[french]{article}\#(preamble)\begin{document}T\end{document}"#)
            #expect(fragment.language == tag)
        }
    }

    @Test("文中の言語変更は段落を分けず、グループの終了時に名称を戻す")
    func scopedLanguages() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{article}\begin{document}A {\selectlanguage{french}\abstractname} B \abstractname.
            First \selectlanguage{ngerman}\abstractname.\par Next \abstractname.\end{document}
            """#)
        #expect(fragment.body.contains(#"<span lang="fr" dir="ltr">Résumé</span> B Abstract."#))
        #expect(fragment.body.contains(#"First <span lang="de" dir="ltr">Zusammenfassung.</span></p>"#))
        #expect(fragment.body.contains(#"<p>Next Zusammenfassung.</p>"#))
    }

    @Test("後のロケール定義が以前の名前に優先し、他言語の図名と .bib の出力時点の題を保つ")
    func captionScopeAndBibliography() {
        let tex = #"""
            \documentclass{article}\usepackage[english]{babel}\renewcommand{\figurename}{Plate}
            \setlocalecaption{english}{figure}{Diagram}
            \addbibresource{book.bib}\begin{document}\cite{b}
            \figurename\foreignlanguage{ngerman}{\figurename}
            \selectlanguage{french}\printbibliography\selectlanguage{english}\printbibliography
            \end{document}
            """#
        let folder = FileManager.default.temporaryDirectory
        let html = LaTeXConverter.convert(
            tex, directory: folder, readFile: { _ in Data("@book{b,title={Notes}}".utf8) }
        ).body
        #expect(
            html.contains("Diagram") && html.contains("Abbildung") && html.contains(">Références</h2>")
                && html.contains(">References</h2>"))
    }

    @Test("付録では節の独自書式を終え、索引と定理の明示名を使う")
    func appendixResets() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass{article}\def\indexname{Register}\def\theoremname{Finding}
            \def\thesection{S-\arabic{section}}\begin{document}\section{Core}
            \begin{theorem}X\end{theorem}\appendix\section{Tail}\label{a}\ref{a}
            \begin{theindex}\item Term\end{theindex}\end{document}
            """#
        ).body
        #expect(html.contains(">S-1</span>") && html.contains(">A</span>") && html.contains(">A</a>"))
        #expect(html.contains("Finding 1") && html.contains(">Register</h2>"))
    }

    @Test("today の日・月・年を主言語の語順と書式で出す")
    func dates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2025, month: 2, day: 1, hour: 12))!
        #expect(LaTeXLanguage.today("de", date: date) == "1. Februar 2025")
        #expect(LaTeXLanguage.today("en-GB", date: date) == "1 February 2025")
        #expect(LaTeXLanguage.today("fr", date: date) == "1er février 2025")
        #expect(LaTeXLanguage.today("en-GB", date: date, classicBabel: true) == "1st February 2025")
        #expect(LaTeXLanguage.today("ja", date: date) == "2025年2月1日")
        for (tag, expected) in [
            ("en-US", "February 1, 2025"), ("es", "1 de febrero de 2025"), ("it", "1 febbraio 2025"),
            ("pt", "1 de fevereiro de 2025"), ("pt-BR", "1 de fevereiro de 2025"), ("nl", "1 februari 2025"),
            ("ru", "1 февраля 2025 г."), ("uk", "1 лютого 2025 р."), ("pl", "1 lutego 2025"),
            ("cs", "1. února 2025"), ("sv", "1 februari 2025"), ("tr", "1 Şubat 2025"),
            ("el", "1 Φεβρουαρίου 2025"), ("ko", "2025년 2월 1일"), ("zh-Hant", "2025年2月1日"),
            ("he", "1 בפברואר 2025"), ("ar", "1 فبراير 2025"),
        ] {
            #expect(LaTeXLanguage.today(tag, date: date) == expected)
        }
    }
}
