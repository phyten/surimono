import Foundation

/// Preserve drawing punctuation while the normal reader evaluates definitions, loops and selected branches.
final class PictureExpansion {
    var source = ""
    var failure: String?
}

/// A caption may precede or follow its pictures. Bind pending pictures to the next caption;
/// any pictures after its last caption share that number when the float ends.
final class LaTeXPictureCaptions {
    var pending: [Int] = []
    var last: String?

    // An author-defined caption name may be a long macro. A diagnostic can repeat for every picture in a float.
    static func heading(_ name: String, _ number: String) -> String {
        let shortName = name.utf8.count > 256 ? String(name.unicodeScalars.prefix(128)) + "…" : name
        return shortName + " " + number
    }

    func assign(_ caption: String?, in document: LaTeXDocument) {
        if let caption {
            for index in pending { document.pictureHeadings[index] = caption }
        }
        pending.removeAll()
        last = caption
    }
}

extension LaTeXReader {
    static let pictureCSS = """
        .tikz-block { display: inline-block; vertical-align: bottom; max-width: 100%; text-indent: 0; break-inside: avoid; page-break-inside: avoid }
        :is(.latex-figure, .latex-center) p:has(.tikz-block, [data-latex-picture]) { text-align: center; text-align-last: center; text-indent: 0 }
        .tikz-block > svg { display: block; margin: auto; max-width: 100%; height: auto }
        .latex-unsupported[data-latex-picture] { display: inline-block; text-indent: 0; border: 0; background: #f6f6f6; padding: .55em; text-align: center }
        .latex-unsupported[data-latex-picture]:has(img) { background: none; padding: 0 }
        """

    func configurePicture(_ name: String) {
        switch name {
        case "usetikzlibrary":
            let libraries = (argument() ?? "").split(separator: ",")
            if libraries.contains(where: { String($0).tikzTrimmed == "arrows.meta" }) { document.usesMetaArrows = true }
        case "colorlet":
            guard let key = argument(), let value = argument() else { return }
            document.colors[key] = LaTeXSymbols.rgb(value, model: nil, defined: document.colors)
        case "tikzset":
            if let options = argument(), document.reserveExpansion(characters: options.utf8.count) {
                if !document.pictureStyles.isEmpty { document.pictureStyles += "," }
                document.pictureStyles += options
            }
        default:
            guard let options = argument() else { return }
            for setting in options.components(separatedBy: ",") {
                let value = setting.trimmingCharacters(in: .whitespacesAndNewlines)
                if !Self.isPlotCompatibility(value) {
                    document.plotDefaults = String(value.prefix(100))
                }
            }
        }
    }

    private static func isPlotCompatibility(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^compat\s*=\s*([0-9.]+|newest)$"#, options: .regularExpression) != nil
    }

