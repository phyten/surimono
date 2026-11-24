import Foundation
import ObjectiveC
import PDFKit
import SurimonoCore
import SurimonoFormats

/// The decoded revision that produced a set of logical pages. A trial, reload or binder keeps its own association.
/// PDFKit supplies the selection's UTF-16 positions. Only the original supplies characters for the clipboard.
@MainActor
public enum SourcePaperText {
    private static var key: UInt8 = 0
    private struct Piece {
        let range: Range<Int>
        let pageStart: Int?
        let pageEnd: Int?
    }

    private final class Sections {
        var starts: [Int: Section] = [:]
    }

    private enum Boundary: Equatable {
        case exact(Int)
        // Whitespace ownership is unknown, but the next page's ink must match here (or this is EOF).
        case nextInk(Int)

        var cursor: Int {
            switch self {
            case .exact(let offset), .nextInk(let offset): offset
            }
        }

        var edge: Int? {
            guard case .exact(let offset) = self else { return nil }
            return offset
        }
    }

    private final class Section {
        let text: String
        lazy var units = Array(text.utf16)
        let pageCount: Int
        let cut: Bool
        let label: String?
        // Only one cursor per visited page survives a copy, including pages with no ink.
        var boundaries: [Boundary] = [.exact(0)]

        init(_ text: String, pages: Int, cut: Bool, label: String?) {
            self.text = text
            pageCount = pages
            self.cut = cut
            self.label = label
        }

        func selected(
            on page: PDFPage, index: Int, in document: PDFDocument, start: Int, ranges: [NSRange]
        ) -> [Piece]? {
            let local = index - start
            while boundaries.count <= local {
                let prior = boundaries.count - 1
                guard let page = document.page(at: start + prior),
                    let scanned = scan(page, at: prior, ranges: [])
                else { return nil }
                boundaries.append(scanned.end)
            }
            // PDFKit ranges belong to the displayed page. Redrawing a logical PDF can change its extracted whitespace.
            guard let scanned = scan(page, at: local, ranges: ranges) else { return nil }
            if boundaries.count == local + 1 {
                boundaries.append(scanned.end)
            } else if boundaries[local + 1] != scanned.end {
                return nil
            }
            return scanned.selected
        }

        private func white(_ unit: UInt16) -> Bool { unit == 32 || (9...13).contains(unit) }
        private func newline(_ unit: UInt16) -> Bool { unit == 10 || unit == 13 }

        private func isSourceBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < units.count else { return true }
            return !(units[offset - 1] == 13 && units[offset] == 10) && !(0xDC00...0xDFFF).contains(units[offset])
        }

        // The break terminating a nonempty source line belongs to that line; the indent after it does not.
        // A second break or trailing horizontal space may fall on either sheet. Advance only the ink cursor.
        private func pageEnd(after ink: Int, hasSourceInk: Bool, final: Bool) -> Boundary? {
            let next = units[ink...].firstIndex { !white($0) } ?? units.count
            if final { return next == units.count ? .exact(units.count) : nil }
            guard hasSourceInk, next < units.count else { return .nextInk(next) }
            if next == ink { return .exact(ink) }
            guard newline(units[ink]) else { return .nextInk(next) }
            var end = ink + 1
            if units[ink] == 13, end < units.count, units[end] == 10 { end += 1 }
            if units[end..<next].contains(where: { newline($0) }) { return .nextInk(next) }
            return .exact(end)
        }

        private func selectableGlyphs(on sheet: PDFPage, at page: Int, ranges: [NSRange]) -> [UInt16]? {
            let glyphs = Array((sheet.string ?? "").utf16)
            // Scanning earlier pages only needs the ink, except when locating a label or a cut line.
            guard !ranges.isEmpty || cut || (page == 0 && label != nil),
                !(ranges.count == 1 && ranges[0] == NSRange(glyphs.indices)),
                let first = glyphs.first, let last = glyphs.last, white(first) || white(last)
            else { return glyphs }
            let count = sheet.numberOfCharacters
            guard count > 0, count < glyphs.count else { return glyphs }
            // Only discard extraction padding outside PDFKit's selectable UTF-16 coordinate space.
            // Anchor both strings at their first ink and verify every selectable unit and both margins.
            guard let text = sheet.selection(for: NSRange(location: 0, length: count))?.string else { return nil }
            let selectable = Array(text.utf16)
            guard selectable.count == count else { return nil }
            guard let ink = glyphs.firstIndex(where: { !white($0) }) else {
                return glyphs.starts(with: selectable) || glyphs.suffix(count).elementsEqual(selectable)
                    ? selectable : nil
            }
            guard let selectedInk = selectable.firstIndex(where: { !white($0) }) else { return nil }
            let offset = ink - selectedInk
            guard offset >= 0, offset <= glyphs.count - count,
                glyphs[offset..<(offset + count)].elementsEqual(selectable),
                glyphs[(offset + count)...].allSatisfy(white)
            else { return nil }
            return selectable
        }

