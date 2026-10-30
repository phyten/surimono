/// How an HTML document is shown in the view mode: as a live web page, or as the paginated paper it prints as.
public enum HTMLPresentation: String, Codable, CaseIterable, Sendable {
    case web, paper
}
