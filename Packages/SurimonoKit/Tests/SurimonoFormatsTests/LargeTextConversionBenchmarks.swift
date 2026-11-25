import Darwin
import Foundation
import SurimonoFormats
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH_LARGE_TEXT"] != nil))
struct LargeTextConversionBenchmarks {
    private enum Input: String {
        case text1MB, text10MB, text50MB, csv10k, csv100k, csv500k

        var isCSV: Bool {
            switch self {
            case .csv10k, .csv100k, .csv500k: true
            default: false
            }
        }

        var rows: Int {
            switch self {
            case .text1MB, .csv10k: 10_000
            case .text10MB, .csv100k: 100_000
            case .text50MB, .csv500k: 500_000
            }
        }

        func bytes() -> Data {
            let logPrefix = "2026-01-01 INFO request completed "
            let line =
                isCSV
                ? "1234,\"A,B\",123.45,complete\r\n"
                : logPrefix + String(repeating: "x", count: 99 - logPrefix.utf8.count) + "\n"
            var data = isCSV ? Data("id,label,amount,status\r\n".utf8) : Data()
            let repetitions = rows - (isCSV ? 1 : 0)
            data.reserveCapacity(data.count + repetitions * line.utf8.count)
            // A second input-sized string would count towards the process high-water mark.
            let block = Data(String(repeating: line, count: 1_000).utf8)
            for _ in 0..<(repetitions / 1_000) { data.append(block) }
            data.append(block.prefix((repetitions % 1_000) * line.utf8.count))
            return data
        }
    }

    @Test("大容量ログとCSVのデコードからHTML断片ができるまでを計測する")
    func convert() throws {
        let input = try #require(
            Input(rawValue: ProcessInfo.processInfo.environment["SURIMONO_BENCH_LARGE_TEXT"] ?? ""))
        let data = input.bytes()
        let start = ContinuousClock.now
        let text = TextDecoding.decode(data).text
        let html =
            input.isCSV ? CSVConverter.convert(text).body : PlainTextConverter.convert(text, fileName: "bench.log").body
        let elapsed = start.duration(to: .now)
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            "BENCH \(input.rawValue) inputBytes=\(data.count) htmlBytes=\(html.utf8.count) seconds=\(seconds) peakRSSBytes=\(usage.ru_maxrss)"
        )
        let expectedBytes: Int
        if input.isCSV {
            let header = "<tr><th>id</th><th>label</th><th>amount</th><th>status</th></tr>"
            let row = "<tr><td>1234</td><td>A,B</td><td>123.45</td><td>complete</td></tr>"
            let table = "<table class=\"surimono-csv\"><thead>\(header)</thead><tbody></tbody></table>"
            expectedBytes = table.utf8.count + (input.rows - 1) * row.utf8.count
        } else {
            expectedBytes = "<pre class=\"surimono-plain\"></pre>".utf8.count + input.rows * 100
        }
        #expect(html.utf8.count == expectedBytes)
    }
}
