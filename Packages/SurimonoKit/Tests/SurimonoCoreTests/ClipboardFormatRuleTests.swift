import Foundation
import Testing

@testable import SurimonoCore

struct ClipboardFormatRuleTests {
    private let document = ClipboardFormatAdversarialTests.markdown

    @Test("空文字と空白だけの入力はモードにかかわらず空として扱う")
    func blank() {
        for text in ["", " \t\r\n\u{000C}", String(repeating: " ", count: 32_768)] {
            for mode in ClipboardFormatSettings.Mode.allCases {
                let result = ClipboardFormatDetector.detect(text, settings: .init(mode: mode, fixedKind: .html))
                #expect(result.action == .open(.plainText))
                #expect(result.reason == .blank)
            }
        }
    }

    @Test("UTF16単位の上限ちょうどは切断されず一単位超過は切断される")
    func units() {
        let text = document + String(repeating: " ", count: 32_768 - document.utf16.count - 1) + "x"
        let exact = ClipboardFormatDetector.detect(text)
        #expect(exact.analysedUnits == 32_768)
        #expect(!exact.isTruncated)
        #expect(ClipboardFormatDetector.detect(text + "x").isTruncated)
        #expect(!ClipboardFormatDetector.detect(text + " \r\n").isTruncated)
    }

    @Test("1500行まで同じ窓に入り次の非空行は切断になる")
    func lines() {
        let text = "# Guide\n" + String(repeating: "body\n", count: 1_498) + "- **end**"
        let result = ClipboardFormatDetector.detect(text)
        #expect(result.analysedLines == 1_500)
        #expect(!result.isTruncated)
        #expect(ClipboardFormatDetector.detect(text + "\nx").isTruncated)
    }

    @Test("上限をまたぐサロゲートペアは途中で切らない")
    func surrogate() {
        let result = ClipboardFormatDetector.detect(String(repeating: "x", count: 32_767) + "😀")
        #expect(result.analysedUnits == 32_767)
        #expect(result.isTruncated)
        #expect(result.reason != .damagedText)
    }

    @Test("最初の文字の行頭を残して解析を始める")
    func leading() {
        let result = ClipboardFormatDetector.detect("\n\r\n  " + document)
        #expect(result.analysedUnits == document.utf16.count + 2)
        #expect(result.analysedLines == 4)
    }

