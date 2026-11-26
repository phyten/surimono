import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct SettingsSearchTests {
    @Test(
        "Org は読み方の名前とキーと拡張子から対応する設定行を開く",
        arguments: ["見出しの番号", "先頭の目次", "Subscripts and Superscripts", "num", "toc", "^", ".org"])
    func orgSettings(query: String) {
        let names = ["Heading Numbers": "見出しの番号", "Table of Contents at the Top": "先頭の目次"]
        let results = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { names[$0] ?? $0 })
        #expect(results.bestSection(keeping: .pageNumbers) == .org)
        if query == "num" { #expect(results.rows.contains { $0.section == .org && $0.anchor == "Heading Numbers" }) }
    }

    @Test("Emacs とリセットの検索で Org の対応する一括操作が見つかる")
    func orgDefaultsActions() {
        for (query, action) in [("Emacs", "Use Emacs Defaults…"), ("reset", "Reset to Defaults…")] {
            let hits = SettingsCatalogue.search(query, in: SettingsCatalogue.rows)
            #expect(hits.rows.contains { $0.section == .org && $0.anchor == action })
        }
    }

    @Test("読み方の全行に表示名と区切り付きの Org キーの両方で移動できる")
    func allOrgRows() {
        let ids = OrgReadingGroup.allCases.flatMap(\.settings)
        #expect(ids.count == 24 && Set(ids).count == ids.count)
        for id in ids {
            for query in [id.label.key, id.token, id.token + ":"] {
                let hits = SettingsCatalogue.search(query, in: SettingsCatalogue.rows)
                #expect(hits.rows.contains { $0.section == .org && $0.anchor == id.label.key }, "query=\(query)")
            }
        }
    }

    @Test("読み方の新旧の項目名・区分名・中括弧の選択肢を八言語で検索できる", arguments: UILanguage.supported)
    func orgSearchAliases(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let strings = try #require(Bundle(path: path))
        func translate(_ key: String) -> String { strings.localizedString(forKey: key, value: nil, table: nil) }
        let rows = SettingsCatalogue.rows
        let languages = ["en", "ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"]
        let index = try #require(languages.firstIndex(of: language))
        for (anchor, new, oldNames) in [
            (
                "Levels Shown as Headings", "Levels Shown as Headings",
                [
                    "Heading Depth", "見出しの深さ", "Gliederungstiefe", "Profundidad de los títulos",
                    "Profondeur des titres", "제목 깊이", "标题层级", "標題層級",
                ]
            ),
            (
                "Bold, Italic, and Other Emphasis", "Bold, Italic, and Other Emphasis",
                [
                    "Text Emphasis", "文字の強調", "Texthervorhebungen", "Énfasis del texto", "Mise en valeur du texte",
                    "텍스트 강조", "文字强调", "文字強調",
                ]
            ),
            (
                "Completion Percentages and Counts", "Completion Percentages and Counts",
                [
                    "Statistics Cookies", "進捗の割合と件数", "Fortschrittsangaben", "Indicadores de progreso",
                    "Indicateurs de progression", "진행률 및 개수", "进度与计数", "進度與計數",
                ]
            ),
            (
                "Tasks to Show", "Tasks to Show",
                [
                    "Include Tasks", "含めるタスク", "Einbezogene Aufgaben", "Tareas que se incluyen", "Tâches à inclure",
                    "포함할 작업", "包含的任务", "包含的任務",
                ]
            ),
            (
                "Org Title", "Org Title",
                [
                    "Document Title", "文書の表題", "Dokumenttitel", "Título del documento", "Titre du document", "문서 제목",
                    "文档标题", "文件標題",
                ]
            ),
            (
                "Date", "Date",
                [
                    "Document Date", "文書の日付", "Dokumentdatum", "Fecha del documento", "Date du document", "문서 날짜",
                    "文档日期", "文件日期",
                ]
            ),
            (
                "Subscripts and Superscripts", "Only in { }",
                [
                    "Only with { }", "{ } があるときだけ", "Nur mit { }", "Solo con { }", "Seulement avec { }", "{ }가 있을 때만",
                    "仅在有 { } 时", "僅在有 { } 時",
                ]
            ),
            (
                "Subscripts and Superscripts", "Only in { }",
                [
                    "Only When Enclosed in { }", "{ } で囲んだときだけ", "Nur in { } eingeschlossen",
                    "Solo si se encierra entre { }", "Seulement entre { }", "{ }로 감쌀 때만", "仅当用 { } 括起时", "僅在以 { } 括住時",
                ]
            ),
            (
                "Preserve Line Breaks", "Body Text Formatting",
                ["Text Formatting", "文字", "Text", "Texto", "Texte", "문자", "文字", "文字"]
            ),
            (
                "LaTeX Formulas", "Show Source",
                [
                    "Show Formula Source", "数式の原文", "Formelquelltext", "Código de la fórmula", "Source de la formule",
                    "수식 원문", "公式源码", "公式原始碼",
                ]
            ),
        ] {
            for query in [oldNames[index], translate(new)] {
                let hits = SettingsCatalogue.search(query, in: rows, localize: translate)
                #expect(hits.rows.contains { $0.section == .org && $0.anchor == anchor }, "\(language) \(query)")
            }
        }
        #expect(OrgReadingGroup.allCases == [.structure, .information, .text, .tasks, .details])
    }

    @Test("アイコンと部品の表示を検索するとツールバーの配置の先頭行が見つかる", arguments: ["icon", "アイコン", "Parts", "部品の表示"])
    func bandNames(query: String) {
        let labels = ["Parts": "部品の表示", "Icons and Names": "アイコンと名前", "Icons Only": "アイコンのみ"]
        let hits = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { labels[$0] ?? $0 })
        #expect(hits.rows.contains { $0.section == .toolbarArrangement && $0.anchor == "Parts" })
    }

    @Test("一般の検索結果は画面と同じ順で、見出しで検索すると配下の各行を強調する")
    func generalGroups() {
        let documents = [
            "When a Binder Is Down to One Document", "Reload When the File Changes", "After a File Is Saved",
            "Changed Places", "Changed Text",
        ]
        let window = ["Corners", "Float on Top", "Show on All Spaces"]
        let updates = [
            "Check for Updates Automatically", "When an Update Is Found",
            "Updates are unavailable in development builds.",
        ]
        let names = ["After a Document Opens": "文書を開いたあと", "Window": "ウインドウ", "Updates": "アップデート"]
        let groups = [("文書を開いたあと", documents), ("ウインドウ", window), ("アップデート", updates)]
        for (query, expected) in groups {
            let hits = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { names[$0] ?? $0 })
            #expect(hits.bestSection(keeping: .view) == .general)
            #expect(hits.rows.filter { $0.section == .general }.map(\.anchor) == expected)
        }
        let all = SettingsCatalogue.search("General", in: SettingsCatalogue.rows, localize: { $0 })
        let first = ["Language", "Appearance", "Show in Menu Bar"]
        #expect(all.rows.filter { $0.section == .general }.map(\.anchor) == first + documents + window + updates)
    }

    @Test("印刷とprintは区分名に一致し、余白は部品名より印刷の設定行を優先する", arguments: ["印刷", "print", "余白"])
    func printing(query: String) {
        let names = ["Printing": "印刷", "Margins": "余白", "Text Margins": "本文の余白", "Print…": "印刷…"]
        let results = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { names[$0] ?? $0 })
        #expect(results.bestSection(keeping: .keyboardShortcuts) == .printing)
        #expect(results.bestSection(keeping: .toolbarArrangement) == .printing)
    }

    @Test("項目名の完全一致・前方一致・部分一致の順で選び、同順位は現在の区分かサイドバーの先頭を使う")
    func labelRank() {
        let rows = [
            SettingsSearchRow(.general, "My color"), SettingsSearchRow(.styles, "Color scheme"),
            SettingsSearchRow(.view, "Color"), SettingsSearchRow(.printing, "Color"),
        ]
        func best(_ n: Int, _ section: SettingsSection) -> SettingsSection? {
            SettingsCatalogue.search("color", in: Array(rows.prefix(n)), localize: { $0 }).bestSection(keeping: section)
        }
        #expect(best(2, .general) == .styles)
        #expect(best(3, .styles) == .view)
        #expect(best(4, .printing) == .printing)
        #expect(best(4, .general) == .view)
    }

    @Test("検索中に読者が選んだ区分は、自動選択と同じ区分でもクリア後に残る")
    func explicitChoice() {
        var selection = SettingsSearchSelection()
        selection.begin(in: .html)
        selection.pick(.printing)
        #expect(selection.finish() == .printing)
    }

    @Test("自動で移動しただけなら検索前の区分に戻り、前回の手動選択を次の検索へ持ち越さない")
    func automaticChoice() {
        var selection = SettingsSearchSelection()
        selection.begin(in: .general)
        selection.pick(.styles)
        _ = selection.finish()
        selection.begin(in: .html)
        #expect(selection.finish() == .html)
    }
}
