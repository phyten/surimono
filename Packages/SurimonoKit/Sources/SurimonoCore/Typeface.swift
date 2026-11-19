public enum Typeface: String, Codable, CaseIterable, Sendable {
    case style, latex

    public static func isAvailable(themeID: String, usesPrintTheme: Bool) -> Bool {
        usesPrintTheme
            && ![
                "latex", "latex-article", "latex-report", "latex-plain-ja", "latex-plain-zh", "latex-plain-ko",
                "tategaki",
            ].contains(themeID)
    }

    // Zero specificity supplies the browser defaults only where the style has no family of its own.
    // The prefix is inherited separately so a rule shared by headings and code keeps the right face for each.
    static let overlay = """

        :root { --surimono-western: "Surimono Computer Modern",; }
        :where(svg, math) { --surimono-western: ; }
        :where(html) { font-family: var(--surimono-western) var(--surimono-style-family, serif); }
        :where(code, pre:not(.surimono-plain), kbd, samp) {
            --surimono-western: "Surimono Computer Modern Typewriter",;
            font-family: var(--surimono-western) var(--surimono-style-family, monospace);
        }
        """
}