    @Test("切断文書は自動整形せず表のヒントだけが例外になる")
    func truncation() {
        let table = "name,count\n" + String(repeating: "a,1\n", count: 2_000)
        #expect(ClipboardFormatDetector.detect(table).action == .ask(preferred: .plainText))
        #expect(
            ClipboardFormatDetector.detect(
                table.replacingOccurrences(of: ",", with: "\t"), hints: .init(hasTabularData: true)
            ).action == .open(.csv))
        #expect(
            ClipboardFormatDetector.detect(table, settings: .init(mode: .plainTextWhenUnsure)).action
                == .open(.plainText))
    }

    @Test("禁止文字はコード内でも空白の前後でも自動整形を止める")
    func damaged() {
        let forbidden = [UInt32(0xFFFD), 127] + Array(UInt32(0)...31).filter { ![9, 10, 12, 13].contains($0) }
        for value in forbidden {
            let char = String(Unicode.Scalar(value)!)
            for text in [char + "\n" + document, document + char, document + "\n```\n" + char + "\n```"] {
                let result = ClipboardFormatDetector.detect(text)
                #expect(result.action == .ask(preferred: .plainText), Comment(rawValue: String(value)))
                #expect(result.reason == .damagedText)
            }
        }
    }

    @Test("確認モードと固定モードは非空の文字列に適用される")
    func modes() {
        #expect(ClipboardFormatDetector.detect(document).action == .open(.markdown))
        #expect(
            ClipboardFormatDetector.detect("hello", settings: .init(mode: .alwaysAsk)).action
                == .ask(preferred: .plainText))
        let fixed = ClipboardFormatDetector.detect("\u{0000}", settings: .init(mode: .fixed, fixedKind: .html))
        #expect(fixed.action == .open(.html))
        #expect(fixed.reason == .fixed)
        #expect(
            ClipboardFormatDetector.detect("# Heading", settings: .init(mode: .plainTextWhenUnsure)).action
                == .open(.plainText))
    }

    @Test("自動許可から外した形式も選択肢には残す")
    func disabled() {
        var settings = ClipboardFormatSettings.standard
        settings.automaticKinds.remove(.markdown)
        let result = ClipboardFormatDetector.detect(document, settings: settings)
        #expect(result.action == .open(.plainText))
        #expect(result.reason == .ordinaryText)
        #expect(result.choices.contains { $0.kind == .markdown })
        #expect(result.choices.count == ClipboardTextKind.allCases.count)
    }

    @Test("不足や拒否による確認はReturnでプレーンテキストを選ぶ")
    func preference() {
        for text in ["# Heading", document + "\nconst x = 1;"] {
            #expect(ClipboardFormatDetector.detect(text).action == .ask(preferred: .plainText))
        }
    }

    @Test("URLのヒントがあっても不正なURLを受理しない")
    func urlHint() {
        let hints = ClipboardFormatHints(hasMatchingURL: true)
        #expect(ClipboardFormatDetector.detect(" https://example.org/ \n", hints: hints).action == .open(.url))
        for suffix in ["%", "%GG", " x", "\u{034F}", "\u{E0100}", "\u{0001}"] {
            #expect(ClipboardFormatDetector.detect("https://example.org/" + suffix, hints: hints).action != .open(.url))
        }
    }

    @Test("設定はJSONを往復して保持される")
    func roundTrip() throws {
        let settings = ClipboardFormatSettings(
            mode: .fixed, carefulness: .careful, automaticKinds: [.csv, .url], fixedKind: .org)
        #expect(
            try JSONDecoder().decode(ClipboardFormatSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test("将来の設定値や不正な型を含むJSONオブジェクトも既定値へ戻して読める")
    func tolerant() throws {
        for json in [
            "{}", #"{"automaticKinds":["future"]}"#,
            #"{"mode":"future","carefulness":42,"fixedKind":{},"automaticKinds":null}"#,
        ] {
            #expect(try JSONDecoder().decode(ClipboardFormatSettings.self, from: Data(json.utf8)) == .standard)
        }
        let settings = try JSONDecoder().decode(
            ClipboardFormatSettings.self, from: Data(#"{"automaticKinds":["csv","future"]}"#.utf8))
        #expect(settings.automaticKinds == [.csv])
    }

    @Test("慎重さは根拠の要件だけを変え禁止条件は弱めない")
    func levels() {
        for level in ClipboardFormatSettings.Carefulness.allCases {
            let settings = ClipboardFormatSettings(carefulness: level)
            #expect(
                ClipboardFormatDetector.detect(document + "\n{{ name }}", settings: settings).action
                    == .ask(preferred: .plainText))
        }
    }

    @Test("ヒアドキュメントの全表記は文書の自動確定を止める")
    func heredoc() {
        for opener in ["<<EOF", "<<-EOF", "<<~EOF", "<<'EOF'", "<<\"EOF\"", "<<\\EOF"] {
            #expect(
                ClipboardFormatDetector.detect(document + "\ncat " + opener + " >out\ntext\nEOF").action
                    == .ask(preferred: .plainText))
        }
    }
}

extension ClipboardFormatRuleTests {
    @Test("強調を持つ星の行はMarkdownとOrgの曖昧さを残す")
    func competition() {
        let result = ClipboardFormatDetector.detect("* **First**\n* **Second**\n* **Third**")
        #expect(result.action == .ask(preferred: .plainText))
        #expect(result.reason == .conflictingSyntax)
    }

    @Test("コメントと閉じた領域の前後にあるコードを見落とさない")
    func partialLines() {
        let doc = ClipboardFormatAdversarialTests.markdown
        for text in [
            doc + "\nconst x = 1; <!-- comment -->",
            doc + "\n<!-- comment --> const x = 1;",
            doc + "\n" + String(repeating: "ordinary words ", count: 100) + "const x = 1;",
            ClipboardFormatAdversarialTests.latex.replacingOccurrences(of: "Hello", with: "\\verb|<!--| const x = 1;"),
            ClipboardFormatAdversarialTests.org + "\n#+begin_quote\nconst x = 1;\n#+end_quote",
        ] { #expect(ClipboardFormatDetector.detect(text).action == .ask(preferred: .plainText)) }
    }

    @Test("Markdown内のHTMLも閉鎖とテンプレートを検証する")
    func embeddedHTML() {
        for fragment in [
            "<script>const x = 1;", "<style>x</script>", "<UI />", "<UI.Card />", "<div v-if = \"ready\">a</div>",
            "<div>{user.name}</div>", "<script>const x = '{{ user }}';</script>",
        ] {
            #expect(
                ClipboardFormatDetector.detect(document + "\n\n" + fragment).action == .ask(preferred: .plainText),
                Comment(rawValue: fragment))
        }
        #expect(
            ClipboardFormatDetector.detect(document + "\n\n<script>const x = 1;</script>").action == .open(.markdown))
    }

    @Test("フェンスは文字と長さが一致する終端までを所有する")
    func fenceClosure() {
        for text in ["````swift\nlet x = 1\n```", "~~~swift\nlet x = 1\n```"] {
            #expect(ClipboardFormatDetector.detect(text).action == .ask(preferred: .plainText))
        }
        #expect(ClipboardFormatDetector.detect("~~~swift\nlet x = 1\n~~~~").action == .open(.markdown))
    }

    @Test("Markdown表の区切りと全行の列数を検証する")
    func markdownTable() {
        for table in ["| a | b |\n| --- | : |\n| 1 | 2 |", "| a | b |\n| --- | --- |\n| 1 | 2 | 3 |"] {
            #expect(ClipboardFormatDetector.detect(table).action != .open(.markdown))
        }
        #expect(ClipboardFormatDetector.detect("| a | b |\n| --- | :---: |\n| 1 | 2 |").action == .open(.markdown))
    }

    @Test("表の中のコードは表が所有する")
    func tableOwnsSyntax() {
        for text in [
            "name,code,count\na,{{ value }},1\nb,{{ value }},2",
            "| name | code |\n| --- | --- |\n| a | {{ value }} |\n| b | const x = 1; |",
        ] {
            let result = ClipboardFormatDetector.detect(text)
            #expect(result.action == .open(.csv) || result.action == .open(.markdown))
        }
    }

    @Test("一つのURLには上限とホスト構文を適用する")
    func urlBound() {
        let prefix = "https://example.org/"
        #expect(
            ClipboardFormatDetector.detect(prefix + String(repeating: "a", count: 8_192 - prefix.utf16.count)).action
                == .open(.url))
        #expect(
            ClipboardFormatDetector.detect(prefix + String(repeating: "a", count: 8_193 - prefix.utf16.count)).action
                != .open(.url))
        #expect(ClipboardFormatDetector.detect("https://[2001:db8::1]/").action == .open(.url))
        #expect(ClipboardFormatDetector.detect("https://[no::hex]/").action != .open(.url))
    }
}

