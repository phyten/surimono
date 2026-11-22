import Foundation

public enum AsciiDocConverter {
    private static let host = ScriptConverterHost(
        "asciidoctor-4.2.1", bridge: "asciidoc-bridge", category: "AsciiDoc", commonJS: false)

    /// Table cell spans, row spans and repeat counts, and column repeat counts, become arrays of that size in
    /// Asciidoctor: one cell spanning 9,999,999 columns took over 3 GB and kept running after the conversion was given
    /// up on. The bridge script caps the numbers Asciidoctor itself parsed at `asciidoc-bridge.js`'s
    /// `maximumTableSpan` (1,000), so only real specifiers change; cell text and every other line stay as written.
    public static func convert(_ source: String) throws -> HTMLFragment {
        try host.fragment(
            source, notice: String(localized: "AsciiDoc exceeds 5 MB. Showing the original text."),
            rewrite: AsciiDocMarkup.fragment)
    }
}
