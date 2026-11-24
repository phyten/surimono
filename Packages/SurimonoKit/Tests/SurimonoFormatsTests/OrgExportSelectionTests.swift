import Foundation
import Testing

@testable import SurimonoFormats

struct OrgExportSelectionTests {
    @Test("選択・除外タグは未指定なら既定を使い、空指定なら解除する")
    func defaultTags() {
        let body = "preamble\n* All\n* Chosen :export:\n* Secret :noexport:\nsecret text"
        let selected = OrgConverter.convert(body).body
        #expect(selected.contains("Chosen") && !selected.contains("All") && !selected.contains("secret text"))
        let noSelect = OrgConverter.convert("#+SELECT_TAGS:\n" + body).body
        #expect(noSelect.contains("All") && !noSelect.contains("Secret"))
        let empty = OrgConverter.convert("#+SELECT_TAGS:\n#+EXCLUDE_TAGS:\n" + body).body
        #expect(empty.contains("preamble") && empty.contains("All") && empty.contains("secret text"))
        #expect(!OrgConverter.convert("* All\n* Secret :noexport:\n** Private").body.contains("Private"))
    }

    @Test(
        "コメント部分木は原稿の設定・脚注・タグを集める前に除く",
        arguments: [
            "COMMENT", "TODO [#A] COMMENT", "[#B] COMMENT", "TODO [#10] COMMENT", "[#10] COMMENT", "[#64] COMMENT",
            "LATER COMMENT",
        ])
    func comments(prefix: String) {
        let declaration = prefix.hasPrefix("LATER") ? "\n#+SEQ_TODO: LATER | FIN" : ""
        let source = """
            #+PRIORITIES: 1 10 5
            #+TITLE: Public
            * \(prefix) Hidden
            #+TITLE: Secret
            #+OPTIONS: *:nil
            #+FILETAGS: :noexport:
            ** Nested :export:
            [fn:c] private definition
            * Visible
            *bold* ref [fn:c]
            """ + declaration
        let fragment = OrgConverter.convert(source)
        #expect(fragment.title == "Public")
        #expect(fragment.body.contains("<strong>bold</strong>") && fragment.body.contains("[fn:c]"))
        #expect(!fragment.body.contains("Hidden") && !fragment.body.contains("private definition"))
        #expect(fragment.orgInstructions?.hasWholeDocumentInstructions == false)
    }

    @Test("コメント位置の語は原稿の宣言でタスク語かどうかを決める")
    func commentKeywordGrammar() {
        let ordinary =
            "* TODO COMMENT Room\n#+TODO: OPEN | FIN\n#+TITLE: Visible\n* OPEN COMMENT Draft\n#+TITLE: Hidden"
        let exported = OrgConverter.convert(ordinary)
        #expect(exported.title == "Visible" && exported.body.contains("Room") && !exported.body.contains("Draft"))
        let hiddenWorkflow = "* COMMENT Draft\n#+TODO: NEXT | FIN\n* TODO RealTask\n* NEXT room\n#+OPTIONS: tasks:nil"
        let filtered = OrgConverter.convert(hiddenWorkflow).body
        #expect(!filtered.contains("RealTask") && filtered.contains("room"))
    }

    @Test("除外タグの内側の指示は有効で、例の中でコンマを付けた星印や接頭辞は本文を隠さない")
    func excludedDirectives() {
        let source =
            "* Draft :noexport:\n#+TITLE: Public\n#+OPTIONS: *:nil\n* COMMENTARY\n#+begin_example\n,* COMMENT example\n#+end_example\n*bold*"
        let html = OrgConverter.convert(source).body
        #expect(html.contains("Public") && html.contains("*bold*") && html.contains("COMMENTARY"))
        #expect(html.contains("* COMMENT example") && !html.contains("Draft"))
    }

    @Test("空の兄弟見出しで非公開の部分木が終わり、公開本文と空の見出しを刷る")
    func emptyHeadingBoundary() {
        for marker in ["*", "**"] {
            for privateTitle in ["Private :noexport:", "COMMENT Private"] {
                let source = "\(marker) \(privateTitle)\nsecret\n\(marker) \npublic"
                let html = OrgConverter.convert(source).body
                let tag = marker == "*" ? "h1" : "h2"
                #expect(html == "<\(tag)></\(tag)>\n<p>public</p>\n")
            }
        }
        let note = OrgConverter.convert("[fn:x] unused\n* \npublic").body
        #expect(note == "<h1></h1>\n<p>public</p>\n")
    }