extension ClipboardFormatRuleTests {
    @Test("競合以外にも禁止理由があればReturnは形式を選ばない")
    func disabledCompetition() {
        let text = "* **First**\n* **Second**\n* **Third**"
        var settings = ClipboardFormatSettings.standard
        settings.automaticKinds.remove(.markdown)
        #expect(ClipboardFormatDetector.detect(text, settings: settings).action == .ask(preferred: .plainText))
        #expect(ClipboardFormatDetector.detect(text + "\u{0000}").action == .ask(preferred: .plainText))
    }

    @Test("同じ先頭を構造とみなして拒否した候補は別形式の自動確定を止める")
    func refusedCompetitor() {
        let text = "# **Guide**,bad\"quote\n- [one](https://example.org),1\n- **two**,2"
        #expect(ClipboardFormatDetector.detect(text).action == .ask(preferred: .plainText))
    }

    @Test("HTMLとDOCTYPEの直後にある裸の散文を文書の開始にしない")
    func proseAfterRoot() {
        for text in [
            "<html>Explanation\n<body><p>Hello</p></body></html>",
            "<!doctype html>Explanation\n<html><body><p>Hello</p></body></html>",
        ] {
            #expect(ClipboardFormatDetector.detect(text).action == .ask(preferred: .plainText))
        }
    }

