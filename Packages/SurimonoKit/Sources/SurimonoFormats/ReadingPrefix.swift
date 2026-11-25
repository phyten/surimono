import Foundation

package enum ReadingPrefix {
    // On the development Mac, opening and snapshotting 1/10/29 MB logs took 3.9/15.4/53.5 s;
    // 10k/59k CSV records took 4.7/28.8 s. About 3 s in each measurement was launch and quit.
    package static let textThresholdBytes = 1_000_000
    static let byteBudget = 200_000
    static let textLeadingLines = 1_000
    static let csvThresholdRecords = 5_000
    static let csvLeadingRecords = 1_000

    package static func text(_ text: String, sourceBytes: Int) -> String? {
        guard sourceBytes > textThresholdBytes else { return nil }
        let bytes = text.utf8
        var end: String.UTF8View.Index?
        var lines = 0
        var index = bytes.startIndex
        let limit = bytes.index(index, offsetBy: byteBudget, limitedBy: bytes.endIndex) ?? bytes.endIndex
        while index < limit {
            let byte = bytes[index]
            bytes.formIndex(after: &index)
            if byte == 13, index < bytes.endIndex, bytes[index] == 10 {
                guard index < limit else { break }
                bytes.formIndex(after: &index)
            } else if byte != 13 && byte != 10 {
                continue
            }
            end = index
            lines += 1
            // Short log lines can consume hundreds of pages within the byte budget.
            if lines == textLeadingLines { break }
        }
        guard index < bytes.endIndex, let end else { return nil }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    package static func csvColumnGroup(in rows: [[String]], widthAtDefaultScale: Double? = nil) -> String? {
        guard rows.count > csvThresholdRecords else { return nil }
        // Standard tables use 10.5 pt type. Allow 5.75 pt per half-width character plus separate cell padding.
        let capacity = (widthAtDefaultScale ?? 512) / 5.75
        let lineLimit = Int(max(32, capacity.rounded(.up)))
        var columns: [ColumnStatistics] = []
        var compact: [UInt8] = []
        for (index, row) in rows.enumerated() {
            // A late record may add millions of columns. When even empty columns cannot fit, switch
            // to one byte per column, carrying forward the maxima already seen.
            if !compact.isEmpty || Double(row.count) * cellPadding > capacity {
                if compact.isEmpty {
                    compact = columns.map(\.compactWeight)
                    columns.removeAll()
                }
                if row.count > compact.count {
                    compact.append(contentsOf: repeatElement(4, count: row.count - compact.count))
                }
                for (column, cell) in row.enumerated() where compact[column] < 32 {
                    let width = CellWidth.measure(cell, tokenLimit: 0, lineLimit: 32)
                    compact[column] = max(compact[column], UInt8(min(32, width.longestLine)))
                }
                continue
            }
            while columns.count < row.count { columns.append(ColumnStatistics(lineLimit: lineLimit)) }
            for (column, cell) in row.enumerated() {
                let width = CellWidth.measure(cell, tokenLimit: index == 0 ? 28 : 16, lineLimit: lineLimit)
                columns[column].record(width)
            }
        }
        if !compact.isEmpty { return columnGroup(compact.lazy.map(Double.init)) }
        guard !columns.isEmpty else { return nil }
        let minimums = columns.map(\.minimum)
        guard minimums.reduce(0, +) <= capacity else {
            return columnGroup(columns.lazy.map { Double($0.compactWeight) })
        }
        let naturals = columns.map { $0.natural(rowCount: rows.count) }
        let total = naturals.reduce(0, +)
        if total > capacity { return columnGroup(shrink(naturals, above: minimums, to: capacity)) }
        let contentTotal = naturals.filter { $0 > cellPadding }.reduce(0, +)
        let extra = contentTotal > 0 ? (capacity - total) / contentTotal : 0
        return columnGroup(naturals.map { $0 > cellPadding ? $0 * (1 + extra) : $0 })
    }

    private static func columnGroup(_ widths: some Collection<Double>) -> String {
        let total = widths.reduce(0, +)
        var group = "<colgroup>"
        var start = widths.startIndex
        // HTML limits each col span to 1,000.
        while start != widths.endIndex {
            let width = widths[start]
            var count = 1
            var end = widths.index(after: start)
            while end != widths.endIndex, count < 1_000, widths[end] == width {
                widths.formIndex(after: &end)
                count += 1
            }
            let span = count > 1 ? " span=\"\(count)\"" : ""
            group += "<col\(span) style=\"width:\(100 * width / total)%\">"
            start = end
        }
        return group + "</colgroup>"
    }

    // Leave room for cell padding, borders and differences in proportional typefaces.
    private static let cellPadding = 4.0

    private static func displayWidth(of character: Character) -> Int {
        character.isEastAsianWide || character.unicodeScalars.first?.properties.isEmojiPresentation == true ? 2 : 1
    }

    private struct ColumnStatistics {
        private var histogram: [Int]
        private var count = 0
        private var tokenWidth = 0
        private(set) var compactWeight: UInt8 = 4

        init(lineLimit: Int) {
            histogram = Array(repeating: 0, count: lineLimit + 1)
        }

        mutating func record(_ width: CellWidth) {
            tokenWidth = max(tokenWidth, width.longestToken)
            compactWeight = max(compactWeight, UInt8(min(32, width.longestLine)))
            histogram[width.longestLine == 0 ? 0 : max(4, width.longestLine)] += 1
            count += 1
        }

        var minimum: Double { Double(tokenWidth) + cellPadding }

        func natural(rowCount: Int) -> Double {
            // Missing trailing fields in ragged rows have zero width; account for them without visiting them.
            var rank = (rowCount * 9 + 9) / 10 - (rowCount - count)
            for (width, frequency) in histogram.enumerated() {
                rank -= frequency
                if rank <= 0 { return Double(max(tokenWidth, width)) + cellPadding }
            }
            return minimum
        }
    }

    private struct CellWidth {
        var longestLine = 0
        var longestToken = 0
        private var line = 0
        private var token = 0

        private mutating func add(_ width: Int, newline: Bool, separator: Bool) {
            line = newline ? 0 : line + width
            token = separator ? 0 : token + width
            longestLine = max(longestLine, line)
            longestToken = max(longestToken, token)
        }

        static func measure(_ cell: String, tokenLimit: Int, lineLimit: Int) -> Self {
            var result = Self()
            // Counters, dates and most log fields can be measured directly in UTF-8. For other text
            // measure grapheme clusters so wide glyphs and combining characters keep their display width.
            for byte in cell.utf8 {
                if byte >= 128 {
                    result = Self()
                    for character in cell {
                        let separator =
                            character == "\u{200B}"
                            || (character.isWhitespace && character != "\u{A0}" && character != "\u{2007}"
                                && character != "\u{202F}")
                        result.add(displayWidth(of: character), newline: character.isNewline, separator: separator)
                        if result.longestLine >= lineLimit && result.longestToken >= tokenLimit { break }
                    }
                    break
                }
                result.add(1, newline: (10...13).contains(byte), separator: (9...13).contains(byte) || byte == 32)
                if result.longestLine >= lineLimit && result.longestToken >= tokenLimit { break }
            }
            // Any longer line would be shrunk to the same available width. A hash gets only a capped minimum.
            result.longestLine = min(lineLimit, result.longestLine)
            result.longestToken = min(tokenLimit, result.longestToken)
            return result
        }
    }

    private static func shrink(_ naturals: [Double], above minimums: [Double], to capacity: Double) -> [Double] {
        // Lower a common ceiling on the widest columns. Between two measured widths the total changes linearly.
        func capped(at ceiling: Double) -> [Double] {
            naturals.indices.map { max(minimums[$0], min(naturals[$0], ceiling)) }
        }
        var previous = 0.0
        var occupied = minimums.reduce(0, +)
        for level in Set(minimums + naturals).sorted() {
            let next = capped(at: level).reduce(0, +)
            if next > capacity {
                let fraction = (capacity - occupied) / (next - occupied)
                return capped(at: previous + fraction * (level - previous))
            }
            previous = level
            occupied = next
        }
        return naturals
    }

    package static func csv(_ rows: ArraySlice<[String]>) -> ArraySlice<[String]>? {
        guard rows.count > csvThresholdRecords else { return nil }
        var size = 0
        var count = 0
        for row in rows.prefix(csvLeadingRecords) {
            size += 9
            for field in row {
                size += field.utf8.count + 9
                if size > byteBudget { break }
            }
            if size > byteBudget { break }
            count += 1
        }
        return count > 1 ? rows.prefix(count) : nil
    }
}
