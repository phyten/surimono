/// The ways a Markdown text can ask for a new page, as read by `MarkdownConverter`.
public enum PageBreakSyntax: String, CaseIterable, Codable, Sendable {
    case comment = "break"
    case pagebreak, newpage, kramdown, custom
}
