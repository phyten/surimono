import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXFrontMatterTests {
    private func convert(_ name: String, _ content: String, preamble: String = "") -> HTMLFragment {
        LaTeXConverter.convert("\\documentclass{\(name)}\n\(preamble)\n\\begin{document}\n\(content)\n\\end{document}")
    }

    private func expectOrder(_ words: [String], in html: String, sourceLocation: SourceLocation = #_sourceLocation)
        throws
    {
        var start = html.startIndex
        for word in words {
            let range = try #require(
                html.range(of: word, range: start..<html.endIndex), "順番に現れる語「\(word)」", sourceLocation: sourceLocation)
            start = range.upperBound
        }
    }

    @Test("学会誌のクラスは日付を指定したときだけ刷る", arguments: ["amsart", "revtex4-2"])
    func journalDates(name: String) {
        let paper = #"\title{仕口の寸法}\maketitle"#
        #expect(!convert(name, paper).body.contains("latex-date"))
        #expect(!convert(name, paper, preamble: #"\date{}"#).body.contains("latex-date"))
        #expect(convert(name, paper, preamble: #"\date{冬学期}"#).body.contains("冬学期</p>"))
    }

    @Test("表題に日付欄のないクラスは指定した日付も組まない", arguments: ["amsbook", "IEEEtran", "llncs", "acmart", "elsarticle"])
    func noTitleDate(name: String) {
        let paper = convert(name, #"\title{仕口の寸法}\maketitle"#, preamble: #"\date{冬学期}"#)
        #expect(!paper.body.contains("冬学期"))
        #expect(!paper.body.contains("latex-front-date"))
    }

    @Test("標準クラスは日付の省略と明示した空欄を区別する", arguments: ["article", "report", "book"])
    func standardDates(name: String) {
        let paper = #"\title{仕口の寸法}\maketitle"#
        #expect(convert(name, paper).body.contains("latex-date latex-front-date"))
        #expect(!convert(name, paper, preamble: #"\date{}"#).body.contains("latex-date"))
    }

    @Test("AMS の短い柱題を本文に混ぜず、概要と分類と著者の謝辞を一度ずつ刷る", arguments: ["amsart", "amsbook"])
    func ams(name: String) throws {
        let paper = convert(
            name, #"\maketitle\maketitle 本文"#,
            preamble: #"""
                \title[柱用]{折り目の測定}\author[略称]{担当甲}\address{製本室}\email{sample@example.test}
                \thanks{試作協力}\subjclass[2020]{12X34}\keywords{折り目}
                \begin{abstract}紙厚の結果。\end{abstract}
                """#)
        #expect(paper.readingIssues.isEmpty)
        #expect(paper.title == "折り目の測定")
        try expectOrder(
            ["折り目の測定", "担当甲", "sample@example.test", "製本室", "紙厚の結果。", "12X34", "Keywords:", "本文"], in: paper.body)
        for word in ["試作協力", "紙厚の結果。", "製本室", "12X34"] { #expect(paper.body.components(separatedBy: word).count == 2) }
        #expect(!paper.body.contains("柱用"))
        #expect(!paper.body.contains("略称"))
    }

    @Test("REVTeX の本文で先に読む概要を、明示した日付とキーワードの間に組む")
    func revtex() throws {
        let paper = convert(
            "revtex4-2",
            #"""
            \title{鉛筆の角度}\author{作図係}\affiliation{第一工作室}\date{春期}
            \begin{abstract}平均値を求めた。\end{abstract}\keywords{角度}\maketitle 測定表
            """#)
        #expect(paper.readingIssues.isEmpty)
        try expectOrder(["鉛筆の角度", "作図係", "第一工作室", "春期", "平均値", "Keywords:", "測定表"], in: paper.body)
    }

    @Test("ACM の所属・著者識別子・分類を読み、機械用 XML を本文に刷らない")
    func acm() throws {
        let paper = convert(
            "acmart",
            #"""
            \title{継手試験}\author{藤}\orcid{0000-0000}\authornote{連絡担当}
            \affiliation{\institution{紙工房}\city{港町}\country{例国}}\email{one@example.test}
            \author{葵}\affiliation{\institution{糸工房}\city{丘町}}
            \begin{CCSXML}<bad>\bogus{非表示}</bad>\end{CCSXML}
            \ccsdesc[500]{加工技術}\begin{abstract}比較の結果。\end{abstract}\keywords{継ぎ目}\maketitle
            """#)
        #expect(paper.readingIssues.isEmpty)
        try expectOrder(
            [
                "継手試験", "藤<sup", "one@example.test", "0000-0000", "葵<sup", "紙工房, 港町, 例国", "糸工房, 丘町", "比較の結果", "加工技術",
                "継ぎ目",
            ], in: paper.body)
        #expect(!paper.body.contains("非表示"))
        #expect(paper.body.contains("連絡担当"))
    }

    @Test("IEEE の著者ブロックと後置の要旨・索引用語を所定の順に置く")
    func ieee() throws {
        let paper = convert(
            "IEEEtran",
            #"""
            \title{紙管の長さ}\author{\IEEEauthorblockN{紙係}\IEEEauthorblockA{測定所}}
            \maketitle\begin{abstract}基準を調べた。\end{abstract}
            \begin{IEEEkeywords}紙厚, 直径\end{IEEEkeywords}\section{計器}
            """#)
        #expect(paper.readingIssues.isEmpty)
        try expectOrder(["紙管の長さ", "紙係", "測定所", "基準を調べた。", "Index Terms—", "紙厚", "計器"], in: paper.body)
    }

    @Test("IEEE の著者と所属に書かれた番号を二重に振らない")
    func explicitIEEEMarks() {
        let paper = convert(
            "IEEEtran",
            #"""
            \title{針目}\author{\IEEEauthorblockN{空\IEEEauthorrefmark{1}, 雪\IEEEauthorrefmark{2}}
            \IEEEauthorblockA{\IEEEauthorrefmark{1}海辺}\IEEEauthorblockA{\IEEEauthorrefmark{2}山辺}}\maketitle
            """#)
        #expect(paper.readingIssues.isEmpty)
        #expect(paper.body.components(separatedBy: #"class="latex-front-mark">1</sup>"#).count == 3)
        #expect(paper.body.components(separatedBy: #"class="latex-front-mark">2</sup>"#).count == 3)
    }

    @Test("LNCS の著者番号と研究所を結び、要旨内のキーワードを要旨の直後に置く")
    func proceedings() throws {
        let paper = convert(
            "llncs",
            #"""
            \title{糸の幅}\author{雨\inst{2}\and 晴\inst{1,2}}\institute{木室\and 紙室}\maketitle
            \begin{abstract}幅を比べた。\keywords{繊維\and ばらつき}\end{abstract}\section{測定条件}
            """#)
        #expect(paper.readingIssues.isEmpty)
        try expectOrder(
            [
                "雨<sup", ">2</sup>", "晴<sup", ">1,2</sup>", ">1</sup> 木室", ">2</sup> 紙室", "幅を比べた。", "</div>",
                "Keywords:", "繊維", "ばらつき", "測定条件",
            ], in: paper.body)
    }

    @Test("Elsevier の frontmatter の終端でラベル付き所属と共通の連絡先注を一度だけ刷る")
    func elsevier() throws {
        let paper = convert(
            "elsarticle",
            #"""
            \begin{frontmatter}\title{台紙の反り}\author[west]{青\corref{contact}}\ead{blue@example.test}
            \author[east,west]{白\corref{contact}}
            \affiliation[east]{organization={東会},city={水町},country={例国}}
            \address[west]{西会}\cortext[contact]{窓口は編集室}
            \begin{abstract}試作の所見。\end{abstract}\begin{keyword}台紙\sep 湿度\end{keyword}
            \end{frontmatter}\maketitle\section{調査}
            """#)
        #expect(paper.readingIssues.isEmpty)
        try expectOrder(
            [
                "台紙の反り", "青", ">b</sup>", "blue@example.test", "白", ">a,b</sup>", ">a</sup> 東会, 水町, 例国", ">b</sup> 西会",
                "試作の所見。", "Keywords:", "台紙, 湿度", "調査",
            ], in: paper.body)
        #expect(paper.body.components(separatedBy: "窓口は編集室").count == 2)
        #expect(paper.body.components(separatedBy: "台紙の反り").count == 2)
        #expect(!paper.body.contains("latex-date"))
        #expect(!paper.body.contains("organization="))
    }

    @Test("同じ所属に戻る著者と ACM の共通脚注は、最初の所属番号と謝辞記号を使う")
    func sharedAffiliation() {
        let paper = convert(
            "acmart",
            #"""
            \title{繊維の向き}\author{東}\authornote{共同責任}\affiliation{波室}
            \author{西}\affiliation{丘室}\author{南}\authornotemark[1]\affiliation{波室}\maketitle
            """#)
        #expect(paper.readingIssues.isEmpty)
        #expect(paper.body.components(separatedBy: "波室").count == 2)
        #expect(paper.body.components(separatedBy: "共同責任").count == 2)
        #expect(paper.body.components(separatedBy: ##"href="#fn-symbol-1""##).count == 3)
        #expect(paper.body.components(separatedBy: #"class="latex-front-mark">1</sup>"#).count == 4)
    }

    @Test("IEEE の箇条書き謝辞と Elsevier の未参照の連絡先注を落とさない")
    func titleNoteVariants() {
        let ieee = convert(
            "IEEEtran", #"\title{紙の厚さ}\author{係\IEEEcompsocitemizethanks{\IEEEcompsocthanksitem 試作協力}}\maketitle"#)
        #expect(ieee.body.contains("試作協力"))
        #expect(ieee.readingIssues.isEmpty)
        let els = convert(
            "elsarticle", #"\begin{frontmatter}\title{紙}\author{係}\cortext[contact]{連絡担当}\end{frontmatter}"#)
        #expect(els.body.contains("連絡担当"))
        #expect(els.readingIssues.isEmpty)
    }

    @Test("日付を明示する和文クラスでは表題の直後に一度だけ日付を出す")
    func japaneseDate() throws {
        let paper = convert(
            "ltjsarticle", #"\title{綴じ目}\author{}\date{春期四日}\maketitle\begin{abstract}見本を調べた。\end{abstract}"#)
        try expectOrder(["綴じ目", "春期四日", "概要", "見本を調べた。"], in: paper.body)
        #expect(paper.body.components(separatedBy: "春期四日").count == 2)
    }

    @Test("和文のキーワード見出しには文書の言語を使う")
    func localizedKeywords() {
        let paper = convert("ltjsarticle", #"\title{観測}\keywords{湿度}\date{}\maketitle"#)
        #expect(paper.body.contains("キーワード：</strong> 湿度"))
    }

    @Test("本文開始だけでは各学会誌の表題を作らず、欧州ポルトガル語のキーワードを使う")
    func titleTrigger() {
        for name in ["amsart", "amsbook", "IEEEtran", "revtex4-2", "llncs", "acmart", "elsarticle", "scrartcl"] {
            let fragment = convert(name, "本文", preamble: #"\title{冊子}"#)
            #expect(fragment.title == "冊子")
            #expect(!fragment.body.contains("latex-front-title"))
        }
        let portuguese = convert("article", #"\keywords{costura}\maketitle"#, preamble: #"\usepackage[pt-PT]{babel}"#)
        #expect(portuguese.body.contains("Palavras-chave:"))
    }

    @Test("学会誌のテンプレートで providecommand が本来のキーワード欄を上書きしない")
    func providedFallback() {
        let source = #"\title{冊子}\keywords{断裁}\maketitle"#
        let fallback = #"\providecommand{\keywords}[1]{代替: #1}"#
        let journal = convert("amsart", source, preamble: fallback)
        #expect(journal.body.contains("Keywords:</strong> 断裁"))
        #expect(!journal.body.contains("代替:"))
        #expect(convert("article", source, preamble: fallback).body.contains("代替: 断裁"))
    }

    @Test("KOMA の副題と発行元、目次に載せる無番号の章節を保つ")
    func koma() throws {
        let paper = convert(
            "scrreprt",
            #"""
            \title{素材録}\subtitle{冬の巻}\author{記録係}\publishers{工作室}\date{}\maketitle
            \tableofcontents\addchap{前置き}\addsec{凡例}\addsec*{控え}\chapter{採寸}
            """#, preamble: #"\setkomafont{chapter}{\Large}\addtokomafont{section}{\bfseries}"#)
        #expect(paper.readingIssues.isEmpty)
        try expectOrder(["素材録", "冬の巻", "記録係", "工作室"], in: paper.body)
        let toc = try #require(paper.body.components(separatedBy: "</nav>").first)
        #expect(toc.contains("前置き</a>"))
        #expect(toc.contains("凡例</a>"))
        #expect(!toc.contains("控え"))
        #expect(paper.body.contains("Chapter 1</span>採寸"))
    }

    @Test("memoir の章頭の題辞を出典とともに出し、章の書式名は紙に残さない")
    func memoir() {
        let paper = convert("memoir", #"\chapterstyle{demo}\chapter{記録}\epigraph{紙目を読む。}{作業票}"#)
        #expect(paper.readingIssues.isEmpty)
        #expect(!paper.body.contains("demo"))
        #expect(paper.body.contains(#"<blockquote class="latex-epigraph"><p>紙目を読む。</p>"#))
        #expect(paper.body.contains("<footer>作業票</footer>"))
    }
}