    @Test("星だけの行と星の直後がタブの行は見出しにならない")
    func headingSeparator() {
        let html = OrgConverter.convert("*\tOrdinary :noexport:\npublic\n\n*").body
        #expect(html.contains("Ordinary :noexport:") && html.contains("public") && !html.contains("<h1"))
    }

    @Test("ブロックの途中でも見出しからコメントが始まり、その中の本文と指示を除く", arguments: ["example", "src", "quote"])
    func interruptedBlock(kind: String) {
        let raw =
            "#+begin_\(kind)\n* COMMENT Hidden\nprivate text\n#+TITLE: Secret\n#+end_\(kind)\n* Visible\npublic text"
        let fragment = OrgConverter.convert(raw)
        #expect(fragment.title == nil && !fragment.body.contains("Hidden") && !fragment.body.contains("private text"))
        #expect(fragment.body.contains("<h1>Visible</h1>") && fragment.body.contains("public text"))

        let publicHeading = OrgConverter.convert("#+begin_\(kind)\n* Visible\n#+TITLE: Public\nbody\n#+end_\(kind)")
        #expect(publicHeading.title == "Public" && publicHeading.body.contains("<h2>Visible</h2>"))
        #expect(publicHeading.body.contains("#+begin_\(kind)") && publicHeading.body.contains("#+end_\(kind)"))
    }

