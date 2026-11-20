import Foundation

extension LaTeXFrontMatter {
    static func period(_ html: String) -> String {
        let text = HTML.unescape(html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last,
            !".?!:;。？！".contains(last)
        else { return html }
        return html + "."
    }

    func resolveAMS(in html: String, document: LaTeXDocument) -> String {
        let verso = document.classInfo.profile.titleBlock.notesOnVerso
        let abstract = abstractHTML ?? ""
        let contacts = amsContacts.joined()
        var lines: [String] = []
        func add(_ kind: String, _ value: String, label: String = "") {
            guard !value.isEmpty else { return }
            let content = (label.isEmpty ? "" : "<em>\(label)</em> ") + (verso ? value : Self.period(value))
            lines.append("<p class=\"latex-front-\(kind)\">\(content)</p>")
        }
        if !verso, let date {
            let reader = LaTeXReader(date, document: document, isBlock: false)
            add("date", reader.read(), label: document.classInfo.profile.titleBlock.noteDateLabel)
        }
        let year = HTML.escape(classificationYear)
        let yearHTML =
            document.classInfo.profile.titleBlock.uprightClassificationYear
            ? "<span class=\"latex-msc-year\">\(year)</span>" : year
        add(
            "classifications", classifications.joined(separator: "; "),
            label: "\(yearHTML) Mathematics Subject Classification.")
        add("keywords", keywords.joined(separator: ", "), label: "Key words and phrases.")
        for note in amsThanks { add("thanks", note) }
        let details = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        var titleEnd = ""
        var afterTitle = abstract
        if printed && verso {
            titleEnd = contacts
            afterTitle =
                "<div class=\"latex-amsbook-verso\" data-latex-page-action=\"thispagestyle\" data-value=\"empty\">\n"
                + details + abstract + "</div>\n"
        } else if printed && !details.isEmpty {
            // An anchor in the title reserves the notes on that page without stepping the body footnote counter.
            let id = "fn-ams-title"
            document.footnotes.insert(.init(id: id, number: "", html: details), at: 0)
            titleEnd = "<span class=\"footnote-ref latex-ams-note-ref\"><a href=\"#\(id)\">&#8203;</a></span>"
        }
        return html.replacingOccurrences(of: document.placeholder("F", 0), with: printed ? "" : abstract)
            .replacingOccurrences(of: document.placeholder("F", 1), with: printed ? "" : details)
            .replacingOccurrences(of: document.placeholder("F", 2), with: afterTitle)
            .replacingOccurrences(of: document.placeholder("F", 3), with: titleEnd)
            + (verso ? "" : contacts)
    }
}
