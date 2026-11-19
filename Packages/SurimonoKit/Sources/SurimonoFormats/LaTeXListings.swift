import Foundation

extension LaTeXReader {
    func configureListings(_ command: String) {
        if command == "lstdefinestyle" {
            guard let name = argument(), let options = argument() else { return }
            document.listingStyles[name] = options
        } else {
            document.listingDefaults = listingSettings(argument())
        }
    }

    func listingSettings(_ options: String?, minted: Bool = false) -> [String: String] {
        var settings = minted ? [:] : document.listingDefaults
        if let options { applyListingOptions(options, to: &settings, depth: 0) }
        return settings
    }

    /// listings applies keys from left to right, so a named style can override an earlier language and
    /// a later key can override the style. Nested styles share the macro budget, including cycles.
    private func applyListingOptions(_ options: String, to settings: inout [String: String], depth: Int) {
        var braces = 0
        for option in options.split(whereSeparator: { character in
            if character == "{" { braces += 1 }
            if character == "}" { braces = max(0, braces - 1) }
            return character == "," && braces == 0
        }) {
            let pair = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            var value = pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespacesAndNewlines) : "true"
            if value.first == "{", value.last == "}" { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "style":
                guard let style = document.listingStyles[value] else { continue }
                guard depth + document.depth < LaTeXDocument.maximumDepth else {
                    document.stopsExpanding = true
                    return
                }
                if document.reserveExpansion(characters: style.utf8.count) {
                    applyListingOptions(style, to: &settings, depth: depth + 1)
                }
            case "language", "numbers", "linenos", "firstnumber", "caption", "label", "basicstyle", "frame",
                "keywordstyle", "commentstyle", "stringstyle", "numberstyle", "breaklines", "backgroundcolor":
                settings[key] = value
            default: break
            }
        }
    }

    func readListingFile(_ name: String) {
        let minted = name == "inputminted"
        var settings = listingSettings(optional(), minted: minted)
        if minted { settings["language"] = argument() }
        let path = argument() ?? ""
        guard let code = readLocalText(path) else {
            appendBlock(fileNote(path))
            return
        }
        appendListing(code, settings: settings, environment: false, minted: minted)
    }

    func readInlineListing(_ name: String) {
        let minted = name == "mintinline"
        let options = listingSettings(optional(), minted: minted)
        let language = minted ? argument() : options["language"]
        while peek() == " " || peek() == "\t" { index += 1 }
        let code: String
        if peek() == "{" {
            index += 1
            // Unlike a TeX argument, '%' in a braced code argument does not start a comment.
            code = balanced(comments: false)
        } else {
            code = delimitedCode()
        }
        guard !minted, document.reserveExpansion(characters: options.values.reduce(0) { $0 + $1.utf8.count }) else {
            appendHTML(listingInline(code, language: language))
            return
        }
        let tokens = listingTokens(options)
        let html = listingInline(code, language: language, tokens: tokens)
        let styles = listingStyles(options, usesDefaultComment: html.contains("hl-comment"))
        guard !styles.isEmpty || tokens != nil else { return appendHTML(html) }
        let classes = tokens == nil ? "latex-inline-listing" : "latex-inline-listing latex-styled-listing"
        appendHTML("<span class=\"\(classes)\" style=\"\(styles)\">\(html)</span>")
    }

    // Once listings specifies basicstyle or a token style the remaining non-comment tokens use basicstyle. Other code
    // (including minted) continues to use the full palette provided by the print theme.
    private func listingTokens(_ settings: [String: String]) -> Set<String>? {
        let tokens = Set(["keyword", "comment", "string"].filter { settings[$0 + "style"] != nil })
        return tokens.isEmpty && settings["basicstyle"] == nil ? nil : tokens.union(["comment"])
    }

    func listingInline(_ code: String, language: String?, tokens: Set<String>? = nil) -> String {
        guard let language, document.reserveExpansion(characters: code.utf8.count + language.utf8.count),
            let id = SyntaxHighlighter.canonicalLanguage(for: language),
            let highlighted = SyntaxHighlighter.highlight(code, canonicalID: id, listingTokens: tokens)
        else { return "<code>\(HTML.escape(code))</code>" }
        return "<code class=\"language-\(HTML.escape(language.lowercased())) hl\">\(highlighted)</code>"
    }

    /// A named listings style is local to each use. Resolve TeX color declarations to trusted
    /// values here so nested listings and an explicitly chosen app palette inherit the right ink.
    private func listingStyles(_ settings: [String: String], usesDefaultComment: Bool) -> String {
        var styles: [String] = []
        for (key, prefix) in [
            ("basicstyle", "--latex-code"), ("numberstyle", "--latex-number"), ("keywordstyle", "--latex-keyword"),
            ("commentstyle", "--latex-comment"), ("stringstyle", "--latex-string"),
        ] {
            guard let source = settings[key] else { continue }
            let reader = LaTeXReader(source, document: document, isBlock: false)
            while reader.peek() != nil {
                guard reader.peek() == "\\" else {
                    reader.index += 1
                    continue
                }
                let command = reader.controlToken()
                switch command {
                case "\\color":
                    let model = reader.optional()
                    if let name = reader.argument(),
                        let value = LaTeXSymbols.cssColor(name, model: model, defined: document.colors)
                    {
                        styles.append("\(prefix)-ink: \(value)")
                    }
                case "\\bfseries": styles.append("\(prefix)-weight: bold")
                case "\\mdseries": styles.append("\(prefix)-weight: normal")
                case "\\itshape", "\\slshape": styles.append("\(prefix)-shape: italic")
                case "\\upshape": styles.append("\(prefix)-shape: normal")
                default:
                    let name = String(command.dropFirst())
                    if let size = LaTeXSymbols.sizes[name] {
                        let relative = "\(size)em"
                        // In the class styles the two numbering sizes are absolute, even when
                        // basicstyle makes the source code smaller; other themes retain their scale.
                        let value =
                            key == "numberstyle" && ["tiny", "scriptsize"].contains(name)
                            ? "var(--latex-number-\(name), \(relative))" : relative
                        styles.append("\(prefix)-size: \(value)")
                    }
                }
            }
        }
        if usesDefaultComment, settings["commentstyle"] == nil {
            styles.append("--latex-comment-shape: italic")
        }
        return styles.joined(separator: "; ")
    }

    func appendListing(
        _ source: String, settings: [String: String], environment: Bool, verbatim: Bool = false, minted: Bool = false
    ) {
        var code = source[...]
        // The first newline after \begin is syntax. A file listing's first line belongs to the file.
        if environment, code.first == "\n" { code = code.dropFirst() }
        if environment {
            while code.last == " " || code.last == "\t" { code = code.dropLast() }
        }
        if code.last == "\n" { code = code.dropLast() }
        let text = String(code)
        // Defaults such as a long caption can be reused by thousands of empty listings. Charge their
        // expanded size on each use; the literal code remains readable if the document reaches its limit.
        let cost = settings.values.reduce(0) { $0 + $1.utf8.count }
        guard settings.isEmpty || document.reserveExpansion(characters: cost) else {
            appendBlock("<pre><code>\(HTML.escape(text))</code></pre>\n")
            return
        }
        let language = settings["language"]?.lowercased()
        let tokens = listingTokens(settings)
        let highlighted = language.flatMap(SyntaxHighlighter.canonicalLanguage(for:)).flatMap {
            SyntaxHighlighter.highlight(text, canonicalID: $0, listingTokens: tokens)
        }
        let attribute =
            language.map { " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\"" } ?? ""
        var body = highlighted ?? HTML.escape(text)
        let numbered = settings["numbers"] == "left" || settings["linenos"] == "true"
        var classes: [String] = verbatim ? ["latex-verbatim"] : []
        var style = listingStyles(settings, usesDefaultComment: !minted && highlighted?.contains("hl-comment") == true)
        if let source = settings["backgroundcolor"] {
            let reader = LaTeXReader(source, document: document, isBlock: false)
            reader.skipSpaces()
            if reader.controlToken() == "\\color", let background = reader.color() {
                if !style.isEmpty { style += "; " }
                style += "--latex-listing-background: \(background)"
                classes.append("latex-filled-listing")
            }
        }
        if let frame = settings["frame"], ["single", "lines", "tb", "none"].contains(frame) {
            classes.append("latex-frame-" + (frame == "tb" ? "lines" : frame))
        }
        if settings["breaklines"] == "true" { classes.append("latex-wrap-code") }
        if style.contains("--latex-code-size:") { classes.append("latex-sized-code") }
        if settings["basicstyle"] != nil { classes.append("latex-basic-listing") }
        if tokens != nil { classes.append("latex-styled-listing") }
        if numbered {
            let first = settings["firstnumber"].flatMap(Int.init) ?? 1
            let lineCount = code.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
            let (_, overflow) = first.addingReportingOverflow(lineCount - 1)
            // Avoid allocating one span per newline after the document's expansion allowance is spent.
            if !overflow, document.reserveExpansion(characters: lineCount * 80),
                let lines = SyntaxHighlighter.lines(of: body[...])
            {
                body = lines.enumerated().map { offset, line in
                    let contents = line.isEmpty ? "<br>" : line
                    return
                        "<span class=\"code-line\" data-no=\"\(first + offset)\"><span class=\"code-src\">\(contents)</span></span>"
                }.joined()
                classes.append("latex-numbered-listing")
            }
        }
        var html = "<pre><code\(attribute)>\(body)</code></pre>\n"
        if classes.isEmpty, !style.isEmpty { classes.append("latex-code-style") }
        if !classes.isEmpty {
            let css = style.isEmpty ? "" : " style=\"\(style)\""
            html = "<div class=\"\(classes.joined(separator: " "))\"\(css)>\(html)</div>\n"
        }
        if settings["caption"] != nil || settings["label"] != nil {
            let number = stepCounter("listing")
            let id = document.counters.anchor("listing", suffix: number)
            let target = (number, id)
            document.labelTarget = target
            if let key = settings["label"], !key.isEmpty { document.labels[key] = target }
            let caption = settings["caption"].map(inline)
            document.describeTarget(id, kind: "listing", title: caption ?? "")
            let name = captionName("lstlistingname")
            let separator = document.isJapanese ? "　" : ": "
            let title =
                caption.map {
                    "<figcaption><span class=\"latex-caption-label\">\(name) \(HTML.escape(number))</span>\(separator)\($0)</figcaption>\n"
                } ?? ""
            html = "<figure class=\"latex-listing\" id=\"\(id)\">\n\(title)\(html)</figure>\n"
        }
        appendBlock(html)
    }
}
