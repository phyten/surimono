import Foundation

extension LaTeXSocietyFrontMatter {
    // The bilingual journal assigns numbers at declaration; the Transactions assign daggers
    // in byline order, even when the address declarations occur in another order.
    func affiliationMarks(_ layout: Layout) -> [String: String] {
        let present = Set(affiliations.filter(\.present).map(\.label))
        let declared = affiliations.map(\.label)
        let order = layout == .bilingualJournal ? declared : authors.flatMap(\.labels) + declared
        var marks: [String: String] = [:]
        var regular = 0
        var current = 0
        for key in order where !key.isEmpty && marks[key] == nil {
            let isPresent = present.contains(key)
            if isPresent { current += 1 } else { regular += 1 }
            let n = isPresent ? current : regular
            if layout == .bilingualJournal {
                marks[key] = (isPresent ? "†" : "") + String(n)
            } else {
                let symbol = isPresent ? "*" : "†"
                marks[key] = n <= 9 ? String(repeating: symbol, count: n) : symbol + String(n)
            }
        }
        return marks
    }

    static func nameParts(_ name: String) -> (given: String, family: String) {
        // A braced compound given name counts as one component.
        let parts = LaTeXLexer.split(name, at: [" ", "\n", "\t"]).filter { !$0.isEmpty }
        guard parts.count > 1 else { return ("", parts.first ?? "") }
        return (parts[0], parts.dropFirst().joined(separator: " "))
    }

    static func membership(_ code: String, plural: Bool) -> String {
        let singular: String
        switch code {
        case "m", "r": singular = "Member"
        case "n": singular = "Nonmember"
        case "s": singular = "Student Member"
        case "a": singular = "Affiliate Member"
        case "h": return plural ? "Fellows, Honorary Members" : "Fellow, Honorary Member"
        case "f": singular = "Fellow"
        case "e", "S": singular = "Senior Member"
        default: return code
        }
        return singular + (plural ? "s" : "")
    }

    var presentCount: Int { affiliations.filter(\.present).count }

    var titleNoteMark: String {
        guard titleNote?.isEmpty == false else { return "" }
        return presentCount < 6 ? String(repeating: "*", count: presentCount + 1) : "*\(presentCount + 1)"
    }

    var emailMarks: [Int: String] {
        var marks: [Int: String] = [:]
        for (i, author) in authors.enumerated() where author.email?.isEmpty == false {
            marks[i] = LaTeXSymbols.format(marks.count + 1, as: "alph") + ")"
        }
        return marks
    }
}

extension LaTeXReader {
    typealias SocietyLayout = LaTeXSocietyFrontMatter.Layout

    func makeSocietyTitle(_ layout: SocietyLayout) {
        let front = document.frontMatter
        let society = front.society
        let profile = document.classInfo.profile.titleBlock
        let english =
            layout == .framedPaper
            || layout == .bilingualJournal && document.classInfo.mainLanguage == "en" && !society.hasBilingualMetadata
        let nativeTitle = front.title.map(inline) ?? ""
        document.titleHTML = nativeTitle
        let marks = society.affiliationMarks(layout)
        let emails = society.emailMarks
        let language = english ? "en" : "ja"
        let mark = society.titleNoteMark.isEmpty ? "" : "<sup class=\"latex-front-mark\">\(society.titleNoteMark)</sup>"
        let firstTitle =
            nativeTitle.isEmpty
            ? "" : "<h1 class=\"latex-front-title\" lang=\"\(language)\">\(nativeTitle)\(mark)</h1>\n"
        let type = document.classInfo.profile.titleBlock.paperTypeLabel
        let special = society.theme.map { " <em>\(inline($0))</em>" } ?? ""
        let label = type.isEmpty ? "" : "<div class=\"latex-paper-type\">\(HTML.escape(type))\(special)</div>\n"

        let span =
            profile.inColumn ? " data-latex-in-column" : (document.classInfo.columns > 1 ? " data-latex-wide" : "")
        let adjustment = society.titleAdjustment.map { " style=\"margin-bottom: \($0)\"" } ?? ""
        var title = "<header class=\"latex-title-block\"\(span)\(adjustment)>\n"
        if profile.englishInTitle {
            title += "<div class=\"latex-paper-type\">信学技報<br>IEICE Technical Report</div>\n"
        }
        if layout == .framedPaper {
            title += "<div class=\"latex-framed-title\">\(label)\(firstTitle)</div>\n"
        } else {
            if layout == .bilingualJournal { title += label }
            title += firstTitle
        }
        if let subtitle = society.japaneseSubtitle {
            title += "<p class=\"latex-front-subtitle\" lang=\"ja\">\(inline(subtitle))</p>\n"
        }
        title += societyByline(layout, english: english, marks: marks, emails: emails)
        if layout == .bilingualJournal { title += societyDates(english: english) }

        func abstractSlots(english: Bool) -> String {
            LaTeXSocietyFrontMatter.AbstractSection.allCases.filter { $0.english == english }
                .map { document.placeholder("SA", $0.rawValue) }.joined()
        }
        if profile.englishInTitle {
            title += reportAddresses(english: false, marks: marks)
        }
        if !english && (layout == .bilingualJournal || profile.englishInTitle) {
            title += abstractSlots(english: false)
        }
        if !english {
            if let second = society.englishTitle {
                title += "<h2 class=\"latex-front-title\" lang=\"en\">\(inline(second))</h2>\n"
            }
            if let subtitle = society.englishSubtitle {
                title += "<p class=\"latex-front-subtitle\" lang=\"en\">\(inline(subtitle))</p>\n"
            }
            title += societyByline(layout, english: true, marks: marks, emails: emails)
            if layout == .bilingualJournal { title += societyDates(english: true) }
        }
        if profile.englishInTitle {
            title += reportAddresses(english: true, marks: marks) + abstractSlots(english: true)
        } else if layout != .framedPaper {
            title += abstractSlots(english: layout == .bilingualJournal)
        }
        title += "</header>\n"
        appendBlock(title)
        appendBlock(societyNotes(layout, marks: marks, emails: emails))
        if layout == .framedPaper {
            appendBlock(abstractSlots(english: true))
            document.counters["footnote"] = 6 + society.presentCount + (society.titleNoteMark.isEmpty ? 0 : 1)
        }
        setSocietyIssue(layout)
    }

