import Foundation

public enum AsciiDocConverter {
    private static let host = ScriptConverterHost(
        "asciidoctor-4.2.1", bridge: "asciidoc-bridge", category: "AsciiDoc", commonJS: false)

    /// Asciidoctor expands table spans and repeats into arrays that can keep growing after the caller times out.
    /// The bridge caps cell spans, cell repeats and the total number of explicit columns at 1,000 before expansion.
    public static func convert(_ source: String, contentsDepth: Int? = nil, reading: FormatReadingSettings = .init())
        throws -> HTMLFragment
    {
        try host.fragment(
            source, contentsDepth: contentsDepth, asciiDocReading: reading,
            notice: String(localized: "AsciiDoc exceeds 5 MB. Showing the original text."),
            rewrite: AsciiDocMarkup.fragment)
    }
}
