import SurimonoCore

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