    private func reportAddresses(english: Bool, marks: [String: String]) -> String {
        let society = document.frontMatter.society
        var html = ""
        for affiliation in society.affiliations {
            let index = english ? 1 : 0
            guard affiliation.lines.indices.contains(index) else { continue }
            let mark = marks[affiliation.label] ?? ""
            html += "<p class=\"latex-front-affiliation\"><sup>\(mark)</sup>\(inline(affiliation.lines[index]))</p>\n"
        }
        let contacts =
            society.contactLine.map(inline) ?? society.authors.compactMap(\.email).map(inline).joined(separator: ", ")
        if !contacts.isEmpty { html += "<p class=\"latex-front-email\">E-mail: \(contacts)</p>\n" }
        return html
    }

    private func setSocietyIssue(_ layout: SocietyLayout) {
        let front = document.frontMatter
        var issue = front.society.issue
        issue.shortTitle = LaTeXPageNumbers.text(front.shortTitle ?? front.title ?? "")
        let profile = document.classInfo.profile.titleBlock
        if issue.paperType.isEmpty { issue.paperType = profile.paperTypeLabel }
        issue.yearOffset = profile.yearOffset
        issue.journalName = document.classInfo.profile.titleBlock.journalName
        let family = front.society.authors.map {
            LaTeXPageNumbers.text(LaTeXSocietyFrontMatter.nameParts($0.english).family).uppercased()
        }
        if family.count > 2, let first = family.first {
            issue.authorHeading = first + " et al."
        } else {
            issue.authorHeading = family.joined(separator: " and ")
        }
        if layout == .bilingualJournal {
            let counters = document.counters
            func value(_ names: [String]) -> String {
                names.first(where: counters.contains).map { String(counters[$0]) } ?? ""
            }
            issue.volume = value(["巻数", "volume"])
            issue.issue = value(["号数", "number"])
            issue.year = value(["年数", "year"])
            issue.month = value(["月数", "month"])
        }
        document.classInfo.pageNumbers.setJournalIssue(issue)
    }

    private func societyByline(_ layout: SocietyLayout, english: Bool, marks: [String: String], emails: [Int: String])
        -> String
    {
        let authors = document.frontMatter.society.authors
        var line = ""
        var consecutive = 0
        for (index, author) in authors.enumerated() {
            let source = english ? author.english : author.native
            guard !source.isEmpty else { continue }
            let name: String
            if english && layout != .bilingualJournal {
                let parts = LaTeXSocietyFrontMatter.nameParts(source)
                name = inline((parts.given.isEmpty ? "" : parts.given + " ") + "\\MakeUppercase{\(parts.family)}")
            } else if layout == .insetBilingual && !english {
                // The native byline separates the first two name fields at a top-level TeX space.
                let (first, rest) = LaTeXSocietyFrontMatter.nameParts(source)
                name =
                    first.isEmpty
                    ? inline(source)
                    : "<span class=\"latex-japanese-name\"><span>\(inline(first))</span> <span>\(inline(rest))</span></span>"
            } else {
                name = inline(source)
            }
            if !line.isEmpty {
                if english && layout != .bilingualJournal {
                    let and = layout == .framedPaper ? "<em>and</em>" : "and"
                    line += index == authors.count - 1 ? (authors.count == 2 ? " " : ", ") + and + " " : ", "
                } else {
                    line += " "
                }
            }
            var symbols = author.labels.compactMap { marks[$0] }
            let separator = layout == .bilingualJournal ? "," : ""
            if let email = emails[index] { symbols.append(email) }
            let mark =
                symbols.isEmpty ? "" : "<sup class=\"latex-front-mark\">\(symbols.joined(separator: separator))</sup>"
            line += "<span class=\"latex-front-author\">\(name)\(mark)</span>"
            if english, layout != .bilingualJournal, !author.membership.isEmpty {
                consecutive += 1
                if index == authors.count - 1 || authors[index + 1].membership != author.membership {
                    line +=
                        ", <em>\(HTML.escape(LaTeXSocietyFrontMatter.membership(author.membership, plural: consecutive > 1)))</em>"
                    consecutive = 0
                }
            }
            if english, document.frontMatter.society.bylineBreaks.contains(index + 1), index < authors.count - 1 {
                line += "<br>"
            }
        }
        return line.isEmpty
            ? "" : "<div class=\"latex-front-author-row\" lang=\"\(english ? "en" : "ja")\">\(line)</div>\n"
    }

