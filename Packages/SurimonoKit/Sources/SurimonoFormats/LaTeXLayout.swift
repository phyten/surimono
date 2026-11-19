import Foundation

/// A figure and its children share a number even when the main caption follows all the subfigures.
/// Reserving the number at the first caption also leaves an entirely uncaptioned figure unnumbered.
final class LaTeXFigureCaptions {
    var number: String?
    var mainCaptionPrinted = false
    var children = 0
}

extension LaTeXReader {
    func layoutBox(from reader: LaTeXReader, environment: Bool) {
        appendLayoutBox(layoutBoxHTML(from: reader, environment: environment))
    }

    private func layoutBoxHTML(from reader: LaTeXReader, environment: Bool, cssClass: String = "", style: String = "")
        -> String
    {
        let position = reader.optional()
        _ = reader.optional()  // Explicit height and inner position need not crop overflowing content on paper.
        _ = reader.optional()
        let width = reader.argument()
        let body = environment ? reader.rest : reader.argument() ?? ""
        guard document.reserveExpansion(characters: body.count) else { return "" }
        return boxHTML(width: width, position: position, cssClass: cssClass, style: style) { blocks(body) }
    }

    /// A frame around a single parbox takes that box's width. Applying the decoration to
    /// the line that holds it would stretch a narrow box across the entire text measure.
    func appendDecoratedLayoutBox(_ source: String, cssClass: String, style: String) -> Bool {
        let probe = LaTeXReader(source, document: document, isBlock: false)
        probe.skipSpaces()
        let command = probe.controlToken()
        guard document.macros[String(command.dropFirst())] == nil else { return false }
        let inner: LaTeXReader
        let environment: Bool
        if command == "\\parbox" {
            let arguments = probe.index
            for _ in 0..<3 { _ = probe.optional() }
            _ = probe.argument()
            _ = probe.argument()
            probe.skipSpaces()
            guard probe.peek() == nil else { return false }
            probe.index = arguments
            inner = probe
            environment = false
        } else if command == "\\begin", probe.argument() == "minipage", document.environments["minipage"] == nil {
            inner = LaTeXReader(probe.environmentBody("minipage"), document: document, isBlock: false)
            probe.skipSpaces()
            guard probe.peek() == nil else { return false }
            environment = true
        } else {
            return false
        }
        appendLayoutBox(layoutBoxHTML(from: inner, environment: environment, cssClass: " " + cssClass, style: style))
        return true
    }

    private func boxHTML(
        width: String?, position: String?, cssClass: String = "", style: String = "", contents: () -> String
    ) -> String {
        // Percentages refer to the current text block. An inner parbox therefore measures against the outer
        // minipage, and the same source adapts to a different paper size or margin when the renderer lays it out.
        let outer = document.textWidthPoints
        defer { document.textWidthPoints = outer }
        var cssWidth = width.flatMap(LaTeXSymbols.printLength)
        var physicalWidth = ""
        if let width, let rendered = cssWidth {
            if let mm = LaTeXPageSettings.millimetres(width) {
                let points = mm * 72 / 25.4
                var fallback = rendered
                if let outer, outer.isFinite, outer > 0, (points / outer * 100).isFinite {
                    fallback = String(format: "%g%%", points / outer * 100)
                }
                document.textWidthPoints = points
                // The fragment also serves themes whose text block is set by the selected paper.
                physicalWidth = String(format: "--latex-box-points: %g; ", points)
                cssWidth = "var(--latex-measured-width, \(fallback))"
            } else if rendered.hasSuffix("%"), let number = Double(rendered.dropLast()), let outer {
                document.textWidthPoints = outer * number / 100
            } else {
                document.textWidthPoints = nil
            }
        }
        let body = contents()
        let alignment = position == "t" ? "top" : position == "b" ? "bottom" : "middle"
        let sizing = physicalWidth + (cssWidth.map { "width: \($0); " } ?? "") + "vertical-align: \(alignment)"
        return "<div class=\"latex-minipage\(cssClass)\" style=\"\(style)\(sizing)\">\(body)</div>"
    }

    func subfigureTarget() -> (letter: String, id: String) {
        let figure = document.figureCaptions ?? LaTeXFigureCaptions()
        let parent = figure.number ?? stepCounter("figure")
        figure.number = parent
        figure.children += 1
        let letter = LaTeXSymbols.format(figure.children, as: "alph")
        let number = parent + letter
        let id = document.counters.anchor("fig", suffix: number)
        document.labelTarget = (number, id)
        return (letter, id)
    }

    func subcaptionHTML(_ source: String, target: (letter: String, id: String)) -> String {
        let text = inline(source)
        document.describeTarget(target.id, kind: "figure", title: text)
        return
            "<figcaption id=\"\(target.id)\"><span class=\"latex-caption-label\">(\(target.letter))</span> \(text)</figcaption>\n"
    }

    func subfigureCommand(_ name: String) {
        let source: String
        var width: String?
        if name != "subcaptionbox" {
            let first = optional()
            source = optional() ?? first ?? ""
        } else {
            _ = optional()
            source = argument() ?? ""
            width = optional()
            _ = optional()
        }
        let body = argument() ?? ""
        guard document.reserveExpansion(characters: body.count + source.count) else { return }
        // A label may appear in the caption OR at the very start of the picture argument.
        let target = subfigureTarget()
        let caption = subcaptionHTML(source, target: target)
        appendLayoutBox(boxHTML(width: width, position: "b") { blocks(body) + caption })
    }

