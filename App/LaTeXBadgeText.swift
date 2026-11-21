import SurimonoCore
import SwiftUI

struct LaTeXBadgeText {
    let label: String
    let explanation: String

    init(_ recognition: LaTeXRecognition, language: String) {
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
            explanation = PrintModeText.format(
                "Shown as the document specifies (%@).", language: language, Self.quote(source))
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
        Picker(selection: Binding(get: { model.latexComposition }, set: model.selectComposition)) {
            ForEach(LaTeXComposition.allCases, id: \.self) { choice in
                Text(verbatim: PrintModeText.string(choice.titleKey, language: model.language)).tag(choice)
            }
        } label: {
            Text(verbatim: PrintModeText.string("LaTeX Layout", language: model.language))
        }
    }
}