    func picture(environment: String, body: String, closed: Bool = true) -> String {
        let index = document.pictureIndex
        document.pictureIndex += 1
        let name = document.nextPictureName
        document.nextPictureName = nil
        let source = "\\begin{\(environment)}\(body)" + (closed ? "\\end{\(environment)}" : "")
        let figure = DocumentOutline.plainText(ofHTML: captionName("figurename"))
        let caption = document.language == "ja" || figure == "図" ? "\(figure)（TikZ）" : "\(figure) (TikZ)"
        var label = LaTeXPictureCaptions.heading(figure, String(index + 1))
        if let captions = document.pictureCaptions {
            captions.pending.append(index)
            document.pictureHeadings[index] = label
            label = document.placeholder("P", index)
        }
        let heading = label + " (TikZ)"
        let original = HTML.escape(source)
        func fallback(_ reason: String, optional: Bool) -> String {
            let image = externalPicture(index: index, explicit: name, optional: optional)
            let detail = [reason, image?.warning].compactMap { $0 }.joined(separator: " — ")
            if !optional { document.reportFileIssue(detail) }
            let contents = image?.html ?? HTML.escape(caption)
            return "<span class=\"latex-unsupported\" data-latex-picture data-issue=\"\(HTML.escape(detail))\""
                + " data-source=\"\(original)\">\(contents)</span>"
        }

        do {
            guard closed else { throw TikZError("\\end{\(environment)}") }
            guard body.utf8.count <= 200_000 else { throw TikZError("200 kB") }
            let input: String
            switch environment {
            case "tikzpicture": input = body
            case "axis", "semilogxaxis", "semilogyaxis", "loglogaxis": input = source
            default: throw TikZError(environment)
            }
            let expanded = try expandedPicture(input)
            if let defaults = document.plotDefaults,
                expanded.range(of: #"\\begin\s*\{(?:semi(?:logx|logy)|loglog)?axis\}"#, options: .regularExpression)
                    != nil
            {
                throw TikZError("pgfplotsset: " + defaults)
            }
            var labels: [String] = []
            let styles = (document.usesMetaArrows ? ">=To," : "") + (try expandedPicture(document.pictureStyles))
            let scene = try TikZParser.scene(expanded, styles: styles, colors: document.colors) {
                label in
                labels.append(label)
                return String(labels.count - 1)
            }
            for label in labels { try validatePictureLabel(label) }
            let data = try JSONSerialization.data(
                withJSONObject: scene, options: [.sortedKeys, .withoutEscapingSlashes])
            guard data.count <= 4_000_000 else { throw TikZError("4 MB") }
            let templates = labels.map { "<template>\(inline($0))</template>" }.joined()
            return "<span class=\"tikz-block\" data-scene=\"\(HTML.escape(String(decoding: data, as: UTF8.self)))\">"
                + fallback(heading, optional: true) + templates + "</span>"
        } catch {
            let detail = heading + " — " + ((error as? TikZError)?.feature ?? environment)
            return fallback(detail, optional: false)
        }
    }

    func expandedPicture(_ text: String) throws -> String {
        guard document.depth < LaTeXDocument.maximumDepth else { throw TikZError("expansion depth") }
        document.depth += 1
        defer { document.depth -= 1 }
        let reader = LaTeXReader(text, document: document, isBlock: false)
        let saved = (document.macros, document.mathDefinitions, document.hasExtendedMathDefinitions)
        defer { (document.macros, document.mathDefinitions, document.hasExtendedMathDefinitions) = saved }
        let expansion = PictureExpansion()
        reader.pictureExpansion = expansion
        reader.readSteps()
        if let failure = expansion.failure { throw TikZError(failure) }
        guard !document.stopsExpanding else { throw TikZError("expansion limit") }
        return expansion.source
    }

    /// An inline reader also understands files and document-level commands. Only text formatting and math
    /// belong to a diagram label. Validate before calling inline so a discarded picture has no file effects.
    private func validatePictureLabel(_ label: String) throws {
        let reader = LaTeXReader(label, document: document, isBlock: false)
        var mathEnd: String?
        while let ch = reader.peek() {
            if ch == "$" {
                if mathEnd == "$" { mathEnd = nil } else if mathEnd == nil { mathEnd = "$" }
                reader.index += 1
            } else if ch == "\\" {
                let token = reader.controlToken()
                if mathEnd == token {
                    mathEnd = nil
                    continue
                }
                if mathEnd != nil { continue }
                if token == #"\("# {
                    mathEnd = #"\)"#
                    continue
                }
                let name = String(token.dropFirst())
                if name == "color" || name == "textcolor" {
                    guard reader.color() != nil else { throw TikZError(token) }
                }
                if name == "\\", reader.optional() != nil { throw TikZError(token + "[]") }
                guard
                    ["textbf", "textit", "emph", "texttt", "textsf", "textrm", "textnormal", "text"].contains(name)
                        || LaTeXSymbols.text[name] != nil
                        || LaTeXSymbols.sizes[name] != nil
                        || ["bfseries", "itshape", "ttfamily", "sffamily"].contains(name)
                        || ["\\", "newline", "textcolor", "color", "ref", "eqref"].contains(name)
                        || name.count == 1 && name.first.map({ LaTeXSymbols.controlSymbols[$0] != nil }) == true
                else { throw TikZError(token) }
            } else {
                reader.index += 1
            }
        }
        if let mathEnd { throw TikZError(mathEnd) }
    }

    func expandPictureTokens(into expansion: PictureExpansion) {
        var groups: [[String: LaTeXDocument.Macro]] = []
        while let ch = peek(), expansion.failure == nil, !document.stopsExpanding {
            if ch == "%" {
                skipComment()
            } else if ch != "\\" {
                if ch == "{" { groups.append(document.macros) }
                if ch == "}", let macros = groups.popLast() { document.macros = macros }
                guard groups.count <= 64 else {
                    expansion.failure = "group depth"
                    return
                }
                expansion.source.append(ch)
                index += 1
            } else {
                retireMacroFrames()
                let token = controlToken()
                let name = String(token.dropFirst())
                if name == "begin" || name == "end" {
                    let start = index
                    if argument() == "scope" {
                        if name == "begin" { groups.append(document.macros) }
                        if name == "end", let macros = groups.popLast() { document.macros = macros }
                        guard groups.count <= 64 else {
                            expansion.failure = "scope depth"
                            return
                        }
                        expansion.source += token + "{scope}"
                    } else {
                        index = start
                        expansion.source += token
                    }
                } else if let primitive = document.macros[name]?.primitive {
                    // Re-enter this scanner so a saved primitive cannot dispatch a file or document command.
                    skipSpacesAfterControlWord()
                    insertExpansion("\\" + primitive)
                } else if ["def", "newcommand", "renewcommand", "providecommand"].contains(name)
                    || document.macros[name] != nil
                {
                    skipSpacesAfterControlWord()
                    _ = handleMacro(name)
                } else if ["foreach", "ifnum", "ifdim"].contains(name) {
                    skipSpacesAfterControlWord()
                    _ = handleControl(name)
                } else if name == "pgfplotsset" {
                    guard let value = argument(), Self.isPlotCompatibility(value) else {
                        expansion.failure = token
                        return
                    }
                } else if name == "pgfmathsetmacro" {
                    guard let target = argument(),
                        target.range(of: #"^\\[a-zA-Z]+$"#, options: .regularExpression) != nil,
                        let expr = argument(), document.depth < LaTeXDocument.maximumDepth
                    else {
                        expansion.failure = token
                        return
                    }
                    do {
                        let value = try PGFMath.evaluate(expandedPicture(expr))
                        document.macros[String(target.dropFirst())] = .init(
                            parameters: 0, defaultArgument: nil, body: String(value))
                    } catch { expansion.failure = token }
                } else {
                    expansion.source += token
                }
            }
        }
    }
}
