import Foundation

package struct LaTeXResolvedStyle: Equatable, Sendable {
    package enum Family: String, Sendable { case neurips, iclr, icml, cvpr, acl, aaai }
    package typealias Mode = LaTeXRecognition.Mode
    package enum Review: String, Codable, Sendable {
        case textLines, ruler, leftRuler, blueColumnLines, grayColumnLines
    }
    enum DisplayFace: Sendable { case bold, smallCaps }

    let classProfile: LaTeXClassProfile
    let requestedName: String
    package let family: Family
    var displayName: String {
        let name = family == .neurips ? "NeurIPS" : family.rawValue.uppercased()
        return name + " " + (displayYear ?? (year.isEmpty ? String(definitionYear) : year))
    }
    var displayYear: String?
    let year: String
    let definitionYear: Int
    let options: [String]
    package let mode: Mode
    let displayFace: DisplayFace
    let acknowledgementHeading: String?
    let anonymousAuthor: String?
    let loadsNatbib: Bool
    let usesTimesRoman: Bool
    var paper = LaTeXClassProfile.Paper.letter
    var columns = 1
    var textWidthInches = 5.5
    var textHeightInches = 9.0
    let textTop: Double  // PDF points
    let headSep: Double  // TeX points
    let baseline: Double
    let paragraphSkip: Double
    let noteSize: Double
    let notePitch: Double
    var maximumTopFloatFraction: Double
    var maximumBottomFloatFraction: Double
    var minimumTextFraction: Double
    var floatPageFraction: Double
    let captionSkip: Double
    let runningHeader: String?
    package let firstPageNotice: String?
    package let review: Review?
    let diagnostics: [String]
    var textLeft: Double?
    var columnGap: Double?  // TeX points, as for an explicit columnsep.
    var footSkip: Double = 30
    var headHeight: Double = 12
    var paragraphIndent: Double = 0
    var outerParsep: Double = 2
    var noteRuleWidth: Double = 144
    var smallPitch: Double = 10
    var pointSize = 10
    var headingDot = false
    var runInSubsubsection = false
    var captionSeparator: String?
    var firstColumnNotice: String?
    var usesAffiliationList = false
    var separateAffiliations = false
    var regularAuthorNames = false
    var showsPageNumbers = true
    var centeredRunningTitle = false
    package var runningTitleFallback: String?
    package var reviewBanner: String?
    package var reviewCorner: String?
    package var raggedBottom = false
    package var frenchSpacing = false
}

enum LaTeXStylePackageRegistry {
    struct Request {
        let name: String
        let year: String
        let family: LaTeXResolvedStyle.Family
        let options: [String]

        var usesAffiliationList: Bool { family == .icml }
        var separateAffiliations: Bool { family == .aaai }

        var loadsNatbib: Bool {
            switch family {
            case .neurips: !options.contains("nonatbib")
            case .iclr, .icml, .cvpr, .acl: true
            case .aaai: false
            }
        }
    }

    // Year-specific definitions require a complete filename stem with four ASCII digits.
    static func match(_ name: String, options: [String]) -> Request? {
        if let match = name.wholeMatch(of: /neurips_([0-9]{4})/) {
            return Request(name: name, year: String(match.1), family: .neurips, options: options)
        }
        if let match = name.wholeMatch(of: /iclr([0-9]{4})_conference/) {
            return Request(name: name, year: String(match.1), family: .iclr, options: options)
        }
        if let match = name.wholeMatch(of: /icml([0-9]{4})/) {
            return Request(name: name, year: String(match.1), family: .icml, options: options)
        }
        if let match = name.wholeMatch(of: /aaai([0-9]{4})/) {
            return Request(name: name, year: String(match.1), family: .aaai, options: options)
        }
        switch name {
        case "cvpr": return Request(name: name, year: "", family: .cvpr, options: options)
        case "acl": return Request(name: name, year: "", family: .acl, options: options)
        default: return nil
        }
    }

