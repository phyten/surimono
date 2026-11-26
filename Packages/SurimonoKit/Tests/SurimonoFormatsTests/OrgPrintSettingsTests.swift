import Foundation
import Testing

@testable import SurimonoFormats

struct OrgPrintSettingsTests {
    @Test(
        "非表示の予定・作業時間・優先度・進捗・日時もタスクと日時の群を開く",
        arguments: [
            "#+DATE: <2026-11-23 Mon>", "<2026-11-23 Mon>", "[2026-11-23 Mon]", "* [#B] A", "* A [1/2]", "- A [50%]",
            "* A\nSCHEDULED: <2026-11-23 Mon>", "* A\nDEADLINE: <2026-11-23 Mon>", "* A\nCLOSED: [2026-11-23 Mon]",
            "CLOCK: [2026-11-23 Mon]", ":LOGBOOK:\nCLOCK: [2026-11-23 Mon]\n:END:",
            "* LATER [#B] A\n#+TODO: LATER | FIN", "* A :noexport:\n[2026-11-23]",
        ])
    func taskElements(source: String) throws {
        let options = "#+OPTIONS: todo:nil tasks:nil pri:nil p:nil stat:nil c:nil d:nil <:nil date:nil\n"
        let file = try #require(OrgConverter.convert(options + source).orgInstructions)
        #expect(file.hasTaskOrDateElements)
        #expect(OrgReadingGroup.tasksAndDates.isExpanded(manual: nil, changed: 0, file: file))
        #expect(!OrgReadingGroup.textAndMarkup.isExpanded(manual: nil, changed: 0, file: file))
    }

    @Test(
        "設定やコード例や普通の語だけではタスクを含む文書にしない",
        arguments: [
            "* TODO A", "* DONE A", "* LATER A\n#+TODO: LATER | FIN", "#+begin_src org\n* TODO A\n#+end_src",
            "#+OPTIONS: todo:t p:t pri:t stat:t c:t <:t", "* A\nTODO text", "* =code [50%]=",
            "#+begin_src org\n,* TODO A\nCLOCK: [2026-11-23 Mon]\n#+end_src",
            "* TODO ordinary word\n#+TODO: OPEN | FIN", "* TODO [#A] ordinary text\n#+TODO: OPEN | FIN",
            "#+TODO: OPEN | FIN",
        ])
    func noTaskElements(source: String) {
        #expect(OrgConverter.convert(source).orgInstructions?.hasTaskOrDateElements == false)
    }

    @Test("追加項目の継承・原稿による固定・個別解除・保存・コピーが往復する")
    func layers() throws {
        func check<Value>(_ key: OrgSetting<Value>, shipping: Value, choice: Value, option: String) throws {
            let line = "#+OPTIONS: " + option
            let file = try #require(OrgConverter.convert(line).orgInstructions)
            var settings = OrgReadingSettings()
            #expect(settings.resolve(key, file: .init()).value == shipping)
            settings.defaults[keyPath: key.fallback] = choice
            #expect(settings.resolve(key, file: .init()).value == choice)
            settings.defaults[keyPath: key.fallback] = shipping
            settings.set(choice, for: key, file: .init())
            #expect(settings.document.changedCount == 1)
            #expect(settings.document.optionsLine == line)
            let saved = try JSONEncoder().encode(settings.document)
            #expect(try JSONDecoder().decode(OrgDocumentReadingSettings.self, from: saved) == settings.document)
            let row = settings.resolve(key, file: file)
            #expect(row.layer == .file && row.value == choice && row.source?.rawText == option)
            settings.setAllowsFileChanges(true, file: file)
            settings.set(shipping, for: key, file: file)
            #expect(settings.resolve(key, file: file).layer == .document)
            #expect(settings.fileOverrideCount(file: file) == 1)
            #expect(settings.effectiveDefaults(file: file, documentOnly: true)[keyPath: key.fallback] == shipping)
            settings.setAllowsFileChanges(false, file: file)
            #expect(settings.document.changedCount == 0 && settings.resolve(key, file: file).value == choice)
        }
        try check(.headlineLevels, shipping: 3, choice: 1, option: "H:1")
        try check(.tags, shipping: .all, choice: .notInContents, option: "tags:not-in-toc")
        try check(.preserveBreaks, shipping: false, choice: true, option: "\\n:t")
        try check(.emphasis, shipping: true, choice: false, option: "*:nil")
        try check(.math, shipping: .render, choice: .verbatim, option: "tex:verbatim")
        try check(.planning, shipping: false, choice: true, option: "p:t")
        try check(.clocks, shipping: true, choice: false, option: "c:nil")
        try check(.priority, shipping: false, choice: true, option: "pri:t")
        try check(.todo, shipping: true, choice: false, option: "todo:nil")
        try check(.statistics, shipping: true, choice: false, option: "stat:nil")
        try check(.tasks, shipping: .all, choice: .todo, option: "tasks:todo")
        try check(.title, shipping: true, choice: false, option: "title:nil")
        try check(.author, shipping: true, choice: false, option: "author:nil")
        try check(.date, shipping: true, choice: false, option: "date:nil")
        try check(.drawers, shipping: .off, choice: .including(["owner"]), option: "d:(\"owner\")")
        try check(.properties, shipping: .off, choice: .including(["owner"]), option: "prop:(\"owner\")")
        try check(.timestamps, shipping: .all, choice: .inactive, option: "<:inactive")
        try check(.footnotes, shipping: true, choice: false, option: "f:nil")
        try check(.tables, shipping: true, choice: false, option: "|:nil")
        try check(.fixedWidth, shipping: true, choice: false, option: "::nil")
        try check(.archived, shipping: .all, choice: .headline, option: "arch:headline")
    }

