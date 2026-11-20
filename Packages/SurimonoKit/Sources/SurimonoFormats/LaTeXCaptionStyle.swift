import Foundation

/// caption applies the type-specific declarations after the common declarations at each float.
struct LaTeXCaptionStyle {
    private var groups: [String: [String: String]] = [:]

    mutating func configure(_ options: String, kind: String) {
        guard ["", "figure", "table", "lstlisting"].contains(kind) else { return }
        if groups[kind] == nil { groups[kind] = [:] }
        for (key, value) in LaTeXPageSettings.options(options)
        where ["font", "labelfont", "labelsep", "skip", "justification", "format", "singlelinecheck"].contains(key) {
            groups[kind, default: [:]][key] = value
        }
    }

    func resolve(_ kind: String, info: LaTeXDocumentClassInfo) -> (attributes: String, separator: String?, hangs: Bool)
    {
        let options = (groups[""] ?? [:]).merging(groups[kind] ?? [:]) { _, local in local }
        guard groups[""] != nil || groups[kind] != nil else { return ("", nil, false) }
        var css: [String: String] = [:]
        for (key, prefix) in [("font", "caption"), ("labelfont", "label")] {
            for token in (options[key] ?? "").split(separator: ",") {
                let word = token.trimmingCharacters(in: .whitespaces)
                switch word {
                case "bf", "md": css[prefix + "-weight"] = word == "bf" ? "bold" : "normal"
                case "it", "sl", "up": css[prefix + "-shape"] = word == "up" ? "normal" : "italic"
                case "sf", "rm":
                    css[prefix + "-family"] = word == "sf" ? "var(--tex-sans-fonts)" : "var(--tex-body-fonts)"
                default:
                    if let baseline = LaTeXLabelMetrics(info).baseline(for: word) {
                        css[prefix + "-size"] = "var(--latex-size-\(word))"
                        if key == "font" {
                            css["caption-pitch"] =
                                "calc(\(LaTeXPageSettings.number(baseline)) * var(--tex-pt) * var(--latex-stretch, 1))"
                        }
                    }
                }
            }
        }
        if let length = options["skip"].flatMap(LaTeXSymbols.printLength) {
            css["abovecaptionskip"] = length
            css["caption-table-gap"] = length
        }
        let alignments = [
            "centering": "center", "raggedright": "start", "RaggedRight": "start",
            "raggedleft": "end", "justified": "justify",
        ]
        if let alignment = options["justification"].flatMap({ alignments[$0] }) { css["caption-align"] = alignment }
        if options["singlelinecheck"] == "false" { css["caption-width"] = "100%" }
        let separators = [
            "colon": ": ", "period": ". ", "space": " ", "quad": " ", "none": "", "newline": "<br/>",
            "endash": " – ",
        ]
        if options["format"] == "hang", ["none", "quad"].contains(options["labelsep"] ?? "") {
            css["caption-label-gap"] = "0px"
        }
        if info.profile.body.alignsHangingCaptions, options["format"] == "hang", options["justification"] == nil,
            (css["label-weight"] ?? css["caption-weight"]) == "bold"
        {
            css["label-colon-space"] = ".5253em"
        }
        let attributes =
            " data-latex-caption-style"
            + (css.isEmpty ? "" : " style=\"\(HTML.escape(LaTeXPageSettings.cssVariables(css)))\"")
        return (
            attributes, options["labelsep"].flatMap { separators[$0] } ?? info.profile.body.styledCaptionSeparator,
            options["format"] == "hang" && options["justification"] != "centering"
        )
    }
}
