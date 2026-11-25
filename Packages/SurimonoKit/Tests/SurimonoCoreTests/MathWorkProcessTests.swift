import Darwin
import Foundation
import Testing

@testable import SurimonoCore

struct MathWorkProcessTests {
    @Test("組版の上限を超えた式だけを原文で残し、同じ子プロセスで次の式と本文を表示する")
    func bothReadersSurvive() async {
        await #expect(processExitsWith: .success) {
            // These limits apply only to this disposable test process.
            alarm(15)
            var cpu = rlimit(rlim_cur: 8, rlim_max: 8)
            guard setrlimit(RLIMIT_CPU, &cpu) == 0 else { exit(2) }
            // Darwin rejects RLIMIT_AS on this platform. Monitor the process high-water RSS,
            // including mmap allocations, and check it again at completion for a short peak.
            @Sendable func checkMemory() {
                var usage = rusage()
                if getrusage(RUSAGE_SELF, &usage) != 0 || usage.ru_maxrss > 512 << 20 { _exit(3) }
            }
            let ready = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                ready.signal()
                while true {
                    checkMemory()
                    usleep(10_000)
                }
            }
            ready.wait()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("paper.md")
            let inputs = [
                #"\left(\middle|\htmlStyle{font-size:4096em}{x}\right)"#,
                #"\htmlStyle{font-size:1e-323em}{\begin{array}{:c}x\end{array}}"#,
                #"\begin{array}{::::}\rule{0pt}{4096em}\end{array}"#,
                String(repeating: #"\pmb{"#, count: 15) + "x" + String(repeating: "}", count: 15),
                #"\htmlStyle{font-size:5000em;font-size:1em}{x}"#,
            ]
            for formula in inputs {
                let document = "Before.\n\n$$" + formula + "$$\n\nAfter $a+b$. Tail."
                try Data(document.utf8).write(to: file)
                for html in [MarkdownConverter.convert(document).body, FinderPreview.make(for: file).html] {
                    let source = "<pre class=\"math-error\">$$" + HTML.escape(formula) + "$$</pre>"
                    guard html.contains(source), html.contains("Before."), html.contains("Tail."),
                        html.contains(#"aria-label="a+b""#), html.components(separatedBy: "<svg ").count == 2
                    else { throw CocoaError(.coderInvalidValue) }
                }
            }
            checkMemory()
        }
    }
}