    // Keep the pre-existing two-column hint for older, abbreviated package names.
    static func usesLegacyColumns(_ name: String) -> Bool {
        name.wholeMatch(of: /icml(?:[0-9]{2,4})?/) != nil
    }

    static func resolve(
        _ request: Request, profile: LaTeXClassProfile, finalCopy: Bool, workshop: String,
        macros: [String: LaTeXDocument.Macro], shortTitle: String?
    )
        -> LaTeXResolvedStyle
    {
        switch request.family {
        case .neurips: neurips(request, profile: profile, workshop: workshop)
        case .iclr: iclr(request, profile: profile, finalCopy: finalCopy)
        case .icml: icml(request, profile: profile, shortTitle: shortTitle)
        case .cvpr: cvpr(request, profile: profile, macros: macros)
        case .acl: acl(request, profile: profile)
        case .aaai: aaai(request, profile: profile)
        }
    }

    private static func neurips(_ r: Request, profile: LaTeXClassProfile, workshop: String) -> LaTeXResolvedStyle {
        let tracks = ["main", "position", "eandd", "creativeai", "education", "sglblindworkshop", "dblblindworkshop"]
        let known = tracks + ["final", "preprint", "nonatbib", "nonanonymous"]
        let mode: LaTeXResolvedStyle.Mode =
            r.options.contains("preprint") ? .preprint : r.options.contains("final") ? .final : .submission
        let track = r.options.last(where: tracks.contains) ?? "main"
        let anonymous =
            mode == .submission && !r.options.contains("nonanonymous")
            && !["education", "creativeai", "sglblindworkshop"].contains(track)
        let meeting = "40th Conference on Neural Information Processing Systems (NeurIPS 2026)."
        let suffix: String
        switch track {
        case "position": suffix = " Position Paper Track."
        case "eandd": suffix = " Track on Evaluations and Datasets."
        case "education": suffix = " Education Track."
        case "creativeai": suffix = " Creative AI Track."
        case "sglblindworkshop", "dblblindworkshop": suffix = " Workshop: \(workshop)."
        default: suffix = ""
        }
        let notice: String
        switch mode {
        case .submission: notice = "Submitted to \(meeting) Do not distribute."
        case .final: notice = meeting + suffix
        case .preprint, .draft, .rebuttal: notice = "Preprint."
        }
        return LaTeXResolvedStyle(
            classProfile: profile, requestedName: r.name, family: r.family, year: r.year, definitionYear: 2026,
            options: r.options, mode: mode, displayFace: .bold,
            acknowledgementHeading: mode == .submission ? "" : "Acknowledgments and Disclosure of Funding",
            anonymousAuthor: anonymous ? #"Anonymous Author(s) \\ Affiliation \\ Address \\ \texttt{email}"# : nil,
            loadsNatbib: r.loadsNatbib, usesTimesRoman: true, textTop: 72, headSep: 25,
            baseline: 10.95, paragraphSkip: 5.5, noteSize: 8, notePitch: 9.5, maximumTopFloatFraction: 0.85,
            maximumBottomFloatFraction: 0.4, minimumTextFraction: 0.1, floatPageFraction: 0.7, captionSkip: 7,
            runningHeader: nil, firstPageNotice: notice, review: mode == .submission ? .textLines : nil,
            diagnostics: r.options.filter { !known.contains($0) })
    }

