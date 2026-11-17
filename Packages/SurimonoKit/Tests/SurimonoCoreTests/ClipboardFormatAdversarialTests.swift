import Testing

@testable import SurimonoCore

struct ClipboardFormatAdversarialTests {
    static let markdown = "# Guide\n\n- **First**\n- [Second](https://example.org)"
    static let org = "#+TITLE: Guide\n* Plan\n** Tasks\nBody"
    static let html = "<html>\n<body><h1>Guide</h1><p>Body</p></body>\n</html>"
    static let latex = "\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}"

    static var wrongfulOpens: [(String, String)] {
        let rows = "name,note,count\nAlice,{{ name }},1\nBob,{{ name }},2\nCarol,{{ name }},3"
        return [
            ("A10", org + "\n#+begin_src html\n" + html + "\n#+end_example"),
            ("A72", org + "\n#+begin_srcx html\n" + html + "\n#+end_src"),
            ("A11", "<html>\n<body>\n<p>Hello</p>\n<script>\nconst x = 1;\n</body>\n</html>"),
            ("A12", "<html>\n<body>\n<p>Hello</p>\n<style>\np { color: red; }\n</body>\n</html>"),
            ("A13", "<html>\n<body>\n<script>\n</style>\n<p>Missing script close</p>\n</body>\n</html>"),
            ("A14", "<html>\n<body>\n<style>\n</script>\n<p>Missing style close</p>\n</body>\n</html>"),
            ("A71", latex.replacingOccurrences(of: "Hello", with: "\\begin{verbatim}\n\\end{minted}\nHello")),
            ("A16", "const x = 1; <!-- comment\n-->\n" + org),
            ("B01", "const x = \"<!--\";\n-->\n" + org),
            ("A22", "<html>\n<body>\n<script>\nconst x = \"{{ secret }}\";\n</script>\n</body>\n</html>"),
            ("A23", "<html>\n<style>\np { color: {{ color }}; }\n</style>\n<body><p>Hello</p></body>\n</html>"),
            ("A25", "<html>\n<body>{{ " + String(repeating: "user + ", count: 35) + "suffix }}</body>\n</html>"),
            ("A26", "<html>\n<body><UI /></body>\n</html>"),
            ("A27", "<html>\n<body><UI.Card /></body>\n</html>"),
            ("A28", "<html>\n<body><p>{user.name}</p></body>\n</html>"),
            ("A29", "<html>\n<body>\n<div\n v-if\n = \"ready\">\n<p>Hello</p>\n</div>\n</body>\n</html>"),
            (
                "B03",
                "<html>\n<body>\n<h1>Title</h1>\n<p>Read me</p>\n<p>{{\n user.name\n}}</p>\n<p>Footer</p>\n</body>\n</html>"
            ),
            ("C01", "# **Guide**\n\n" + rows),
            ("C02", "# [Guide](https://example.org)\n\n" + rows),
            ("A66", "\u{000C}\n" + html),
            ("B06", "\u{000B}\n" + html),
            (
                "B07",
                "<html><body><p>"
                    + String(repeating: "x", count: 32768 - "<html><body><p></p></body></html>".utf16.count)
                    + "</p></body></html>\u{000C}"
            ),
            ("B08", "\u{000C}\nhttps://example.org/"),
            ("B02", String(repeating: ": comment\n", count: 400) + "Copy these commands literally.\n" + org),
            ("A54", "-1,234,567\n-2,345,678\n-3,456,789"),
            ("A55", "1,234,567.89\n2,345,678.90\n3,456,789.01"),
            ("A56", "$1,234,567\n$2,345,678\n$3,456,789"),
            ("A57", "1,23,456\n2,34,567\n3,45,678"),
            ("Prices", "Prices\nA;1,20;0,30\nB;2,40;0,50\nC;3,40;0,60\nD;4,40;0,60\nE;5,40;0,60"),
        ]
    }

    @Test("v4の誤自動判定29件は新仕様が許可したFFの3件を除き自動整形しない")
    func wrongful() {
        #expect(Self.wrongfulOpens.count == 29)
        for (id, text) in Self.wrongfulOpens {
            let result = ClipboardFormatDetector.detect(text)
            if ["A66", "B07", "B08"].contains(id) {
                // The brief explicitly permits FF, superseding the older review's blanket control veto.
                #expect(result.action == .open(id == "B08" ? .url : .html), Comment(rawValue: id))
            } else if ["A16", "B01"].contains(id) {
                // A declaration at the start owns the later embedded document in round 4.
                #expect(result.action == .open(.plainText), Comment(rawValue: id))
            } else {
                #expect(result.action == .ask(preferred: .plainText), Comment(rawValue: id))
            }
        }
    }