    @Test("巨大な空白だけの接尾部を切断とはしない")
    func whitespaceTail() {
        #expect(ClipboardFormatDetector.detect(String(repeating: " ", count: 40_000)).isTruncated)
        #expect(!ClipboardFormatDetector.detect(document + String(repeating: " ", count: 40_000)).isTruncated)
    }
}

extension ClipboardFormatRuleTests {
    @Test("LaTeXの数式も開いた区切りと同じもので閉じる必要がある")
    func latexMathClosure() {
        for body in ["$x", "$$x", "$$x$", "\\[x"] {
            let text = ClipboardFormatAdversarialTests.latex.replacingOccurrences(of: "Hello", with: body)
            #expect(ClipboardFormatDetector.detect(text).action == .ask(preferred: .plainText))
        }
        let valid = ClipboardFormatAdversarialTests.latex.replacingOccurrences(of: "Hello", with: "$$x = 1$$")
        #expect(ClipboardFormatDetector.detect(valid).action == .open(.latex))
    }
}

extension ClipboardFormatRuleTests {
    @Test("常に確認でも自動確定できた形式をReturnで選ぶ")
    func confirmationPreference() {
        let texts = [
            document, ClipboardFormatAdversarialTests.latex, ClipboardFormatAdversarialTests.org,
            "<div><p>Hello</p></div>", "name,count\na,1\nb,2", "https://example.org/",
        ]
        for text in texts {
            let normal = ClipboardFormatDetector.detect(text)
            let asked = ClipboardFormatDetector.detect(text, settings: .init(mode: .alwaysAsk))
            if case .open(let kind) = normal.action {
                #expect(asked.action == .ask(preferred: kind))
            } else {
                #expect(asked.action == normal.action)
            }
            #expect(asked.reason == .alwaysAsk)
        }
        for text in ["# Heading", document + "\nconst x = 1;", "* **First**\n* **Second**\n* **Third**"] {
            #expect(
                ClipboardFormatDetector.detect(text, settings: .init(mode: .alwaysAsk)).action
                    == ClipboardFormatDetector.detect(text).action)
        }
    }

    @Test("外した形式は構造不足や破損や切断でも確認の理由にならない")
    func absentKinds() {
        for text in [document, "# Heading", document + "\u{0000}", document + String(repeating: "x", count: 40_000)] {
            let result = ClipboardFormatDetector.detect(text, settings: .init(automaticKinds: []))
            #expect(result.action == .open(.plainText))
            #expect(result.reason == .ordinaryText)
            #expect(result.choices.first?.kind == .plainText)
            #expect(result.choices.contains { $0.kind == .markdown && !$0.evidence.isEmpty })
        }
    }

    @Test("外した競合候補や先頭を拒否する候補は残った形式を妨げない")
    func absentCompetition() {
        let competing = "* **First**\n* **Second**\n* **Third**"
        let refused = "# **Guide**,bad\"quote\n- [one](https://example.org),1\n- **two**,2"
        for (text, disabled) in [(competing, ClipboardTextKind.org), (refused, .csv)] {
            var settings = ClipboardFormatSettings.standard
            settings.automaticKinds.remove(disabled)
            let result = ClipboardFormatDetector.detect(text, settings: settings)
            #expect(result.action == .open(.markdown))
            #expect(result.choices.last?.kind == disabled)
            #expect(result.choices.last?.evidence.isEmpty == false)
        }
    }

    @Test("固定形式のURLは初期化と復号でプレーンテキストに戻す")
    func fixedURL() throws {
        let initialized = ClipboardFormatSettings(mode: .fixed, fixedKind: .url)
        let decoded = try JSONDecoder().decode(
            ClipboardFormatSettings.self,
            from: Data(#"{"mode":"fixed","fixedKind":"url"}"#.utf8))
        for settings in [initialized, decoded] {
            #expect(settings.fixedKind == .plainText)
            #expect(
                ClipboardFormatDetector.detect("https://example.org/", settings: settings).action == .open(.plainText))
        }
    }

    @Test("上限まで空白の接尾部を調べても未確定なら切断とする")
    func boundedWhitespaceTail() {
        let huge = String(repeating: " ", count: 50_000_000)
        let blank = ClipboardFormatDetector.detect(huge)
        #expect(blank.reason == .truncated)
        #expect(blank.analysedUnits == 0)
        #expect(blank.isTruncated)
        #expect(ClipboardFormatDetector.detect(document + huge).isTruncated)
    }
}

