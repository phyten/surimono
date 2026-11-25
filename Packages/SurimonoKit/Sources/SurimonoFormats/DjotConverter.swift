import Foundation

public enum DjotConverter {
    private static let host = ScriptConverterHost("djot-0.3.2", bridge: "djot-bridge", category: "Djot")

    public static func convert(_ source: String) throws -> HTMLFragment {
        try host.fragment(source, notice: String(localized: "Djot exceeds 5 MB. Showing the original text.")) { parts in
            try PrintMarkup.fragment(parts.html, format: .djot)
        }
    }
}