    private func societyDates(english: Bool) -> String {
        let dates = document.frontMatter.society.dates
        guard !dates.isEmpty else { return "" }
        let labels =
            english
            ? ["received": "Received:", "accepted": "Accepted:", "released": "Released:"]
            : ["received": "受付日", "accepted": "採録日", "released": "公開日"]
        let line = dates.map { date in
            (labels[date.kind] ?? (english ? "Revised:" : "再受付日")) + " "
                + inline(english ? date.english : date.japanese)
        }.joined(separator: ", ")
        return "<p class=\"latex-society-dates\" lang=\"\(english ? "en" : "ja")\">\(line)</p>\n"
    }

    private func societyNotes(_ layout: SocietyLayout, marks: [String: String], emails: [Int: String]) -> String {
        let society = document.frontMatter.society
        var lines: [String] = []
        if layout != .bilingualJournal && !document.classInfo.profile.titleBlock.datesAtEnd {
            for date in society.dates {
                if layout == .framedPaper {
                    let label =
                        [
                            "finalreceived": "Final manuscript received", "onlinefirst": "Manuscript publicized",
                            "revised": "Manuscript revised",
                        ][date.kind] ?? "Manuscript received"
                    lines.append("\(label) \(inline(date.english)).")
                } else {
                    lines.append(inline(date.japanese) + (date.kind == "received" ? "受付" : "再受付"))
                }
            }
        }
        let addressesInTitle = document.classInfo.profile.titleBlock.englishInTitle
        for present in [false, true] where !addressesInTitle {
            for affiliation in society.affiliations where affiliation.present == present {
                let mark = marks[affiliation.label] ?? ""
                let text = affiliation.lines.map(inline).joined(separator: "<br>")
                let prefix =
                    layout == .bilingualJournal && present
                    ? (document.classInfo.mainLanguage == "en" ? "Presently, " : "現在，") : ""
                lines.append("<sup class=\"latex-note-mark\">\(mark)</sup>\(prefix)\(text)")
            }
        }
        if let note = society.titleNote, !note.isEmpty {
            lines.append("<sup class=\"latex-note-mark\">\(society.titleNoteMark)</sup>\(inline(note))")
        }
        for (index, author) in society.authors.enumerated() where !addressesInTitle {
            if let mark = emails[index], let address = author.email {
                let label = layout == .bilingualJournal ? "" : "E-mail: "
                let tag = layout == .bilingualJournal ? "sup" : "span"
                let gap = layout == .bilingualJournal ? "" : " "
                lines.append("<\(tag) class=\"latex-note-mark\">\(mark)</\(tag)>\(gap)\(label)\(inline(address))")
            }
        }
        let field = society.issue.field
        let journal = ["A": "fun", "B": "com", "C": "ele", "D": "inf"][field] ?? ""
        if layout == .insetBilingual, let doi = society.doi, !doi.isEmpty {
            lines.append("DOI:10.14923/trans\(journal)j.\(inline(doi))")
        }
        if layout == .framedPaper {
            if let doi = society.doi, !doi.isEmpty {
                let supplied = inline(doi)
                lines.append(supplied.lowercased().hasPrefix("doi:") ? supplied : "DOI: " + supplied)
            } else {
                let volume = Int(society.issue.volume) ?? 0
                let page = document.counters.contains("page") ? document.counters["page"] : 1
                lines.append("DOI: 10.1587/trans\(journal).E\(volume).\(HTML.escape(field)).\(page)")
            }
        }
        guard !lines.isEmpty else { return "" }
        return "<template data-latex-column-notice=\"first\">" + lines.map { "<p>\($0)</p>" }.joined() + "</template>\n"
    }
}
