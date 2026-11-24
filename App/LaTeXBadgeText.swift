import SurimonoCore
import SwiftUI

struct LaTeXBadgeText {
    let label: String
    let explanation: String

    let slideNotes: [String]

    init(_ recognition: LaTeXRecognition, language: String, facts: DocumentFacts? = nil) {
        var notes: [String] = []
        if let count = facts?.continuedBeamerFrames, count > 0 {
            let key =
                count == 1
                ? "1 slide did not fit and continues on a following page."
                : "%lld slides did not fit and continue on a following page."
            notes.append(PrintModeText.format(key, language: language, count))
        }
        if let count = facts?.unreadableBeamerFrames, count > 0 {
            let key =
                count == 1
                ? "1 slide shows all its steps at once because its overlay commands could not be read."
                : "%lld slides show all their steps at once because their overlay commands could not be read."
            notes.append(PrintModeText.format(key, language: language, count))
        }
        slideNotes = notes
        switch recognition {
        case .recognised(let name, let detail, let source):
            let title = name.text(japanese: language.hasPrefix("ja"))
            if let detail {
                let key =
                    switch detail {
                    case .submission: "%@ (submission)"
                    case .final: "%@ (final)"
                    case .preprint: "%@ (preprint)"
                    case .rebuttal: "%@ (rebuttal)"
                    case .draft: "%@ (draft)"
                    }
                label = PrintModeText.format(key, language: language, title)
            } else {
                label = title
            }
            if let theme = facts?.unsupportedBeamerTheme {
                explanation = PrintModeText.format(
                    "The theme “%@” is not supported, so beamer's default look is used.", language: language,
                    Self.quote(theme))
            } else {
                explanation = PrintModeText.format(
                    "Shown as the document specifies (%@).", language: language, Self.quote(source))
            }
        case .substituted(let requestedClass):
            label = PrintModeText.string("standard layout", language: language)
            explanation = PrintModeText.format(
                "The class “%@” is not supported, so the standard layout is used.", language: language,
                Self.quote(requestedClass))
        }
    }

    private static func quote(_ source: String) -> String {
        guard source.count > 60 else { return source }
        return source.prefix(30) + "…" + source.suffix(29)
    }
}

extension LaTeXComposition {
    var titleKey: String {
        switch self {
        case .document: "As Written"
        case .twoColumn: "Two Columns"
        case .proof: "Proof"
        }
    }

    var detailKey: String {
        switch self {
        case .document: "Typeset as the document specifies."
        case .twoColumn: "Sets the text in two columns."
        case .proof: "Adds line numbers and a margin for notes."
        }
    }

    var suffixKey: String? {
        switch self {
        case .document: nil
        case .twoColumn: "two columns"
        case .proof: "proof"
        }
    }
}

struct LaTeXCompositionPicker: View {
    let model: DocumentViewModel

    var body: some View {
        // A closure, not the method reference: Swift 6.3 (Xcode 26.6) crashes in IR generation
        // on the thunk it makes for a main-actor method passed as the setter.
        Picker(selection: model.controlBinding(get: \.latexComposition, set: { $0.selectComposition($1) })) {
            ForEach(LaTeXComposition.allCases, id: \.self) { [language = model.language] choice in
                Text(verbatim: PrintModeText.string(choice.titleKey, language: language)).tag(choice)
            }
        } label: { [language = model.language] in
            Text(verbatim: PrintModeText.string("LaTeX Layout", language: language))
        }
    }
}
