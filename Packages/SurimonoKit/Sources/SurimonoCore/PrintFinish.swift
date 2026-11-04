import Foundation

/// What a heading level does to the page it stands on.
public enum HeadingBreak: String, CaseIterable, Codable, Sendable {
    case none, page, rightPage
}

/// The ways a Markdown text can ask for a new page, as read by `MarkdownConverter`.
public enum PageBreakSyntax: String, CaseIterable, Codable, Sendable {
    case comment = "break"
    case pagebreak, newpage, kramdown, custom
}

public struct PageBreakRules: Codable, Hashable, Sendable {
    public var h1 = HeadingBreak.none
    public var h2 = HeadingBreak.none
    public var h3 = HeadingBreak.none
    /// The syntaxes that do not break the page. Nothing is shown in their place.
    public var ignoredSyntaxes: Set<PageBreakSyntax> = []
    /// `---` breaks the page instead of drawing a line.
    public var breaksAtThematicBreaks = false
    /// A line of the reader's own that stands for a page break.
    public var customLine = ""
    public var keepsHeadingsWithText = true
    public var keepsTablesWhole = false

    public init() {}

    public func rule(forLevel level: Int) -> HeadingBreak {
        switch level {
        case 1: h1
        case 2: h2
        case 3: h3
        default: .none
        }
    }

    public var usesRightPages: Bool { [h1, h2, h3].contains(.rightPage) }

    private enum CodingKeys: String, CodingKey {
        case h1, h2, h3, ignoredSyntaxes, breaksAtThematicBreaks, customLine, keepsHeadingsWithText, keepsTablesWhole
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        h1 = (try? values.decodeIfPresent(HeadingBreak.self, forKey: .h1)) ?? .none
        h2 = (try? values.decodeIfPresent(HeadingBreak.self, forKey: .h2)) ?? .none
        h3 = (try? values.decodeIfPresent(HeadingBreak.self, forKey: .h3)) ?? .none
        let ignored = (try? values.decodeIfPresent([String].self, forKey: .ignoredSyntaxes)) ?? []
        ignoredSyntaxes = Set(ignored.compactMap(PageBreakSyntax.init(rawValue:)))
        breaksAtThematicBreaks = (try? values.decodeIfPresent(Bool.self, forKey: .breaksAtThematicBreaks)) ?? false
        customLine = (try? values.decodeIfPresent(String.self, forKey: .customLine)) ?? ""
        keepsHeadingsWithText = (try? values.decodeIfPresent(Bool.self, forKey: .keepsHeadingsWithText)) ?? true
        keepsTablesWhole = (try? values.decodeIfPresent(Bool.self, forKey: .keepsTablesWhole)) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(h1, forKey: .h1)
        try values.encode(h2, forKey: .h2)
        try values.encode(h3, forKey: .h3)
        try values.encode(ignoredSyntaxes.map(\.rawValue).sorted(), forKey: .ignoredSyntaxes)
        try values.encode(breaksAtThematicBreaks, forKey: .breaksAtThematicBreaks)
        try values.encode(customLine, forKey: .customLine)
        try values.encode(keepsHeadingsWithText, forKey: .keepsHeadingsWithText)
        try values.encode(keepsTablesWhole, forKey: .keepsTablesWhole)
    }
}

/// How the printed pages show a table of contents.
public struct PaperTOC: Codable, Hashable, Sendable {
    public enum Mode: String, CaseIterable, Codable, Sendable {
        /// No table of contents, not even the one the text asks for with `[TOC]`.
        case hidden
        /// The text's own `[TOC]`, where it stands.
        case source
        /// Pages of their own in front of the text, with page numbers.
        case front
    }

    public enum Depth: String, CaseIterable, Codable, Sendable { case chapters, sections }
    public enum Look: String, CaseIterable, Codable, Sendable { case dotted, plain, ruled }

    public var mode = Mode.source
    public var depth = Depth.chapters
    public var look = Look.dotted
    /// With `front`, the text's own `[TOC]` stays where it stands as well.
    public var keepsSourceTOC = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case mode, depth, look, keepsSourceTOC }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? values.decodeIfPresent(Mode.self, forKey: .mode)) ?? .source
        depth = (try? values.decodeIfPresent(Depth.self, forKey: .depth)) ?? .chapters
        look = (try? values.decodeIfPresent(Look.self, forKey: .look)) ?? .dotted
        keepsSourceTOC = (try? values.decodeIfPresent(Bool.self, forKey: .keepsSourceTOC)) ?? false
    }
}

