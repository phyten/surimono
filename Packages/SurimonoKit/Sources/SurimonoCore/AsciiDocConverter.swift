import Foundation

public enum AsciiDocConverter {
    private static let host = ScriptConverterHost(
        "asciidoctor-4.2.1", bridge: "asciidoc-bridge", category: "AsciiDoc", commonJS: false)

    public static func convert(_ source: String) throws -> HTMLFragment {
        try host.fragment(
            source, notice: String(localized: "AsciiDoc exceeds 5 MB. Showing the original text."),
            rewrite: AsciiDocMarkup.fragment)
    }
}
