import Foundation
import RobustnessSupport
import Testing

@testable import SurimonoCore

struct ClipboardFormatWorkTests {
    static var inputs: [(String, String)] {
        let limit = 32_768
        func fill(_ unit: String) -> String {
            String(String(repeating: unit, count: limit / max(1, unit.utf16.count) + 1).prefix(limit))
        }
        let tokens = [
            "`", "``", "```", "~~~", "*", "**", "_", "__", "~~", "$", "$$", "[", "]", "[[", "]]", "](", "![x](", "(",
            ")",
            "<", ">", "<a", "<a>", "</a>", "<html>", "<!--", "-->", "<!doctype html>", "<script>", "</script>", "|",
            "| --- ", "|---",
            "\\", "\\a{", "\\begin{x}", "\\end{x}", "\\documentclass{a}", "\\[", "\\]", "\"", "'", "\"a,", "a,", ",",
            "a\t", "\t",
            "#", "# ", "#+", "#+a:", "#+begin_src", "#+end_src", "* ", "** ", ":A:", ":PROPERTIES:", ":END:", "=",
            "=a=", "~a~",
            "-", "- ", "- [ ] ", "1. ", "> ", "{", "}", "{{", "}}", "{%", "%}", "<%", "%>", "<?=", "?>", "{-", "-}",
            "/*", "*/",
            "\"\"\"", "'''", "--[[", "<<", "<<EOF", "@'", "'@", "v-if = ", " :a=", "<>", "</>", "http://",
            "https://a.example/",
            "%", "&", ";", "***************", "*** 1,3 ****", "--- 1,3 ----", "@@ -1 +1 @@", "\u{0000}", "\u{2066}",
            "\u{FFFD}",
        ]
        let pairs = [
            ("/*", "*/"), ("<!--", "-->"), ("{-", "-}"), ("\"\"\"", "\"\"\""), ("{{", "}}"), ("<%", "%>"),
            ("<?=", "?>"),
            ("`", "`"), ("[[", "]]"), ("[", "]"), ("(", ")"), ("<a>", "</a>"), ("$", "$"), ("**", "**"), ("--[[", "]]"),
            ("\\begin{x}", "\\end{x}"),
        ]
        var inputs: [(String, String)] = []
        for token in tokens {
            inputs.append(("one \(token.debugDescription)", fill(token)))
            inputs.append(("space \(token.debugDescription)", fill(token + " ")))
            inputs.append(("line \(token.debugDescription)", fill(token + "\n")))
        }
        // Keep every short-line mark in a full-window mixed pattern; the individual marks retain
        // their full-window contiguous, spaced and line-delimited cases above.
        inputs.append(
            (
                "mixed short lines",
                fill(
                    tokens.map {
                        String(repeating: $0, count: max(1, 20 / $0.utf16.count)) + "\n"
                    }.joined())
            ))
        for (open, close) in pairs {
            let openers = String(repeating: open + " ", count: (limit - close.utf16.count) / (open.utf16.count + 1))
            inputs.append(("openers \(open)", openers + close))
            inputs.append(("closers \(open)", close + " " + openers))
            inputs.append(("alternating \(open)", fill(open + "a" + close + " ")))
            inputs.append(
                (
                    "nested \(open)",
                    String(repeating: open, count: limit / 2 / open.utf16.count)
                        + String(repeating: close, count: limit / 2 / close.utf16.count)
                ))
        }
        inputs.append(("comment", String(repeating: "/* ", count: 32_000 / 3) + "*/"))
        inputs.append(("punctuation", fill("`*_~$[]()<>|\\\"#=:-{}%&;!?")))
        let noteStart = "# Notes\n\n## Details\n\n"
        inputs.append(("note long sentence", noteStart + String(repeating: "word ", count: 6_000) + "ends here."))
        inputs.append(("note long CJK", noteStart + String(repeating: "文", count: 30_000) + "。"))
        inputs.append(("note many sentences", noteStart + String(repeating: "We can print this.\n", count: 1_400)))
        inputs.append(
            ("note final bare token", noteStart + String(repeating: "We can print this.\n", count: 1_400) + "flask"))
        for n in [4_096, 8_192, 16_384, 32_000] {
            inputs.append(("backtick-dollar \(n)", "`" + String(repeating: "a$", count: (n - 1) / 2)))
            inputs.append(("script \(n)", String(repeating: "<script>x</script>", count: n / 18)))
            inputs.append(("style \(n)", String(repeating: "<style>x</style>", count: n / 16)))
        }
        var seen: Set<String> = []
        return inputs.filter { seen.insert($0.1).inserted }
    }

    @Test("全生成入力の走査量はUTF16単位数の固定倍数以内で三秒以内に終わる")
    func boundedWork() {
        var worstRatio = 0.0
        var worstTime = 0.0
        var slowest = ""
        for (name, text) in Self.inputs {
            let start = ContinuousClock.now
            let result = ClipboardFormatDetector.detect(text)
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let ratio = Double(result.scannerSteps) / Double(max(1, result.analysedUnits))
            worstRatio = max(worstRatio, ratio)
            if seconds > worstTime {
                worstTime = seconds
                slowest = name
            }
            #expect(result.scannerSteps <= max(1, result.analysedUnits) * 256, Comment(rawValue: name))
            // The step bound above is what keeps the scan linear; the clock only catches a gross stall. Debug builds on
            // shared CI runners took 0.77 s and then 1.13 s for the same long CJK note that a local debug run finishes in
            // a tenth of that, so the clock allows for them. The release test below holds the real latency bar.
            // Only the time is skipped under a sanitizer, which slows the code several times over.
            if !Sanitizer.isActive { #expect(seconds < 3, Comment(rawValue: "\(name): \(seconds)s")) }
        }
        print(
            "WORK inputs=\(Self.inputs.count) worstMultiple=\(worstRatio) worstSeconds=\(worstTime) slowest=\(slowest)")
    }
}

extension ClipboardFormatWorkTests {
    @Test("Releaseでは各生成入力をウォームアップ後の最小時間で5ミリ秒以内に判定する")
    func releaseLatency() {
        #if !DEBUG
            var slowest = ""
            var worst = 0.0
            for (name, text) in Self.inputs {
                _ = ClipboardFormatDetector.detect(text)
                var best = Double.infinity
                for _ in 0..<15 {
                    let start = ContinuousClock.now
                    _ = ClipboardFormatDetector.detect(text)
                    let elapsed = start.duration(to: .now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    best = min(best, seconds)
                }
                if best > worst {
                    worst = best
                    slowest = name
                }
                #expect(best < 0.005, Comment(rawValue: "\(name): \(best)s"))
            }
            print("RELEASE_WORK inputs=\(Self.inputs.count) worstSeconds=\(worst) slowest=\(slowest)")
        #endif
    }
}
