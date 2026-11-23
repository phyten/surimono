import Foundation
import SurimonoCore

// Frozen from 979a4433 so changes to the production matcher cannot also change the oracle.
enum MasterOutlineReference {
    static func pages(
        of headings: [DocumentHeading], inPageTexts pages: [String], contentsEntries: [String] = []
    ) -> [Int?] {
        var index = LineIndex(pages: pages)
        if contentsEntries.contains("") {
            for table in contentsEntries.split(separator: "") {
                let entries = table.map(normalized).filter { !$0.isEmpty }
                if !entries.isEmpty && !index.excludeNext(entries) { break }
            }
        } else {
            index.exclude(contentsEntries.map(normalized))
        }
        var cursor = 0
        return headings.map { heading in
            let target = normalized(heading.text)
            guard !target.isEmpty, let match = index.firstMatch(of: target, from: cursor) else { return nil }
            cursor = match.end
            return match.page
        }
    }

    private struct LineIndex {
        /// A heading wraps only when it is long, so a wrapped one shares at least this much with its first line.
        private static let wrappedPrefixLength = 4

        private var lines: [(page: Int, forms: [String])] = []
        private var whole: [String: [Int]] = [:]
        private var wrapped: [String: [Int]] = [:]
        private var excluded: Set<Int> = []

        init(pages: [String]) {
            for (page, text) in pages.enumerated() {
                for line in text.components(separatedBy: .newlines) {
                    let forms = Self.forms(of: line)
                    guard let first = forms.first, !first.isEmpty else { continue }
                    for form in forms {
                        whole[form, default: []].append(lines.count)
                        if form.count >= Self.wrappedPrefixLength {
                            wrapped[String(form.prefix(Self.wrappedPrefixLength)), default: []].append(lines.count)
                        }
                    }
                    lines.append((page, forms))
                }
            }
        }

        // Restrict only the candidate starts so the original single-table function can be used verbatim.
        mutating func excludeNext(_ entries: [String]) -> Bool {
            let cursor = (excluded.max() ?? -1) + 1
            var remaining = self
            remaining.whole = whole.mapValues { $0.filter { $0 >= cursor } }
            remaining.wrapped = wrapped.mapValues { $0.filter { $0 >= cursor } }
            remaining.exclude(entries)
            guard remaining.excluded.count > excluded.count else { return false }
            excluded = remaining.excluded
            return true
        }

        /// The text's own table of contents repeats the headings line after line, wherever it stands; a heading
        /// with text under it never does, so the first unbroken run of the entries is the table.
        mutating func exclude(_ entries: [String]) {
            let entries = entries.filter { !$0.isEmpty }
            guard let first = entries.first else { return }
            var starts = whole[first] ?? []
            if first.count > Self.wrappedPrefixLength {
                starts += wrapped[String(first.prefix(Self.wrappedPrefixLength))] ?? []
            }
            for start in Set(starts).sorted() {
                var line = start
                var covered: [Int] = []
                var matched = 0
                for entry in entries {
                    guard line < lines.count else { break }
                    if lines[line].forms.contains(entry) {
                        covered.append(line)
                        line += 1
                    } else if let end = endOfWrappedHeading(entry, from: line) {
                        covered += Array(line..<end)
                        line = end
                    } else {
                        break
                    }
                    matched += 1
                }
                // A wrapped entry takes several lines, so only the entries themselves can tell the table is whole.
                if matched == entries.count {
                    excluded.formUnion(covered)
                    return
                }
            }
        }

        func firstMatch(of target: String, from cursor: Int) -> (page: Int, end: Int)? {
            var best: (page: Int, end: Int, start: Int)?
            let exact = whole[target] ?? []
            var start = Self.firstPosition(in: exact, atLeast: cursor)
            while start < exact.count, excluded.contains(exact[start]) { start += 1 }
            if start < exact.count {
                best = (lines[exact[start]].page, exact[start] + 1, exact[start])
            }
            guard target.count > Self.wrappedPrefixLength else { return best.map { ($0.page, $0.end) } }
            let candidates = wrapped[String(target.prefix(Self.wrappedPrefixLength))] ?? []
            var position = Self.firstPosition(in: candidates, atLeast: cursor)
            while position < candidates.count, candidates[position] < best?.start ?? .max {
                let start = candidates[position]
                if !excluded.contains(start), let end = endOfWrappedHeading(target, from: start) {
                    best = (lines[start].page, end, start)
                    break
                }
                position += 1
            }
            return best.map { ($0.page, $0.end) }
        }

        /// The index after the last line of a heading that wraps from `start`. It stays on one page.
        private func endOfWrappedHeading(_ target: String, from start: Int) -> Int? {
            for form in lines[start].forms where target.hasPrefix(form) {
                var joined = form
                var index = start + 1
                while index < lines.count, lines[index].page == lines[start].page {
                    joined += lines[index].forms[0]
                    index += 1
                    if joined == target { return index }
                    guard target.hasPrefix(joined) else { break }
                }
            }
            return nil
        }

        /// The line as it stands, and without a number when it has one: a theme can number a heading with a counter,
        /// which puts text in front of it on the page only.
        private static func forms(of line: String) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let number = trimmed.prefix { $0.isNumber || ".．、:：-)）(（".contains($0) }
            let rest = trimmed.dropFirst(number.count)
            let endsNumber = rest.first?.isWhitespace == true || number.last.map { !$0.isNumber } == true
            guard !number.isEmpty, !rest.isEmpty, endsNumber else { return [normalized(line)] }
            return [normalized(line), normalized(String(rest))]
        }

        private static func firstPosition(in sorted: [Int], atLeast value: Int) -> Int {
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    private static func normalized(_ text: String) -> String {
        String(
            text.precomposedStringWithCompatibilityMapping.unicodeScalars
                .filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                .map(Character.init))
    }
}
