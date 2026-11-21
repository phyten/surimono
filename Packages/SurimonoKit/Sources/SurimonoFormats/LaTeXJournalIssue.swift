import Foundation

/// The title reader supplies text; issue and page numbers are resolved once the paper has pages.
struct LaTeXJournalIssue: Equatable, Sendable {
    var field = ""
    var volume = ""
    var issue = ""
    var year = ""
    var month = ""
    var shortTitle = ""
    var authorHeading = ""
    var paperType = ""
    var journalName = ""
    var yearOffset = 1959

    // These keys share the running furniture dictionary with fancyhdr fields (OLH, ECF, etc.).
    // Both directions use the same mapping so writing a new title replaces every old issue field.
    private static var textFields: [(String, WritableKeyPath<Self, String>)] {
        [
            ("journalField", \.field), ("journalVolume", \.volume), ("journalIssueNumber", \.issue),
            ("journalYear", \.year), ("journalMonth", \.month), ("journalShortTitle", \.shortTitle),
            ("journalAuthorHeading", \.authorHeading), ("journalPaperType", \.paperType),
            ("journalName", \.journalName),
        ]
    }

    init(fields: [String: String] = [:]) {
        for (key, path) in Self.textFields { self[keyPath: path] = fields[key] ?? "" }
        yearOffset = fields["journalYearOffset"].flatMap(Int.init) ?? 1959
    }

    func store(in fields: inout [String: String]) {
        for (key, path) in Self.textFields {
            let value = self[keyPath: path]
            fields[key] = value.isEmpty ? nil : value
        }
        fields["journalYearOffset"] = yearOffset == 1959 ? nil : String(yearOffset)
    }

    private func publicationYear(offset: Int, default fallback: String) -> String {
        if !year.isEmpty { return year }
        guard let vol = Int(volume), (0...9999).contains(vol) else { return fallback }
        return String(vol + offset)
    }

    private var monthIndex: Int? {
        guard let n = Int(month.isEmpty ? issue : month), (1...12).contains(n) else { return nil }
        return n - 1
    }