/// What the tray adds to the pages of a text: where they break and the table of contents. It changes how the text is
/// laid out, so unlike the header and footer it belongs to the pages rather than the sheets.
public struct PrintFinish: Codable, Hashable, Sendable {
    public var breaks = PageBreakRules()
    public var toc = PaperTOC()

    public init() {}

    private enum CodingKeys: String, CodingKey { case breaks, toc }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        breaks = (try? values.decodeIfPresent(PageBreakRules.self, forKey: .breaks)) ?? PageBreakRules()
        toc = (try? values.decodeIfPresent(PaperTOC.self, forKey: .toc)) ?? PaperTOC()
    }

    /// Style rules laid over the theme, empty when nothing is asked of the text.
    public var styleSheet: String {
        var rules: [String] = []
        let headings = ":is(h1, h2, h3, h4, h5, h6)"
        let levels = [1, 2, 3].filter { breaks.rule(forLevel: $0) != .none }
        if !levels.isEmpty {
            // The first heading has nothing before it worth leaving, and a heading right under another stays with it.
            // Right after a page break the page is new already; WebKit would break once more and leave a blank.
            var before = [headings]
            before += PageBreakSyntax.allCases.filter { !breaks.ignoredSyntaxes.contains($0) }.map {
                ".page-break[data-syntax=\"\($0.rawValue)\"]"
            }
            if breaks.breaksAtThematicBreaks { before.append("hr") }
            let breaking = levels.map { "\(headings) ~ h\($0)" }.joined(separator: ", ")
            let staying = before.flatMap { first in levels.map { "\(first) + h\($0)" } }.joined(separator: ", ")
            rules.append("\(breaking) { break-before: page; page-break-before: always; }")
            rules.append("\(staying) { break-before: auto; page-break-before: auto; }")
        }
        for syntax in PageBreakSyntax.allCases where breaks.ignoredSyntaxes.contains(syntax) {
            rules.append(
                ".page-break[data-syntax=\"\(syntax.rawValue)\"] { break-after: auto; page-break-after: auto; }")
        }
        if breaks.breaksAtThematicBreaks {
            rules.append(
                "hr { visibility: hidden; height: 0 !important; margin: 0 !important; padding: 0 !important; "
                    + "border: 0 !important; break-after: page; page-break-after: always; }")
        }
        if !breaks.keepsHeadingsWithText {
            rules.append("h1, h2, h3, h4, h5, h6 { break-after: auto; page-break-after: auto; }")
        }
        if breaks.keepsTablesWhole {
            // A table that fits on a page already moves as a whole (common.css); a longer one breaks between its rows.
            rules.append("table, tr { break-inside: avoid; page-break-inside: avoid; }")
        }
        if toc.mode == .hidden || (toc.mode == .front && !toc.keepsSourceTOC) {
            rules.append("nav.toc { display: none !important; }")
        }
        return rules.joined(separator: "\n")
    }
}

/// Where the pages of a finished document come from: the laid-out pages, with contents pages in front, blanks that
/// bring a chapter to a right-hand page and note pages.
public struct FinishedPagePlan: Equatable, Sendable {
    public enum Page: Equatable, Sendable {
        case contents(Int)
        case body(Int)
        case blank
        case note
    }

    /// How note pages go in among the pages.
    public struct Notes: Equatable, Sendable {
        public var placement: NotePagePlan.Placement
        public var layoutKind: LayoutKind
        /// The pages of the text that end a chapter; the last page always does.
        public var chapterEnds: Set<Int>

        public init(placement: NotePagePlan.Placement, layoutKind: LayoutKind, chapterEnds: Set<Int> = []) {
            self.placement = placement
            self.layoutKind = layoutKind
            self.chapterEnds = chapterEnds
        }
    }

    public let pages: [Page]
    /// The final index of each page of the text.
    public let bodyPageIndices: [Int]

    /// - Parameter rightPageStarts: Pages of the text that must come out as a right-hand page, which is an odd page.
    ///   Notes on a side of each spread keep every page of the text on one side, so these then take no blanks.
    public init(bodyPageCount: Int, contentsPageCount: Int, rightPageStarts: Set<Int>, notes: Notes? = nil) {
        var pages = (0..<contentsPageCount).map(Page.contents)
        var indices: [Int] = []
        func addBody(_ body: Int) {
            indices.append(pages.count)
            pages.append(.body(body))
        }
        if let notes, notes.placement != .chapterEnd {
            for page in NotePagePlan.pages(
                bodyPageIndices: Array(0..<bodyPageCount), placement: notes.placement, layoutKind: notes.layoutKind,
                leadingPageCount: contentsPageCount)
            {
                switch page {
                case .body(let body): addBody(body)
                case .note: pages.append(.note)
                }
            }
        } else {
            for body in 0..<bodyPageCount {
                if rightPageStarts.contains(body), pages.count % 2 == 1 { pages.append(.blank) }
                addBody(body)
                if let notes, notes.chapterEnds.contains(body) || body == bodyPageCount - 1 { pages.append(.note) }
            }
        }
        self.pages = pages
        bodyPageIndices = indices
    }

