import Darwin
import Foundation
import LaTeXCorpusSupport
import SurimonoFormats
import Testing

struct LaTeXReaderStackTests {
    /// A dispatch queue or Swift task may reuse a thread with a larger stack and mask the regression.
    private func onWorker<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let size = 512 * 1024
        let (actual, result): (Int, Value) = try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    let actual = pthread_get_stacksize_np(pthread_self())
                    continuation.resume(returning: (actual, try body()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = size
            thread.start()
        }
        // Darwin may include thread bookkeeping up to the next VM page in pthread's reported span.
        #expect((size...(size + Int(getpagesize()))).contains(actual))
        return result
    }

    @Test("512 KiB のスレッドで八重のリスト・引用と後続本文を最後まで読む", .timeLimit(.minutes(1)), arguments: ["itemize", "quote", "mixed"])
    func nestedEnvironments(_ pattern: String) async throws {
        let body = try await onWorker {
            var tex = "Innermost"
            for level in 0..<8 {
                let list = pattern == "itemize" || pattern == "mixed" && level.isMultiple(of: 2)
                let environment = list ? "itemize" : "quote"
                tex = "\\begin{\(environment)}\n" + (list ? #"\item "# : "") + tex + "\n\\end{\(environment)}"
            }
            let type = pattern == "mixed" ? "beamer" : "article"
            if type == "beamer" {
                tex = #"\begin{frame}{Stack fixture}\begin{block}{Steps}"# + tex + #"\end{block}\end{frame}"#
            }
            return LaTeXConverter.convert(
                "\\documentclass{\(type)}\\begin{document}\n" + tex + "\n\nAfter nesting.\\end{document}",
                fontIndex: InstalledFontIndex(faces: [:])
            ).body
        }
        let lists = pattern == "itemize" ? 8 : pattern == "quote" ? 0 : 4
        #expect(body.components(separatedBy: "</ul>").count - 1 == lists)
        #expect(body.components(separatedBy: "</blockquote>").count - 1 == 8 - lists)
        #expect(body.contains("Innermost") && body.contains("After nesting."))
    }

    @Test("512 KiB のスレッドで全コーパスを変換し、分割された原稿の本文も読む", .timeLimit(.minutes(1)))
    func corpus() async throws {
        let (ids, empty, split, table) = try await onWorker {
            var ids: [String] = []
            var empty: [String] = []
            var split = ""
            var table = ""
            try LaTeXCorpus.forEachDocument { folder, fragment in
                ids.append(String(folder.prefix(3)))
                if fragment.body.isEmpty { empty.append(folder) }
                if folder == "022-batch-grid" { table = fragment.body }
                if folder == "038-bound-ledger" { split = fragment.body }
            }
            return (ids, empty, split, table)
        }
        let required = (1...127).map { String(format: "%03d", $0) }
        #expect(Set(required).isSubset(of: Set(ids)))
        #expect(empty.isEmpty)
        #expect(split.contains("Two blue slips arrived"))
        #expect(split.contains("The gauge fitted the middle slot."))
        var inCell = false
        var math: [String] = []
        for case .tag(let tag) in HTMLScanner.tokens(table) {
            if tag.name == "td" { inCell = !tag.isClosing }
            if inCell, tag.name == "svg", let formula = tag.attribute("aria-label") { math.append(formula) }
        }
        #expect(math == ["x_1", "x_2", "x_3", #"\bar{x}"#])
    }
}