    func callout(options: String?, body: String) -> String {
        guard document.reserveExpansion(characters: body.count + (options?.count ?? 0)) else { return "" }
        let title =
            (option("title", in: options) ?? option("frametitle", in: options)).map {
                "<p class=\"callout-title\">\(inline($0))</p>\n"
            } ?? ""
        var styles: [String] = []
        if let color = boxColor("colback", in: options) ?? boxColor("backgroundcolor", in: options) {
            styles.append("--callout-tint: \(color)")
        }
        if let color = boxColor("colframe", in: options) ?? boxColor("linecolor", in: options) {
            styles.append("--callout-color: \(color)")
        }
        let attr = styles.isEmpty ? "" : " style=\"\(styles.joined(separator: "; "))\""
        return "<div class=\"callout callout-neutral\"\(attr)>\n\(title)\(blocks(body))</div>\n"
    }

    private func boxColor(_ key: String, in options: String?) -> String? {
        option(key, in: options).flatMap { LaTeXSymbols.cssColor($0, defined: document.colors) }
    }

    func inlineColorBox() {
        let options = optional()
        let body = argument() ?? ""
        guard document.reserveExpansion(characters: body.count) else { return }
        var styles: [String] = []
        if let color = boxColor("colback", in: options) { styles.append("background-color: \(color)") }
        if let color = boxColor("colframe", in: options) { styles.append("border-color: \(color)") }
        let attr = styles.isEmpty ? "" : " style=\"\(styles.joined(separator: "; "))\""
        appendHTML("<span class=\"latex-fbox\"\(attr)>\(inline(body))</span>")
    }

    /// These declarations select TeX's running heads, layout or fonts. Consume their full signatures so
    /// arguments such as a font filename or a header's replacement text never leak into the printed prose.
    func handleLayoutSetting(_ name: String) -> Bool {
        switch name {
        case "newtcolorbox", "newtcbtheorem":
            defineBox(theorem: name == "newtcbtheorem")
        case "fancypagestyle": defineFancyPageStyle()
        case "titleformat":
            if star() {
                _ = argument()
                _ = argument()
            } else {
                _ = argument()
                _ = optional()
                for _ in 0..<4 { _ = argument() }
                _ = optional()
            }
        case "titlespacing":
            _ = star()
            for _ in 0..<4 { _ = argument() }
            _ = optional()
        case "babelfont":
            let language = optional()
            let family = argument() ?? ""
            let role = ["rm": "main", "sf": "sans", "tt": "mono"][family]
            let matchesMain = language.map { LaTeXLanguage.tag($0) == document.classInfo.mainLanguage } ?? true
            readFont(role: matchesMain ? role : nil)
        case "setmainfont": readFont(role: "main")
        case "setsansfont": readFont(role: "sans")
        case "setmonofont": readFont(role: "mono")
        case "setCJKmainfont", "setmainjfont", "setjamainfont": readFont(role: "cjk-main")
        case "setCJKsansfont", "setsansjfont", "setjasansfont": readFont(role: "cjk-sans")
        case "setCJKmonofont", "setmonojfont", "setjamonofont": readFont(role: "cjk-mono")
        case "newfontfamily", "renewfontfamily":
            let selector = argument()
            readFont(role: nil, selector: selector)
        case "fontspec", "jfontspec", "setmathfont":
            _ = optional()
            _ = argument()
            _ = optional()
        case "newjfontfamily", "newfontface", "newjfontface", "setCJKfamilyfont", "newCJKfontfamily",
            "renewjfontfamily", "newCJKfontface", "renewfontface":
            let selector = argument() ?? ""
            _ = optional()
            _ = argument()
            _ = optional()
            if selector.hasPrefix("\\"), selector.count > 1, document.reserveExpansion() {
                document.macros[String(selector.dropFirst())] = .init(specification: [], body: "")
            }
        case "titleclass":
            _ = argument()
            _ = optional()
            _ = argument()
            _ = optional()
        default: return false
        }
        return true
    }

    /// Register the opening as an ordinary LaTeX environment macro. Argument substitution, recursion, and
    /// repeated long option lists then spend exactly the same budgets as a user-defined environment.
    private func defineBox(theorem: Bool) {
        let settings = optional()
        let name = argument() ?? ""
        let macro: LaTeXDocument.Macro
        if theorem {
            let heading = argument() ?? ""
            let options = argument() ?? ""
            let prefix = argument() ?? ""
            let counter = option("use counter", in: settings) ?? name
            guard !name.isEmpty, document.reserveExpansion(characters: heading.count + options.count) else { return }
            if !document.counters.contains(counter) { document.counters[counter] = 0 }
            if let parent = option("number within", in: settings) {
                document.counters.within(counter, parent: parent, prefix: true)
            }
            let begin =
                "\\refstepcounter{\(counter)}\\label{\(prefix):#3}\\begin{tcolorbox}"
                + "[\(options),title={\(heading) \\the\(counter): #2},#1]"
            macro = .init(parameters: 3, defaultArgument: "", body: begin)
        } else {
            let count = optional().flatMap { Int($0) } ?? 0
            let defaultArgument = count > 0 ? optional() : nil
            let options = argument() ?? ""
            guard !name.isEmpty, (0...9).contains(count), document.reserveExpansion(characters: options.count) else {
                return
            }
            macro = .init(parameters: count, defaultArgument: defaultArgument, body: "\\begin{tcolorbox}[\(options)]")
        }
        document.environments[name] = (macro, "\\end{tcolorbox}")
    }
}