extension ClipboardFormatRuleTests {
    @Test("構造の事前走査でも空のリスト項目と空白だけのフェンス本文を区別する")
    func preflightBoundaries() {
        #expect(ClipboardFormatDetector.detect("+").action == .ask(preferred: .plainText))
        for fence in ["```", "~~~"] {
            #expect(
                ClipboardFormatDetector.detect(fence + "\n\u{200B}\n" + fence).action == .ask(preferred: .plainText))
        }
        #expect(ClipboardFormatDetector.detect("``` x `").action == .open(.plainText))
        #expect(ClipboardFormatDetector.detect("<https://a.org> <https://b.org>").action == .ask(preferred: .plainText))
    }
}

extension ClipboardFormatRuleTests {
    @Test("共通の構文検査はコメント終端と長い行の宣言も拒否する")
    func unsafeBoundary() {
        for suffix in ["*/", String(repeating: "a ", count: 511) + "const x = 1;"] {
            #expect(ClipboardFormatDetector.detect(document + "\n" + suffix).action == .ask(preferred: .plainText))
        }
    }
}

extension ClipboardFormatRuleTests {
    @Test("拒否しても見出しやリストや表を観測した候補は確認に残る")
    func retainedSyntax() {
        for text in [
            "# 予定\n朝は会議。\n# 午後\n資料を書く。",
            "# 予定\n1. 会議\n# 午後\n2. **印刷**",
            "# Notes\nfirst;\n- one\n- **two**",
            "Region,Avg. Temp,Est. Revenue\nTokyo,15,1200\nOsaka,16,800",
            "id,name,\n1,Alice,\n2,Bob,",
            "\\tableofcontents\n\\newpage\n# Title\n- one\n- **two**",
        ] {
            let result = ClipboardFormatDetector.detect(text)
            #expect(result.action != .open(.plainText), Comment(rawValue: text))
            #expect(result.action != .open(.latex), Comment(rawValue: text))
        }
        var work = ClipboardWork()
        let candidate = ClipboardScanners.markdown(
            ClipboardWindow("* " + String(repeating: "[", count: 80)), level: .standard, work: &work)
        #expect(candidate.structures > 0)
        #expect(candidate.ownsStart)
        #expect(!candidate.accepted)
    }

    @Test("日付や少数のログやOrgの深い見出しでは文書を消さない")
    func envelopeRequiresCorroboration() {
        for text in [
            "2026-11-16 10:00 Meeting\n\n" + document,
            "# Report\n\n[INFO] ready\n[ERROR] retry\n\n- **first**\n- second",
            "*** TODO Write\nSCHEDULED: <2026-11-20 Fri>\n*** DONE Read",
        ] { #expect(ClipboardFormatDetector.detect(text).action != .open(.plainText)) }
        #expect(ClipboardFormatDetector.detect("[INFO] one\n[INFO] two\n[ERROR] three").action == .open(.plainText))
        #expect(
            ClipboardFormatDetector.detect("--- a/file\n+++ b/file\n@@ -1 +1 @@\n- old\n+ new").action
                == .open(.plainText))
    }

