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

    @Test("コメント部分木は原稿の設定・脚注・タグを集める前に除く", arguments: ["COMMENT", "TODO [#A] COMMENT", "[#B] COMMENT", "LATER COMMENT"])
    func comments(prefix: String) {
        let declaration = prefix.hasPrefix("LATER") ? "\n#+SEQ_TODO: LATER | FIN" : ""
        let source = """
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

    @Test("除外タグの内側の指示は有効で、例の中のコメント見出しや接頭辞は本文を隠さない")
    func excludedDirectives() {
        let source =
            "* Draft :noexport:\n#+TITLE: Public\n#+OPTIONS: *:nil\n* COMMENTARY\n#+begin_example\n* COMMENT example\n#+end_example\n*bold*"
        let html = OrgConverter.convert(source).body
        #expect(html.contains("Public") && html.contains("*bold*") && html.contains("COMMENTARY"))
        #expect(html.contains("* COMMENT example") && !html.contains("Draft"))
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