    static var preservedDocuments: [String] {
        [
            markdown + "\n\nconst x = 1;",
            org + "\n\nconst x = 1;",
            latex + "\nconst x = 1;",
            markdown + "\n\nReplace {{ name }} with the recipient.",
            "# Guide\n\n> ```html\n> <div>{{ name }}</div>\n> ```\n\n- **Install**\n- [Help](https://example.org)",
            "# Guide\n\n- Example:\n\n    ```html\n    <div>{{ name }}</div>\n    ```\n\n- **Install**\n- [Help](https://example.org)",
            markdown + "\n\n`<?= $name ?>`",
            markdown + "\n\n`<%= name %>`",
        ]
    }

    @Test("レビューに生成式が載った黙示的プレーン化8件は文書の候補を残す")
    func silentPlainText() {
        for text in Self.preservedDocuments {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.plainText))
        }
    }

    @Test("通常文書のコードとコメントは外側の文法で保護する")
    func ordinary() {
        let cases: [(String, ClipboardTextKind)] = [
            (Self.latex.replacingOccurrences(of: "Hello", with: "\\verb|<!--|\nHello"), .latex),
            (
                "# Guide\n\nThe token `<!--` starts a comment.\n\n- **First**\n- [Second](https://example.org)",
                .markdown
            ),
            ("% Header\n% Author\n% Date\n% Copyright\n% License\n" + Self.latex, .latex),
            ("% Header\n% Author\n" + Self.latex, .latex),
            ("[![build](badge.svg)](https://example.org)\n\n" + Self.markdown, .markdown),
            ("<article>\n<h1>Guide</h1>\n<p>Read this.</p>\n</article>", .html),
            ("Guide\n=====\n\n- **First**\n- [Second](https://example.org)", .markdown),
            ("a\tb\tc\nx\t\tz\n\nq\tr\t", .csv),
        ]
        for (text, kind) in cases {
            #expect(
                ClipboardFormatDetector.detect(text).action == .open(kind),
                Comment(rawValue: text.prefix(60).description))
        }
        for text in Self.preservedDocuments.suffix(4) {
            #expect(ClipboardFormatDetector.detect(text).action == .open(.markdown))
        }
    }

    @Test("文書前の散文と小さい断片は確認する")
    func introductoryProse() {
        for text in [
            "Guide\n\n" + Self.markdown, "A note.\n\n" + Self.markdown,
            "Hello!\n\n" + Self.markdown, "A note.\n\n" + Self.org,
            "2026-11-16\n\n" + Self.markdown, "<p>Hello</p>",
            "\ta\tb\n\tx\ty\n\tq\tr", "Sales\na,b,c\nx,1,2\ny,3,4",
        ] {
            let preferred: ClipboardTextKind = text.hasSuffix(Self.markdown) ? .markdown : .plainText
            #expect(ClipboardFormatDetector.detect(text).action == .ask(preferred: preferred))
        }
    }
}

