import SurimonoCore
import SurimonoRendering

/// What one press of Print takes and makes, read from the composed sheets rather than from the chosen card: the paper
/// that goes through the printer and how many sheets of it, then only what needs saying beyond that.
///
/// The numbers all come from one composition (the sheets on the tray), so the paper, the sheets and the pages never
/// mix an older plan with a newer one.
struct PrintOutcome: Equatable {
    /// The layout the sheets were composed with.
    var layout: PrintLayout
    /// The paper the sheets are, as the plan says.
    var paper: PaperSize
    /// The sheets of one copy.
    var sheets: Int
    /// The pages on the sheets, blank slots included, and what they are; the parts add up to `pages`.
    var pages: Int
    var body: Int
    var contents = 0
    var notes = 0
    var blanks = 0
    var copies = 1
    var orientations: [PaperOrientation] = []

    /// The paper, the sheets of every copy and the sides, for example "Paper A3 · 10 sheets · Two-Sided".
    func lead(language: String) -> String {
        // A number stays with its unit, and a separator with the part before it, where a narrow bar wraps the line.
        let sheetText = PrintModeText.sheetCount(sheets * max(copies, 1), language: language)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
        return PrintModeText.format(
            "Paper %1$@ · %2$@ · %3$@", language: language, paper.shortName, sheetText,
            PrintModeText.string(layout.sentDuplex == .none ? "One-Sided" : "Two-Sided", language: language)
                .replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "-", with: "\u{2011}")
        ).replacingOccurrences(of: " · ", with: "\u{00A0}· ")
    }

    /// What else there is to know, or nil when the first line says it all: what the sheets make when it is not the
    /// paper itself, what the pages are when not all of them are the document's, the sheets of one copy and of all
    /// of them, and paper turned two ways.
    func detail(language: String) -> String? {
        let parts = detailParts(language: language)
        guard let first = parts.first else { return nil }
        let line = parts.dropFirst().reduce(first) { PrintModeText.format("%@ · %@", language: language, $0, $1) }
        return Self.keepingNumbers(line)
    }

    /// The detail for a bar too narrow to give it one line: the breakdown of the pages goes on a line of its own, and
    /// each line is in pieces that a narrower bar moves to the next line whole, so that no word is broken. Every piece
    /// but the last of a line carries the separator after it. Nil when there is nothing to say.
    func detailLines(language: String) -> [[String]]? {
        let parts = detailParts(language: language, breakdown: false)
        guard !parts.isEmpty else { return nil }
        var lines = [
            Self.pieces(parts, language: language) { PrintModeText.format("%@ · %@", language: language, $0, $1) }
        ]
        if let counts = breakdownCounts(language: language) {
            lines.append(
                Self.pieces(counts, language: language) {
                    PrintModeText.format("%1$@ + %2$@", language: language, $0, $1)
                })
        }
        return lines
    }

    /// What the detail says, in order. With `breakdown`, the page count carries what its pages are, in parentheses.
    private func detailParts(language: String, breakdown: Bool = true) -> [String] {
        var parts: [String] = []
        if let finished = finished(language: language) { parts.append(finished) }
        if let counts = breakdownCounts(language: language) {
            let pageCount = PrintModeText.pageCount(pages, language: language)
            if breakdown {
                let sum = counts.dropFirst().reduce(counts[0]) {
                    PrintModeText.format("%1$@ + %2$@", language: language, $0, $1)
                }
                parts.append(PrintModeText.format("%1$@ (%2$@)", language: language, pageCount, sum))
            } else {
                parts.append(pageCount)
            }
        }
        if copies > 1 {
            parts.append(
                PrintModeText.format(
                    "%1$@ per copy · %2$@ in total", language: language,
                    PrintModeText.sheetCount(sheets, language: language),
                    PrintModeText.sheetCount(sheets * copies, language: language)))
        }
        if let mixed = PrintModeText.mixedNote(orientations, language: language) { parts.append(mixed) }
        return parts
    }

    /// The body, the contents, the notes and the blanks, when not all the pages are the document's.
    private func breakdownCounts(language: String) -> [String]? {
        guard contents + notes + blanks > 0 else { return nil }
        return [
            PrintModeText.format("Body %lld", language: language, body),
            contents > 0 ? PrintModeText.format("Contents %lld", language: language, contents) : nil,
            notes > 0 ? PrintModeText.format("Notes %lld", language: language, notes) : nil,
            blanks > 0 ? PrintModeText.format("Blank %lld", language: language, blanks) : nil,
        ].compactMap { $0 }
    }

    /// The parts with the separator the language joins them with left on each but the last, as `join` puts it between
    /// two parts. A space at the end of a piece would be dropped where the piece ends a line, so it is a no-break
    /// space that keeps the gap before the next piece.
    private static func pieces(_ parts: [String], language: String, join: (String, String) -> String) -> [String] {
        let marker = "\u{E000}"
        return parts.enumerated().map { index, part in
            guard index < parts.count - 1 else { return keepingNumbers(part) }
            let joined = join(part, marker)
            let piece = joined.components(separatedBy: marker).first ?? joined
            return keepingNumbers(piece).replacingOccurrences(of: #" $"#, with: "\u{00A0}", options: .regularExpression)
        }
    }

    /// A number stays with the word beside it where the line wraps: "40 pages", "Blank 2".
    private static func keepingNumbers(_ text: String) -> String {
        text.replacingOccurrences(of: #"(\d) "#, with: "$1\u{00A0}", options: .regularExpression)
            .replacingOccurrences(of: #" (\d)"#, with: "\u{00A0}$1", options: .regularExpression)
    }

    /// What the sheets make where that is not the paper itself: a booklet folded from it, or pages of half its size.
    private func finished(language: String) -> String? {
        let half = (layout.sheet.halved ?? layout.sheet).shortName
        switch layout.kind {
        case .booklet: return PrintModeText.format("Finished: %@ booklet", language: language, half)
        case .twoUp: return PrintModeText.format("Finished: 2 pages of %@ on each sheet", language: language, half)
        case .normal, .handout3, .fourUp: return nil
        }
    }
}

extension PrintOutcome {
    /// What one composition takes and makes: the paper and sheets of its plan, and its pages sorted into the body, the
    /// contents, the notes and the blanks. A blank is an empty slot of the plan (the end of a booklet, the half of the
    /// last sheet of two pages on one sheet) or a page left blank on purpose; a note counts only when it is printed.
    /// - Parameter contents: The contents pages to count apart from the body (`countedContents`).
    init(
        plan: ImpositionPlan, layout: PrintLayout, blankPages: Set<Int>, notePages: [Int], contents: Int, copies: Int,
        orientations: [PaperOrientation]
    ) {
        let slots = plan.sides.flatMap(\.slots)
        let printed = Set(slots.compactMap { $0 })
        let blanks = slots.filter { $0 == nil }.count + blankPages.intersection(printed).count
        let notes = notePages.filter(printed.contains).count
        self.init(
            layout: layout, paper: plan.paper, sheets: plan.sheetCount, pages: slots.count,
            body: max(0, slots.count - blanks - contents - notes), contents: contents, notes: notes, blanks: blanks,
            copies: copies, orientations: orientations)
    }

    /// The contents pages told apart from the body. Where the contents are among the pages of a range is not known,
    /// so a range counts them with the body; a document that is not a text has none.
    static func countedContents(added: Int, appliesToText: Bool, selectsPages: Bool) -> Int {
        appliesToText && !selectsPages ? added : 0
    }
}

extension DocumentViewModel {
    /// What one press of Print takes and makes, all from the sheets on the tray (`shownSheets`): while newer sheets are
    /// composed it still tells the sheets in view, so that a newer page count never meets an older sheet count.
    var printOutcome: PrintOutcome? {
        guard let result = shownSheets else { return nil }
        return PrintOutcome(
            plan: result.plan, layout: result.layout, blankPages: result.blankPages, notePages: result.notePages,
            contents: PrintOutcome.countedContents(
                added: result.addedContentsPages, appliesToText: finishAppliesToText,
                selectsPages: result.pageSelection.pages != nil),
            copies: copies, orientations: result.sheetOrientations)
    }
}

extension PrintModeText {
    static func sheetCount(_ count: Int, language: String) -> String {
        format("%lld sheets", language: language, count)
    }
}