    func page(
        _ layout: LaTeXJournalPage.Layout, first: Bool, even: Bool, label: String, range: String,
        doiPrefix: String?, runningType: String?
    ) -> LaTeXJournalPage {
        var page = LaTeXJournalPage()
        let volumeText = volume.isEmpty ? "xx" : volume
        let issueText = issue.isEmpty ? "xx" : issue
        switch layout {
        case .issueAndCopyright, .bilingualReport, .reportTitle:
            let year = publicationYear(offset: yearOffset, default: String(yearOffset))
            let months = [
                "Jan.", "Feb.", "Mar.", "Apr.", "May", "June", "July", "Aug.", "Sep.", "Oct.", "Nov.", "Dec.",
            ]
            let date = (monthIndex.map { months[$0] } ?? "???") + " " + year
            let title = journalName.isEmpty ? "情報処理学会論文誌" : journalName
            page.top[0] =
                "\(title)　Vol.\(volume.isEmpty ? "0" : volume)　No.\(issue.isEmpty ? "0" : issue)　\(range) (\(date))"
            page.bottom[0] = "© \(year) Information Processing Society of Japan"
            page.bottom[2] = label
            page.headerFont = .init(family: "sans", weight: "bold", sizeInPoints: 9.25)
            page.japaneseHeaderFace = "HiraginoSans-W5"
            page.japaneseHeaderScale = 8.51 / (9.25 * 72 / 72.27)
            page.footerFont = .init(sizeInPoints: 7.11)
            page.copyrightFont = .init(family: "Times New Roman", sizeInPoints: 7.11)
            page.numberFont = .init(sizeInPoints: 9.25)
            page.footerNumberSlot = 2
            if layout == .reportTitle || layout == .bilingualReport {
                page.top[0] = title
                if layout == .bilingualReport {
                    page.secondary = .init(
                        text: "IPSJ SIG Technical Report", header: true, loweredMM: 4, trailingInset: nil,
                        font: .init(sizeInPoints: 7.83))
                }
            } else if first, let doiPrefix {
                page.secondary = .init(
                    text: "[DOI: \(doiPrefix).\(volume.isEmpty ? "0" : volume).\(label)]",
                    header: true, loweredMM: 6, trailingInset: nil,
                    font: .init(family: "sans", sizeInPoints: 7.83))
            }
        case .ruledType:
            let year = publicationYear(offset: 1917, default: "xxxx")
            let field = field.isEmpty ? "X" : field
            let volume = "J\(volumeText)–\(field)"
            let type = paperType.isEmpty ? "論文" : paperType
            page.headRule = 0.25 * Self.bpPerMM
            page.headRuleDepth = 1.5 * Self.bpPerMM
            if first {
                page.top[0] = type == "論文" ? "論　文" : type
                page.headerFont = .init(sizeInPoints: 17.28)
                page.japaneseHeaderFace = "HiraMinProN-W3"
                page.japaneseHeaderScale = 17.01 / (17.28 * 72 / 72.27)
                page.headerLeftInset = runningType == nil ? 14 * Self.bpPerMM : 0
                page.headerLowering[0] = 3 * Self.bpPerMM
                page.interruptsRuleAtLeftText = true
                page.bottom[1] =
                    "電子情報通信学会論文誌　\(field)　Vol. \(volume)　No. \(issueText)　pp. \(range)　©一般社団法人電子情報通信学会 \(year)"
                page.japaneseFooterFace = "HiraginoSans-W5"
                page.copyrightFont = .init(family: "Times New Roman", sizeInPoints: 8)
                page.japaneseFooterScale = 7.09 / (7.52 * 72 / 72.27)
            } else {
                if even {
                    page.top[2] = "電子情報通信学会論文誌 \(year)/\(issueText) Vol. \(volume) No. \(issueText)"
                } else {
                    page.top[0] = runningType ?? "\(type)／\(shortTitle)"
                }
                page.headerFont = .init(sizeInPoints: 8)
                page.japaneseHeaderFace = "HiraMinProN-W3"
                page.japaneseHeaderScale = 7.8 / (8 * 72 / 72.27)
            }
            let slot = even && !first ? 0 : 2
            page.bottom[slot] = label
            page.footerNumberSlot = slot
            page.footerSideInset = 3 * Self.bpPerMM
            page.footerFont = .init(family: "Helvetica", sizeInPoints: 7.52)
            page.numberFont = page.footerFont
        case .outerHeaderNumber:
            let names = ["A": "FUNDAMENTALS", "B": "COMMUN.", "C": "ELECTRON.", "D": "INF. & SYST."]
            let year = publicationYear(offset: 1917, default: "200x")
            let monthNames = [
                "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER",
                "NOVEMBER", "DECEMBER",
            ]
            let month = monthIndex.map { monthNames[$0] } ?? "XXXX"
            let part = volume.isEmpty || names[field] == nil ? "??" : field
            let issueLine =
                "IEICE TRANS. \(names[field] ?? "??"), VOL.E\(volumeText)–\(part), NO.\(issueText) \(month) \(year)"
            let slot = even ? 0 : 2
            page.top[2 - slot] =
                (first || even)
                ? issueLine
                : runningType
                    ?? [authorHeading, shortTitle.uppercased()].filter { !$0.isEmpty }.joined(separator: ": ")
            page.top[slot] = label
            page.headerNumberSlot = slot
            page.headerLowering[slot] = 3 * Self.bpPerMM
            page.headerFont = .init(sizeInPoints: 7)
            page.numberFont = .init(sizeInPoints: 8)
            if first {
                page.bottom[1] =
                    "Copyright © \(year) The Institute of Electronics, Information and Communication Engineers"
                page.footerLowering = 7 * Self.bpPerMM
            }
        case .reportNotice:
            page.footerFont = .init(sizeInPoints: 9)
            if first {
                page.bottom[0] =
                    "This article is a technical report without peer review. A revised or extended version may appear elsewhere."
                page.secondary = .init(
                    text: "Copyright ©\(year.isEmpty ? "20xx" : year) by IEICE",
                    header: false, loweredMM: 3.5, trailingInset: 9 * 72 / 72.27, font: .init(sizeInPoints: 9))
            } else {
                page.bottom[2] = "— \(label) —"
            }
        }
        return page
    }

    private static let bpPerMM = 72.0 / 25.4
}

/// Baseline offsets and rule lengths are PDF points relative to the class header and footer baselines.
package struct LaTeXJournalPage: Equatable, Sendable {
    enum Layout: String, Equatable, Sendable {
        case issueAndCopyright, bilingualReport, reportTitle, ruledType, outerHeaderNumber, reportNotice
    }
    package struct Secondary: Equatable, Sendable {
        package var text: String
        package var header: Bool
        package var loweredMM: Double
        package var trailingInset: Double?
        package var font: LaTeXElementFont
    }

    package var secondary: Secondary?
    package var top = ["", "", ""]
    package var bottom = ["", "", ""]
    package var headerFont: LaTeXElementFont?
    package var footerFont: LaTeXElementFont?
    package var copyrightFont: LaTeXElementFont?
    package var numberFont: LaTeXElementFont?
    package var japaneseHeaderFace: String?
    package var japaneseFooterFace: String?
    package var japaneseHeaderScale = 1.0
    package var japaneseFooterScale = 1.0
    package var headerNumberSlot: Int?
    package var footerNumberSlot: Int?
    package var headerLeftInset = 0.0
    package var footerSideInset = 0.0
    package var headerLowering = [0.0, 0.0, 0.0]
    package var footerLowering = 0.0
    package var headRule = 0.0
    package var headRuleDepth = 0.0
    package var interruptsRuleAtLeftText = false
}