    private static func iclr(_ r: Request, profile: LaTeXClassProfile, finalCopy: Bool) -> LaTeXResolvedStyle {
        let header = finalCopy ? "Published as a conference paper" : "Under review as a conference paper"
        return LaTeXResolvedStyle(
            classProfile: profile, requestedName: r.name, family: r.family, year: r.year, definitionYear: 2027,
            options: r.options, mode: finalCopy ? .final : .submission, displayFace: .smallCaps,
            acknowledgementHeading: nil,
            anonymousAuthor: finalCopy ? nil : #"Anonymous authors \\ Paper under double-blind review"#,
            loadsNatbib: true, usesTimesRoman: false, textTop: 81.862, headSep: 25 + 0.25 * 72.27,
            baseline: 11, paragraphSkip: 6, noteSize: 9, notePitch: 10, maximumTopFloatFraction: 0.95,
            maximumBottomFloatFraction: 0.3, minimumTextFraction: 0.05, floatPageFraction: 0.5, captionSkip: 10,
            runningHeader: "\(header) at ICLR \(r.year)", firstPageNotice: nil, review: finalCopy ? nil : .ruler,
            diagnostics: r.options)
    }
    private static func twoColumn(
        _ r: Request, _ profile: LaTeXClassProfile, mode: LaTeXResolvedStyle.Mode, definitionYear: Int,
        options: [String], width: Double, height: Double, top: Double, gap: Double,
        baseline: Double, parskip: Double = 0, anonymous: String? = nil,
        times: Bool = true, noteSize: Double = 9, notePitch: Double = 10,
        captionSkip: Double = 10, runningHeader: String? = nil, review: LaTeXResolvedStyle.Review? = nil
    ) -> LaTeXResolvedStyle {
        var style = LaTeXResolvedStyle(
            classProfile: profile, requestedName: r.name, family: r.family, year: r.year,
            definitionYear: definitionYear, options: r.options, mode: mode, displayFace: .bold,
            acknowledgementHeading: nil, anonymousAuthor: anonymous, loadsNatbib: r.loadsNatbib,
            usesTimesRoman: times, textTop: top, headSep: runningHeader == nil ? 0 : 10,
            baseline: baseline, paragraphSkip: parskip, noteSize: noteSize, notePitch: notePitch,
            maximumTopFloatFraction: 0.7, maximumBottomFloatFraction: 0.3,
            minimumTextFraction: 0.2, floatPageFraction: 0.5, captionSkip: captionSkip,
            runningHeader: runningHeader, firstPageNotice: nil, review: review,
            diagnostics: r.options.filter { !options.contains($0) })
        style.columns = 2
        style.textWidthInches = width / 72
        style.textHeightInches = height / 72
        style.columnGap = gap * 72.27 / 72
        style.headHeight = 0
        return style
    }

    private static func icml(_ r: Request, profile: LaTeXClassProfile, shortTitle: String?) -> LaTeXResolvedStyle {
        let mode: LaTeXResolvedStyle.Mode =
            r.options.contains("preprint") ? .preprint : r.options.contains("accepted") ? .final : .submission
        var style = twoColumn(
            r, profile, mode: mode, definitionYear: 2026, options: ["preprint", "accepted", "nohyperref"],
            width: 486, height: 648, top: 67.07, gap: 18, baseline: 12, parskip: 6,
            anonymous: mode == .submission ? "Anonymous Authors" : nil, captionSkip: 7.227,
            runningHeader: shortTitle ?? "", review: mode == .submission ? .leftRuler : nil)
        style.textLeft = 55.44
        style.headHeight = 10
        style.footSkip = 25
        style.centeredRunningTitle = true
        style.runningTitleFallback = "Title Suppressed Due to Excessive Size"
        style.noteRuleWidth = 0.8 * 72.27
        style.headingDot = true
        style.outerParsep = 4
        style.captionSeparator = ". "
        style.usesAffiliationList = true
        switch mode {
        case .submission:
            style.firstColumnNotice =
                "Preliminary work. Under review by the International Conference on Machine Learning (ICML). Do not distribute."
        case .preprint: style.firstColumnNotice = #"\textit{Preprint. \today.}"#
        default:
            // The meeting details belong to the bundled definition, even for another requested year.
            style.firstColumnNotice =
                #"\textit{Proceedings of the 43\textsuperscript{rd} International Conference on Machine Learning}, Seoul, South Korea. PMLR 306, 2026. Copyright 2026 by the author(s)."#
        }
        return style
    }