    @Test("例とソースの行頭では星と指示のエスケープを一段だけ外す", arguments: ["src", "example"])
    func escapedBlockLines(kind: String) {
        let raw = "#+begin_\(kind)\n,* COMMENT Hidden\n,,* second\n  ,#+TITLE: Local\n,ordinary\n#+end_\(kind)"
        let fragment = OrgConverter.convert(raw)
        #expect(
            fragment.title == nil && fragment.body.contains("* COMMENT Hidden\n,* second\n  #+TITLE: Local\n,ordinary"))
        #expect(!fragment.body.contains(",* COMMENT Hidden") && !fragment.body.contains("<h1"))
    }

    @Test("数字の優先度は零から六十四までを表示設定に従って組む")
    func numericPriorities() {
        let headings = "* [#0] Zero\n* TODO [#10] Ten\n* [#64] Max\n* [#65] Overflow\n* [#a] Lowercase"
        let hidden = OrgConverter.convert(headings).body
        #expect(!hidden.contains("#0") && !hidden.contains("#10") && !hidden.contains("#64"))
        #expect(hidden.contains("[#65] Overflow") && hidden.contains("[#a] Lowercase"))
        let shown = OrgConverter.convert("#+OPTIONS: pri:t\n" + headings).body
        for value in ["#0", "#10", "#64"] {
            #expect(shown.contains("<span class=\"org-priority\">\(value)</span>"))
        }
    }

    @Test("タスク語を隠しても未宣言の語は題に残し、宣言した語だけを外す")
    func hiddenTodoKeywords() {
        let source = "#+OPTIONS: todo:nil\n* NEXT page\n* WAITING room\n* HOLD door\n* TODO work\n* DONE finished"
        let plain = OrgConverter.convert(source).body
        for title in ["NEXT page", "WAITING room", "HOLD door"] { #expect(plain.contains(">\(title)</h1>")) }
        #expect(!plain.contains("TODO") && !plain.contains("DONE"))
        let declared = OrgConverter.convert(source + "\n#+TODO: NEXT WAITING | HOLD").body
        for word in ["NEXT", "WAITING", "HOLD"] { #expect(!declared.contains(word)) }
    }

    @Test("末尾全体が有効なタグ列のときだけ見出しを選別しタグを組む")
    func tagAlphabet() {
        let raw = "* Report :noexport:bad!:\nordinary body\n* Tagged :日本語:abc_2:@home:#x:%y:"
        let html = OrgConverter.convert(raw).body
        #expect(html.contains("<h1>Report :noexport:bad!:</h1>") && html.contains("ordinary body"))
        for tag in ["日本語", "abc_2", "@home", "#x", "%y"] {
            #expect(html.contains("<span class=\"org-tag\">\(tag)</span>"))
        }
        let selected = OrgConverter.convert("#+SELECT_TAGS: 日本語\n" + raw).body
        #expect(selected.contains("Tagged") && !selected.contains("Report"))
    }

    @Test("末尾や語の間に八千個の空白があってもタグと本文を区別する")
    func longHeadingWhitespace() {
        let spaces = String(repeating: " ", count: 8000)
        let html = OrgConverter.convert("* Hidden :noexport:\(spaces)\nsecret\n* X\(spaces)Y\(spaces)").body
        #expect(!html.contains("secret") && html.contains("X\(spaces)Y"))
    }

    @Test("作業時間は非アクティブな日時か所要時間で判定し、アクティブな日時の行は本文に残す")
    func clockForms() {
        for line in ["CLOCK: [2026-11-23 Mon 10:00]--[2026-11-23 Mon 11:30] => 1:30", "CLOCK: => 12:30"] {
            let hidden = OrgConverter.convert("#+OPTIONS: c:nil\n" + line)
            #expect(hidden.body.isEmpty && hidden.orgInstructions?.hasTaskElements == true)
            #expect(OrgConverter.convert("#+OPTIONS: c:t\n" + line).body.contains("CLOCK:"))
        }
        for line in ["CLOCK: <2026-11-23 Mon>", "CLOCK:=> 12:30", "CLOCK: =>1:30", "CLOCK: => 1:3"] {
            let ordinary = OrgConverter.convert("#+OPTIONS: c:nil\n" + line)
            #expect(ordinary.body.contains("CLOCK:") && ordinary.orgInstructions?.hasTaskElements == false)
        }
    }

    @Test("ファイルのタグは全見出しの選別に使い、見出しや目次には足さない")
    func fileTags() {
        let body = "intro\n* One\n** Two :local:\n* Three"
        let chosen = OrgConverter.convert("#+FILETAGS: :export:\n" + body).body
        #expect(!chosen.contains("intro") && !chosen.contains("export"))
        #expect(chosen.contains("One") && chosen.contains("local") && chosen.contains("Three"))
        let excluded = OrgConverter.convert("#+EXCLUDE_TAGS: secret\n#+FILETAGS: :secret:\n" + body).body
        #expect(!excluded.contains("One") && !excluded.contains("Three"))
    }

    @Test("唯一の選択対象が除外されてもその親を残す")
    func selectionBeforeExclusion() {
        let body = "* Parent\nparent body\n** Both :export:noexport:\nsecret\n* Other"
        #expect(OrgConverter.convert(body).body == "<h1>Parent</h1>\n<p>parent body</p>\n")
        let archived = OrgConverter.convert(
            "#+OPTIONS: arch:headline\n* Old :ARCHIVE:\nold body\n** Child :export:\n* Other"
        ).body
        #expect(
            archived.contains("Old") && !archived.contains("old body") && !archived.contains("Child")
                && !archived.contains("Other"))
    }

    @Test("文頭・空行の後・段落中の予定表記を本文に残す", arguments: ["", "* Head\n\n", "* Head\nwords\n"])
    func planningInProse(prefix: String) {
        let fragment = OrgConverter.convert(prefix + "SCHEDULED: <2026-11-23 Mon>")
        #expect(fragment.body.contains("SCHEDULED:") && !fragment.body.contains("org-planning"))
        #expect(fragment.orgInstructions?.hasTaskElements == false)
    }

    @Test("普通のドロワーは本文と同じ強調・リンク・リスト・表・数式・脚注を使う")
    func drawerContents() {
        let text = "*bold* [[https://example.org][link]] [fn:n]\n- item\n| cell |\n\n$x$\n\n[fn:n] definition"
        let inside = ":WORK:\n" + text + "\n:END:"
        for options in ["d:t tex:verbatim", "d:t |:nil tex:nil f:nil"] {
            let prefix = "#+OPTIONS: " + options + "\n"
            let drawer = OrgConverter.convert(prefix + inside).body
            let body = OrgConverter.convert(prefix + text).body
            #expect(drawer == body, "\(options)")
        }
        for option in ["d:t", "d:nil"] {
            let outsideRef = OrgConverter.convert(
                "#+OPTIONS: " + option + "\nRead [fn:n]\n:WORK:\n[fn:n] inside definition\n:END:"
            ).body
            #expect(outsideRef.contains("footnote-ref") && outsideRef.contains("inside definition"))
        }
    }

    @Test("タスクによる除外は標準または原稿で宣言した語だけを対象とする", arguments: ["TODO", "SEQ_TODO", "TYP_TODO"])
    func taskVocabulary(directive: String) {
        let body = "* WAITING room\n* NEXT page\n* HOLD door\n* TODO work\n* DONE finished"
        let filtered = OrgConverter.convert("#+OPTIONS: tasks:nil\n" + body).body
        #expect(filtered.contains("room") && filtered.contains("page") && filtered.contains("door"))
        #expect(!filtered.contains("work") && !filtered.contains("finished"))
        let custom = OrgConverter.convert("#+OPTIONS: tasks:nil\n" + body + "\n#+" + directive + ": WAITING | DONE")
            .body
        #expect(!custom.contains("room") && custom.contains("work") && !custom.contains("finished"))
    }

    @Test("段落とリスト途中の統計クッキーを隠し、コード・逐語表記を保つ")
    func statisticsInProse() {
        let html = OrgConverter.convert(
            "#+OPTIONS: stat:nil\ntext [2/3] end\n- item [50%] end\n\n=code [4/5]= ~raw [60%]~"
        ).body
        #expect(!html.contains("[2/3]") && !html.contains("[50%]"))
        #expect(html.contains("code [4/5]") && html.contains("raw [60%]"))
    }

    @Test("名前の一覧は空の除外・空白・引用符・逆斜線をコピーして読み戻せる")
    func nameLists() throws {
        for token in [#"(not )"#, #"()"#, #"(not "two words" "A\"B" "X\\Y")"#] {
            let value = try #require(OrgReadingDefaults.Names(token: token, allowsExclusion: true))
            #expect(OrgReadingDefaults.Names(token: value.token, allowsExclusion: true) == value)
        }
        for token in [#"(not )"#, #"(not "two words" "A\"B" "X\\Y")"#] {
            let input = try #require(OrgConverter.convert("#+OPTIONS: d:" + token).orgInstructions)
            var settings = OrgReadingSettings()
            let choice = settings.resolve(.drawers, file: input).value
            settings.set(choice, for: .drawers, file: .init())
            let copied = try #require(settings.document.optionsLine)
            let readback = try #require(OrgConverter.convert(copied).orgInstructions)
            #expect(settings.resolve(.drawers, file: readback).layer == .file)
            #expect(settings.resolve(.drawers, file: readback).value == choice)
        }
    }

    @Test("タスク語は大文字小文字を区別し、ドロワーとプロパティの名前は区別しない")
    func nameMatching() {
        let source =
            "#+OPTIONS: d:(\"woRK\") prop:(\"owNEr\") tasks:(\"Take\")\n#+TODO: Take TAKE | Done\n* Take yes\n:PROPERTIES:\n:OWNER: Alice\n:END:\n:WORK:\nlog\n:END:\n* TAKE no"
        let html = OrgConverter.convert(source).body
        #expect(html.contains("yes") && !html.contains("TAKE") && html.contains("Alice") && html.contains("log"))
    }

    @Test(
        "古い記録は未指定・不明値・異なる型を項目ごとに扱う",
        arguments: [
            "", #","scripts":null"#, #","future":17"#, #","tags":"future""#, #","tasks":{"future":{}}"#,
            #","planning":"yes""#, #","allowsFileChanges":37"#,
        ])
    func partialRecords(extra: String) throws {
        let data = Data(("{\"headlineLevels\":2,\"author\":false" + extra + "}").utf8)
        let defaults = try JSONDecoder().decode(OrgReadingDefaults.self, from: data)
        #expect(defaults.headlineLevels == 2 && !defaults.author && defaults.tags == .all && !defaults.planning)
        let document = try JSONDecoder().decode(OrgDocumentReadingSettings.self, from: data)
        #expect(
            document.changedCount == 2 && !document.allowsFileChanges
                && document.optionsLine == "#+OPTIONS: H:2 author:nil")
    }

    @Test("三通り以上ある項目はすべての層を異なる値にして保存・再固定を確かめる")
    func differentLayers() throws {
        func check<Value>(_ key: OrgSetting<Value>, app: Value, document: Value, file: Value, token: String) throws {
            let instructions = try #require(OrgConverter.convert("#+OPTIONS: " + token).orgInstructions)
            var settings = OrgReadingSettings()
            settings.defaults[keyPath: key.fallback] = app
            #expect(settings.resolve(key, file: .init()).value == app)
            settings.set(document, for: key, file: .init())
            #expect(settings.resolve(key, file: .init()).value == document)
            #expect(settings.resolve(key, file: instructions).value == file)
            settings.setAllowsFileChanges(true, file: instructions)
            let data = try JSONEncoder().encode(settings.document)
            let restored = try JSONDecoder().decode(OrgDocumentReadingSettings.self, from: data)
            settings = OrgReadingSettings(defaults: settings.defaults, document: restored)
            #expect(settings.resolve(key, file: instructions).value == document)
            settings.setAllowsFileChanges(false, file: instructions)
            #expect(settings.resolve(key, file: instructions).value == file)
            #expect(settings.resolve(key, file: .init()).value == app)
        }
        try check(.headlineLevels, app: 3, document: 2, file: 1, token: "H:1")
        try check(.sectionNumbers, app: .off, document: .levels(2), file: .all, token: "num:t")
        try check(.tableOfContents, app: .all, document: .off, file: .levels(2), token: "toc:2")
        try check(.scripts, app: .all, document: .braces, file: .off, token: "^:nil")
        try check(.tags, app: .off, document: .all, file: .notInContents, token: "tags:not-in-toc")
        try check(.math, app: .off, document: .verbatim, file: .render, token: "tex:t")
        try check(.tasks, app: .all, document: .off, file: .done, token: "tasks:done")
        try check(.drawers, app: .off, document: .all, file: .excluding(["D"]), token: #"d:(not "D")"#)
        try check(.properties, app: .off, document: .all, file: .including(["P"]), token: #"prop:("P")"#)
        try check(.timestamps, app: .all, document: .off, file: .active, token: "<:active")
        try check(.archived, app: .all, document: .headline, file: .off, token: "arch:nil")
    }

    @Test("真偽の設定はアプリと原稿が一致していても文書による変更許可を区別する", arguments: [true, false])
    func booleanLayers(app: Bool) throws {
        let token = app ? "t" : "nil"
        let file = try #require(OrgConverter.convert("#+OPTIONS: p:" + token).orgInstructions)
        var settings = OrgReadingSettings()
        settings.defaults.planning = app
        settings.set(!app, for: .planning, file: .init())
        #expect(settings.resolve(.planning, file: .init()).value == !app)
        #expect(settings.resolve(.planning, file: file).value == app)
        settings.setAllowsFileChanges(true, file: file)
        #expect(settings.resolve(.planning, file: file).value == !app)
        settings.setAllowsFileChanges(false, file: file)
        #expect(settings.resolve(.planning, file: file).value == app)
    }

    @Test("見出しの上限は残った最浅見出しから数え、零ならすべて箇条書きにする")
    func relativeDepth() {
        let raw = "*** One\n**** Two\n***** Three\n****** Four"
        for suffix in ["", "\n* Secret :noexport:"] {
            let html = OrgConverter.convert(raw + suffix).body
            #expect(html.contains("<h5>Three</h5>") && html.contains("<ul><li>Four"))
            #expect(!html.contains("Secret"))
        }
        let zero = OrgConverter.convert("#+OPTIONS: H:0\n" + raw).body
        #expect(!zero.contains("<h") && zero.contains("<ul><li>One"))
    }

    @Test("深い見出しで番号を外し、子の指定で番号付きリストに戻す")
    func deepUnnumbered() {
        let source =
            "#+OPTIONS: H:1 num:t\n* Root\n** Child\n:PROPERTIES:\n:UNNUMBERED: t\n:END:\n*** Grandchild\n:PROPERTIES:\n:UNNUMBERED: nil\n:END:"
        let html = OrgConverter.convert(source).body
        #expect(html.contains("<ul><li>Child") && html.contains("<ol><li>Grandchild"))
    }
}
