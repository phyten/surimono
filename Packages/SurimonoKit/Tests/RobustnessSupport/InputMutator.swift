import Foundation
import SurimonoFormats

/// Deterministic edits of a seed document. Besides blind byte edits it knows each format's delimiters, because
/// readers mostly fail where an opener is repeated, dropped or left without its closer, and random bytes rarely
/// form one.
package enum InputMutator {
    /// Mutations stay small enough that thousands of them fit in a run; the hand-written cases cover huge inputs.
    package static let maximumSize = 1 << 20

    private static let interestingBytes: [UInt8] = [
        0x00, 0xFF, 0xFE, 0x7F, 0x80, 0xC0, 0xE0, 0xED, 0xA0, 0xF0, 0xF8, 0x0A, 0x0D, 0x09, 0x20, 0x5C, 0x7B, 0x7D,
        0x5B, 0x5D, 0x3C, 0x3E, 0x22, 0x27, 0x24, 0x2A, 0x5F, 0x60, 0x7C, 0x23, 0x25, 0x26, 0x3A, 0x3D,
    ]
    private static let numbers = [
        "0", "-1", "99999999999999999999", "2147483648", "9223372036854775807", "-9223372036854775808", "1e308",
        "1e-308", "NaN", "65535", "4294967296", "0.0000001",
    ]

    package static func mutate(
        _ input: [UInt8], splice other: [UInt8], tokens: [String], using random: inout SeededGenerator
    ) -> (bytes: [UInt8], steps: [String]) {
        var bytes = input
        var steps: [String] = []
        let tokenBytes = tokens.map { Array($0.utf8) }
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            steps.append(step(&bytes, other: other, tokens: tokenBytes, using: &random))
            if bytes.count > maximumSize { bytes.removeLast(bytes.count - maximumSize) }
        }
        return (bytes, steps)
    }

    private static func position(in bytes: [UInt8], using random: inout SeededGenerator) -> Int {
        Int.random(in: 0...bytes.count, using: &random)
    }

    // A run length that is usually short but sometimes large enough to reach nesting and quadratic limits.
    private static func runLength(using random: inout SeededGenerator) -> Int {
        1 << Int.random(in: 0...13, using: &random)
    }

    private static func step(
        _ bytes: inout [UInt8], other: [UInt8], tokens: [[UInt8]], using random: inout SeededGenerator
    ) -> String {
        let choice = Int.random(in: 0..<12, using: &random)
        switch choice {
        case 0 where !bytes.isEmpty:
            let count = Int.random(in: 1...8, using: &random)
            for _ in 0..<count {
                let index = Int.random(in: 0..<bytes.count, using: &random)
                bytes[index] ^= 1 << UInt8.random(in: 0...7, using: &random)
            }
            return "flip \(count) bits"
        case 1:
            let at = position(in: bytes, using: &random)
            let inserted = (0..<Int.random(in: 1...16, using: &random)).map { _ in
                Bool.random(using: &random)
                    ? interestingBytes.randomElement(using: &random) ?? 0 : UInt8.random(in: 0...255, using: &random)
            }
            bytes.insert(contentsOf: inserted, at: at)
            return "insert \(inserted.count) bytes at \(at)"
        case 2 where !bytes.isEmpty:
            let at = Int.random(in: 0..<bytes.count, using: &random)
            let count = min(bytes.count - at, Int.random(in: 1...256, using: &random))
            bytes.removeSubrange(at..<(at + count))
            return "delete \(count) bytes at \(at)"
        case 3 where !bytes.isEmpty:
            let start = Int.random(in: 0..<bytes.count, using: &random)
            let chunk = Array(bytes[start..<min(bytes.count, start + Int.random(in: 1...256, using: &random))])
            let times = min(runLength(using: &random), maximumSize / max(1, chunk.count))
            let at = position(in: bytes, using: &random)
            bytes.insert(contentsOf: Array([[UInt8]](repeating: chunk, count: times).joined()), at: at)
            return "duplicate \(chunk.count) bytes \(times) times at \(at)"
        case 4 where !bytes.isEmpty:
            let at = Int.random(in: 0..<bytes.count, using: &random)
            bytes.removeLast(bytes.count - at)
            return "truncate at \(at)"
        case 5 where !other.isEmpty:
            let keep = position(in: bytes, using: &random)
            let from = Int.random(in: 0..<other.count, using: &random)
            bytes = Array(bytes[..<keep]) + other[from...]
            return "splice at \(keep) from \(from)"
        case 6 where !tokens.isEmpty:
            let token = tokens.randomElement(using: &random) ?? []
            let times = min(runLength(using: &random), maximumSize / max(1, token.count))
            let at = position(in: bytes, using: &random)
            bytes.insert(contentsOf: Array([[UInt8]](repeating: token, count: times).joined()), at: at)
            return "repeat \(String(decoding: token, as: UTF8.self).debugDescription) \(times) times at \(at)"
        case 7 where !tokens.isEmpty:
            let token = tokens.randomElement(using: &random) ?? []
            guard let range = occurrence(of: token, in: bytes, using: &random) else { return "no token to remove" }
            bytes.removeSubrange(range)
            return "remove \(String(decoding: token, as: UTF8.self).debugDescription) at \(range.lowerBound)"
        case 8 where !tokens.isEmpty:
            let token = tokens.randomElement(using: &random) ?? []
            let at = position(in: bytes, using: &random)
            bytes.insert(contentsOf: token, at: at)
            return "insert \(String(decoding: token, as: UTF8.self).debugDescription) at \(at)"
        case 9 where tokens.count > 1:
            let token = tokens.randomElement(using: &random) ?? []
            let replacement = tokens.randomElement(using: &random) ?? []
            guard let range = occurrence(of: token, in: bytes, using: &random) else { return "no token to swap" }
            bytes.replaceSubrange(range, with: replacement)
            return "swap \(String(decoding: token, as: UTF8.self).debugDescription) at \(range.lowerBound)"
        case 10:
            let number = Array((numbers.randomElement(using: &random) ?? "0").utf8)
            let start = position(in: bytes, using: &random)
            guard let digits = bytes[start...].firstIndex(where: { (0x30...0x39).contains($0) }) else {
                bytes.insert(contentsOf: number, at: start)
                return "insert number at \(start)"
            }
            let end = bytes[digits...].firstIndex(where: { !(0x30...0x39).contains($0) }) ?? bytes.count
            bytes.replaceSubrange(digits..<end, with: number)
            return "replace number at \(digits)"
        default:
            // Duplicating the whole input nests or repeats every construct it has at once.
            guard !bytes.isEmpty, bytes.count * 2 <= maximumSize else { return "no change" }
            let at = position(in: bytes, using: &random)
            bytes.insert(contentsOf: bytes, at: at)
            return "duplicate input at \(at)"
        }
    }

    private static func occurrence(of token: [UInt8], in bytes: [UInt8], using random: inout SeededGenerator)
        -> Range<Int>?
    {
        guard !token.isEmpty, bytes.count >= token.count else { return nil }
        let last = bytes.count - token.count
        let start = Int.random(in: 0...last, using: &random)
        for offset in 0...last {
            let index = (start + offset) % (last + 1)
            if bytes[index] == token[0], Array(bytes[index..<(index + token.count)]) == token {
                return index..<(index + token.count)
            }
        }
        return nil
    }
}