    public var blankPages: Set<Int> {
        Set(pages.indices.filter { pages[$0] == .blank })
    }

    /// The final indices of the note pages, in order.
    public var notePages: [Int] {
        pages.indices.filter { pages[$0] == .note }
    }

    public var isUnchanged: Bool { pages.count == bodyPageIndices.count }

    /// The pages of the text that must start on the right, from where the headings fell. A heading right under another
    /// heading, and a first heading that did not open its page, do not start a page, so they leave the page alone.
    public static func rightPageStarts(
        headings: [DocumentHeading], pages: [Int?], followsHeading: [Bool], rules: PageBreakRules
    ) -> Set<Int> {
        var starts: Set<Int> = []
        for (index, heading) in headings.enumerated() where rules.rule(forLevel: heading.level) == .rightPage {
            guard pages.indices.contains(index), let page = pages[index] else { continue }
            if followsHeading.indices.contains(index), followsHeading[index] { continue }
            if index == 0 && page != 0 { continue }
            starts.insert(page)
        }
        return starts
    }
}

/// The contents pages put in front of a text.
public enum PaperContents {
    public struct Entry: Equatable, Sendable {
        /// 1 for a chapter, 2 for a section.
        public var depth: Int
        public var text: String
        public var page: Int?

        public init(depth: Int, text: String, page: Int?) {
            self.depth = depth
            self.text = text
            self.page = page
        }
    }

    /// The entries of the headings. The chapters are the largest headings of the text, unless the largest is a single
    /// title over everything else; `pageNumbers` holds the printed number of each heading.
    public static func entries(headings: [DocumentHeading], pageNumbers: [Int?], depth: PaperTOC.Depth) -> [Entry] {
        guard let top = DocumentOutline.chapterLevel(of: headings.map(\.level)) else { return [] }
        let deepest = depth == .chapters ? top : top + 1
        return headings.enumerated().compactMap { index, heading in
            guard (top...deepest).contains(heading.level) else { return nil }
            return Entry(
                depth: heading.level - top + 1, text: heading.text,
                page: pageNumbers.indices.contains(index) ? pageNumbers[index] : nil)
        }
    }

    public static func title(language: String) -> String {
        UILanguage.name(
            [
                "en": "Contents", "ja": "目次", "zh-Hans": "目录", "zh-Hant": "目錄", "ko": "목차", "fr": "Sommaire",
                "de": "Inhalt", "es": "Índice",
            ], language: language, english: "Contents")
    }

    public static func fragment(entries: [Entry], look: PaperTOC.Look, title: String) -> HTMLFragment {
        let rows = entries.map { entry in
            let page = entry.page.map(String.init) ?? ""
            return "<div class=\"paper-toc-row paper-toc-depth-\(entry.depth)\">"
                + "<span class=\"paper-toc-text\">\(HTML.escape(entry.text))</span>"
                + "<span class=\"paper-toc-page\">\(page)</span></div>"
        }
        let line = "1px dotted rgba(0, 0, 0, 0.4)"
        let borders =
            switch look {
            case .dotted: ".paper-toc-row { border-bottom: \(line); }"
            case .plain: ""
            case .ruled:
                ".paper-toc-depth-1 { border-bottom: 1px solid rgba(0, 0, 0, 0.5); font-weight: 700; }"
            }
        let body = """
            <style>
            .paper-toc-title::before, .paper-toc-title::after { content: none !important; }
            .paper-toc-row { display: flex; justify-content: space-between; align-items: baseline; gap: 1em; \
            padding-block: 0.25em; }
            .paper-toc-depth-2 { padding-left: 1.2em; font-size: 0.92em; }
            .paper-toc-page { font-variant-numeric: tabular-nums; }
            \(borders)
            </style>
            <h1 class="paper-toc-title">\(HTML.escape(title))</h1>
            \(rows.joined(separator: "\n"))
            """
        return HTMLFragment(body: body, title: title)
    }
}