        private func scan(_ sheet: PDFPage, at page: Int, ranges: [NSRange])
            -> (end: Boundary, selected: [Piece])?
        {
            guard let glyphs = selectableGlyphs(on: sheet, at: page, ranges: ranges) else { return nil }
            let start = boundaries[page]
            var cursor = start.cursor
            var i = 0
            var groups: [Range<Int>] = []
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                guard range.location >= 0, range.location <= glyphs.count, range.length >= 0,
                    range.length <= glyphs.count - range.location
                else { return nil }
                guard range.length > 0 else { continue }
                let bounds = range.location..<NSMaxRange(range)
                if let last = groups.last, last.upperBound >= bounds.lowerBound {
                    groups[groups.count - 1] = last.lowerBound..<max(last.upperBound, bounds.upperBound)
                } else {
                    groups.append(bounds)
                }
            }
            let wholePage = groups.count == 1 && groups[0] == glyphs.indices
            let endsAtEdge = groups.last?.upperBound == glyphs.count
            // PDFKit can count the following separator even though the selection ends on the last visible glyph.
            for index in groups.indices where !wholePage {
                let range = groups[index]
                var stop = range.upperBound - 1
                guard newline(glyphs[stop]) else { continue }
                if glyphs[stop] == 10, stop > range.lowerBound, glyphs[stop - 1] == 13 { stop -= 1 }
                if let visible = sheet.selection(for: NSRange(range))?.string,
                    glyphs[range.lowerBound..<stop].elementsEqual(visible.utf16)
                {
                    groups[index] = range.lowerBound..<stop
                }
            }