    @Test("先頭空白の上限では空と断定せずモードに従う")
    func leadingWhitespaceBound() {
        let text = String(repeating: " ", count: 40_000) + document
        for mode in ClipboardFormatSettings.Mode.allCases {
            let result = ClipboardFormatDetector.detect(text, settings: .init(mode: mode, fixedKind: .html))
            #expect(result.isTruncated)
            #expect(result.reason != .blank)
            switch mode {
            case .fixed: #expect(result.action == .open(.html))
            case .plainTextWhenUnsure: #expect(result.action == .open(.plainText))
            case .askWhenUnsure, .alwaysAsk: #expect(result.action == .ask(preferred: .plainText))
            }
        }
    }

    @Test("先頭の散文だけが障害なら確認のReturnはMarkdownになる")
    func prosePreference() {
        let text = "Here is the answer.\n\n" + document
        for mode in [ClipboardFormatSettings.Mode.askWhenUnsure, .alwaysAsk] {
            #expect(
                ClipboardFormatDetector.detect(text, settings: .init(mode: mode)).action == .ask(preferred: .markdown))
        }
        for suffix in ["\nconst x = 1;", "\u{0000}", String(repeating: "x", count: 40_000)] {
            #expect(ClipboardFormatDetector.detect(text + suffix).action == .ask(preferred: .plainText))
        }
    }

    @Test("構造を見ていない形式の確信度はゼロである")
    func confidenceRequiresStructure() {
        var empty = ClipboardCandidate(kind: .markdown)
        empty.sufficient = true
        #expect(empty.choice.confidence == 0)
        for text in ["plain words", "[INFO] one\n[INFO] two\n[ERROR] three", "# Title\nX=1\nY=2"] {
            let result = ClipboardFormatDetector.detect(text)
            if result.action == .open(.plainText) {
                #expect(result.choices.filter { $0.kind != .plainText }.allSatisfy { $0.confidence == 0 })
            }
        }
    }

    @Test("普通の散文の語や句読点だけではコードと断定しない")
    func proseIsNotCode() {
        for line in [
            "from the survey", "using the ruler", "return to the office", "let us begin", "if (possible), print it",
            "a sentence;", "a brace {", "\"a quotation\"", "E = mc^2", "n = 100", "the function render()",
        ] {
            #expect(
                ClipboardFormatDetector.detect(document + "\n\n" + line).action == .open(.markdown),
                Comment(rawValue: line))
        }
    }

    @Test("タブ区切りを桁区切りのコンマより優先し表のヒントは競合を解消する")
    func tabRecords() {
        for hint in [false, true] {
            let result = ClipboardFormatDetector.detect(
                "Name\tAmount\nA\t1,200\nB\t3,400",
                hints: .init(hasTabularData: hint))
            #expect(result.tableDelimiter == "\t")
            #expect(result.action == .open(.csv))
        }
        for header in ["\tQ1\tQ2", "#\tName\tScore"] {
            #expect(
                ClipboardFormatDetector.detect(
                    header + "\n1\tA\t10\n2\tB\t20",
                    hints: .init(hasTabularData: true)
                ).action == .open(.csv))
        }
    }
}