    @Test("以前の三項目の既定値と文書設定を保ち、新しい項目は出荷値を継ぐ")
    func oldRecords() throws {
        let json = Data(#"{"sectionNumbers":{"all":{}},"scripts":"off","tableOfContents":{"levels":{"_0":2}}}"#.utf8)
        let restored = try JSONDecoder().decode(OrgReadingDefaults.self, from: json)
        #expect(restored == .init(sectionNumbers: .all, tableOfContents: .levels(2), scripts: .off))
        let choices = try JSONDecoder().decode(OrgDocumentReadingSettings.self, from: json)
        #expect(choices.changedCount == 3 && choices.optionsLine == "#+OPTIONS: num:t toc:2 ^:nil")
    }

    @Test("上限を超える見出しは本文と子を含むリストになり、次の章の前で閉じる")
    func deepHeadings() {
        let source = "* A\n**** B\nb\n***** C\nc\n***** D\nd\n**** E\ne\n* F"
        #expect(
            OrgConverter.convert(source).body == """
                <h1>A</h1>
                <ul><li>B
                <p>b</p>
                <ul><li>C
                <p>c</p>
                </li>
                <li>D
                <p>d</p>
                </li></ul>
                </li>
                <li>E
                <p>e</p>
                </li></ul>
                <h1>F</h1>

                """)
        let numbered = OrgConverter.convert("#+OPTIONS: num:t toc:t\n" + source)
        #expect(numbered.decidesHeadingNumbers && numbered.body.contains("<ol><li"))
        #expect(DocumentOutline.headings(inHTML: numbered.body).map(\.text) == ["1. A", "2. F"])
    }

