import Foundation

/// Chapter titles indexed like the page numbers printed by the furniture, including inserted pages.
public enum PageChapters {
    public static func titles(
        headings: [DocumentHeading], pages: [Int?], pageCount: Int, plan: FinishedPagePlan? = nil
    ) -> [String] {
        var starts: [Int: String] = [:]
        if let level = DocumentOutline.chapterLevel(of: headings.map(\.level)) {
            for (heading, page) in zip(headings, pages) where heading.level == level {
                if let page, page >= 0, page < pageCount { starts[page] = heading.text }
            }
        }
        var current = ""
        let body = (0..<max(0, pageCount)).map { index in
            if let title = starts[index] { current = title }
            return current
        }
        guard let plan else { return body }
        return plan.pages.map { page in
            if case .body(let index) = page, body.indices.contains(index) { return body[index] }
            return ""
        }
    }
}
