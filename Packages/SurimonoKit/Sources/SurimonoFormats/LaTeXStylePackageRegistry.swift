import Foundation

package struct LaTeXResolvedStyle: Equatable, Sendable {
    package enum Family: String, Sendable { case neurips, iclr }
    package enum Mode: String, Sendable { case submission, final, preprint }
    package enum Review: String, Codable, Sendable { case textLines, ruler }
    enum DisplayFace: Sendable { case bold, smallCaps }

    let classProfile: LaTeXClassProfile
    let requestedName: String
    package let family: Family
    let year: String
    let definitionYear: Int
    let options: [String]
    package let mode: Mode
    let displayFace: DisplayFace
    let acknowledgementHeading: String?
    let anonymousAuthor: String?
    let loadsNatbib: Bool
    let usesTimesRoman: Bool
    let paper = LaTeXClassProfile.Paper.letter
    let columns = 1
    let textWidthInches = 5.5
    let textHeightInches = 9.0
    let textTop: Double  // PDF points
    let headSep: Double  // TeX points
    let baseline: Double
    let paragraphSkip: Double
    let noteSize: Double
    let notePitch: Double
    let maximumTopFloatFraction: Double
    let maximumBottomFloatFraction: Double
    let minimumTextFraction: Double
    let floatPageFraction: Double
    let captionSkip: Double
    let runningHeader: String?
    package let firstPageNotice: String?
    package let review: Review?
    let diagnostics: [String]
}

enum LaTeXStylePackageRegistry {
    struct Request {
        let name: String
        let year: String
        let family: LaTeXResolvedStyle.Family
        let options: [String]

        var loadsNatbib: Bool {
            switch family {
            case .neurips: !options.contains("nonatbib")
            case .iclr: true
            }
        }
    }

    // Only the complete kit filename stem with four ASCII year digits denotes a conference style.
    static func match(_ name: String, options: [String]) -> Request? {
        if let match = name.wholeMatch(of: /neurips_([0-9]{4})/) {
            return Request(name: name, year: String(match.1), family: .neurips, options: options)
        }
        if let match = name.wholeMatch(of: /iclr([0-9]{4})_conference/) {
            return Request(name: name, year: String(match.1), family: .iclr, options: options)
        }
        return nil
    }

    // Keep the pre-existing two-column convention until the ICML kit has its own definition.
    static func usesLegacyColumns(_ name: String) -> Bool {
        name.wholeMatch(of: /icml(?:[0-9]{2,4})?/) != nil
    }

    static func resolve(_ request: Request, profile: LaTeXClassProfile, finalCopy: Bool, workshop: String)
        -> LaTeXResolvedStyle
    {
        switch request.family {
        case .neurips: neurips(request, profile: profile, workshop: workshop)
        case .iclr: iclr(request, profile: profile, finalCopy: finalCopy)
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
        case .preprint: notice = "Preprint."
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
}

extension LaTeXDocument {
    func resolveStylePackage() {
        guard let request = stylePackage else { return }
        let style = LaTeXStylePackageRegistry.resolve(
            request, profile: classInfo.profile, finalCopy: finalCopy, workshop: workshopTitle)
        classInfo.resolvedStyle = style
        classInfo.columns = style.columns
        if style.loadsNatbib { bibDatabase.natbib = true }
        if style.usesTimesRoman && pageSettings.fonts.mainFontRevision == styleMainFontRevision {
            pageSettings.fonts.readPackage("times")
        }
        if loadsTimesPackage && pageSettings.fonts.roleVariables["mono-font"] == nil {
            pageSettings.fonts.readPackage("courier")
        }
        if let header = style.runningHeader {
            var numbers = LaTeXPageNumbers(classInfo.profile.pageStyle)
            numbers.apply("pagestyle", value: "fancy")
            numbers.apply("fancy:H", value: "")
            numbers.apply("fancy:LH", value: header)
            for (action, value) in preamblePageActions { numbers.apply(action, value: value) }
            classInfo.pageNumbers = numbers
        }
    }
}
