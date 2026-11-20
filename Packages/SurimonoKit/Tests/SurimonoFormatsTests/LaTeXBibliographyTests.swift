import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXBibliographyTests {
    private func fragment(_ tex: String, files: [String: String]) throws -> HTMLFragment {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        return LaTeXConverter.convert(tex, directory: folder, readFile: { try? Data(contentsOf: $0) })
    }

    @Test("alpha は著者数と年からラベルを作り、衝突した文献の本文と一覧に同じ小文字を付ける")
    func alphaLabels() throws {
        let records = #"""
            @book{one,author={Smith, J},title={Zinc},year={1981}}
            @book{two,author={Smith, J},title={Ash},year={1981}}
            @book{pair,author={Elm, A and Ash, B},year={2005}}
            @book{four,author={Elm, A and Ash, B and Oak, C and Pine, D},year={2006}}
            @book{many,author={Elm, A and Ash, B and Oak, C and Pine, D and Yew, E},year={2007}}
            @book{corp,author={{Autumn Press}},year={2008}}
            """#
        let html = try fragment(
            #"\cite{one,two,pair,four,many,corp}\bibliographystyle{alpha}\bibliography{refs}"#,
            files: ["refs.bib": records]
        ).body
        #expect(html.contains("latex-alpha"))
        for label in ["Smi81a", "Smi81b", "EA05", "EAOP06", "EAO+07", "Aut08"] {
            #expect(html.contains(">\(label)</a>"))
            #expect(html.contains(">[\(label)]</span>"))
        }
        #expect(html.contains("[Smi81a]</span> <span>J Smith. <em>Ash</em>"))
    }

    @Test("unsrt は複数ファイルの引用だけを引用順に並べ、連結した文字列・保護した表記・欧文アクセントを読む")
    func citationOrder() throws {
        let tex = #"\cite{second,first,missing}\bibliographystyle{unsrt}\bibliography{one,two.bib}"#
        let first = #"@book{first,author={Able, Alice},title={First book},year=2020} @misc{unused,title="Hidden"}"#
        let second = #"""
            @string(j = "Test ")
            @string{jrnl = j # "Journal"}
            @article(second, title = "The {NASA} {nested {Title}}", journal=jrnl,
              author = {M{\"u}ller, Franz and others}, year = 2021, volume=4, number="2",
              pages={1--5},doi={10.0000/test},url={https://example.test/paper?a=1&b=2})
            """#
        let result = try fragment(tex, files: ["one.bib": first, "two.bib": second])
        let html = result.body
        #expect(result.readingIssues.isEmpty)
        #expect(html.contains(##"[<a href="#bib-db-1">1</a>, <a href="#bib-db-2">2</a>"##))
        #expect(html.contains(#"<span class="latex-missing">missing</span>"#))
        #expect(html.contains("Franz Müller et al. The NASA"))
        #expect(html.contains("The NASA nested Title. <em>Test Journal</em>, 4(2):1–5, 2021."))
        #expect(html.contains(#"<a href="https://doi.org/10.0000/test">"#))
        #expect(html.contains("https://example.test/paper?a=1&amp;b=2"))
        #expect(!html.contains("Hidden"))
    }

    @Test("plain は著者順に番号を振り、nocite の星は引用しなかった文献も加える")
    func authorSorting() throws {
        let tex = #"\bibliographystyle{plain}\cite{z}\nocite{*}\bibliography{refs}"#
        let result = try fragment(tex, files: ["refs.bib": "@misc{z,author={Zulu, Zoe}} @misc{a,author={Able, Ann}}"])
        #expect(result.body.contains(##"<span class="latex-cite">[<a href="#bib-db-2">2</a>]"##))
        #expect(result.body.contains(#"<li id="bib-db-1"><span class="bib-label">[1]</span> Ann Able"#))
    }

    @Test("数値の文献番号の桁数は実際に載る最も大きな番号にそろえる")
    func numericLabelMeasure() throws {
        let records = (1...10).map { "@misc{k\($0),title={Entry \($0)}}" }.joined(separator: "\n")
        let all = try fragment(#"\nocite{*}\bibliography{refs}"#, files: ["refs.bib": records])
        #expect(all.body.contains(#"latex-numbered" style="--latex-label-digits: 2ch""#))
        #expect(all.body.contains(#"<span class="bib-label">[10]</span>"#))
        let one = try fragment(#"\cite{k10}\bibliography{refs}"#, files: ["refs.bib": records])
        #expect(one.body.contains(#"latex-numbered" style="--latex-label-digits: 1ch""#))
    }

    @Test("biblatex の著者年式は本文・括弧・著者・年の各引用を分け、複数キーと前後の注を残す")
    func authorYear() throws {
        let tex = #"""
            \usepackage[style=authoryear]{biblatex}\addbibresource{refs.bib}
            \begin{document}\printbibliography
            \textcite{z}\parencite[see][p. 2]{a,z}\citeauthor{a}\citeyear{z}\autocite{a}\end{document}
            """#
        let database = #"""
            @book{z,author={Zulu, Zoe and Beta, Bea and Delta, Dan},year=2011}
            @book{a,author={{Alpha and Co.}},date="2010-01-01"}
            """#
        let result = try fragment(tex, files: ["refs.bib": database])
        let html = result.body
        #expect(result.readingIssues.isEmpty)
        #expect(html.contains("Zulu et al."))
        #expect(html.contains(##"Zulu et al. (<a href="#bib-db-2">2011</a>)"##))
        #expect(
            html.contains(
                ##"(see <a href="#bib-db-1">Alpha and Co. 2010</a>; <a href="#bib-db-2">Zulu et al. 2011</a>, p. 2)"##
            ))
        #expect(html.contains(##"<span class="latex-cite"><a href="#bib-db-1">Alpha and Co.</a></span>"##))
        #expect(html.contains(##"<span class="latex-cite"><a href="#bib-db-2">2011</a></span>"##))
        #expect(html.contains(##"(<a href="#bib-db-1">Alpha and Co. 2010</a>)"##))
        #expect(!html.contains(#"class="bib-label""#))
    }

    @Test("natbib の著者年式と numbers を区別し、親の書名と年を引き継ぐ")
    func natbibStyles() throws {
        let database =
            "@proceedings{p,title={Collected},year=2021} @inproceedings{k,author={Doe, J},crossref={p},title={Chapter}}"
        let body = #"\begin{document}\citet{k}\citep{k}\bibliographystyle{plainnat}\bibliography{refs}\end{document}"#
        let authorYear = try fragment(#"\usepackage{natbib}"# + body, files: ["refs.bib": database]).body
        #expect(authorYear.contains("Doe, 2021"))
        #expect(authorYear.contains(##"Doe [<a href="#bib-db-1">2021</a>]"##))
        #expect(!authorYear.contains(#"class="bib-label""#))
        #expect(authorYear.contains("<em>Collected</em>"))
        let numeric = try fragment(#"\usepackage[numbers]{natbib}"# + body, files: ["refs.bib": database]).body
        #expect(numeric.contains(##"[<a href="#bib-db-1">1</a>]"##))
    }

    @Test("著者年の区切りは指定した方式に従い、natbib の明示した括弧を優先する")
    func punctuationByStyle() throws {
        let files = ["refs.bib": "@book{m,author={Moss, Ada},year={2024},title={Fold}}"]
        let agsm = try fragment(
            #"\usepackage{natbib}\begin{document}\citep{m}\bibliographystyle{agsm}\bibliography{refs}\end{document}"#,
            files: files)
        #expect(agsm.body.contains(##"(<a href="#bib-db-1">Moss 2024</a>)"##))
        let round = try fragment(
            #"\usepackage[round]{natbib}\begin{document}\citep{m}\bibliographystyle{plainnat}\bibliography{refs}\end{document}"#,
            files: files)
        #expect(round.body.contains(##"(<a href="#bib-db-1">Moss, 2024</a>)"##))
    }

    @Test("文献表を再掲しても引用の飛び先を一つにし、後からの natbib 設定を反映する")
    func repeatedBibliography() throws {
        let result = try fragment(
            #"\usepackage[numbers]{natbib}\setcitestyle{authoryear}\addbibresource{refs.bib}\begin{document}\citep{k}\printbibliography\printbibliography\end{document}"#,
            files: ["refs.bib": "@article{k,author={Best, Beth},title={Example},year=2020}"])
        #expect(result.body.contains(##"(<a href="#bib-db-1">Best, 2020</a>)"##))
        #expect(result.body.components(separatedBy: #"<li id="bib-db-1">"#).count == 2)
        #expect(result.body.components(separatedBy: "Beth Best. Example").count == 3)
    }

    @Test("plain 形式は書籍・論文・学位論文・報告書・論文集の書誌情報を誌面に残す")
    func publicationFields() throws {
        let database = #"""
            @book{b,title={{\TeX} Book},author={Mint, Mari and Ash, An and Dee, Don},publisher={Press},address={Town},edition={Second},series={Systems},year=2000}
            @article{a,title={Folding {NASA} Paper in Theory},journal={Journal},volume=12,number=3,pages={45--67},year=2020}
            @phdthesis{p,title={Leaf},school={School P},year=2021}
            @mastersthesis{m,title={Tree},school={School M},year=2022}
            @techreport{t,institution={Lab},number={R-8},year=2003}
            @misc{o,howpublished={Online},month=jan,year=2004,note={Updated}}
            @incollection{i,editor={Bee, Bob and May, Mae},booktitle={Essays},pages={1--5},publisher={House},year=2005}
            @inproceedings{c,editor={Bee, Bob},booktitle={Symposium},pages={7--8},year=2006}
            """#
        let html = try fragment(
            #"\bibliographystyle{plain}\nocite{*}\bibliography{refs}"#, files: ["refs.bib": database]
        ).body
        #expect(html.contains("Mari Mint, An Ash, and Don Dee. <em><span class=\"latex-logo\">"))
        for expected in [
            "Systems. Press, Town, second edition, 2000.",
            "Folding NASA paper in theory. <em>Journal</em>, 12(3):45–67, 2020.",
            "<em>Leaf</em>. PhD thesis, School P, 2021.", "Tree. Master’s thesis, School M, 2022.",
            "Technical Report R-8, Lab, 2003.", "Online, January 2004. Updated.",
            "In Bob Bee and Mae May, editors, <em>Essays</em>, pages 1–5. House, 2005.",
            "In Bob Bee, editor, <em>Symposium</em>, pages 7–8, 2006.",
        ] { #expect(html.contains(expected)) }
    }

    @Test("本の一章・会議の論文・会議録は巻・シリーズ・編者・発行団体を種類に応じた順に出す")
    func collectionTypes() throws {
        let database = #"""
            @inbook{b,editor={Kay, Jo},title={The {NASA} Book},volume={2},series={Shelf},type={Part},chapter=4,pages=17,publisher={Press},address={Town},edition={Third},year=2000}
            @book{n,author={Kay, Jo},title={Title},series={Papers},number=8,publisher={Press},year=2001}
            @incollection{i,author={Kay, Jo},title={One Part},editor={Ann Roe},booktitle={Volume},number=5,series={Studies},chapter=2,pages={7,9},publisher={Press},year=2002}
            @conference{c,author={Kay, Jo},title={One Talk},booktitle={Meeting},volume=3,series={Notes},pages={11+},address={Port},organization={Guild},publisher={Press},year=2003}
            @proceedings{e,editor={Jo Kay},title={Annual Meeting},series={Meetings},number=9,organization={Guild},publisher={Press},year=2004}
            @proceedings{o,title={Collected Papers},organization={Open Guild},address={Port},publisher={Press},year=2005}
            """#
        let html = try fragment(
            #"\nocite{*}\bibliographystyle{plain}\bibliography{refs}"#, files: ["refs.bib": database]
        ).body
        for expected in [
            "Jo Kay, editor. <em>The NASA Book</em>, volume 2 of <em>Shelf</em>, part 4, page 17. Press, Town, third edition, 2000.",
            "<em>Title</em>. Number 8 in Papers. Press, 2001.",
            "One part. In Ann Roe, editor, <em>Volume</em>, number 5 in Studies, chapter 2, pages 7,9. Press, 2002.",
            "One talk. In <em>Meeting</em>, volume 3 of <em>Notes</em>, pages 11+, Port, 2003. Guild, Press.",
            "Jo Kay, editor. <em>Annual Meeting</em>, number 9 in Meetings. Guild, Press, 2004.",
            "Open Guild. <em>Collected Papers</em>, Port, 2005. Press.",
        ] { #expect(html.contains(expected)) }
    }

    @Test("手引き・小冊子・修士論文・未刊原稿は題の書体と発行者・注・日付の位置を区別する")
    func manualAndUnpublishedTypes() throws {
        let database = #"""
            @manual{c,title={Paper Manual},organization={Paper Guild},address={Town},edition={Second},year=2011}
            @manual{a,author={Kay, Jo},title={Print Manual},organization={Press Guild},address={Port},edition={Third},year=2012}
            @booklet{b,author={Kay, Jo},title={Short {ABC} Booklet},howpublished={Handout},address={Hill},year=2013}
            @mastersthesis{m,author={Kay, Jo},title={Study of {ABC}},school={College},year=2014}
            @unpublished{u,author={Kay, Jo},title={New Findings},note={Draft},month=feb,year=2015}
            @article{p,author={Kay, Jo},title={Solo Page},journal={Journal},pages=3,year=2016}
            """#
        let html = try fragment(
            #"\nocite{*}\bibliographystyle{plain}\bibliography{refs}"#, files: ["refs.bib": database]
        ).body
        for expected in [
            "Paper Guild, Town. <em>Paper Manual</em>, second edition, 2011.",
            "Jo Kay. <em>Print Manual</em>. Press Guild, Port, third edition, 2012.",
            "Jo Kay. Short ABC booklet. Handout, Hill, 2013.",
            "Jo Kay. Study of ABC. Master’s thesis, College, 2014.",
            "Jo Kay. New findings. Draft, February 2015.",
            "Jo Kay. Solo page. <em>Journal</em>, page 3, 2016.",
        ] { #expect(html.contains(expected)) }
    }

    @Test("文字列定義の繰り返しによる膨張は文書全体の予算で止まる")
    func stringBudget() throws {
        var database = #"@string{s0="x"}"#
        for i in 1...24 {
            database += "@string{s\(i)=s\(i - 1)#s\(i - 1)}\n"
        }
        let result = try fragment(#"\nocite{*}\bibliography{refs}"#, files: ["refs.bib": database])
        #expect(result.readingIssues.contains("LaTeX expansion limit reached"))
    }
}
