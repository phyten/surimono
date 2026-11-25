import Foundation

public enum TextileConverter {
    private static let host = ScriptConverterHost("textile-2.1.1", bridge: "textile-bridge", category: "Textile")

    public static func convert(_ source: String) throws -> HTMLFragment {
        try host.fragment(source, notice: String(localized: "Textile exceeds 5 MB. Showing the original text.")) {
            parts in
            try PrintMarkup.fragment(parts.html, format: .textile)
        }
    }
}