extension ClipboardFormatRuleTests {
    @Test("見出しと散文だけやYAMLにもなる箇条書きはどの慎重さでも自動整形しない")
    func headingsNeedDistinctiveStructure() {
        for level in ClipboardFormatSettings.Carefulness.allCases {
            for text in [
                "# First\nBody.\n## Second\nMore.\n### Third\nEnd.",
                "# Fruits\n- apple\n- banana\n# Vegetables\n- carrot\n- onion",
                "---\n# First document\nkind: One\nname: first\n---\n# Second document\nkind: Two\nname: second",
                "## Input\nx <- read.csv(\"x.csv\")\n## Output\nplot(x)",
            ] {
                #expect(
                    ClipboardFormatDetector.detect(text, settings: .init(carefulness: level)).action != .open(.markdown)
                )
            }
        }
    }

    @Test("LaTeX宣言だけでは刷れる本文とみなさず括弧なしのマクロ名は受理する")
    func latexDeclarations() {
        for level in ClipboardFormatSettings.Carefulness.allCases {
            for text in [
                "\\documentclass{article}\n\\usepackage{amsmath}",
                "\\documentclass{article}\n\\def\\foo#1{#1}",
                "\\documentclass{article}\n\\hypersetup{colorlinks=true}\n\\geometry{margin=2cm}",
                "\\newcommand\\R{\\mathbb{R}}\n\\newcommand{\\N}{\\mathbb{N}}",
                "\\documentclass{article}\n\\begin{document}\n\\end{document}",
            ] {
                #expect(
                    ClipboardFormatDetector.detect(text, settings: .init(carefulness: level)).action != .open(.latex))
            }
        }
        let text = "\\documentclass{article}\n\\newcommand\\R{\\mathbb{R}}\n\\begin{document}\nHello.\n\\end{document}"
        #expect(ClipboardFormatDetector.detect(text).action == .open(.latex))
    }

    @Test("HTMLのコード領域と通常要素と省略可能な終端を受理する")
    func htmlGrammar() {
        for fragment in [
            "<p><ruby>漢<rt>かん</ruby><abbr title='word'>W</abbr><cite>Book</cite><q>Quote</q>",
            "<table><thead><tr><th>A<th>B<tbody><tr><td>1<td>2</table>",
            "<dl><dt>A<dd>B<dt>C<dd>D</dl>",
            "<select><optgroup label='A'><option>One<option>Two</select>",
            "<custom-card><p>Hello</p></custom-card>",
            "<pre><code>if (x) { {{ value }}; @Model.X; }</code></pre>",
            "<p>The opening brace is { and the closing brace is }.</p>",
        ] {
            #expect(
                ClipboardFormatDetector.detect("<html><body>" + fragment + "</body></html>").action == .open(.html),
                Comment(rawValue: fragment))
        }
        for fragment in [
            "<button onClick={() => save()}>Save</button>", "<img src={logo}>",
            "<p *ngFor='let x of xs' (click)='go()' [title]='x'>Text</p>",
            "@if (ready)<p>Yes</p>@endif", "<p>@Model.Name</p>", "<p>{user}</p>",
        ] {
            #expect(
                ClipboardFormatDetector.detect("<html><body>" + fragment + "</body></html>").action != .open(.html),
                Comment(rawValue: fragment))
        }
    }

    @Test("大量の平坦な強調やsnake_caseは入れ子の深さに数えない")
    func flatDelimiters() {
        let text =
            "# Glossary\n\n" + (0..<120).map { "- **Term\($0)**: some_snake_case_name_\($0) means a word.\n" }.joined()
        #expect(ClipboardFormatDetector.detect(text).action == .open(.markdown))
        let links = "# References\n\n" + String(repeating: "<https://example.org> ", count: 70)
        #expect(ClipboardFormatDetector.detect(links).action == .open(.markdown))
    }

    @Test("配列リテラルや列数の崩れたタブをコンマ表に読み替えない")
    func tableLiterals() {
        for text in ["[1,2,3]\n[4,5,6]\n[7,8,9]", "1,200\t3,400\n5,600\t7,800\t9\n9,100\t2,300"] {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.csv))
        }
        let hinted = ClipboardFormatDetector.detect("name,count\na,1\nb,2", hints: .init(hasTabularData: true))
        #expect(hinted.tableDelimiter == "\t")
        #expect(hinted.action == .ask(preferred: .plainText))
    }
}
