public enum NotePagePlan {
    public enum Page: Equatable, Sendable {
        case body(Int)
        case note
    }

    public enum Placement: String, Codable, CaseIterable, Sendable {
        case spreadLeft, spreadRight, duplexBack, chapterEnd
    }

    /// - Parameter leadingPageCount: The pages in front of these, such as the contents, which decide what comes first.
    public static func pages(
        bodyPageIndices: [Int], placement: Placement, layoutKind: LayoutKind = .booklet,
        chapterEndBodyIndices: Set<Int> = [], leadingPageCount: Int = 0
    ) -> [Page] {
        guard !bodyPageIndices.isEmpty else { return [] }
        if placement == .chapterEnd {
            return bodyPageIndices.enumerated().flatMap { offset, index -> [Page] in
                let endsChapter = chapterEndBodyIndices.contains(index) || offset == bodyPageIndices.count - 1
                return endsChapter ? [.body(index), .note] : [.body(index)]
            }
        }
        // A book opens on a lone recto; two-up instead pairs the first page with the second.
        let noteOnOdd = placement != .duplexBack && ((placement == .spreadLeft) == (layoutKind == .twoUp))
        let bodyPosition = noteOnOdd ? 1 : 0
        var result: [Page] = []
        for index in bodyPageIndices {
            if (leadingPageCount + result.count) % 2 != bodyPosition { result.append(.note) }
            result.append(.body(index))
        }
        if !noteOnOdd || layoutKind != .twoUp { result.append(.note) }
        return result
    }
}
