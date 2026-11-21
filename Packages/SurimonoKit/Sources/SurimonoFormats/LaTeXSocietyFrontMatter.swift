import Foundation

struct LaTeXSocietyFrontMatter {
    typealias Layout = LaTeXClassProfile.SocietyTitle

    struct Author {
        var native: String
        var english: String
        var membership: String
        var labels: [String]
        var email: String?
    }

    struct Affiliation {
        var label: String
        var lines: [String]
        var present: Bool
    }

    struct ManuscriptDate {
        let kind: String
        let year: String
        let month: String
        let day: String

        var english: String {
            let months = [
                "January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November", "December",
            ]
            let name = Int(month).flatMap { (1...12).contains($0) ? months[$0 - 1] : nil } ?? month
            return "\(name) \(day), \(year)"
        }

        var japanese: String { "\(year)年\(month)月\(day)日" }
    }

    enum AbstractSection: Int, CaseIterable {
        case nativeAbstract, nativeKeywords, englishAbstract, englishKeywords

        var english: Bool { self == .englishAbstract || self == .englishKeywords }
        var keywords: Bool { self == .nativeKeywords || self == .englishKeywords }
    }

    var englishTitle: String?
    var japaneseSubtitle: String?
    var englishSubtitle: String?
    var contactLine: String?
    var authors: [Author] = []
    var bylineBreaks: Set<Int> = []
    var affiliations: [Affiliation] = []
    var dates: [ManuscriptDate] = []
    var sections: [AbstractSection: String] = [:]
    var issue = LaTeXJournalIssue()
    var doi: String?
    var theme: String?
    var titleNote: String?
    var titleAdjustment: String?

    var hasBilingualMetadata: Bool { englishTitle != nil || authors.contains { !$0.native.isEmpty } }

    func resolveAbstracts(in html: String, layout: Layout, document: LaTeXDocument) -> String {
        var result = html
        var supplement = ""
        for section in AbstractSection.allCases {
            let content = sections[section] ?? ""
            result = result.replacingOccurrences(of: document.placeholder("SA", section.rawValue), with: content)
            // Before maketitle keep an abstract at its source if no title is ever printed.
            let endPage =
                layout == .insetBilingual && section.english && !document.classInfo.profile.titleBlock.englishInTitle
            let atSource = document.frontMatter.printed || endPage ? "" : content
            result = result.replacingOccurrences(of: document.placeholder("SB", section.rawValue), with: atSource)
            if endPage { supplement += content }
        }
        if document.classInfo.profile.titleBlock.datesAtEnd, !dates.isEmpty {
            var lastYear = ""
            let labels = ["received": "受付", "revised": "再受付", "finalreceived": "最終受付", "onlinefirst": "早期公開"]
            let line = dates.map { date in
                let year = date.year == lastYear ? "" : date.year + "年"
                lastYear = date.year
                return HTML.escape(year + date.month + "月" + date.day + "日" + (labels[date.kind] ?? "受付"))
            }.joined(separator: "，")
            result += "<p class=\"latex-society-dates\" lang=\"ja\">（\(line)）</p>\n"
        }
        if !supplement.isEmpty, !document.classInfo.profile.titleBlock.omitsEnglishSupplement {
            result += "<template data-latex-break=\"clear\"></template>\n" + document.columnMarker(1)
            result +=
                "<div class=\"latex-english-supplement\" data-latex-page-action=\"journalSupplement\" "
                + "data-value=\"empty\">\(supplement)</div>\n"
        }
        return result
    }
}

extension LaTeXReader {
    // pTeX treats these particular Japanese control sequences as words. Other classes
    // keep the existing control-symbol lexer, including its treatment of a following kanji.
    func societyDateControlWord() -> String? {
        guard document.classInfo.profile.titleBlock.societyLayout == .bilingualJournal else { return nil }
        for name in ["再再受付", "再受付", "受付", "採録"] {
            if characters[index...].starts(with: name), peek(name.count)?.isLetter != true {
                index += name.count
                return name
            }
        }
        return nil
    }

