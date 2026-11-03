/// Preferred window width when a spread shows only its cover.
public enum LoneCoverWidth: String, Codable, CaseIterable, Sendable {
    case onePage
    case twoPages
}

extension ViewOptions {
    /// Whether the reader sees the cover one page wide at `pageIndex` (0-based). Only a spread turned a unit at a time
    /// narrows: a scrolling strip keeps one width, and the lone last page of a book keeps its spread.
    public func narrowsCover(at pageIndex: Int, width: LoneCoverWidth) -> Bool {
        width == .onePage && layout == .spread && showsCoverAlone && !isContinuous && pageIndex == 0
    }
}
