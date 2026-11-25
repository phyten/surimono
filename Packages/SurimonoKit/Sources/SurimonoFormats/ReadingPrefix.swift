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

    package static func csvColumns(in rows: [[String]]) -> Int? {
        guard rows.count > csvThresholdRecords else { return nil }
        return rows.lazy.map(\.count).max()
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
