import Foundation

/// Publishing classes use different printed and reference forms for the same counter.
package enum LaTeXJournalStyle: String, Sendable {
    case ieee, aps
    case apsPreprint = "aps-preprint"
    case lncs, elsevier

    init?(name: String, options: [String]) {
        switch name {
        case "IEEEtran" where !options.contains("compsoc") && !options.contains("transmag"): self = .ieee
        case "revtex4-2" where Set(options).isDisjoint(with: ["aip", "aapm", "sor"]):
            self = options.last(where: { $0 == "preprint" || $0 == "reprint" }) == "preprint" ? .apsPreprint : .aps
        case "llncs": self = .lncs
        case "elsarticle": self = .elsevier
        default: return nil
        }
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
        guard self == .ieee || self == .lncs else {
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