            var selected = [Range<Int>?](repeating: nil, count: groups.count)
            var group = 0
            // Endpoints between two matching glyphs are known. Inside transformed whitespace, only its
            // outer endpoints are anchored. A soft wrap with no source units has just one possible offset.
            func record(_ printed: Range<Int>, source: Range<Int>) -> Bool {
                if wholePage || group == groups.count { return true }
                let canSplit =
                    printed.count > 1 && printed.count == source.count && glyphs[printed].elementsEqual(units[source])
                while group < groups.count {
                    let span = groups[group]
                    if span.lowerBound >= printed.upperBound { break }
                    let overlap = span.clamped(to: printed)
                    if !overlap.isEmpty {
                        var part = source
                        if overlap != printed && !source.isEmpty {
                            guard canSplit else { return false }
                            let lower = source.lowerBound + (overlap.lowerBound - printed.lowerBound)
                            part = lower..<(lower + overlap.count)
                        }
                        selected[group] = (selected[group]?.lowerBound ?? part.lowerBound)..<part.upperBound
                    }
                    if span.upperBound > printed.upperBound { break }
                    group += 1
                }
                return true
            }
            if page == 0, let label, glyphs.starts(with: label.utf16) {
                i = label.utf16.count
                while i < glyphs.count, newline(glyphs[i]) { i += 1 }
            }
            if start.edge == nil {
                // Leading PDF whitespace has no known origin. The first nonblank still has a unique offset.
                while i < glyphs.count, white(glyphs[i]) { i += 1 }
                if groups.contains(where: { !$0.isEmpty && $0.lowerBound < i }) { return nil }
            }
            // Handle trailing whitespace once, after deciding how much of the original belongs to this page.
            let inkEnd = glyphs.lastIndex(where: { !white($0) }).map { $0 + 1 } ?? 0
            let hasSourceInk = i < inkEnd
            while i < inkEnd {
                let begin = i
                if white(glyphs[i]) {
                    while i < inkEnd, white(glyphs[i]) { i += 1 }
                    if cut, glyphs[begin..<i].contains(where: { newline($0) }) {
                        while cursor < units.count, !newline(units[cursor]) { cursor += 1 }
                    }
                    let before = cursor
                    while cursor < units.count, white(units[cursor]) { cursor += 1 }
                    guard record(begin..<i, source: before..<cursor) else { return nil }
                } else {
                    while cursor < units.count, white(units[cursor]) { cursor += 1 }
                    let before = cursor
                    if cut, glyphs[i] == 0x2026, cursor == units.count || units[cursor] != glyphs[i] {
                        while cursor < units.count, !newline(units[cursor]) { cursor += 1 }
                    } else {
                        guard cursor < units.count,
                            glyphs[i] == units[cursor] || LaTeXIdeographs.isRadicalPair(glyphs[i], units[cursor])
                        else { return nil }
                        cursor += 1
                    }
                    i += 1
                    guard record(begin..<i, source: before..<cursor) else { return nil }
                }
            }
            if cut, hasSourceInk {
                while cursor < units.count, !newline(units[cursor]) { cursor += 1 }
            }
            guard let end = pageEnd(after: cursor, hasSourceInk: hasSourceInk, final: page + 1 == pageCount),
                isSourceBoundary(end.cursor)
            else {
                return nil
            }
            if wholePage {
                guard let first = start.edge, let last = end.edge else { return nil }
                return (end, [Piece(range: first..<last, pageStart: first, pageEnd: last)])
            }
            if let last = end.edge {
                if i < glyphs.count, !record(i..<glyphs.count, source: cursor..<last) { return nil }
            } else if let stop = groups.last?.upperBound, endsAtEdge || stop > inkEnd {
                return nil
            }
            var pieces: [Piece] = []
            for (index, part) in selected.enumerated() {
                guard let part, !part.isEmpty else { continue }
                guard isSourceBoundary(part.lowerBound), isSourceBoundary(part.upperBound) else { return nil }
                pieces.append(
                    Piece(
                        range: part, pageStart: groups[index].lowerBound == 0 ? start.edge : nil,
                        pageEnd: index == groups.count - 1 && endsAtEdge ? end.edge : nil))
            }
            return (end, pieces)
        }
    }

    private static func sections(_ document: PDFDocument) -> Sections? {
        objc_getAssociatedObject(document, &key) as? Sections
    }

    private static func writableSections(_ document: PDFDocument) -> Sections {
        if let existing = sections(document) { return existing }
        let value = Sections()
        objc_setAssociatedObject(document, &key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }

    /// A visible folio on one of these pages must not extend PDFKit's selectable source range.
    static func pageIndices(in document: PDFDocument) -> IndexSet {
        var pages = IndexSet()
        if let sections = sections(document) {
            for (start, section) in sections.starts {
                pages.insert(integersIn: start..<(start + section.pageCount))
            }
        }
        return pages
    }

    static func attach(_ text: String, to document: PDFDocument, options: CodeBlockOptions, language: SourceLanguage?) {
        writableSections(document).starts[0] = Section(
            text, pages: document.pageCount, cut: options.longLines == .cut,
            label: options.languageLabel == .none ? nil : language?.displayName)
    }

    static func include(_ child: PDFDocument, in binder: PDFDocument, startingAt offset: Int) {
        guard let children = sections(child) else { return }
        let target = writableSections(binder)
        for (start, section) in children.starts { target.starts[start + offset] = section }
    }

    /// The displayed copy can contain blank cover slots or reversed spreads. Read the selected pages in source order.
    public static func selected(
        _ selection: PDFSelection, in document: PDFDocument, logicalIndex: (PDFPage) -> Int?
    ) -> String? {
        guard let sections = sections(document) else { return nil }
        let pages = selection.pages.compactMap { page in logicalIndex(page).map { ($0, page) } }.sorted { $0.0 < $1.0 }
        var result = ""
        var usedSource = false
        var previous: (section: Section, page: Int, piece: Piece)?
        let starts = sections.starts.keys.sorted()
        var nextStart = starts.startIndex
        for (index, page) in pages {
            while nextStart < starts.count, starts[nextStart] <= index { nextStart += 1 }
            let start = nextStart > 0 ? starts[nextStart - 1] : -1
            guard let section = sections.starts[start],
                index < start + section.pageCount
            else {
                for part in 0..<selection.numberOfTextRanges(on: page) {
                    let range = selection.range(at: part, on: page)
                    if let part = page.selection(for: range)?.string {
                        if !result.isEmpty { result += "\n" }
                        result += part
                    }
                }
                previous = nil
                continue
            }
            let ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
            guard !ranges.isEmpty else { continue }
            guard let pieces = section.selected(on: page, index: index, in: document, start: start, ranges: ranges)
            else { return nil }
            for piece in pieces {
                var lower = piece.range.lowerBound
                if let previous, previous.section === section, previous.page + 1 == index,
                    let edge = previous.piece.pageEnd, piece.pageStart == edge
                {
                    // These endpoints straddle the same known boundary. Restore its original break and indent,
                    // or nothing if a single source line wrapped onto the next page.
                    lower = previous.piece.range.upperBound
                } else if let previous, previous.section === section {
                    if previous.page != index || previous.piece.range.upperBound != lower { result += "\n" }
                } else if !result.isEmpty, !result.hasSuffix("\n") {
                    result += "\n"
                }
                result += String(decoding: section.units[lower..<piece.range.upperBound], as: UTF16.self)
                previous = (section, index, piece)
            }
            usedSource = true
        }
        return usedSource ? result : nil
    }
}