    private static func cvpr(_ r: Request, profile: LaTeXClassProfile, macros: [String: LaTeXDocument.Macro])
        -> LaTeXResolvedStyle
    {
        func literal(_ name: String) -> String? {
            guard let macro = macros[name], macro.specification.isEmpty else { return nil }
            let text = LaTeXPageNumbers.text(macro.body)
            return text.isEmpty ? nil : text
        }
        let mode: LaTeXResolvedStyle.Mode =
            r.options.contains("rebuttal") ? .rebuttal : r.options.contains("review") ? .submission : .final
        let meeting = literal("confName") ?? "CVPR"
        let year = literal("confYear") ?? "2027"
        let id = literal("paperID")
        var anonymous: String?
        if mode == .submission {
            anonymous = "Anonymous \(meeting) submission" + (id.map { #" \\ Paper ID "# + $0 } ?? "")
        } else if mode == .rebuttal {
            anonymous = ""
        }
        var style = twoColumn(
            r, profile, mode: mode, definitionYear: 2027, options: ["review", "rebuttal", "pagenumbers"],
            width: 495, height: 639, top: 72, gap: 22.5, baseline: 12, anonymous: anonymous,
            noteSize: 8, notePitch: 9.5, review: mode == .final ? nil : .blueColumnLines)
        style.displayYear = year
        style.showsPageNumbers = r.options.contains("review") || r.options.contains("pagenumbers")
        style.paragraphIndent = 12
        style.outerParsep = 0
        style.maximumTopFloatFraction = 0.99
        style.maximumBottomFloatFraction = 0.99
        style.minimumTextFraction = 0.01
        style.floatPageFraction = 0.99
        style.smallPitch = 11
        style.regularAuthorNames = true
        style.headingDot = true
        style.noteRuleWidth = 94.5 * 72.27 / 72
        style.captionSeparator = ". "
        if mode != .final {
            let paper = id.map { " #" + $0 } ?? ""
            style.reviewBanner = "\(meeting) \(year) Submission\(paper). CONFIDENTIAL REVIEW COPY. DO NOT DISTRIBUTE."
            style.reviewCorner = meeting
        }
        return style
    }

    private static func acl(_ r: Request, profile: LaTeXClassProfile) -> LaTeXResolvedStyle {
        let mode: LaTeXResolvedStyle.Mode =
            r.options.contains("preprint") ? .preprint : r.options.contains("review") ? .submission : .final
        let cm = 72 / 2.54
        var style = twoColumn(
            r, profile, mode: mode, definitionYear: 2026,
            options: ["review", "final", "preprint", "hyperref", "nohyperref"],
            width: 16 * cm, height: 704.6 * 72 / 72.27, top: 2.5 * cm, gap: 0.6 * cm,
            baseline: 13.6, anonymous: mode == .submission ? "Anonymous ACL submission" : nil,
            times: false, review: mode == .submission ? .grayColumnLines : nil)
        style.paper = .a4
        style.paragraphIndent = 10.95
        style.outerParsep = 4.5
        style.pointSize = 11
        style.showsPageNumbers = mode == .submission
        style.noteRuleWidth = 60
        return style
    }

    private static func aaai(_ r: Request, profile: LaTeXClassProfile) -> LaTeXResolvedStyle {
        let anonymous = r.options.contains("submission")
        let mode: LaTeXResolvedStyle.Mode =
            r.options.contains("draft")
            ? .draft : r.options.contains("preprint") ? .preprint : anonymous ? .submission : .final
        var style = twoColumn(
            r, profile, mode: mode, definitionYear: 2027, options: ["submission", "draft", "preprint", "ccby"],
            width: 504, height: 648, top: 54, gap: 27, baseline: 11,
            anonymous: anonymous ? "Anonymous submission" : nil)
        style.separateAffiliations = true
        style.frenchSpacing = true
        style.showsPageNumbers = false
        style.runInSubsubsection = true
        style.paragraphIndent = 10
        style.noteRuleWidth = 60
        if mode != .preprint && mode != .draft {
            if anonymous && !r.options.contains("ccby") {
                style.firstColumnNotice =
                    "This is an anonymized submission for review purposes only. Distribution, citation, or public sharing of this manuscript is strictly prohibited. Copyright and publication details will appear in the final version if accepted."
            } else {
                let rights =
                    r.options.contains("ccby")
                    ? "This work is published under the CC BY 4.0 license: https://creativecommons.org/licenses/by/4.0/."
                    : "All rights reserved."
                style.firstColumnNotice =
                    "Copyright © \(r.year), Association for the Advancement of Artificial Intelligence (www.aaai.org). "
                    + rights
            }
        }
        return style
    }
}

extension LaTeXDocument {
    // Apply package defaults at the load site. Later natbib, color, and counter declarations win.
    func applyPackageDefaults(_ request: LaTeXStylePackageRegistry.Request) {
        // Conference kits select sloppy at load time (CVPR inherits it from the two-column class).
        lineParameters.setSloppy(true)
        let ink: String?
        switch request.family {
        case .cvpr:
            bibDatabase.applyConferenceDefaults(authorYear: false, compress: true)
            ink = nil
        case .icml, .acl:
            bibDatabase.applyConferenceDefaults(authorYear: true)
            bibDatabase.parentheticalCite = true
            bibDatabase.linksTextualAuthors = true
            ink = request.options.contains("nohyperref") ? nil : request.family == .icml ? "#001473" : "#000080"
        case .aaai:
            counters["secnumdepth"] = 0
            bibDatabase.applyConferenceDefaults(authorYear: true, separator: " ")
            bibDatabase.parentheticalCite = true
            ink = nil
        case .neurips, .iclr: ink = nil
        }
        // psfonts' Times package also selects Helvetica and Courier; later font packages can replace either role.
        if [.icml, .cvpr, .aaai].contains(request.family) {
            pageSettings.fonts.readPackage("helvet")
            pageSettings.fonts.readPackage("courier")
        }
        if let ink {
            if hyperref.colored == nil { hyperref.colored = true }
            if !explicitPreambleInks.contains("linkcolor") { hyperref.link = ink }
            if !explicitPreambleInks.contains("citecolor") { hyperref.cite = ink }
            if !explicitPreambleInks.contains("urlcolor") { hyperref.url = ink }
        }
    }

    func resolveStylePackage() {
        guard let request = stylePackage else { return }
        var style = LaTeXStylePackageRegistry.resolve(
            request, profile: classInfo.profile, finalCopy: finalCopy, workshop: workshopTitle, macros: macros,
            shortTitle: frontMatter.runningTitle)
        style.raggedBottom = requestsRaggedBottom ?? false
        if let requestsFrenchSpacing { style.frenchSpacing = requestsFrenchSpacing }
        if style.frenchSpacing { lineParameters.frenchspacing = true }
        classInfo.resolvedStyle = style
        classInfo.styleDeclaration = styleDeclaration
        classInfo.columns = style.columns
        if style.loadsNatbib { bibDatabase.natbib = true }
        if style.usesTimesRoman && pageSettings.fonts.mainFontRevision == styleMainFontRevision {
            pageSettings.fonts.readPackage("times")
        }
        if loadsTimesPackage && pageSettings.fonts.roleVariables["mono-font"] == nil {
            pageSettings.fonts.readPackage("courier")
        }
        if style.runningHeader != nil || !style.showsPageNumbers {
            var numbers = LaTeXPageNumbers(classInfo.profile.pageStyle)
            if let header = style.runningHeader {
                if style.centeredRunningTitle {
                    numbers.runningTitleFallback = style.runningTitleFallback
                    numbers.setRunningTitle(header)
                } else {
                    numbers.apply("pagestyle", value: "fancy")
                    numbers.apply("fancy:H", value: "")
                    numbers.apply("fancy:LH", value: header)
                }
            } else {
                numbers.apply("pagestyle", value: "empty")
            }
            for (action, value) in preamblePageActions { numbers.apply(action, value: value) }
            classInfo.pageNumbers = numbers
        }
    }
}
