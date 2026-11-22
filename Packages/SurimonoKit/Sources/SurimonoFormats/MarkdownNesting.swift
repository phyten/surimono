import Foundation
import Markdown
import cmark_gfm
import cmark_gfm_extensions

/// swift-markdown turns cmark's tree into its own with a recursive call per level, and so do the converter's visitors.
/// Ten thousand nested block quotes ran out of the 512 KiB stack the app converts on. cmark itself parses without
/// recursion, so the tree is measured with it first, and a top-level block that nests too deeply is shown as its
/// own text instead; the rest of the document is unaffected.
package enum MarkdownNesting {
    /// Levels below the document. Ordinary writing stays far below (a list nested eight deep is about 20 levels).
    /// It is fixed so that a document prints the same wherever it is converted; the conversion runs on a stack that
    /// holds it (about 9 KB a level; `StackSpace.onLargeStack`).
    package static let maximumDepth = 100
    package static let issue = StackSpace.limitIssue

    /// swift-markdown's document for `text`, with any top-level block deeper than the limit shown as its text. Every
    /// place that hands text to swift-markdown goes through here: a footnote's body, re-read without its indent, can
    /// nest deeper than it did inside the document. A flattened block is noted for the document's reading issues.
    package static func document(parsing text: String, options: ParseOptions = []) -> Document {
        let lines = text.components(separatedBy: "\n")
        let flat = flattened(lines)
        guard flat.changed else { return Document(parsing: text, options: options) }
        StackSpace.noteLimitReached()
        return Document(parsing: flat.lines.joined(separator: "\n"), options: options)
    }

    /// The lines with each top-level block that nests deeper than the limit replaced, line for line (so source
    /// positions stay the same), by a `pre` holding its text.
    package static func flattened(_ lines: [String]) -> (lines: [String], changed: Bool) {
        let ranges = deepBlocks(lines.joined(separator: "\n"))
        guard !ranges.isEmpty else { return (lines, false) }
        var lines = lines
        for range in ranges {
            let first = max(0, range.lowerBound)
            let last = min(lines.count - 1, range.upperBound)
            guard first <= last else { continue }
            for index in first...last { lines[index] = HTML.escape(lines[index]) }
            // An HTML block that starts with `pre` ends only at a line holding `</pre>`, which escaped text cannot.
            lines[first] = "<pre class=\"markdown-unread\">" + lines[first]
            lines[last] += "</pre>"
        }
        return (lines, true)
    }

    /// Whether no part of the text nests deeper than the limit.
    package static func isShallow(_ text: String) -> Bool { deepBlocks(text).isEmpty }

    /// `isShallow` without the shortcut for texts with few delimiters (tests compare the two).
    static func isShallowMeasured(_ text: String) -> Bool { deepBlocks(text, shortcut: false).isEmpty }

    /// Zero-based line ranges of the top-level blocks with a node deeper than the limit.
    private static func deepBlocks(_ text: String, shortcut: Bool = true) -> [ClosedRange<Int>] {
        // Every node below the document but a paragraph and its text needs a byte that is not a letter, and one such
        // byte makes at most two levels (a list marker: the list and its item). A text with too few of them for the
        // limit cannot nest that deep, and needs no second parse.
        var delimiters = 0
        let enough = (maximumDepth - 2) / 2 + 1
        for byte in text.utf8 where !(97...122).contains(byte) && !(65...90).contains(byte) && byte != 10 {
            delimiters += 1
            if delimiters >= enough { break }
        }
        guard !shortcut || delimiters >= enough else { return [] }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            if let extensionPointer = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, extensionPointer)
            }
        }
        var bytes = Array(text.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.map {
                cmark_parser_feed(parser, UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self), buffer.count)
            }
        }
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }
        guard let iterator = cmark_iter_new(root) else { return [] }
        defer { cmark_iter_free(iterator) }
        var ranges: [ClosedRange<Int>] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            // Counting at most the limit's worth of parents keeps this linear in the size of the text.
            var depth = 0
            var parent = cmark_node_parent(node)
            while let above = parent, depth <= maximumDepth {
                depth += 1
                parent = cmark_node_parent(above)
            }
            guard depth > maximumDepth else { continue }
            var block = node
            while let above = cmark_node_parent(block), above != root { block = above }
            let start = Int(cmark_node_get_start_line(block)) - 1
            let end = max(start, Int(cmark_node_get_end_line(block)) - 1)
            ranges.append(start...end)
            // The rest of this block is shown as text anyway.
            cmark_iter_reset(iterator, block, CMARK_EVENT_EXIT)
        }
        return ranges
    }
}
