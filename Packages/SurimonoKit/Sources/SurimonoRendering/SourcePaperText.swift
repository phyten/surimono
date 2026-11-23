import Foundation
import ObjectiveC
import PDFKit
import SurimonoCore

/// The decoded revision that produced a set of logical pages. A trial, reload or binder keeps its own association.
/// PDFKit supplies the selection's UTF-16 positions. Only the original supplies characters for the clipboard.
@MainActor
public enum SourcePaperText {
    private static var key: UInt8 = 0
    private struct UnmatchedSelection: Error {}

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
            on page: PDFPage, index: Int, in document: PDFDocument, start: Int, ranges: [NSRange], fromPrevious: Bool,
            intoNext: Bool
        ) -> String? {
            let local = index - start
            while offsets.count <= local {
                let prior = offsets.count - 1
                guard let page = document.page(at: start + prior),
                    let scanned = scan(page, at: prior, ranges: [])
                else { return nil }
                offsets.append(scanned.end)
            }
            // PDFKit ranges belong to the displayed page. Redrawing a logical PDF can change its extracted whitespace.
            guard
                let scanned = scan(
                    page, at: local, ranges: ranges, fromPrevious: fromPrevious, intoNext: intoNext)
            else { return nil }
            if offsets.count == local + 1 { offsets.append(scanned.end) }
            return scanned.selected.map { String(decoding: units[$0], as: UTF16.self) }.joined(separator: "\n")
        }

        private func scan(
            _ pdfPage: PDFPage, at page: Int, ranges: [NSRange], fromPrevious: Bool = false, intoNext: Bool = false
        )
            -> (end: Int, selected: [Range<Int>])?
        {
            let pdf = pdfPage.string ?? ""
            let glyphs = Array(pdf.utf16)
            let start = offsets[page]
            var cursor = start
            var i = 0
            func white(_ unit: UInt16) -> Bool { unit == 32 || (9...13).contains(unit) }
            func newline(_ unit: UInt16) -> Bool { unit == 10 || unit == 13 }
            // A continuous selection can arrive as runs separated only by PDFKit's layout whitespace.
            // Separate selections with visible text between them must never copy that intervening code.
            var groups: [NSRange] = []
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                guard range.location >= 0, range.location <= glyphs.count, range.length >= 0,
                    range.length <= glyphs.count - range.location
                else { return nil }
                if let last = groups.last,
                    NSMaxRange(last) >= range.location
                        || glyphs[NSMaxRange(last)..<range.location].allSatisfy({ white($0) })
                {
                    groups[groups.count - 1] = NSUnionRange(last, range)
                } else {
                    groups.append(range)
                }
            }
            // PDFKit can count the following line separator in a range ending on the last visible glyph.
            // Trim it only if the selection's text agrees exactly, retaining breaks inside or across pages.
            for index in groups.indices {
                let range = groups[index]
                let end = NSMaxRange(range)
                guard range.length > 0, newline(glyphs[end - 1]) else { continue }
                if end == glyphs.count, range.location == 0 || intoNext { continue }
                var stop = end - 1
                if glyphs[stop] == 10, stop > range.location, glyphs[stop - 1] == 13 { stop -= 1 }
                if let visible = pdfPage.selection(for: range)?.string,
                    glyphs[range.location..<stop].elementsEqual(visible.utf16)
                {
                    groups[index].length = stop - range.location
                }
            }
            var selected = [Range<Int>?](repeating: nil, count: groups.count)
            var group = 0
            func record(_ lower: Int, _ upper: Int) {
                while group < groups.count, NSMaxRange(groups[group]) <= i { group += 1 }
                guard group < groups.count, NSLocationInRange(i, groups[group]) else { return }
                selected[group] = (selected[group]?.lowerBound ?? lower)..<upper
            }
            if page == 0, let label, pdf.hasPrefix(label) {
                i = label.utf16.count
                while i < glyphs.count, newline(glyphs[i]) { i += 1 }
            }
            while i < glyphs.count {
                if white(glyphs[i]) {
                    let begin = i
                    while i < glyphs.count, white(glyphs[i]) { i += 1 }
                    let end = i
                    if cut, glyphs[begin..<end].contains(where: { newline($0) }) {
                        while cursor < units.count, !newline(units[cursor]) { cursor += 1 }
                    }
                    let before = cursor
                    while cursor < units.count, white(units[cursor]) { cursor += 1 }
                    if end == glyphs.count, page + 1 < pageCount {
                        // A trailing PDF newline does not own the indentation at the start of the next page.
                        var boundary = before
                        for offset in before..<cursor where newline(units[offset]) { boundary = offset + 1 }
                        cursor = boundary
                    }
                    // PDFKit can emit one space for a tab, several spaces, or none. A visual wrap can emit
                    // a newline for no source character at all. Project only within this whitespace interval.
                    let width = cursor - before
                    for offset in 0..<(end - begin) {
                        i = begin + offset
                        record(before + width * offset / (end - begin), before + width * (offset + 1) / (end - begin))
                    }
                    i = end
                } else {
                    while cursor < units.count, white(units[cursor]) { cursor += 1 }
                    if cut, glyphs[i] == 0x2026, cursor == units.count || units[cursor] != glyphs[i] {
                        let before = cursor
                        while cursor < units.count, !newline(units[cursor]) { cursor += 1 }
                        record(before, cursor)
                    } else {
                        guard cursor < units.count, glyphs[i] == units[cursor] else { return nil }
                        record(cursor, cursor + 1)
                        cursor += 1
                    }
                    i += 1
                }
            }
            // Give the hard line terminator to the preceding page. Leave the next line's indent to that page.
            if cut, let final = glyphs.last, !newline(final) {
                while cursor < units.count, !newline(units[cursor]) { cursor += 1 }
            }
            var look = cursor
            while look < units.count, white(units[look]) {
                look += 1
                if newline(units[look - 1]) { cursor = look }
            }
            if page + 1 == pageCount {
                guard look == units.count else { return nil }
                cursor = look
            }
            if groups.count == 1, groups[0] == NSRange(location: 0, length: glyphs.count) {
                return (cursor, [start..<cursor])
            }
            if fromPrevious, groups.first?.location == 0, let first = selected.first ?? nil {
                selected[0] = start..<first.upperBound
            }
            if intoNext, let range = groups.last, NSMaxRange(range) == glyphs.count, let last = selected.last ?? nil {
                selected[selected.count - 1] = last.lowerBound..<cursor
            }
            return (cursor, selected.compactMap { $0 })
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
    ) throws -> String? {
        guard let sections = sections(document) else { return nil }
        let pages = selection.pages.compactMap { page in logicalIndex(page).map { ($0, page) } }.sorted { $0.0 < $1.0 }
        var result = ""
        var usedSource = false
        var previous: Section?
        let starts = sections.starts.keys.sorted()
        var nextStart = starts.startIndex
        for (offset, item) in pages.enumerated() {
            let (index, page) = item
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
            let intoNext = offset + 1 < pages.count && pages[offset + 1].0 == index + 1
            guard
                let part = section.selected(
                    on: page, index: index, in: document, start: start, ranges: ranges,
                    fromPrevious: previous === section && offset > 0 && pages[offset - 1].0 == index - 1,
                    intoNext: intoNext)
            else { throw UnmatchedSelection() }
            if !result.isEmpty, previous !== section, !result.hasSuffix("\n") { result += "\n" }
            result += part
            previous = section
            usedSource = true
        }
        return usedSource ? result : nil
    }
}