/// The delimiters each format's reader balances or matches.
package enum FormatTokens {
    package static func tokens(for format: DocumentFormat) -> [String] {
        let markdown = [
            "```", "~~~", "*", "**", "_", "__", "[", "]", "](", ")", "<", ">", "> ", "- ", "1. ", "|", "$", "$$", "==",
            "^", "~", "~~", "{", "}", ":::", "[^1]", "[^1]: ", "\n", "\n\n", "    ", "<div>", "</div>", "<!--", "-->",
            "`", "\\", "---\n", "{#id}", "[TOC]", ":smile:", "{漢字|かんじ}", "> [!note]", "\\(", "\\[", "@key",
            "[@key]", "![a](", "\t", "#", "######",
        ]
        switch format {
        case .markdown: return markdown
        case .quarto, .rMarkdown:
            return markdown + [
                "```{r}", "```{python}", "::: {.callout-note}", ":::: {.columns}", "{{< pagebreak >}}", "`r 1+1`",
                "#| echo: false\n", "---\ntitle: a\n---\n",
            ]
        case .latex:
            return [
                "{", "}", "[", "]", "$", "$$", "\\(", "\\)", "\\[", "\\]", "\\begin{itemize}", "\\end{itemize}",
                "\\item ", "\\begin{enumerate}", "\\end{enumerate}", "\\begin{tabular}{ll}", "\\end{tabular}", "&",
                "\\\\", "\\def\\a{\\a}", "\\newcommand{\\x}[1]{#1#1}", "\\x{", "\\input{self}", "%", "\\verb|",
                "\\begin{verbatim}", "\\end{verbatim}", "\\end{document}", "\\begin{document}", "\\section{", "\\left(",
                "\\right)", "\\multicolumn{999999}{c}{", "\\frac{", "\\begin{equation}", "\\end{equation}", "#1",
                "\\expandafter", "\\csname", "\\endcsname", "\\ifnum", "\\fi", "\\else", "\\loop", "\\repeat",
                "\\label{a}", "\\ref{a}", "\\footnote{", "\\begin{tikzpicture}", "\\end{tikzpicture}",
                "\\foreach \\i in {1,...,99999}", "\\setcounter{page}{", "\\rule{1e9pt}{", "\\catcode`\\{=12 ",
                "\\begin{lstlisting}[style=a]", "\\lstdefinestyle{a}{style=a}", "\\newenvironment{e}{\\begin{e}}{}",
                "\\begin{e}", "\\documentclass{article}", "\\begin{thebibliography}{9}", "\\bibitem{a}", "\\cite{a}",
            ]
        case .org:
            return [
                "* ", "** ", "#+begin_src", "#+end_src", "#+begin_quote", "#+end_quote", "#+begin_note",
                "#+end_note", "- ", "1. ", "[[", "]]", "][", "[fn:1]", "[fn:1] ", "*", "/", "=", "~", "+", "_", "$",
                "\\(", "\\[", "|", "|-", ":PROPERTIES:", ":END:", "#+TITLE: ", "#+CAPTION: ", "[ ] ", "[X] ",
                "SCHEDULED: <2026-01-01>", "\\begin{equation}", "\\end{equation}", "#+TODO: A | B", "\n", "  ",
            ]
        case .asciidoc:
            return [
                "====", "----", "....", "****", "|===", "++++", "____", "--", "* ", "** ", ". ", "[[", "]]", "<<", ">>",
                "{", "}", "ifdef::a[]", "endif::[]", "include::self.adoc[]", "+", "`", "*", "_", ":a: ", "{a}",
                "footnote:[", "]", "image::", "link:", "[source,swift]", "|", "a|", "\n", "== ", "=",
            ]
        case .djot:
            return [
                "{", "}", "[", "]", "(", ")", "*", "_", "`", ":::", "> ", "- ", "1. ", "^", "~", "{=", "=}", "$`",
                "$$`", "|", "[^a]", "[^a]: ", "{#a}", "{.c}", "``` =html", "```", "\n", "  ", "![", "<", ">",
            ]
        case .textile:
            return [
                "h1. ", "bq. ", "bc. ", "bc.. ", "p. ", "* ", "** ", "# ", "|", "|_. ", "*", "_", "\"", "\":", "[", "]",
                "{", "}", "(", ")", "<pre>", "</pre>", "notextile. ", "<notextile>", "==", "fn1. ", "[1]", "%", "@",
                "^", "~", "-", "+", "!", "\n",
            ]
        case .mediawiki:
            return [
                "[[", "]]", "{{", "}}", "{|", "|}", "|-", "|", "!", "''", "'''", "<ref>", "</ref>", "<ref name=a/>",
                "==", "* ", "# ", ":", ";", "<nowiki>", "</nowiki>", "{{{", "}}}", "{{#if:", "<references/>",
                "[[File:a.png|", "<pre>", "</pre>", "<math>", "</math>", "__TOC__", "\n", "----",
            ]
        case .rst:
            return [
                ".. ", "::", "`", "``", "*", "**", "_", "__", "|", "+---+", "====", "----", "   ", ".. note::",
                ".. include:: self.rst", "[#]_", ".. [#] ", ":role:`", "`_", ".. |a| replace:: |a|", "|a|", "\n\n",
                "\n", ".. _a: ", "a_", ".. code-block:: python", ".. math::", ":math:`", "- ", "#. ", ".. table::",
                ".. list-table::", "* - ", ".. contents::",
            ]
        case .notebook:
            return [
                "{", "}", "[", "]", "\"", ",", ":", "\\", "\\u", "\\ud800", "\"cells\":", "\"source\":",
                "\"outputs\":", "\"data\":", "\"image/png\":", "\"text/html\":", "\"cell_type\":\"markdown\"",
                "\"cell_type\":\"code\"", "\"execution_count\":", "null", "true", "1e999", "\"attachments\":",
                "\"metadata\":",
            ]
        case .csv: return [",", "\"", "\n", "\r\n", "\r", "\t", "\"\"", ";", "\u{0}"]
        case .plainText:
            return [
                "\n", "\r", "\r\n", "{", "}", "[", "]", "<", ">", "</", "\"", ":", "- ", "&a ", "*a", "<<: *a", "#",
                "<!--", "-->", "<![CDATA[", "]]>", "[[a]]", "= ", "\t",
            ]
        case .graphviz:
            return [
                "{", "}", "[", "]", "->", "--", ";", "\"", "subgraph", "<", ">", "<<", ">>", "digraph", "graph",
                "label=", "node", "edge", "=", ",", "\n", "/*", "*/", "//", "#",
            ]
        case .plantuml:
            return [
                "@startuml", "@enduml", "->", "-->", ":", ";", "{", "}", "!include self.puml", "(", ")", "[", "]",
                "if (a) then", "endif", "else", "\"", "class ", "participant ", "note left", "end note", "*", "**",
                "!define A A A", "skinparam ", "start", "stop", "repeat", "repeat while", "fork", "end fork", "\n",
                "@startmindmap", "@endmindmap", "@startgantt", "@endgantt",
            ]
        case .html:
            return [
                "<", ">", "</", "<div>", "</div>", "<table>", "<tr>", "<td>", "</table>", "<!--", "-->", "\"", "'",
                "<script>", "</script>", "<title>", "</title>", "<h1>", "</h1>", "<svg>", "</svg>", "<style>",
                "</style>", "&", "&#", "<!DOCTYPE html>", "<meta charset=\"x\">", "<base href=\"",
            ]
        case .docx:
            return [
                "<w:p>", "</w:p>", "<w:r>", "</w:r>", "<w:t>", "</w:t>", "<w:tbl>", "</w:tbl>", "<w:tr>", "</w:tr>",
                "<w:tc>", "</w:tc>", "<", ">", "</", "\"", "w:val=\"99999999\"", "<w:gridSpan w:val=\"9999\"/>",
                "<w:numPr><w:ilvl w:val=\"999\"/><w:numId w:val=\"1\"/></w:numPr>", "&", "&amp;", "<!--", "-->",
                "<![CDATA[", "]]>", "<w:sz w:val=\"999999999\"/>", "<w:vMerge/>", "<w:footnoteReference w:id=\"1\"/>",
            ]
        case .pdf:
            return [
                "obj", "endobj", "stream", "endstream", "<<", ">>", "[", "]", "xref", "trailer", "startxref", "/Kids",
                "/Count 999999999", "/MediaBox [0 0 1e9 1e9]", "/Length 999999999", "/Parent 2 0 R", "0 0 R", "(",
                ")", "\n", "%%EOF", "/Type /Page", "/Filter /FlateDecode",
            ]
        case .image:
            return [
                "<", ">", "</", "<svg>", "</svg>", "<g>", "</g>", "<use href=\"#a\"/>", "id=\"a\"", "width=\"1e9\"",
                "IHDR", "IDAT", "IEND", "GIF89a", "\u{FF}\u{D8}", "<script>", "<foreignObject>", "<pattern>",
            ]
        case .zipArchive:
            return ["PK\u{3}\u{4}", "PK\u{1}\u{2}", "PK\u{5}\u{6}", "../", "/", "\u{0}", "\u{FF}\u{FF}\u{FF}\u{FF}"]
        }
    }
}
