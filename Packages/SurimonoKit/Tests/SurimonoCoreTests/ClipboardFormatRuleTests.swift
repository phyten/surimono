import Foundation
import Testing

@testable import SurimonoCore

struct ClipboardFormatRuleTests {
    private let document = ClipboardFormatAdversarialTests.markdown

    @Test("空文字と空白だけの入力はモードにかかわらず空として扱う")
    func blank() {
        for text in ["", " \t\r\n\u{000C}", String(repeating: " ", count: 40_000)] {
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
        #expect(ClipboardFormatDetector.detect(table, hints: .init(hasTabularData: true)).action == .open(.csv))
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
        for text in ["# Heading", document + "\nconst x = 1;", "Introduction\n\n" + document] {
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
    @Test("受理済み候補同士だけが競合するときReturnは最上位の形式を選ぶ")
    func competition() {
        let result = ClipboardFormatDetector.detect("* **First**\n* **Second**\n* **Third**")
        #expect(result.action == .ask(preferred: .markdown))
        #expect(result.reason == .competingFormats)
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
        #expect(!ClipboardFormatDetector.detect(String(repeating: " ", count: 40_000)).isTruncated)
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
        #expect(blank.reason == .blank)
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
    @Test("共通の構文検査はコメント終端と検査窓の末尾の記号も拒否する")
    func unsafeBoundary() {
        for suffix in ["*/", String(repeating: "a", count: 511) + ";" + "tail"] {
            #expect(ClipboardFormatDetector.detect(document + "\n" + suffix).action == .ask(preferred: .plainText))
        }
    }
}
