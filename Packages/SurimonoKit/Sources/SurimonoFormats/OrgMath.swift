import Foundation

/// Org's LaTeX fragments (`$…$`, `\(…\)`, `\[…\]`, `$$…$$` and amsmath environments), typeset by `MathRenderer`.
enum OrgMath {
    /// Formulas inside running text. As in Markdown, an inline `$` must touch its formula on both sides; here it
    /// must also stand clear of ASCII letters and digits, so prices (`$5 and $10`) and shell variables (`$HOME`)
    /// stay text while a formula set against Japanese text, which has no spaces, is still read. A bracketed formula
    /// ends at the next opener of its kind (one after a backslash is a row break with a spacing, `\\[2pt]`) and has
    /// a length limit, so a run of unclosed openers cannot each scan the rest of the text. A display formula that
    /// is a paragraph of its own (`displayBlock`) has no such limit.
    static let inlinePattern =
        #"\$\$[^$]+?\$\$|\\\[(?:(?!(?<!\\)\\\[)[\s\S]){1,2000}?\\\]|\\\((?:(?!(?<!\\)\\\()[\s\S]){1,2000}?\\\)"#
        + #"|(?<![$\\A-Za-z0-9])\$(?=[^\s$])(?:\\.|[^$\\\n])*?(?<=[^\s\\])\$(?![0-9A-Za-z$])"#

    /// A fragment with its delimiters, as matched by `inlinePattern`.
    static func inline(_ source: String, context: OrgContext) -> String {
        let display = source.hasPrefix("$$") || source.hasPrefix("\\[")
        let width = source.hasPrefix("$") && !display ? 1 : 2
        return context.formula(String(source.dropFirst(width).dropLast(width)), display: display, source: source)
    }

    /// A paragraph that is one display formula and nothing else, as a block of its own.
    static func displayBlock(_ paragraph: String, context: OrgContext) -> String? {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 4 else { return nil }
        let inner = String(text.dropFirst(2).dropLast(2))
        let whole =
            text.hasPrefix("\\[") && text.hasSuffix("\\]") && !inner.contains("\\]")
            || text.hasPrefix("$$") && text.hasSuffix("$$") && !inner.contains("$")
        guard whole else { return nil }
        return "<div class=\"math-block\">\(context.formula(inner, display: true, source: text))</div>\n"
    }

    /// The name of a math environment a line opens. Other environments (tabular, tikzpicture) are not math and
    /// stay text.
    static func environmentName(_ line: String) -> String? {
        guard let name = orgCaptures(#"^\\begin\{([A-Za-z]+\*?)\}"#, line)?.first,
            LaTeXReader.mathEnvironments.keys.contains(name.hasSuffix("*") ? String(name.dropLast()) : name)
        else { return nil }
        return name
    }

    /// A display environment, numbered as the LaTeX converter numbers it: an unstarred equation or multline gets
    /// the next number at the right, an unstarred align or gather numbers each row. Org's own references do not
    /// reach these numbers, so a `\label` is only removed.
    static func environment(_ name: String, body: String, context: OrgContext) -> String {
        guard !context.discovering else { return "" }
        let starred = name.hasSuffix("*")
        let base = starred ? String(name.dropLast()) : name
        var latex = LaTeXReader.withoutComments(body)
        // alignat's column count is not part of the formula.
        if base == "alignat", latex.drop(while: \.isWhitespace).first == "{", let close = latex.firstIndex(of: "}") {
            latex = String(latex[latex.index(after: close)...])
        }
        latex = LaTeXReader.removingLabels(latex).0
        let wrapper = LaTeXReader.mathEnvironments[base] ?? nil
        let source = "\\begin{\(name)}\(body)\\end{\(name)}"
        func render(_ formula: String) -> String {
            context.formula(wrapper.map { $0.0 + formula + $0.1 } ?? formula, display: true, source: source)
        }
        func withoutSkips(_ text: String) -> String {
            text.replacingOccurrences(of: "\\nonumber", with: "").replacingOccurrences(of: "\\notag", with: "")
        }
        if LaTeXReader.numberedRows.contains(base) {
            var rows = LaTeXReader.rows(of: latex)
            for position in rows.indices {
                var row = rows[position]
                // eqnarray's three columns read as align's two: `a & = & b` becomes `a &= b`.
                if base == "eqnarray", let first = row.firstIndex(of: "&"),
                    let second = row[row.index(after: first)...].firstIndex(of: "&")
                {
                    row.remove(at: second)
                }
                let skipped = row.contains("\\notag") || row.contains("\\nonumber")
                row = withoutSkips(row)
                if !starred, !skipped, LaTeXReader.explicitTag(row) == nil,
                    !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    context.equationCount += 1
                    row += "\\tag{\(context.equationCount)}"
                }
                rows[position] = row
            }
            return "<div class=\"math-block\">\(render(rows.joined(separator: "\\\\")))</div>\n"
        }
        let formula = withoutSkips(latex)
        guard !starred, base != "displaymath", LaTeXReader.explicitTag(formula) == nil else {
            return "<div class=\"math-block\">\(render(formula))</div>\n"
        }
        context.equationCount += 1
        return "<div class=\"math-block latex-equation\">\(render(formula))"
            + "<span class=\"eqno\">(\(context.equationCount))</span></div>\n"
    }

    /// A `#+LATEX_HEADER:` line as a definition for every formula, or nil for a line that defines nothing
    /// (`\usepackage`) or that SwaTex cannot read, so it cannot break the formulas.
    static func definition(_ header: String, after definitions: String) -> String? {
        var definition = header.trimmingCharacters(in: .whitespaces)
        if let match = orgCaptures(#"^\\DeclareMathOperator(\*?)\s*\{\s*(\\[A-Za-z]+)\s*\}\s*\{(.*)\}$"#, definition) {
            definition = "\\def\(match[1]){\\operatorname\(match[0]){\(match[2])}}"
        }
        guard orgCaptures(#"^\\(?:newcommand|renewcommand|providecommand|def)(?![A-Za-z])"#, definition) != nil,
            MathRenderer.html("x", display: false, macros: definitions + definition) != nil
        else { return nil }
        return definition
    }
}