    func handleSocietyCommand(_ command: String, layout: LaTeXSocietyFrontMatter.Layout) -> Bool {
        let front = document.frontMatter
        switch command {
        case "jtitle", "title":
            front.shortTitle = optional()
            front.title = argument()
        case "etitle":
            _ = optional()
            front.society.englishTitle = argument()
        case "author" where layout == .bilingualJournal:
            let name = argument() ?? ""
            let second = argument() ?? ""
            let third = bracedSocietyArgument()
            let labels = societyLabels(third ?? second)
            front.society.authors.append(
                .init(
                    native: third == nil ? "" : name, english: third == nil ? name : second,
                    membership: "", labels: labels, email: optional()))
        case "authorlist" where layout != .bilingualJournal:
            _ = blocks(argument() ?? "")
        case "authorentry" where layout != .bilingualJournal:
            let email = optional()
            let name = argument() ?? ""
            let second = argument() ?? ""
            let third = argument() ?? ""
            // Some short-paper templates supply a membership code before the affiliation label.
            let fourth = layout == .insetBilingual ? bracedSocietyArgument() : nil
            let labels = societyLabels(fourth ?? third) + societyLabels(optional())
            front.society.authors.append(
                .init(
                    native: layout == .insetBilingual ? name : "",
                    english: layout == .insetBilingual ? second : name,
                    membership: layout == .insetBilingual ? (fourth == nil ? "" : third) : second,
                    labels: labels, email: email))
        case "MembershipNumber" where layout != .bilingualJournal:
            // A membership ID identifies the submission; it is not part of the printed byline.
            _ = argument()
        case "affiliate", "paffiliate":
            let key = layout == .bilingualJournal ? argument() : optional()
            var lines = [argument() ?? ""]
            if layout == .insetBilingual, let english = bracedSocietyArgument() { lines.append(english) }
            front.society.affiliations.append(.init(label: key ?? "", lines: lines, present: command == "paffiliate"))
        case "field": front.society.issue.field = LaTeXPageNumbers.text(argument() ?? "")
        case "vol": front.society.issue.volume = LaTeXPageNumbers.text(argument() ?? "")
        case "no": front.society.issue.issue = LaTeXPageNumbers.text(argument() ?? "")
        case "jalcdoi": front.society.doi = argument()
        case "jsubtitle": front.society.japaneseSubtitle = argument()
        case "esubtitle": front.society.englishSubtitle = argument()
        case "MailAddress": front.society.contactLine = argument()
        case "tecrepyear": front.society.issue.year = LaTeXPageNumbers.text(argument() ?? "")
        case "typeofletter": front.society.issue.paperType = LaTeXPageNumbers.text(argument() ?? "")
        case "titlenote": front.society.titleNote = argument()
        case "titleadj": front.society.titleAdjustment = argument().flatMap(LaTeXSymbols.printLength)
        case "theme": front.society.theme = argument()
        case "SpecialSection", "SpecialIssue":
            let prefix = command == "SpecialSection" ? "Special Section on " : "Special Issue on "
            front.society.theme = prefix + (argument() ?? "")
        case "breakauthorline" where layout != .bilingualJournal:
            front.society.bylineBreaks.formUnion(societyLabels(argument()).compactMap(Int.init))
        case "受付", "採録", "再受付", "再再受付", "received", "accepted", "rereceived", "rerereceived",
            "revised", "finalreceived", "onlinefirst", "released":
            let aliases = ["受付": "received", "採録": "accepted", "再受付": "rereceived", "再再受付": "rerereceived"]
            front.society.dates.append(
                .init(
                    kind: aliases[command] ?? command, year: argument() ?? "", month: argument() ?? "",
                    day: argument() ?? ""))
        default: return false
        }
        return true
    }

    private func bracedSocietyArgument() -> String? {
        let start = index
        skipSpaces()
        guard peek() == "{" else {
            index = start
            return nil
        }
        return argument()
    }

    private func societyLabels(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func societyAbstract(_ name: String) -> LaTeXSocietyFrontMatter.AbstractSection? {
        guard let layout = document.classInfo.profile.titleBlock.societyLayout else { return nil }
        let english =
            layout == .framedPaper
            || layout == .bilingualJournal && document.classInfo.mainLanguage == "en"
                && !document.frontMatter.society.hasBilingualMetadata
        switch name {
        case "summary", "eabstract": return .englishAbstract
        case "ekeyword": return .englishKeywords
        case "abstract": return english ? .englishAbstract : .nativeAbstract
        case "jabstract": return .nativeAbstract
        case "jkeyword": return .nativeKeywords
        case "keyword", "keywords": return english ? .englishKeywords : .nativeKeywords
        default: return nil
        }
    }

    func readSocietyAbstract(_ section: LaTeXSocietyFrontMatter.AbstractSection, body: String) {
        let front = document.frontMatter
        let layout = document.classInfo.profile.titleBlock.societyLayout
        if layout == .insetBilingual && section.english && !document.classInfo.profile.titleBlock.englishInTitle
            && document.classInfo.profile.titleBlock.omitsEnglishSupplement
        {
            return
        }
        let label: String
        switch section {
        case .nativeAbstract: label = layout == .insetBilingual ? "あらまし" : "概要："
        case .nativeKeywords: label = layout == .insetBilingual ? "キーワード" : "キーワード："
        case .englishAbstract:
            label = layout == .framedPaper ? "SUMMARY" : layout == .insetBilingual ? "Abstract" : "Abstract:"
        case .englishKeywords:
            label = layout == .framedPaper ? "key words:" : layout == .insetBilingual ? "Key words" : "Keywords:"
        }
        let prefix = "<strong>\(label)</strong>" + (label.hasSuffix("：") ? "" : " ")
        var content = blocks(body)
        if content.hasPrefix("<p"), let end = content.firstIndex(of: ">") {
            content.insert(contentsOf: prefix, at: content.index(after: end))
        } else {
            content = "<p>\(prefix)</p>\n" + content
        }
        let suffix = section.keywords ? "keywords" : "abstract"
        let language = section.english ? "en" : "ja"
        let html = "<div class=\"latex-front-\(suffix)\" lang=\"\(language)\">\(content)</div>\n"
        let inColumn = document.classInfo.profile.titleBlock.inColumn && !section.english && front.printed
        if (layout == .framedPaper || inColumn) && !inPreamble {
            appendBlock(html)
        } else {
            if front.society.sections[section] == nil && !inPreamble {
                appendBlock(document.placeholder("SB", section.rawValue))
            }
            front.society.sections[section, default: ""] += html
        }
    }
}