extension ClipboardFormatAdversarialTests {
    static let commentedSentenceFiles: [(String, String)] = [
        ("ライセンス付き依存一覧", "# License\nPermission is granted to use this software.\n\n## Dependencies\nflask\nrequests\n"),
        (
            "SPDX付きシェル",
            "# License\nPermission is granted to use this software.\nSPDX-License-Identifier: MIT\n\n## Run\necho done\n"
        ),
        (
            "POの単数メッセージ",
            "# Messages\nmsgid \"Please print this document.\"\n\n## Translation\nmsgstr \"この文書を印刷してください。\"\n"
        ),
        (
            "POの複数メッセージ",
            "# Messages\nThese are the translated messages.\nmsgid_plural \"Please print these documents.\"\n\n## Translation\nmsgstr[0] \"印刷してください。\"\n"
        ),
        (
            "Makefileのhelp",
            "# Help\nThis target prints the available commands.\nhelp:\n\t@echo 'Please run make build.'\n\n## Build\nbuild:\n\tswift build\n"
        ),
        (
            "Makefileの変数",
            "# Help\nThese targets build the application.\nHELP_TEXT := Please run make build.\n\n## Build\nall: build\n"
        ),
        (
            "SQLのコメントと文",
            "# Migration\n-- This table stores the report.\nCREATE TABLE reports (id INTEGER);\n\n## Seed\nINSERT INTO reports VALUES (1);\n"
        ),
        (
            "SQLの設定値",
            "# Session\nThis session uses the report database.\nSET application_name = 'This is a report.';\n\n## Query\nSELECT 1;\n"
        ),
        (
            "DockerfileのLABEL",
            "# Image\nThis image contains the report service.\n\n## Metadata\nLABEL description=\"This is a report service.\"\n"
        ),
        ("Dockerfileの継続行", "# Image\nFROM alpine\n\n## Description\nLABEL description=\"This is a small image.\"\n"),
        (
            "Pythonのdocstring",
            "# Module\n\"\"\"This module prints the daily report.\"\"\"\n\n## Run\nprint('This is a complete sentence.')\n"
        ),
        (
            "Pythonの複数行docstring",
            "# Module\n\"\"\"\nThis module prints the daily report.\n\n## Details\nThese are the implementation notes.\n\"\"\"\n"
        ),
        (
            "番号付き平文README",
            "# 1 Setup\nThis guide describes the installation process.\npython installer.py\n\n# 2 Usage\nRun the application after installation.\n"
        ),
        (
            "版番号を残す変更履歴",
            "# Changes\nThis release improves the printing behavior.\nv1.2.3\n\n## Fixes\nAll known crashes are now fixed.\n"
        ),
        (
            "日時を残す変更履歴",
            "# Changes\nThis release improves the printing behavior.\n2026-11-16\n\n## Fixes\nThe paper size is now correct.\n"
        ),
        (
            "ignoreの説明文とパターン",
            "# Generated\nThese files are generated during builds.\n*.generated.swift\n\n## Local\nThese files contain local settings.\n.env\n"
        ),
        (
            "hostsの説明文とIP",
            "# Loopback\nThis name resolves to the local machine.\n127.0.0.1 localhost\n\n## Printer\n192.168.0.2 printer\n"
        ),
        (
            "cronの説明文と時刻",
            "# Reports\nThis job prints the daily report.\n0 9 * * MON /usr/bin/report\n\n## Cleanup\n0 3 * * SUN /usr/bin/clean\n"
        ),
        ("INIの説明文と節", "# Settings\nThese settings control the print service.\n[printer]\n\n## Paper\nsize = A4\n"),
        ("YAMLの文章値", "# Service\ndescription: This service prints the daily report.\n\n## Paper\nsize: A4\n"),
        (
            "環境設定の文章値",
            "# Service\nThese settings control the print service.\nDESCRIPTION=This is a print service.\n\n## Port\nPORT=8080\n"
        ),
        (
            "シェルのprintf",
            "# Message\nprintf 'Please print this report.'\n\n## Finish\nprintf 'The job is now complete.'\n"
        ),
        ("シェルのecho", "# Message\necho 'Please print this report.'\n\n## Finish\necho 'The job is now complete.'\n"),
        (
            "Rのコメントと代入",
            "# Analysis\nThese results describe the current experiment.\nx <- read.csv('results.csv')\n\n## Plot\nplot(x)\n"
        ),
        (
            "SQLのコメントだけ",
            "# Migration\n-- This table stores the report.\n\n## Details\n-- These records contain the daily totals.\n"
        ),
        (
            "フラグ付きPython実行",
            "# Notes\n\nThis is a complete sentence.\n\n## Run\n\npython -c \"print('This is a complete sentence.')\"\n"
        ),
    ]

    @Test("文に見える本文を持つコメント付きファイル26件を自動整形しない")
    func commentedSentences() {
        #expect(Self.commentedSentenceFiles.count >= 20)
        for (name, text) in Self.commentedSentenceFiles {
            for level in ClipboardFormatSettings.Carefulness.allCases {
                let action = ClipboardFormatDetector.detect(text, settings: .init(carefulness: level)).action
                switch action {
                case .ask, .open(.plainText): break
                default: Issue.record(Comment(rawValue: "\(name) / \(level): \(action)"))
                }
            }
        }
    }
}
