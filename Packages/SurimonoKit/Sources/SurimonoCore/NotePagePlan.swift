public enum NotePagePlan {
    public enum Page: Equatable, Sendable {
        case body(Int)
        case note
    }

    public enum Placement: String, Codable, CaseIterable, Sendable {
        case spreadLeft, spreadRight, duplexBack, chapterEnd
    }

    public static func pages(
        bodyPageIndices: [Int], placement: Placement, layoutKind: LayoutKind = .booklet,
        chapterEndBodyIndices: Set<Int> = []
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
        var result: [Page] = []
        for index in bodyPageIndices {
            result.append(contentsOf: noteOnOdd ? [.note, .body(index)] : [.body(index), .note])
        }
        if noteOnOdd && layoutKind != .twoUp { result.append(.note) }
        return result
    }
}
