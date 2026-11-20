import Foundation

extension LaTeXReader {
    // These declarations can occur on either side of begin{document}. Only the title
    // commands populate the full-width box; addresses belong to the first column.
    func handleAffiliationList(_ command: String) -> Bool {
        let front = document.frontMatter
        switch command {
        case "icmltitlerunning":
            front.runningTitle = argument()
            updateRunningTitle()
        case "icmltitle":
            front.title = argument()
            if front.runningTitle == nil { updateRunningTitle() }
        case "icmlauthor":
            let name = argument() ?? ""
            let keys = (argument() ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            front.namedAuthors.append(.init(name: name, affiliations: keys))
        case "icmlsetsymbol":
            let key = argument() ?? ""
            front.affiliationSymbols[key] = argument()
        case "icmlaffiliation":
            let key = argument()
            front.addAffiliation(label: key, parts: [argument() ?? ""], attach: false)
        case "icmlcorrespondingauthor":
            let name = argument() ?? ""
            front.correspondingAuthors.append((name, argument() ?? ""))
        case "icmlkeywords": _ = argument()
        case "printAffiliationsAndNotice": printAffiliationNotice(argument() ?? "")
        case "vskip" where document.readingConferenceTitle:
            skipSpaces()
            let start = index
            while let character = peek(), character.isASCII,
                character.isNumber || character.isLetter || ".+-".contains(character)
            {
                index += 1
            }
            front.titleBottomSkip = LaTeXSymbols.printLength(String(characters[start..<index]))
        default: return false
        }
        return true
    }

    private func updateRunningTitle() {
        guard document.classInfo.resolvedStyle?.centeredRunningTitle == true,
            let title = document.frontMatter.runningTitle ?? document.frontMatter.title
        else { return }
        document.classInfo.pageNumbers.setRunningTitle(title)
        for (action, value) in document.preamblePageActions {
            document.classInfo.pageNumbers.apply(action, value: value)
        }
    }

    private func affiliationMarks() -> [String: String] {
        let front = document.frontMatter
        var marks = front.affiliationSymbols
        var next = 1
        for author in front.namedAuthors {
            for key in author.affiliations where marks[key] == nil {
                marks[key] = String(next)
                next += 1
            }
        }
        return marks
    }

    func conferenceAuthors(_ style: LaTeXResolvedStyle) -> String {
        let front = document.frontMatter
        if style.usesAffiliationList {
            let marks = affiliationMarks()
            let names: [String]
            if let anonymous = style.anonymousAuthor {
                names = ["<strong>\(HTML.escape(anonymous))</strong><sup>1</sup>"]
            } else {
                names = front.namedAuthors.map { author in
                    let labels = author.affiliations.compactMap { marks[$0] }.map(inline).joined(separator: ",")
                    let suffix = labels.isEmpty ? "" : "\u{202F}<sup>\(labels)</sup>"
                    return "<strong>\(inline(author.name))</strong>\(suffix)"
                }
            }
            let cells = names.map { "<span class=\"latex-front-author\">\($0)</span>" }
            // Each author call in the blind byline leaves a roman space after the single visible entry.
            let trailing =
                style.anonymousAuthor == nil ? "" : " style=\"--latex-byline-spaces: \(front.namedAuthors.count)\""
            return "<div class=\"latex-author-row\"\(trailing)>\(cells.joined(separator: " "))</div>\n"
        }
        let names = style.anonymousAuthor ?? front.authors.map(\.name).joined(separator: #" \And "#)
        return LaTeXLexer.split(names, at: [#"\AND"#]).map { row in
            let blocks = LaTeXLexer.split(row, at: [#"\And"#]).map { block in
                let lines = LaTeXLexer.split(block, at: [#"\\"#]).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                let cells = lines.enumerated().map { index, line in
                    index == 0 && !style.regularAuthorNames ? "<strong>\(inline(line))</strong>" : inline(line)
                }
                let linesHTML = cells.joined(separator: "<br>")
                let content = style.columns == 2 ? "<span class=\"latex-author-lines\">\(linesHTML)</span>" : linesHTML
                return "<span class=\"latex-front-author\">\(content)</span>"
            }
            let separator =
                style.columns == 2 ? #"<span class="latex-author-separator" aria-hidden="true"></span>"# : ""
            return "<div class=\"latex-author-row\">\(blocks.joined(separator: separator))</div>\n"
        }.joined()
    }

    private func printAffiliationNotice(_ extra: String) {
        let front = document.frontMatter
        guard !front.printedColumnNotice, let style = document.classInfo.resolvedStyle,
            let notice = style.firstColumnNotice
        else { return }
        front.printedColumnNotice = true
        let affiliations: String
        let contacts: String
        if style.anonymousAuthor != nil {
            affiliations = "<sup>1</sup>Anonymous Institution, Anonymous City, Anonymous Region, Anonymous Country"
            contacts = "Anonymous Author &lt;anon.email@domain.com&gt;"
        } else {
            let marks = affiliationMarks()
            let byKey = Dictionary(uniqueKeysWithValues: front.affiliations.map { ($0.key, $0.parts) })
            var seen: Set<String> = []
            var addresses: [String] = []
            for author in front.namedAuthors {
                for key in author.affiliations where seen.insert(key).inserted {
                    if let value = byKey[key], let mark = marks[key] {
                        addresses.append("<sup>\(inline(mark))</sup>" + value.map(inline).joined(separator: ", "))
                    }
                }
            }
            let lead = extra.replacingOccurrences(
                of: #"\icmlEqualContribution"#, with: #"\textsuperscript{*}Equal contribution"#)
            affiliations = ([inline(lead)] + addresses).filter { !$0.isEmpty }.joined(separator: " ")
            contacts = front.correspondingAuthors.map { "\(inline($0.name)) &lt;\(HTML.escape($0.email))&gt;" }
                .joined(separator: ", ")
        }
        let address = affiliations.isEmpty ? "" : affiliations + "."
        let contact = contacts.isEmpty ? "" : " Correspondence to: " + contacts + "."
        appendBlock(
            "<template data-latex-column-notice=\"first\"><p>\(address)\(contact)</p><p>\(inline(notice))</p></template>\n"
        )
    }
}
