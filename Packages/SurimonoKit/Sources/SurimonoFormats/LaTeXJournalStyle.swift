import Foundation

/// Publishing classes use different printed and reference forms for the same counter.
package enum LaTeXJournalStyle: String, Sendable {
    case ams, ieee, aps
    case apsPreprint = "aps-preprint"
    case lncs, elsevier

    // cmcsc10's small letters have wider advances than synthesized browser small caps.
    // Preserve the source case for contents, selection and accessibility.
    static func smallCaps(_ html: String, in document: LaTeXDocument) -> String {
        // CMU supplies real small capitals for the default AMS text face in a single run.
        if document.classInfo.profile.headings.smallCapsSections,
            document.classInfo.mainFontName == nil
                || document.classInfo.mainFontName == ComputerModernFamily.roman.rawValue
        {
            return html
        }
        guard html.utf8.count <= 32768 else { return html }
        var svgDepth = 0
        return HTMLScanner.tokens(html).map { token in
            switch token {
            case .tag(let tag):
                if tag.name == "svg", !tag.isSelfClosing { svgDepth += tag.isClosing ? -1 : 1 }
                return tag.source
            case .opaque(let source): return source
            case .text(let text):
                guard svgDepth == 0 else { return text }
                return text.replacing(/&[#a-zA-Z0-9]+;|([a-z]+)/) { match in
                    guard match.1 != nil, document.reserveExpansion(characters: 40) else { return String(match.0) }
                    return "<span class=\"latex-ams-small-cap\">\(match.0)</span>"
                }
            }
        }.joined()
    }

    var isAPS: Bool { self == .aps || self == .apsPreprint }

    var hasWideAbstract: Bool { isAPS || self == .elsevier }

    func defineCounters(in document: LaTeXDocument) {
        if self == .lncs { document.counters["secnumdepth"] = 2 }
        guard self == .ieee || isAPS else { return }
        let defaults = [
            "thesection": #"\Roman{section}"#,
            "thesubsection": self == .ieee ? #"\thesection-\Alph{subsection}"# : #"\Alph{subsection}"#,
            "thesubsubsection": self == .ieee ? #"\thesubsection\arabic{subsubsection}"# : #"\arabic{subsubsection}"#,
            "theparagraph": self == .ieee ? #"\thesubsubsection\alph{paragraph}"# : #"\alph{paragraph}"#,
            "thetable": #"\Roman{table}"#,
        ]
        for (key, body) in defaults {
            document.macros[key] = .init(parameters: 0, defaultArgument: nil, body: body)
        }
    }

    func headingNumber(_ number: String, command: String, counter: Int) -> String {
        if self == .ieee {
            switch command {
            case "subsection": return LaTeXSymbols.format(counter, as: "Alph") + "."
            case "subsubsection": return String(counter) + ")"
            case "paragraph": return LaTeXSymbols.format(counter, as: "alph") + ")"
            default: break
            }
        }
        return self == .lncs ? number : number + "."
    }

    func englishLabel(_ key: String) -> String? {
        switch (self, key) {
        case (.lncs, "abstractname"): "Abstract."
        case (.ieee, "figurename"), (.lncs, "figurename"): "Fig."
        case (.aps, "figurename"), (.apsPreprint, "figurename"): "FIG."
        case (.ieee, "tablename"), (.aps, "tablename"), (.apsPreprint, "tablename"): "TABLE"
        default: nil
        }
    }

    func captionSeparator(for kind: String) -> String? {
        guard kind == "figure" || kind == "table" else { return nil }
        if self == .ieee && kind == "table" { return "<br>" }
        return self == .elsevier ? nil : ". "
    }

    func abstract(heading: String, body: String) -> String {
        let start = "<div class=\"abstract latex-front-abstract\">\n"
        if self == .aps { return start + body + "</div>\n" }
        guard self == .ieee || self == .lncs || self == .ams else {
            return start + "<p class=\"abstract-title\">\(heading)</p>\n" + body + "</div>\n"
        }
        let suffix = self == .ieee ? "—" : (heading.hasSuffix(".") ? " " : ". ")
        let label = "<strong class=\"latex-abstract-label\">\(heading)\(suffix)</strong>"
        // Put the label inside the first paragraph so a narrow column can wrap the lead-in normally.
        // An abstract can also start with a list, maths, or an empty body.
        if body.hasPrefix("<p>") || body.hasPrefix("<p "), let end = body.firstIndex(of: ">") {
            let split = body.index(after: end)
            return start + body[..<split] + label + body[split...] + "</div>\n"
        }
        return start + "<p>\(label)</p>\n" + body + "</div>\n"
    }

    func bibliographyLabel(_ label: String) -> String {
        self == .lncs ? label + "." : "[\(label)]"
    }
}
