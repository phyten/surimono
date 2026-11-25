import Foundation

public enum AsciiDocConverter {
    private static let host = ScriptConverterHost(
        "asciidoctor-4.2.1", bridge: "asciidoc-bridge", category: "AsciiDoc", commonJS: false)

    /// Asciidoctor expands table spans and repeats into arrays that can keep growing after the caller times out.
    /// The bridge caps cell spans, cell repeats and the total number of explicit columns at 1,000 before expansion.
    public static func convert(_ source: String) throws -> HTMLFragment {
        try convert(source, fallsBackToSource: true)
    }

    package static func convert(_ source: String, fallsBackToSource: Bool) throws -> HTMLFragment {
        try host.fragment(
            source, fallsBackToSource: fallsBackToSource,
            notice: String(localized: "AsciiDoc exceeds 5 MB. Showing the original text."),
            rewrite: AsciiDocMarkup.fragment)
    }
}
