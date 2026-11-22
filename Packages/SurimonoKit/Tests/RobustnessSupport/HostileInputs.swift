import CoreGraphics
import Foundation
import ImageIO
import SurimonoFormats
import UniformTypeIdentifiers

/// One hand-written edge case. Large inputs are described here and built when needed, so nothing big is committed.
package struct HostileCase: Sendable, CustomStringConvertible {
    package let format: DocumentFormat
    package let name: String
    /// The file name's extension; plain text is coloured by it, and an include of `self` finds the case itself.
    package let fileExtension: String
    /// Long cases (megabytes, or slow on purpose) run in `make robustness`, not in `make test-kit`.
    package let isLong: Bool
    private let build: @Sendable () -> [UInt8]

    package init(
        _ format: DocumentFormat, _ name: String, extension fileExtension: String? = nil, long: Bool = false,
        _ build: @escaping @Sendable () -> [UInt8]
    ) {
        self.format = format
        self.name = name
        self.fileExtension = fileExtension ?? HostileInputs.defaultExtension(format)
        isLong = long
        self.build = build
    }

    package func bytes() -> [UInt8] { build() }
    package var description: String { "\(format.rawValue)/\(name)" }
}

package enum HostileInputs {
    package static let depth = 10_000

    package static func defaultExtension(_ format: DocumentFormat) -> String {
        switch format {
        case .markdown: "md"
        case .org: "org"
        case .plainText: "txt"
        case .html: "html"
        case .pdf: "pdf"
        case .image: "png"
        case .csv: "csv"
        case .zipArchive: "zip"
        case .latex: "tex"
        case .asciidoc: "adoc"
        case .quarto: "qmd"
        case .rMarkdown: "rmd"
        case .djot: "dj"
        case .textile: "textile"
        case .mediawiki: "mediawiki"
        case .rst: "rst"
        case .docx: "docx"
        case .notebook: "ipynb"
        case .graphviz: "dot"
        case .plantuml: "puml"
        }
    }

    package static func cases(for format: DocumentFormat) -> [HostileCase] {
        switch format {
        case .pdf: return pdfCases
        case .image: return imageCases
        case .zipArchive: return zipCases
        case .docx: return docxCases + encodingCases(.docx)
        default: return encodingCases(format) + textCases(format)
        }
    }

    private static func text(_ string: String) -> [UInt8] { Array(string.utf8) }
    /// Inside `$quick.withValue(true)`, runs and nesting are a fifth as long: still far beyond every depth and run a
    /// reader may need, and fast enough for `make test-kit`.
    @TaskLocal package static var quick = false

    private static func repeated(_ string: String, _ count: Int) -> [UInt8] {
        text(String(repeating: string, count: quick ? max(1, count / 5) : count))
    }

    private static var n: Int { quick ? depth / 5 : depth }

    /// A short valid document of each text format, used as the payload of the encoding cases.
    package static func sample(_ format: DocumentFormat) -> String {
        switch format {
        case .latex: #"\documentclass{article}\begin{document}\section{Crane}PaperCrane $x^2$\end{document}"#
        case .org: "* PaperCrane\n- item\n#+begin_src text\ncode\n#+end_src\n"
        case .asciidoc: "= PaperCrane\n\n* item\n\n----\ncode\n----\n"
        case .djot: "# PaperCrane\n\n- item\n\n```\ncode\n```\n"
        case .textile: "h1. PaperCrane\n\n* item\n\nbc. code\n"
        case .mediawiki: "== PaperCrane ==\n* item\n{|\n| a || b\n|}\n"
        case .rst: "PaperCrane\n==========\n\n- item\n\n::\n\n  code\n"
        case .notebook: ##"{"nbformat":4,"cells":[{"cell_type":"markdown","source":["# PaperCrane"]}]}"##
        case .csv: "name,count\nPaperCrane,2\n"
        case .graphviz: "digraph { PaperCrane -> Sky }"
        case .plantuml: "@startuml\nPaperCrane -> Sky\n@enduml\n"
        case .html: "<!doctype html><title>PaperCrane</title><p>PaperCrane</p>"
        case .plainText: "PaperCrane\nsecond line\n"
        default: "# PaperCrane\n\n- item\n\n```\ncode\n```\n"
        }
    }

    // MARK: Encodings and sizes, for every text format.

    private static func utf16Bytes(bigEndian: Bool, _ units: [UInt16]) -> [UInt8] {
        units.flatMap { unit in
            bigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
    }

    private static func encodingCases(_ format: DocumentFormat) -> [HostileCase] {
        let sample = sample(format)
        let utf16 = Array(sample.utf16)
        var cases = [
            HostileCase(format, "empty") { [] },
            HostileCase(format, "only-whitespace") { repeated(" \t\n\r\u{3000}", 2_000) },
            HostileCase(format, "only-bom") { [0xEF, 0xBB, 0xBF] },
            HostileCase(format, "only-utf16-bom") { [0xFF, 0xFE] },
            HostileCase(format, "invalid-utf8") {
                text(sample) + [
                    0xC3, 0x28, 0xA0, 0xA1, 0xE2, 0x28, 0xA1, 0xF0, 0x28, 0x8C, 0xBC, 0xFF, 0xFE, 0xC0, 0x80,
                ]
            },
            HostileCase(format, "utf8-encoded-surrogate") { text(sample) + [0xED, 0xA0, 0x80, 0xED, 0xBF, 0xBF] },
            HostileCase(format, "utf16le-with-bom") { [0xFF, 0xFE] + utf16Bytes(bigEndian: false, utf16) },
            HostileCase(format, "utf16be-without-bom") { utf16Bytes(bigEndian: true, utf16) },
            HostileCase(format, "utf16le-unpaired-surrogates") {
                [0xFF, 0xFE] + utf16Bytes(bigEndian: false, utf16 + [0xD800, 0x41, 0xDC00, 0xDBFF])
            },
            HostileCase(format, "utf32-bom") { [0xFF, 0xFE, 0, 0, 0x41, 0, 0, 0, 0x00, 0xD8, 0, 0] },
            HostileCase(format, "nul-bytes") { text(sample).flatMap { [$0, 0] } },
            HostileCase(format, "crlf-and-cr-mixed") {
                text(sample.split(separator: "\n").enumerated().map { $1 + ["\r\n", "\r", "\n\r"][$0 % 3] }.joined())
            },
            HostileCase(format, "random-bytes") {
                var random = SeededGenerator(seed: 0x5EED)
                return (0..<8_192).map { _ in UInt8.random(in: 0...255, using: &random) }
            },
            HostileCase(format, "pdf-bytes") { BinaryInputs.onePagePDF() },
            HostileCase(format, "zip-bytes") { BinaryInputs.zip([.init("a.txt", text(sample))]) },
            HostileCase(format, "png-bytes") { BinaryInputs.png(width: 1, height: 1) },
            HostileCase(format, "control-characters") { (0..<32).map { UInt8($0) } + text(sample) + [0x7F, 0x1B] },
            HostileCase(format, "bidi-and-combining") {
                text(sample + "\u{202E}\u{2066}" + String(repeating: "e\u{0301}\u{0302}\u{0303}", count: 5_000))
            },
            HostileCase(format, "one-1mb-line") { repeated("word ", 200_000) },
            HostileCase(format, "100k-short-lines") { repeated("x\n", 100_000) },
            HostileCase(format, "one-10mb-line", long: true) { repeated("word ", 2_000_000) },
            HostileCase(format, "million-short-lines", long: true) { repeated("x\n", 1_000_000) },
            HostileCase(format, "sample-repeated-2000-times", long: true) { repeated(sample + "\n\n", 2_000) },
        ]
        // A run of every character that opens inline markup in one of the formats.
        for opener in ["*", "_", "~", "^", "=", "[", "<", "$", "\\", "{", "`", "|", "#", "(", "\"", "'", "&", ":"] {
            let name = opener.unicodeScalars.map { String($0.value, radix: 16) }.joined()
            cases.append(HostileCase(format, "run-of-u\(name)") { repeated(opener, 20_000) })
            cases.append(HostileCase(format, "run-of-u\(name)-words") { repeated(opener + "a ", 10_000) })
            cases.append(HostileCase(format, "long-run-of-u\(name)", long: true) { repeated(opener, 500_000) })
        }
        // A document cut off just before each delimiter in it.
        for (index, cut) in truncationPoints(of: sample).enumerated() {
            cases.append(HostileCase(format, "truncated-\(index)") { Array(text(sample).prefix(cut)) })
        }
        return cases
    }

    private static func truncationPoints(of sample: String) -> [Int] {
        let bytes = Array(sample.utf8)
        let delimiters = Set(Array("{}[]()<>$*_`|#=:\\\n\"".utf8))
        return Array(Set(bytes.indices.filter { delimiters.contains(bytes[$0]) })).sorted()
    }

    // MARK: Format-specific structure.

    private static func textCases(_ format: DocumentFormat) -> [HostileCase] {
        // Indentation grows with depth, so 1,000 levels already make a megabyte.
        let indentedList: @Sendable (String) -> [UInt8] = { marker in
            text((0..<1_000).map { String(repeating: " ", count: $0 * 2) + marker + " x\n" }.joined())
        }
        switch format {
        case .markdown, .quarto, .rMarkdown:
            var cases = [
                HostileCase(format, "nested-quotes") { repeated("> ", n) + text("x\n") },
                HostileCase(format, "nested-lists") { indentedList("-") },
                HostileCase(format, "nested-ordered-lists") { indentedList("1.") },
                HostileCase(format, "nested-brackets") { repeated("[", n) + text("x") + repeated("](u)", n) },
                HostileCase(format, "nested-html") { repeated("<div>", n) + text("x") + repeated("</div>", n) },
                HostileCase(format, "nested-emphasis") { repeated("*_", n) + text("x") + repeated("_*", n) },
                HostileCase(format, "nested-callouts") { repeated(":::note\n", n / 10) + repeated(":::\n", n / 10) },
                HostileCase(format, "nested-alerts") { repeated("> [!note]\n", n / 10) },
                HostileCase(format, "unterminated-fence") { text("# a\n```swift\n") + repeated("let x = 1\n", 5_000) },
                HostileCase(format, "unterminated-math") { text("$$\n") + repeated("x^2 + \\frac{1}{", 2_000) },
                HostileCase(format, "unterminated-comment") { text("<!-- ") + repeated("a\n", 5_000) },
                HostileCase(format, "self-footnote") { text("a[^1]\n\n[^1]: b[^1] [^1]\n") },
                HostileCase(format, "many-footnotes") {
                    text((0..<5_000).map { "a[^\($0)]" }.joined(separator: " ") + "\n\n")
                        + text((0..<5_000).map { "[^\($0)]: [^\(($0 + 1) % 5_000)]\n" }.joined())
                },
                HostileCase(format, "wide-table") {
                    text(
                        "|" + String(repeating: " a |", count: 2_000) + "\n|" + String(repeating: "---|", count: 2_000)
                            + "\n") + repeated("|" + String(repeating: " b |", count: 2_000) + "\n", 20)
                },
                HostileCase(format, "nested-html-tables") {
                    repeated("<table><tr><td>", 1_000) + text("x") + repeated("</td></tr></table>", 1_000)
                },
                HostileCase(format, "yaml-alias-bomb") {
                    var yaml = "---\na0: &a0 [x, x, x, x, x, x, x, x, x, x]\n"
                    for level in 1..<20 {
                        yaml +=
                            "a\(level): &a\(level) ["
                            + Array(repeating: "*a\(level - 1)", count: 10).joined(
                                separator: ", ") + "]\n"
                    }
                    return text(yaml + "title: *a19\nbibliography: *a19\n---\n# x\n")
                },
                HostileCase(format, "yaml-deep-nesting") {
                    text("---\n") + text((0..<2_000).map { String(repeating: " ", count: $0) + "a:\n" }.joined())
                        + text("---\nx\n")
                },
                HostileCase(format, "unterminated-front-matter") { text("---\ntitle: [\n") + repeated("- x\n", 5_000) },
                HostileCase(format, "many-ruby-openers") { repeated("{漢字|", n) },
                HostileCase(format, "many-reference-definitions") {
                    text((0..<5_000).map { "[\($0)]: /u\($0)\n[a][\($0)]\n" }.joined())
                },
                HostileCase(format, "huge-heading-levels") { repeated("#", 5_000) + text(" x {#a}\n[TOC]\n") },
                HostileCase(format, "citations") {
                    text("---\nbibliography: self.md\n---\n") + repeated("[@a; @b; -@c] @d ", 5_000)
                },
                HostileCase(format, "includes-self") { text("!include self.md\n{{< include self.md >}}\n") },
            ]
            if format != .markdown {
                cases += [
                    HostileCase(format, "nested-chunks") { repeated("```{r}\n", n) },
                    HostileCase(format, "nested-divs") { repeated(":::: {.columns}\n", n) + repeated("::::\n", n) },
                    HostileCase(format, "chunk-options") { text("```{r}\n") + repeated("#| a: b\n", 10_000) },
                    HostileCase(format, "inline-chunks") { repeated("`r 1+` ", n) },
                ]
            }
            return cases
        case .latex:
            return [
                HostileCase(format, "nested-itemize") {
                    repeated("\\begin{itemize}\\item ", n) + text("x") + repeated("\\end{itemize}", n)
                },
                HostileCase(format, "nested-mixed-environments") {
                    repeated("\\begin{quote}\\begin{enumerate}\\item\\begin{center}", n / 3) + text("x")
                },
                HostileCase(format, "nested-braces") { repeated("{", n) + text("x") + repeated("}", n) },
                HostileCase(format, "unclosed-braces") { text("\\begin{document}") + repeated("\\textbf{", n) },
                HostileCase(format, "begin-without-end") {
                    text("\\documentclass{article}\\begin{document}") + repeated("\\begin{figure}", n)
                },
                HostileCase(format, "nested-math") { text("$") + repeated("\\frac{", n) + text("x$") },
                HostileCase(format, "nested-left-right") { text("$") + repeated("\\left(", n) + text("x$") },
                HostileCase(format, "nested-tabular") {
                    repeated("\\begin{tabular}{c}", 1_000) + text("x") + repeated("\\end{tabular}", 1_000)
                },
                HostileCase(format, "self-expanding-def") { text("\\def\\a{\\a\\a}\\a") },
                HostileCase(format, "mutually-recursive-macros") { text("\\def\\a{\\b x}\\def\\b{\\a y}\\a") },
                HostileCase(format, "recursive-newcommand") { text("\\newcommand{\\x}{x\\x}\\x") },
                HostileCase(format, "argument-doubling") { text("\\def\\a#1{\\a{#1#1}}\\a{x}") },
                HostileCase(format, "recursive-environment") {
                    text("\\newenvironment{e}{\\begin{e}}{\\end{e}}\\begin{document}\\begin{e}x\\end{e}\\end{document}")
                },
                HostileCase(format, "loop-without-exit") {
                    text("\\begin{document}\\loop x\\iftrue\\repeat\\end{document}")
                },
                HostileCase(format, "expandafter-chain") { repeated("\\expandafter", n) + text("\\a") },
                HostileCase(format, "csname-self") {
                    text("\\expandafter\\def\\csname a\\endcsname{\\csname a\\endcsname}\\a")
                },
                HostileCase(format, "input-self") {
                    text("\\documentclass{article}\\begin{document}\\input{self}\\end{document}")
                },
                HostileCase(format, "include-self") {
                    text("\\include{self}\\input{self.tex}\\InputIfFileExists{self}{}{}")
                },
                HostileCase(format, "huge-counters") {
                    text(
                        "\\begin{document}\\setcounter{section}{99999999999999999999}\\section{a}"
                            + "\\setcounter{page}{-9223372036854775808}\\addtocounter{page}{-1}"
                            + "\\begin{enumerate}\\setcounter{enumi}{9223372036854775807}\\item a\\item b\\end{enumerate}"
                            + "\\roman{page}\\alph{section}\\fnsymbol{section}\\end{document}")
                },
                HostileCase(format, "huge-dimensions") {
                    text(
                        "\\begin{document}\\rule{1e9pt}{1e9pt}\\hspace{99999999999cm}\\vspace{-1e308pt}"
                            + "\\setlength{\\parindent}{1e400pt}\\includegraphics[width=1e9\\textwidth]{a}"
                            + "\\resizebox{1e9pt}{!}{x}\\scalebox{1e300}{x}\\end{document}")
                },
                HostileCase(format, "huge-multicolumn") {
                    text("\\begin{tabular}{ll}\\multicolumn{999999}{c}{x}\\\\\\multirow{999999}{*}{y}\\end{tabular}")
                },
                HostileCase(format, "wide-tabular-preamble") {
                    text("\\begin{tabular}{") + repeated("c|", 50_000) + text("}x\\end{tabular}")
                },
                HostileCase(format, "repeated-column-spec") { text("\\begin{tabular}{*{99999999}{c}}x\\end{tabular}") },
                HostileCase(format, "unterminated-verbatim") { text("\\begin{verbatim}") + repeated("x\n", 5_000) },
                HostileCase(format, "unterminated-verb") { text("\\verb|") + repeated("x", 50_000) },
                HostileCase(format, "huge-foreach") {
                    text(
                        "\\begin{tikzpicture}\\foreach \\i in {1,...,999999999}{\\node at (\\i,0) {x};}"
                            + "\\end{tikzpicture}")
                },
                HostileCase(format, "nested-foreach") {
                    text("\\begin{tikzpicture}") + repeated("\\foreach \\i in {1,...,100}{", 10)
                        + text("\\draw (0,0)--(1,1);") + repeated("}", 10) + text("\\end{tikzpicture}")
                },
                HostileCase(format, "deep-pgfmath") {
                    text("\\pgfmathparse{") + repeated("(", n) + text("1") + repeated(")", n) + text("}")
                },
                HostileCase(format, "recursive-counter-format") {
                    text("\\renewcommand{\\thesection}{\\thesection}\\section{a}\\ref{a}\\label{a}")
                },
                HostileCase(format, "reference-cycle") {
                    text("\\label{a}\\ref{b}\\label{b}\\ref{a}") + repeated("\\ref{a}", n)
                },
                HostileCase(format, "recursive-listing-style") {
                    text(
                        "\\lstdefinestyle{a}{style=b}\\lstdefinestyle{b}{style=a}"
                            + "\\begin{lstlisting}[style=a]\nx\n\\end{lstlisting}")
                },
                HostileCase(format, "catcode-changes") {
                    text("\\catcode`\\{=12 \\catcode`\\}=12 {x}\\catcode`\\\\=12 \\a")
                },
                HostileCase(format, "unbalanced-conditionals") {
                    repeated("\\ifnum1=1 \\else", n) + repeated("\\fi", 3)
                },
                HostileCase(format, "many-labels") {
                    text((0..<5_000).map { "\\label{l\($0)}\\ref{l\($0 + 1)}" }.joined())
                },
                HostileCase(format, "many-footnotes") { repeated("\\footnote{\\footnote{", 2_000) },
                HostileCase(format, "self-referencing-theorem") {
                    text("\\newtheorem{a}{A}[a]\\newtheorem{b}[b]{B}\\begin{a}x\\end{a}\\begin{b}y\\end{b}")
                },
                HostileCase(format, "bibliography-cycle") {
                    text("\\begin{thebibliography}{9}") + repeated("\\bibitem{a}\\cite{a}", 2_000)
                        + text("\\end{thebibliography}")
                },
                HostileCase(format, "beamer-overlays") {
                    text(
                        "\\documentclass{beamer}\\begin{document}\\begin{frame}\\only<1-99999999>{x}"
                            + "\\pause\\uncover<+->{y}\\alt<9999999999->{a}{b}") + repeated("\\pause", 5_000)
                        + text("\\end{frame}\\end{document}")
                },
            ]
        case .org:
            return [
                HostileCase(format, "deep-headings") { repeated("*", n) + text(" x\n") },
                HostileCase(format, "nested-lists") { indentedList("-") },
                HostileCase(format, "nested-quote-blocks") {
                    repeated("#+begin_quote\n", n) + text("x\n") + repeated("#+end_quote\n", n)
                },
                HostileCase(format, "nested-special-blocks") {
                    repeated("#+begin_note\n#+begin_center\n", n / 2) + text("x\n")
                },
                HostileCase(format, "unterminated-src") {
                    text("#+begin_src swift\n") + repeated("let x = 1\n", 5_000)
                },
                HostileCase(format, "nested-links") { repeated("[[", n) + text("x") + repeated("]]", n) },
                HostileCase(format, "self-footnote") { text("a[fn:1]\n\n[fn:1] b [fn:1]\n") },
                HostileCase(format, "nested-inline-footnotes") { repeated("[fn::", n) + repeated("]", n) },
                HostileCase(format, "wide-table") { repeated("|a", 20_000) + text("|\n|-\n") },
                HostileCase(format, "unterminated-drawer") { text("* a\n:PROPERTIES:\n") + repeated(":A: b\n", 5_000) },
                HostileCase(format, "nested-emphasis") { repeated("*/_+=~", n / 6) + text("x") },
                HostileCase(format, "include-self") { text("#+INCLUDE: \"self.org\"\n#+SETUPFILE: self.org\n") },
                HostileCase(format, "math-environments") { repeated("\\begin{equation}\n", n) + text("x\n") },
                HostileCase(format, "todo-keywords") {
                    text("#+TODO: " + (0..<5_000).map { "K\($0)" }.joined(separator: " ") + "\n* K1 x\n")
                },
            ]
        case .asciidoc:
            return [
                HostileCase(format, "nested-delimited-blocks") {
                    text((0..<1_000).map { String(repeating: "=", count: 4 + $0) + "\n" }.joined())
                },
                HostileCase(format, "nested-mixed-blocks") { repeated("====\n****\n____\n", n / 3) },
                HostileCase(format, "nested-lists") {
                    text((1...1_000).map { String(repeating: "*", count: $0) + " x\n" }.joined())
                },
                HostileCase(format, "nested-ordered-lists") {
                    text((1...1_000).map { String(repeating: ".", count: $0) + " x\n" }.joined())
                },
                HostileCase(format, "include-self") { text("include::self.adoc[]\n") },
                HostileCase(format, "nested-conditionals") { repeated("ifdef::a[]\n", n) + text("x\n") },
                HostileCase(format, "self-attribute") { text(":a: {a}{a}\n:b: {a}{b}\n{a}{b}\n") },
                HostileCase(format, "attribute-chain") {
                    text((0..<2_000).map { ":a\($0): {a\($0 + 1)}{a\($0 + 1)}\n" }.joined() + "{a0}\n")
                },
                HostileCase(format, "wide-table") { text("|===\n") + repeated("|a", 20_000) + text("\n|===\n") },
                HostileCase(format, "huge-colspan") { text("|===\n9999999+|a\n|b|c\n|===\n") },
                HostileCase(format, "nested-footnotes") { repeated("footnote:[", n) + repeated("]", n) },
                HostileCase(format, "cross-reference-cycle") {
                    text("[[a]]<<b>>\n[[b]]<<a>>\n") + repeated("<<a>>", n)
                },
                HostileCase(format, "unterminated-passthrough") { text("++++\n") + repeated("<p>\n", 5_000) },
            ]
        case .djot:
            return [
                HostileCase(format, "nested-braces") { repeated("{", n) + text("x") + repeated("}", n) },
                HostileCase(format, "nested-brackets") { repeated("[", n) + text("x") + repeated("](u)", n) },
                HostileCase(format, "nested-quotes") { repeated("> ", n) + text("x\n") },
                HostileCase(format, "nested-lists") { indentedList("-") },
                HostileCase(format, "nested-divs") {
                    text((0..<1_000).map { String(repeating: ":", count: 3 + $0) + " a\n" }.joined())
                },
                HostileCase(format, "nested-emphasis") { repeated("_*", n) + text("x") + repeated("*_", n) },
                HostileCase(format, "self-footnote") { text("a[^a]\n\n[^a]: b[^a]\n") },
                HostileCase(format, "attribute-run") { repeated("{#a .b c=d}", n) },
                HostileCase(format, "unterminated-raw") { text("``` =html\n") + repeated("<p>\n", 5_000) },
            ]
        case .textile:
            return [
                HostileCase(format, "nested-lists") {
                    text((1...1_000).map { String(repeating: "*", count: $0) + " x\n" }.joined())
                },
                HostileCase(format, "nested-ordered-lists") {
                    text((1...1_000).map { String(repeating: "#", count: $0) + " x\n" }.joined())
                },
                HostileCase(format, "wide-table") { repeated("|a", 20_000) + text("|\n") },
                HostileCase(format, "huge-colspan") { text("|\\99999999. a|\n|/99999999. b|\n") },
                HostileCase(format, "nested-spans") { repeated("%{color:red}", n) + repeated("%", n) },
                HostileCase(format, "nested-links") { repeated("\"a\":", n) + text("u") },
                HostileCase(format, "padding-run") { text("p") + repeated("(", n) + text(". x\n") },
                HostileCase(format, "unterminated-notextile") { text("<notextile>\n") + repeated("x\n", 5_000) },
                HostileCase(format, "extended-block") { text("bc.. ") + repeated("x\n\n", 5_000) },
                HostileCase(format, "self-footnote") { text("a[1]\n\nfn1. b[1]\n") },
            ]
        case .mediawiki:
            return [
                HostileCase(format, "nested-templates") { repeated("{{", n) + text("x") + repeated("}}", n) },
                HostileCase(format, "nested-parameters") { repeated("{{{", n) + text("x") + repeated("}}}", n) },
                HostileCase(format, "nested-links") { repeated("[[", n) + text("x") + repeated("]]", n) },
                HostileCase(format, "nested-tables") { repeated("{|\n|\n", n) + repeated("|}\n", n) },
                HostileCase(format, "nested-lists") {
                    text((1...1_000).map { String(repeating: "*", count: $0) + " x\n" }.joined())
                },
                HostileCase(format, "nested-indents") { repeated(":", n) + text("x\n") },
                HostileCase(format, "nested-refs") { repeated("<ref>", n) + text("x") + repeated("</ref>", n) },
                HostileCase(format, "nested-parser-functions") { repeated("{{#if:", n) + text("x") },
                HostileCase(format, "quote-runs") { repeated("''", n) + text("x") },
                HostileCase(format, "huge-colspan") {
                    text("{|\n| colspan=\"99999999\" rowspan=\"99999999\" | a\n|}\n")
                },
                HostileCase(format, "unterminated-nowiki") { text("<nowiki>") + repeated("[[a]]", 5_000) },
                HostileCase(format, "self-named-ref") {
                    text("<ref name=a>a<ref name=a/></ref>") + repeated("<ref name=a/>", n)
                },
            ]
        case .rst:
            return [
                HostileCase(format, "nested-block-quotes") {
                    text((0..<2_000).map { String(repeating: " ", count: $0) + "x\n\n" }.joined())
                },
                HostileCase(format, "nested-lists") { indentedList("-") },
                HostileCase(format, "nested-directives") {
                    text((0..<1_000).map { String(repeating: "   ", count: $0) + ".. note::\n\n" }.joined())
                },
                HostileCase(format, "self-substitution") { text(".. |a| replace:: |a| |a|\n\n|a|\n") },
                HostileCase(format, "substitution-chain") {
                    text((0..<2_000).map { ".. |a\($0)| replace:: |a\($0 + 1)| |a\($0 + 1)|\n" }.joined() + "\n|a0|\n")
                },
                HostileCase(format, "include-self") { text(".. include:: self.rst\n") },
                HostileCase(format, "reference-cycle") { text("a_\n\n.. _a: b_\n.. _b: a_\n") },
                HostileCase(format, "huge-grid-table") {
                    let line = "+" + String(repeating: "-+", count: 5_000) + "\n"
                    return text(line + "|" + String(repeating: "a|", count: 5_000) + "\n" + line)
                },
                HostileCase(format, "broken-grid-table") {
                    text("+---+---+\n| a | b\n+---+\n|   |   |\n+--+---+---+\n")
                },
                HostileCase(format, "many-auto-footnotes") { repeated("[#]_ ", 5_000) + repeated("\n.. [#] x", 5_000) },
                HostileCase(format, "section-levels") {
                    let marks = Array("=-~^\"'`#*+<>:._")
                    return text(marks.map { "T\n" + String(repeating: $0, count: 3) + "\n\n" }.joined())
                },
                HostileCase(format, "role-runs") { repeated(":a:`", n) },
                HostileCase(format, "huge-list-table") {
                    text(".. list-table::\n   :header-rows: 99999999\n   :widths: 1 2 3\n\n   * - a\n")
                },
            ]
        case .notebook:
            return [
                HostileCase(format, "deep-json") { repeated("[", n) + repeated("]", n) },
                HostileCase(format, "deep-metadata") {
                    text(#"{"nbformat":4,"metadata":"#) + repeated(#"{"a":"#, n) + text("1") + repeated("}", n)
                        + text(#","cells":[]}"#)
                },
                HostileCase(format, "many-cells") {
                    text(#"{"nbformat":4,"cells":["#)
                        + text(
                            Array(repeating: #"{"cell_type":"code","source":"x","outputs":[]}"#, count: 10_000)
                                .joined(separator: ",")) + text("]}")
                },
                HostileCase(format, "large-base64-output") {
                    text(
                        #"{"nbformat":4,"cells":[{"cell_type":"code","source":"","outputs":[{"output_type":"#
                            + #""display_data","data":{"image/png":""#) + repeated("iVBORw0KGgo", 100_000)
                        + text(#""}}]}]}"#)
                },
                HostileCase(format, "enormous-base64-output", long: true) {
                    text(
                        #"{"nbformat":4,"cells":[{"cell_type":"code","source":"","outputs":[{"output_type":"#
                            + #""display_data","data":{"image/png":""#) + repeated("AAAA", 5_000_000)
                        + text(#""}}]}]}"#)
                },
                HostileCase(format, "wrong-types") {
                    text(#"{"nbformat":"4","cells":{"a":1},"metadata":[],"source":7}"#)
                },
                HostileCase(format, "wrong-cell-types") {
                    text(#"{"nbformat":4,"cells":[1,"a",null,{"cell_type":7,"source":{"x":1},"outputs":"x"}]}"#)
                },
                HostileCase(format, "unpaired-escapes") {
                    text(#"{"nbformat":4,"cells":[{"cell_type":"markdown","source":"\ud800\udfff\ud800 \u0000"}]}"#)
                },
                HostileCase(format, "huge-numbers") {
                    text(#"{"nbformat":1e999,"cells":[{"cell_type":"code","execution_count":-1e999,"source":""}]}"#)
                },
                HostileCase(format, "script-outputs") {
                    text(
                        #"{"nbformat":4,"cells":[{"cell_type":"code","source":"","outputs":[{"output_type":"#
                            + #""display_data","data":{"text/html":"<script>while(1){}</script>","image/svg+xml":"#
                            + #""<svg><script>x</script><use href='#a' id='a'/></svg>"}}]}]}"#)
                },
                HostileCase(format, "deep-markdown-cell") {
                    text(#"{"nbformat":4,"cells":[{"cell_type":"markdown","source":""#) + repeated("> ", n)
                        + text(#""}]}"#)
                },
            ]
        case .csv:
            return [
                HostileCase(format, "wide-row") { repeated("a,", 100_000) + text("\n") },
                HostileCase(format, "unterminated-quote") { text("a,\"b\n") + repeated("c,d\n", 5_000) },
                HostileCase(format, "escaped-quote-run") { text("\"") + repeated("\"\"", 50_000) },
                HostileCase(format, "ragged-rows") {
                    text((0..<5_000).map { String(repeating: "a,", count: $0 % 100) + "\n" }.joined())
                },
                HostileCase(format, "nul-fields") { repeated("\u{0},\u{0}\n", 5_000) },
                HostileCase(format, "too-many-rows", long: true) { repeated("a,b\n", 60_002) },
            ]
        case .plainText:
            return [
                HostileCase(format, "deep-json", extension: "json") { repeated("[", 100_000) + repeated("]", 100_000) },
                HostileCase(format, "deep-json-objects", extension: "json") {
                    repeated("{\"a\":", n) + text("1") + repeated("}", n)
                },
                HostileCase(format, "unterminated-json-string", extension: "json") {
                    text("{\"a\": \"") + repeated("\\\"", 50_000)
                },
                HostileCase(format, "json-lines", extension: "jsonl") {
                    repeated("{\"a\":[1,2,{\"b\":null}]}\n", 10_000)
                },
                HostileCase(format, "deep-xml", extension: "xml") { repeated("<a>", n) + repeated("</a>", n) },
                HostileCase(format, "unterminated-xml-comment", extension: "xml") { text("<!--") + repeated("<a>", n) },
                HostileCase(format, "xml-entities", extension: "xml") {
                    text("<!DOCTYPE a [<!ENTITY a \"&a;&a;\">]><a>&a;</a><![CDATA[") + repeated("]]", 5_000)
                },
                HostileCase(format, "yaml-alias-bomb", extension: "yaml") {
                    var yaml = "a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n"
                    for level in 1..<20 {
                        yaml +=
                            "a\(level): &a\(level) ["
                            + Array(repeating: "*a\(level - 1)", count: 10).joined(
                                separator: ", ") + "]\n"
                    }
                    return text(yaml)
                },
                HostileCase(format, "yaml-deep-indent", extension: "yaml") {
                    text((0..<2_000).map { String(repeating: " ", count: $0) + "- a: &x\n" }.joined())
                },
                HostileCase(format, "toml-tables", extension: "toml") { repeated("[[a.b.c]]\nx = \"\"\"", 5_000) },
                HostileCase(format, "log", extension: "log") { repeated("2026-01-01 ERROR \u{1B}[31m x\n", 10_000) },
                HostileCase(format, "huge-json", extension: "json", long: true) {
                    repeated("{\"a\":[1,2,3]},", 1_000_000)
                },
            ]
        case .graphviz:
            return [
                HostileCase(format, "ten-thousand-nodes") {
                    text("digraph {" + (0..<n).map { "n\($0) -> n\(($0 + 1) % n);" }.joined() + "}")
                },
                HostileCase(format, "nested-subgraphs") {
                    text("digraph {") + repeated("subgraph { ", n) + repeated("}", n + 1)
                },
                HostileCase(format, "nested-braces") { repeated("{", n) },
                HostileCase(format, "nested-html-labels") {
                    text("digraph { a [label=") + repeated("<", n) + text("x") + repeated(">", n) + text("] }")
                },
                HostileCase(format, "unterminated-string") { text("digraph { a [label=\"") + repeated("x", 50_000) },
                HostileCase(format, "unterminated-comment") { text("digraph { /*") + repeated("a -> b;", 5_000) },
                HostileCase(format, "complete-graph") {
                    text("graph {" + (0..<200).flatMap { a in (0..<200).map { b in "a\(a) -- a\(b);" } }.joined() + "}")
                },
                HostileCase(format, "huge-attributes") {
                    text("digraph { a [width=1e300, height=-1e300, fontsize=99999999] }")
                },
            ]
        case .plantuml:
            return [
                HostileCase(format, "ten-thousand-nodes") {
                    text("@startuml\n" + (0..<n).map { "A\($0) -> A\(($0 + 1) % n)\n" }.joined() + "@enduml\n")
                },
                HostileCase(format, "include-self") {
                    text("@startuml\n!include self.puml\n!include_once self.puml\n@enduml\n")
                },
                HostileCase(format, "nested-ifs") {
                    text("@startuml\nstart\n") + repeated("if (a) then\n", n) + repeated("endif\n", n)
                        + text("@enduml\n")
                },
                HostileCase(format, "nested-packages") {
                    text("@startuml\n") + repeated("package a {\n", n) + repeated("}\n", n) + text("@enduml\n")
                },
                HostileCase(format, "starts-without-end") { repeated("@startuml\n", n) },
                HostileCase(format, "recursive-define") {
                    text("@startuml\n!define A A A\n!define B A B\nB\n@enduml\n")
                },
                HostileCase(format, "recursive-procedure") {
                    text("@startuml\n!procedure $a()\n$a()\n!endprocedure\n$a()\n@enduml\n")
                },
                HostileCase(format, "deep-mindmap") {
                    text(
                        "@startmindmap\n" + (1...1_000).map { String(repeating: "*", count: $0) + " x\n" }.joined()
                            + "@endmindmap\n")
                },
                HostileCase(format, "nested-braces") {
                    text("@startuml\nclass a ") + repeated("{", n) + text("\n@enduml\n")
                },
            ]
        case .html:
            return [
                HostileCase(format, "deep-divs") { repeated("<div>", 100_000) + text("<title>x</title>") },
                HostileCase(format, "unterminated-comment") { text("<!--") + repeated("<title>a</title>", 5_000) },
                HostileCase(format, "unterminated-title") { text("<title>") + repeated("a", 100_000) },
                HostileCase(format, "unterminated-script") { text("<script>") + repeated("<title>", 5_000) },
                HostileCase(format, "many-titles") { repeated("<title>a</title><h1>b</h1>", 10_000) },
                HostileCase(format, "attribute-runs") { text("<div ") + repeated("a=\"", 50_000) },
                HostileCase(format, "entity-runs") { repeated("&#x110000;&#99999999999;&", 10_000) },
                HostileCase(format, "nested-headings") { repeated("<h1><h2><h3>", 5_000) },
            ]
        default:
            return []
        }
    }

    // MARK: Word documents.

    private static let contentTypes = text(
        #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="xml" ContentType="application/xml"/></Types>"#)
    private static let wordNamespace = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#

    package static func docx(body: String, extra: [BinaryInputs.ZipMember] = []) -> [UInt8] {
        BinaryInputs.zip(
            [
                .init("[Content_Types].xml", contentTypes),
                .init("word/document.xml", text("<w:document \(wordNamespace)><w:body>\(body)</w:body></w:document>")),
            ] + extra)
    }

    private static let paragraph = "<w:p><w:r><w:t>PaperCrane</w:t></w:r></w:p>"

    private static var docxCases: [HostileCase] {
        return [
            HostileCase(.docx, "zip-without-document") {
                BinaryInputs.zip([.init("[Content_Types].xml", contentTypes)])
            },
            HostileCase(.docx, "empty-zip") { BinaryInputs.zip([]) },
            HostileCase(.docx, "valid-paragraph") { docx(body: paragraph) },
            HostileCase(.docx, "document-not-xml") {
                BinaryInputs.zip([.init("word/document.xml", BinaryInputs.onePagePDF())])
            },
            HostileCase(.docx, "deep-xml") {
                docx(body: String(repeating: "<w:sdt><w:sdtContent>", count: n) + paragraph)
            },
            HostileCase(.docx, "deep-tables") {
                docx(
                    body: String(repeating: "<w:tbl><w:tr><w:tc>", count: 1_000) + paragraph
                        + String(repeating: "</w:tc></w:tr></w:tbl>", count: 1_000))
            },
            HostileCase(.docx, "huge-grid-span") {
                docx(
                    body: #"<w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="2147483647"/><w:vMerge w:val="restart"/>"#
                        + #"</w:tcPr>\#(paragraph)</w:tc></w:tr><w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr></w:tc></w:tr>"#
                        + "</w:tbl>")
            },
            HostileCase(.docx, "huge-numbering-level") {
                docx(
                    body: #"<w:p><w:pPr><w:numPr><w:ilvl w:val="99999999"/><w:numId w:val="1"/></w:numPr></w:pPr>"#
                        + "<w:r><w:t>x</w:t></w:r></w:p>",
                    extra: [
                        .init(
                            "word/numbering.xml",
                            text(
                                #"<w:numbering \#(wordNamespace)><w:abstractNum w:abstractNumId="0">"#
                                    + #"<w:lvl w:ilvl="99999999"><w:start w:val="-9223372036854775808"/>"#
                                    + #"<w:lvlText w:val="%1.%2.%3.%4.%5.%6.%7.%8.%9.%99999"/></w:lvl></w:abstractNum>"#
                                    + #"<w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>"#
                                    + #"<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>"#))
                    ])
            },
            HostileCase(.docx, "style-cycle") {
                docx(
                    body: #"<w:p><w:pPr><w:pStyle w:val="a"/></w:pPr><w:r><w:t>x</w:t></w:r></w:p>"#,
                    extra: [
                        .init(
                            "word/styles.xml",
                            text(
                                #"<w:styles \#(wordNamespace)><w:style w:styleId="a"><w:basedOn w:val="b"/></w:style>"#
                                    + #"<w:style w:styleId="b"><w:basedOn w:val="a"/></w:style></w:styles>"#))
                    ])
            },
            HostileCase(.docx, "huge-font-size") {
                docx(body: #"<w:p><w:r><w:rPr><w:sz w:val="999999999999"/></w:rPr><w:t>x</w:t></w:r></w:p>"#)
            },
            HostileCase(.docx, "member-size-lies") {
                BinaryInputs.zip([
                    .init("[Content_Types].xml", contentTypes),
                    .init("word/document.xml", text(paragraph), declaredSize: 0xFFFF_FFF0),
                ])
            },
            HostileCase(.docx, "encrypted-member") {
                BinaryInputs.zip([.init("word/document.xml", text(paragraph), encrypted: true)])
            },
            HostileCase(.docx, "broken-checksum") {
                BinaryInputs.zip([.init("word/document.xml", text(paragraph), breaksChecksum: true)])
            },
            HostileCase(.docx, "dot-dot-member-names") {
                BinaryInputs.zip([
                    .init("../../word/document.xml", text(paragraph)), .init("/word/document.xml", text(paragraph)),
                    .init("word/../word/document.xml", text(paragraph)),
                ])
            },
            HostileCase(.docx, "high-compression-ratio") {
                BinaryInputs.zip([
                    .init(
                        "word/document.xml",
                        Array(text("<w:document \(wordNamespace)><w:body>"))
                            + [UInt8](repeating: 0x20, count: 8_000_000)
                            + text(paragraph + "</w:body></w:document>"), deflates: true)
                ])
            },
            HostileCase(.docx, "zip-bomb", long: true) {
                BinaryInputs.zip([
                    .init("word/document.xml", [UInt8](repeating: 0x20, count: 200_000_000), deflates: true)
                ])
            },
            HostileCase(.docx, "archive-inside-archive") {
                BinaryInputs.zip([.init("word/document.xml", docx(body: paragraph))])
            },
            HostileCase(.docx, "many-entries") {
                BinaryInputs.zip(
                    (0..<20_000).map { .init("word/media/\($0).xml", []) } + [
                        .init("word/document.xml", text(paragraph))
                    ])
            },
            HostileCase(.docx, "hundred-thousand-entries", long: true) {
                BinaryInputs.zip((0..<100_000).map { .init("\($0)", []) })
            },
            HostileCase(.docx, "missing-relationships") {
                docx(
                    body: #"<w:p><w:r><w:drawing><a:blip xmlns:a="a" r:embed="rId9" xmlns:r="r"/></w:drawing>"#
                        + #"<w:footnoteReference w:id="99999999"/></w:r></w:p>"#,
                    extra: [
                        .init(
                            "word/_rels/document.xml.rels",
                            text(
                                "<Relationships><Relationship Id=\"rId9\" Target=\"../../../../etc/hosts\"/></Relationships>"
                            ))
                    ])
            },
            HostileCase(.docx, "doctype-entities") {
                BinaryInputs.zip([
                    .init(
                        "word/document.xml",
                        text(
                            "<!DOCTYPE a [<!ENTITY a \"&a;&a;\"><!ENTITY b SYSTEM \"file:///etc/hosts\">]>"
                                + "<w:document \(wordNamespace)><w:body><w:p><w:r><w:t>&a;&b;</w:t></w:r></w:p>"
                                + "</w:body></w:document>"))
                ])
            },
            HostileCase(.docx, "truncated-archive") { Array(docx(body: paragraph).dropLast(30)) },
            HostileCase(.docx, "comment-length-lies") {
                var archive = docx(body: paragraph)
                archive[archive.count - 2] = 0xFF
                archive[archive.count - 1] = 0xFF
                return archive
            },
        ]
    }

    // MARK: Archives of images.

    private static var zipCases: [HostileCase] {
        let image = BinaryInputs.png(width: 1, height: 1)
        return [
            HostileCase(.zipArchive, "empty-archive") { BinaryInputs.zip([]) },
            HostileCase(.zipArchive, "one-image") { BinaryInputs.zip([.init("paper.png", image)]) },
            HostileCase(.zipArchive, "size-lies") {
                BinaryInputs.zip([
                    .init("a.png", image, declaredSize: 0xFFFF_FFF0), .init("b.png", image, declaredSize: 0),
                ])
            },
            HostileCase(.zipArchive, "deflated-size-lies") {
                BinaryInputs.zip([.init("a.png", image, deflates: true, declaredSize: 0x7FFF_FFFF)])
            },
            HostileCase(.zipArchive, "dot-dot-and-absolute-names") {
                BinaryInputs.zip([
                    .init("../../escape.png", image), .init("/tmp/absolute.png", image), .init("a/../../b.png", image),
                    .init("C:\\windows.png", image), .init("nul\u{0}.png", image),
                ])
            },
            HostileCase(.zipArchive, "encrypted-members") {
                BinaryInputs.zip([.init("a.png", image, encrypted: true)])
            },
            HostileCase(.zipArchive, "broken-checksum") {
                BinaryInputs.zip([.init("a.png", image, breaksChecksum: true)])
            },
            HostileCase(.zipArchive, "high-compression-ratio") {
                BinaryInputs.zip([.init("a.png", image + [UInt8](repeating: 0, count: 8_000_000), deflates: true)])
            },
            HostileCase(.zipArchive, "zip-bomb", long: true) {
                BinaryInputs.zip(
                    (0..<4).map {
                        .init("\($0).png", image + [UInt8](repeating: 0, count: 250_000_000), deflates: true)
                    })
            },
            HostileCase(.zipArchive, "archive-inside-archive") {
                BinaryInputs.zip([.init("inner.zip", BinaryInputs.zip([.init("a.png", image)])), .init("b.png", image)])
            },
            HostileCase(.zipArchive, "many-entries") {
                BinaryInputs.zip((0..<20_000).map { .init("\($0).png", []) })
            },
            HostileCase(.zipArchive, "hundred-thousand-entries", long: true) {
                BinaryInputs.zip((0..<100_000).map { .init("\($0).png", image) })
            },
            HostileCase(.zipArchive, "huge-image-header") {
                BinaryInputs.zip([.init("a.png", BinaryInputs.png(width: 65_535, height: 65_535))])
            },
            HostileCase(.zipArchive, "truncated-directory") {
                Array(BinaryInputs.zip([.init("a.png", image)]).dropLast(10))
            },
            HostileCase(.zipArchive, "directory-offset-beyond-end") {
                var archive = BinaryInputs.zip([.init("a.png", image)])
                archive.replaceSubrange((archive.count - 6)..<(archive.count - 2), with: [0xF0, 0xFF, 0xFF, 0x7F])
                return archive
            },
            HostileCase(.zipArchive, "directory-count-lies") {
                var archive = BinaryInputs.zip([.init("a.png", image)])
                archive.replaceSubrange((archive.count - 12)..<(archive.count - 8), with: [0xFF, 0xFF, 0xFF, 0xFF])
                return archive
            },
            HostileCase(.zipArchive, "zip64-marker") {
                var archive = BinaryInputs.zip([.init("a.png", image, declaredSize: 0xFFFF_FFFF)])
                archive.replaceSubrange((archive.count - 6)..<(archive.count - 2), with: [0xFF, 0xFF, 0xFF, 0xFF])
                return archive
            },
            HostileCase(.zipArchive, "long-member-name") {
                BinaryInputs.zip([.init(String(repeating: "a/", count: 30_000) + "a.png", image)])
            },
        ]
    }

    // MARK: PDF.

    private static var pdfCases: [HostileCase] {
        let valid = BinaryInputs.onePagePDF()
        var cases = [
            HostileCase(.pdf, "valid-page") { valid },
            HostileCase(.pdf, "empty") { [] },
            HostileCase(.pdf, "header-only") { text("%PDF-1.7\n") },
            HostileCase(.pdf, "zero-pages") {
                BinaryInputs.pdf(objects: ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"])
            },
            HostileCase(.pdf, "count-lies") {
                BinaryInputs.pdf(objects: [
                    "<< /Type /Catalog /Pages 2 0 R >>",
                    "<< /Type /Pages /Kids [3 0 R] /Count 2147483647 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>",
                ])
            },
            HostileCase(.pdf, "enormous-page-box") { BinaryInputs.onePagePDF(mediaBox: "0 0 1e9 1e9") },
            HostileCase(.pdf, "largest-page-box") { BinaryInputs.onePagePDF(mediaBox: "-14400 -14400 14400 14400") },
            HostileCase(.pdf, "zero-page-box") { BinaryInputs.onePagePDF(mediaBox: "0 0 0 0") },
            HostileCase(.pdf, "negative-page-box") { BinaryInputs.onePagePDF(mediaBox: "595 842 0 0") },
            HostileCase(.pdf, "non-numeric-page-box") { BinaryInputs.onePagePDF(mediaBox: "/a (b) <c> [d]") },
            HostileCase(.pdf, "page-tree-loop") {
                BinaryInputs.pdf(objects: [
                    "<< /Type /Catalog /Pages 2 0 R >>",
                    "<< /Type /Pages /Kids [2 0 R 3 0 R] /Count 2 >>",
                    "<< /Type /Pages /Parent 2 0 R /Kids [3 0 R 2 0 R] /Count 2 >>",
                ])
            },
            HostileCase(.pdf, "deep-page-tree") {
                let levels = 2_000
                var objects = ["<< /Type /Catalog /Pages 2 0 R >>"]
                for level in 0..<levels {
                    objects.append("<< /Type /Pages /Kids [\(level + 3) 0 R] /Count 1 >>")
                }
                objects.append("<< /Type /Page /MediaBox [0 0 595 842] >>")
                return BinaryInputs.pdf(objects: objects)
            },
            HostileCase(.pdf, "stream-length-lies") {
                BinaryInputs.pdf(objects: [
                    "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>",
                    "<< /Length 2147483647 /Filter /FlateDecode >>\nstream\nxyz\nendstream",
                ])
            },
            HostileCase(.pdf, "broken-cross-references") {
                var bytes = valid
                if let range = text(String(decoding: valid, as: UTF8.self)).firstRange(of: text("xref")) {
                    bytes.replaceSubrange(range, with: text("xrfe"))
                }
                return bytes
            },
            HostileCase(.pdf, "deep-outline") {
                var objects = BinaryInputs.onePagePDFObjects()
                objects[0] = "<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>"
                for level in 0..<2_000 {
                    objects.append("<< /Title (L\(level)) /First \(level + 7) 0 R /Last \(level + 7) 0 R /Count 1 >>")
                }
                objects.append("<< /Title (Leaf) /Dest [3 0 R /Fit] >>")
                return BinaryInputs.pdf(objects: objects)
            },
            HostileCase(.pdf, "outline-cycle") {
                var objects = BinaryInputs.onePagePDFObjects()
                objects[0] = "<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>"
                objects.append("<< /First 7 0 R /Last 7 0 R /Count 1 >>")
                objects.append("<< /Title (a) /Next 7 0 R /Prev 7 0 R /First 7 0 R /Parent 6 0 R >>")
                return BinaryInputs.pdf(objects: objects)
            },
            HostileCase(.pdf, "password-protected") { passwordPDF() },
            HostileCase(.pdf, "random-bytes-with-header") {
                var random = SeededGenerator(seed: 0xBADF)
                return text("%PDF-1.4\n") + (0..<16_384).map { _ in UInt8.random(in: 0...255, using: &random) }
            },
            HostileCase(.pdf, "markdown-named-pdf") { text("# not a pdf\n") },
        ]
        let bytes = valid
        for cut in stride(from: 9, to: bytes.count, by: max(1, bytes.count / 24)) {
            cases.append(HostileCase(.pdf, "truncated-at-\(cut)") { Array(bytes.prefix(cut)) })
        }
        return cases
    }

    private static func passwordPDF() -> [UInt8] {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let options = [kCGPDFContextUserPassword: "a", kCGPDFContextOwnerPassword: "b"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &box, options)
        else { return [] }
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 10, height: 10))
        context.endPDFPage()
        context.closePDF()
        return Array(data as Data)
    }

    // MARK: Images.

    private static var imageCases: [HostileCase] {
        let valid = BinaryInputs.png(width: 1, height: 1)
        var cases = [
            HostileCase(.image, "valid-png") { valid },
            HostileCase(.image, "empty") { [] },
            HostileCase(.image, "huge-png-header") { BinaryInputs.png(width: 65_535, height: 65_535) },
            HostileCase(.image, "largest-png-header") { BinaryInputs.png(width: 0x7FFF_FFFF, height: 0x7FFF_FFFF) },
            HostileCase(.image, "zero-png-size") { BinaryInputs.png(width: 0, height: 0) },
            HostileCase(.image, "thin-png") { BinaryInputs.png(width: 1, height: 1_000_000) },
            HostileCase(.image, "broken-png-checksum") { BinaryInputs.png(width: 1, height: 1, breaksChecksum: true) },
            HostileCase(.image, "short-png-data") {
                BinaryInputs.png(width: 4_000, height: 4_000, idat: [0x78, 0x9C, 0x03])
            },
            HostileCase(.image, "jpeg-truncated") { Array(encoded(UTType.jpeg.identifier, frames: 1).prefix(200)) },
            HostileCase(.image, "jpeg-header-only") { [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + text("JFIF") },
            HostileCase(.image, "gif-with-thousands-of-frames") { encoded(UTType.gif.identifier, frames: 3_000) },
            HostileCase(.image, "tiff-truncated") { Array(encoded(UTType.tiff.identifier, frames: 1).prefix(64)) },
            HostileCase(.image, "bmp-huge-header") {
                [
                    0x42, 0x4D, 0x36, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 0x28, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF,
                    0, 0, 1,
                    0, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                ]
            },
            HostileCase(.image, "webp-garbage") {
                text("RIFF") + [0xFF, 0xFF, 0xFF, 0x7F] + text("WEBPVP8 ") + [0xFF, 0, 0, 0]
            },
            HostileCase(.image, "svg-script-and-foreign-object", extension: "svg") {
                text(
                    #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><script>while(1){}</script>"#
                        + #"<foreignObject width="100" height="100"><div xmlns="http://www.w3.org/1999/xhtml">x</div>"#
                        + #"</foreignObject><image href="file:///nonexistent/a.png"/><rect width="10" height="10"/></svg>"#
                )
            },
            HostileCase(.image, "svg-self-use", extension: "svg") {
                text(
                    #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" "#
                        + ##"width="100" height="100"><g id="a"><use xlink:href="#a"/><use href="#b"/></g>"##
                        + ##"<g id="b"><use href="#a"/></g></svg>"##)
            },
            HostileCase(.image, "svg-use-fan-out", extension: "svg") {
                var svg =
                    #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><defs>"#
                    + #"<rect id="l0" width="1" height="1"/>"#
                for level in 1..<12 {
                    svg +=
                        "<g id=\"l\(level)\">" + String(repeating: "<use href=\"#l\(level - 1)\"/>", count: 10) + "</g>"
                }
                return text(svg + "</defs><use href=\"#l11\"/></svg>")
            },
            HostileCase(.image, "svg-deep-groups", extension: "svg") {
                text(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">"#) + repeated("<g>", depth)
                    + repeated("</g>", depth) + text("</svg>")
            },
            HostileCase(.image, "svg-enormous-size", extension: "svg") {
                text(
                    #"<svg xmlns="http://www.w3.org/2000/svg" width="1e9" height="1e9"><rect width="1e9" height="1e9"/></svg>"#
                )
            },
            HostileCase(.image, "svg-external-references", extension: "svg") {
                text(
                    #"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a SYSTEM "file:///etc/hosts">]>"#
                        + #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&a;</text>"#
                        + #"<image href="../../../../etc/hosts"/></svg>"#)
            },
            HostileCase(.image, "pdf-named-png") { BinaryInputs.onePagePDF() },
        ]
        for cut in [8, 16, 29, 33, 40, valid.count - 12, valid.count - 4] {
            cases.append(HostileCase(.image, "png-truncated-at-\(cut)") { Array(valid.prefix(cut)) })
        }
        return cases
    }

    /// An image written by ImageIO, for formats whose structure is too involved to write by hand.
    package static func encoded(_ type: String, frames: Int) -> [UInt8] {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, frames, nil),
            let context = CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        for frame in 0..<frames {
            context.setFillColor(red: CGFloat(frame % 2), green: 0.5, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            guard let image = context.makeImage() else { return [] }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return [] }
        return Array(data as Data)
    }
}

extension BinaryInputs {
    package static func onePagePDFObjects() -> [String] {
        let content = "BT /F1 24 Tf 72 720 Td (PaperCrane) Tj ET"
        return [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
    }
}