    @Test("目次だけのタグ非表示は本文のタグと目次のキーワードを個別に保つ")
    func tagsInContents() {
        let input = "* TODO [#A] 項目 [2/3] :work:"
        let parts = OrgConverter.convert("#+OPTIONS: toc:t tags:not-in-toc\n" + input).body.components(
            separatedBy: "</nav>")
        #expect(parts.count == 2 && !parts[0].contains("org-tag") && parts[1].contains("org-tag"))
        #expect(parts[0].contains("TODO"))
        let hidden = OrgConverter.convert("#+OPTIONS: tags:nil todo:nil stat:nil\n" + input).body
        #expect(
            !hidden.contains("TODO") && !hidden.contains("#A") && !hidden.contains("work") && !hidden.contains("[2/3]"))
    }

    @Test("優先度やタグだけの見出しでも非表示の印を残さない")
    func headingWithoutText() {
        let source = "#+OPTIONS: tags:nil todo:nil\n* TODO [#A]\n* TODO :work:\n* :work:  "
        #expect(OrgConverter.convert(source).body == String(repeating: "<h1></h1>\n", count: 3))
    }

    @Test("出荷時は予定行と優先度を隠し、原稿で以前の表示に戻せる")
    func planningAndPriority() {
        let text = "* TODO [#A] one\nSCHEDULED: <2026-11-23 Mon> DEADLINE: <2026-11-25 Wed> CLOSED: [2026-11-24 Tue]"
        let hidden = OrgConverter.convert(text).body
        #expect(hidden.contains("TODO") && !hidden.contains("#A") && !hidden.contains("2026-11"))
        let shown = OrgConverter.convert("#+OPTIONS: p:t pri:t\n" + text).body
        #expect(
            shown.contains("#A") && shown.contains("SCHEDULED") && shown.contains("DEADLINE")
                && shown.contains("CLOSED"))
    }

    @Test("文書情報を個別に切り替え、表題を隠すと最初の章が第一見出しになる")
    func metadata() {
        let raw = "#+TITLE: Name\n#+SUBTITLE: Subtitle\n#+AUTHOR: Author\n#+DATE: Date\n* One"
        #expect(
            OrgConverter.convert("#+OPTIONS: title:nil date:nil\n" + raw).body
                == "<header class=\"org-title-block\"><p class=\"org-author\">Author</p></header>\n<h1>One</h1>\n")
        #expect(!OrgConverter.convert("#+OPTIONS: author:nil\n" + raw).body.contains("Author"))
    }

    @Test("改行を保ち、明示的な改行を二重にせず、コード内は原文を保つ")
    func breaks() {
        let raw = #"#+OPTIONS: \n:t"#
        let text = "one\ntwo" + #"\\"# + "\nthree\n#+begin_src\none\ntwo\n#+end_src"
        let html = OrgConverter.convert(raw + "\n" + text).body
        #expect(html.contains("one<br>\ntwo<br>three") && html.contains("<code>one\ntwo</code>"))
    }

    @Test("固定幅・表・脚注・強調・数式は選んだ構文だけを変える")
    func constructs() {
        let raw = ": fixed\n#+CAPTION: table-cap\n| cell |\nprose *bold* =code= $x$ note[fn:1]\n\n[fn:1] def"
        let html = OrgConverter.convert("#+OPTIONS: ::nil |:nil f:nil *:nil tex:verbatim\n" + raw).body
        #expect(html == "<p>prose *bold* <code>code</code> <code>$x$</code> note</p>\n")
        #expect(OrgConverter.convert("#+OPTIONS: tex:nil\nbefore $x$ after").body == "<p>before  after</p>\n")
    }

    @Test("日時だけの段落を選別し、本文や予定行に埋め込んだ日時は保つ")
    func timestamps() {
        let text = "#+OPTIONS: <:active\n[2026-11-20] <2026-11-21>\n\ntext [2026-11-22]"
        let html = OrgConverter.convert(text).body
        #expect(!html.contains("11-20") && html.contains("11-21") && html.contains("11-22"))
    }

    @Test("ドロワーやプロパティを名前で選び、非表示のプロパティも内部リンクに使う")
    func drawers() {
        let raw =
            "* A\n:PROPERTIES:\n:CUSTOM_ID: target\n:OWNER: Alice\n:END:\n:work:\nlog text\nCLOCK: [2026-11-21]\n:END:\n:LOGBOOK:\nprivate\n:END:"
        let html = OrgConverter.convert(#"#+OPTIONS: prop:("OWNER") d:(not "LOGBOOK") c:nil"# + "\n" + raw).body
        #expect(html.contains("id=\"target\"") && html.contains(":OWNER: Alice") && html.contains("log text"))
        #expect(!html.contains(":CUSTOM_ID:") && !html.contains("private") && !html.contains("CLOCK:"))
    }

    @Test("タグ選択は親・子を保ち、除外した木から参照された脚注定義だけを取り込む")
    func tagSelection() {
        let raw = """
            #+SELECT_TAGS: paper
            #+EXCLUDE_TAGS: skip
            preamble
            * Parent
            ** Yes :paper:
            body [fn:hidden]
            *** Child
            ** No
            ** Both :paper:skip:
            [fn:hidden] hidden definition

            [fn:unused] unused definition
            """
        let html = OrgConverter.convert(raw).body
        #expect(
            html.contains("Parent") && html.contains("Yes") && html.contains("Child") && html.contains("footnote-ref"))
        #expect(
            !html.contains("preamble") && !html.contains("No") && !html.contains("Both")
                && html.contains("hidden definition") && !html.contains("unused definition"))
    }

    @Test("独自の完了語とアーカイブで木を選び、コード中のエスケープした星印は見出しにしない")
    func subtrees() {
        let raw =
            "#+OPTIONS: tasks:done arch:headline\n#+TODO: OPEN | FIN\n* FIN done\n* OPEN unfinished\n#+begin_example\n,* Literal\n#+end_example\n* Old :ARCHIVE:\nold body\n** child\n* End"
        let html = OrgConverter.convert(raw).body
        #expect(html.contains("done") && html.contains("Old") && html.contains("End"))
        #expect(
            !html.contains("unfinished") && !html.contains("Literal") && !html.contains("old body")
                && !html.contains("child"))
    }
}
