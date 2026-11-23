import Foundation
import ObjectiveC
import PDFKit
import SurimonoCore

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

    private final class Section {
        let text: String
        lazy var units = Array(text.utf16)
        let pageCount: Int
        let cut: Bool
        let label: String?
        // An offset per visited page. No PDF text or per-glyph index is kept after a copy.
        var offsets = [0]

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
            while offsets.count <= local {
                let prior = offsets.count - 1
                guard let page = document.page(at: start + prior),
                    let scanned = scan(page.string ?? "", at: prior, ranges: [], visibleText: { _ in nil })
                else { return nil }
                offsets.append(scanned.end)
            }
            // PDFKit ranges belong to the displayed page. Redrawing a logical PDF can change its extracted whitespace.
            guard
                let scanned = scan(
                    page.string ?? "", at: local, ranges: ranges, visibleText: { page.selection(for: $0)?.string })
            else { return nil }
            if offsets.count == local + 1 {
                offsets.append(scanned.end)
            } else if offsets[local + 1] != scanned.end {
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
        // A second break represents a blank row whose page is unknown. Never cache an offset beyond it.
        private func pageEnd(after ink: Int, final: Bool) -> Int? {
            if final { return units[ink...].allSatisfy { white($0) } ? units.count : nil }
            guard ink < units.count else { return nil }
            if !white(units[ink]) { return ink }
            // Horizontal space before a break can itself wrap onto the next page.
            guard newline(units[ink]) else { return nil }
            var end = ink + 1
            if units[ink] == 13, end < units.count, units[end] == 10 { end += 1 }
            for unit in units[end...] {
                if !white(unit) { return end }
                if newline(unit) { return nil }
            }
            return nil
        }

        private func scan(_ pdf: String, at page: Int, ranges: [NSRange], visibleText: (NSRange) -> String?)
            -> (end: Int, selected: [Piece])?
        {
            let glyphs = Array(pdf.utf16)
            let start = offsets[page]
            var cursor = start
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
                if let visible = visibleText(NSRange(range)),
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
            if page == 0, let label, pdf.hasPrefix(label) {
                i = label.utf16.count
                while i < glyphs.count, newline(glyphs[i]) { i += 1 }
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
                        guard cursor < units.count, glyphs[i] == units[cursor] else { return nil }
                        cursor += 1
                    }
                    i += 1
                    guard record(begin..<i, source: before..<cursor) else { return nil }
                }
            }
            if cut, hasSourceInk {
                while cursor < units.count, !newline(units[cursor]) { cursor += 1 }
            }
            let final = page + 1 == pageCount
            guard hasSourceInk || final, let end = pageEnd(after: cursor, final: final), isSourceBoundary(end) else {
                return nil
            }
            if wholePage {
                return (end, [Piece(range: start..<end, pageStart: start, pageEnd: end)])
            }
            if i < glyphs.count, !record(i..<glyphs.count, source: cursor..<end) { return nil }
            var pieces: [Piece] = []
            for (index, part) in selected.enumerated() {
                guard let part, !part.isEmpty else { continue }
                guard isSourceBoundary(part.lowerBound), isSourceBoundary(part.upperBound) else { return nil }
                pieces.append(
                    Piece(
                        range: part, pageStart: groups[index].lowerBound == 0 ? start : nil,
                        pageEnd: index == groups.count - 1 && endsAtEdge ? end : nil))
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
