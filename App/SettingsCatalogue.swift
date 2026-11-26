import Foundation
import SurimonoCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case view = "View and Page Turn"
    case toolbarArrangement = "Toolbar Arrangement"
    case styles = "Styles"
    case printing = "Printing"
    case pageNumbers = "Page Numbers"
    case settingSets = "Setting Sets"
    case clipboard = "Clipboard"
    case documents = "Documents"
    // Legacy navigation targets are resolved before selecting a sidebar chapter.
    case html = "HTML"
    case org = "Org"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keyboardShortcuts: "keyboard"
        case .view: "book"
        case .toolbarArrangement: "menubar.rectangle"
        case .pageNumbers: "number"
        case .printing: "printer"
        case .settingSets: "slider.horizontal.3"
        // "textformat" is drawn as kana in Japanese, beside line icons; the band's palette is the same in every language.
        case .styles: "paintpalette"
        case .documents, .org: "doc.text"
        case .html: "globe"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

enum SettingsGroup: String, CaseIterable {
    case general = "General Group"
    case viewing = "Viewing"
    case printing = "Printing Group"
    case opening = "Opening"

    var sections: [SettingsSection] {
        switch self {
        case .general: [.general, .keyboardShortcuts]
        case .viewing: [.view, .toolbarArrangement, .styles]
        case .printing: [.printing, .pageNumbers, .settingSets]
        case .opening: [.clipboard, .documents]
        }
    }
}

struct SettingsSearchRow {
    let section: SettingsSection
    let format: DocumentFormat?
    let label: String
    let anchor: String
    let words: [String]
    let identifiers: [String]
    let heading: String?

    init(
        _ section: SettingsSection, _ label: String, format: DocumentFormat? = nil, anchor: String? = nil,
        words: [String] = [],
        identifiers: [String] = [], heading: String? = nil
    ) {
        self.section = section
        self.format = format
        self.label = label
        self.anchor = anchor ?? label
        self.identifiers = identifiers
        self.words = words
        self.heading = heading
    }
}

struct SettingsSearchSelection {
    private var sectionToKeep: SettingsSection?

    mutating func begin(in section: SettingsSection) { sectionToKeep = section }
    mutating func pick(_ section: SettingsSection) { sectionToKeep = section }

    mutating func finish() -> SettingsSection? {
        defer { sectionToKeep = nil }
        return sectionToKeep
    }
}

struct SettingsSearchResults {
    var rows: [SettingsSearchRow] = []
    fileprivate var ranks: [SettingsSection: Rank] = [:]

    fileprivate var documentMatches: [DocumentFormat: [(anchor: String, rank: Rank)]] = [:]

    var formats: [DocumentFormat] { DocumentsChapter.formats.filter { documentMatches[$0] != nil } }

    func bestFormat(keeping current: DocumentFormat) -> DocumentFormat? {
        guard let best = ranks[.documents] else { return nil }
        func hasBestMatch(_ format: DocumentFormat) -> Bool {
            documentMatches[format]?.contains { $0.rank == best } == true
        }
        return hasBestMatch(current) ? current : formats.first(where: hasBestMatch)
    }

    func hits(for section: SettingsSection, format: DocumentFormat, query: String) -> SettingsSearchHits {
        if section == .documents {
            let matches = documentMatches[format] ?? []
            return SettingsSearchHits(
                query: query, anchors: matches.sorted { $0.rank < $1.rank }.map(\.anchor), format: format)
        }
        return SettingsSearchHits(query: query, anchors: rows.filter { $0.section == section }.map(\.anchor))
    }

    fileprivate struct Rank: Comparable {
        enum Source: Int { case identifier, section, setting, command }
        enum Match: Int, Comparable {
            case exact, prefix, substring, keyword
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        }
        let source: Source
        let match: Match

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.source.rawValue, lhs.match.rawValue) < (rhs.source.rawValue, rhs.match.rawValue)
        }
    }

    func bestSection(keeping current: SettingsSection) -> SettingsSection? {
        guard let best = ranks.values.min() else { return nil }
        if ranks[current] == best { return current }
        return SettingsGroup.allCases.flatMap(\.sections).first { ranks[$0] == best }
    }
}

enum SettingsCatalogue {
    static let shortcutGroups: [ShortcutGroup] = [.application, .documentAndPrinting, .reading, .styles, .lists]

    static let rows: [SettingsSearchRow] = {
        var rows: [SettingsSearchRow] = [
            .init(.general, "Language"),
            .init(.general, "Appearance"),
            .init(.general, "Show in Menu Bar"),
            .init(.general, "When a Binder Is Down to One Document", heading: "After a Document Opens"),
            .init(.general, "Reload When the File Changes", heading: "After a Document Opens"),
            .init(.general, "After a File Is Saved", heading: "After a Document Opens"),
            .init(.general, "Changed Places", words: ["highlight", "background"], heading: "After a Document Opens"),
            .init(.general, "Changed Text", heading: "After a Document Opens"),
            .init(.general, "Corners", heading: "Window"),
            .init(.general, "Float on Top", heading: "Window"),
            .init(.general, "Show on All Spaces", heading: "Window"),
            .init(.general, "Check for Updates Automatically", heading: "Updates"),
            .init(.general, "When an Update Is Found", words: ["install"], heading: "Updates"),
            .init(.general, "Updates are unavailable in development builds.", heading: "Updates"),
            .init(.view, "Scroll Sensitivity"),
            .init(.view, "View Type", words: ["spread", "single page"]),
            .init(.view, "Page Turning"),
            .init(.view, "Reading Direction"),
            .init(.view, "Scroll Direction"),
            .init(.view, "Show First Page Alone"),
            .init(.view, "Window Width When the First Page Is Alone"),
            .init(.view, "Join Pages in Single-Page Scrolling"),
            .init(.view, "Toolbar Layout"),
            .init(.view, "Toolbar Visibility"),
            .init(.view, "Parts of the Toolbar", words: ["Arrange…"]),
            .init(.view, "Show Contents As", words: ["outline", "drawer"]),
            .init(.pageNumbers, "In View Mode"),
            .init(.pageNumbers, "In Print", words: ["header", "footer"]),
            .init(.printing, "Print Layout"),
            .init(.printing, "Paper Orientation"),
            .init(.printing, "Text Margins", words: ["paper"]),
            .init(.printing, "Rotate Back Sides 180°"),
            .init(.printing, "Output Order"),
            .init(.styles, "Try a Style on the Paper When Pointing at It"),
            .init(.styles, "Default Style"),
            .init(.styles, "Default Code Colors"),
            .init(.styles, "Default Text Size"),
            .init(.styles, "Default Typeface", words: ["LaTeX Typeface", "As the Style"]),
            .init(.styles, "Open Styles Folder"),
            .init(.styles, "Reload", anchor: "Open Styles Folder"),
            .init(.clipboard, "Keep Closed Clipboard Documents Until Quit"),
            .init(.clipboard, "Also Keep Them After Quitting"),
            .init(.clipboard, "Choosing the Format"),
            .init(.clipboard, "Format to Open"),
            .init(.clipboard, "How Readily to Format"),
            .init(.toolbarArrangement, "Parts", words: ["Icons and Names", "Icons Only"]),
            .init(.toolbarArrangement, "Start Over"),
            .init(.toolbarArrangement, "Use Saved"),
            .init(
                .toolbarArrangement, "Arrangement Set",
                words: ["Overwrite", "Manage Arrangement", "Duplicate…", "New…", "Rename…", "Delete…"]),
            .init(.toolbarArrangement, "Editing", words: ["Undo", "Redo", "Back to Standard"]),
            .init(.toolbarArrangement, "Toolbar Arrangement"),
            .init(.toolbarArrangement, "Parts to Add", words: ["Separator"]),
            .init(
                .toolbarArrangement, "Move To",
                words: ["Move Earlier", "Move Later", "Add Separator After", "Remove from Toolbar"]),
            .init(.settingSets, "Import…"),
            .init(.settingSets, "Export All…", anchor: "Import…"),
            .init(
                .keyboardShortcuts, "Search Shortcuts",
                words: ["Import Shortcuts…", "Export Shortcuts…", "Restore All Defaults…"]),
        ]
        rows += BandLayout.Item.allCases.map {
            .init(.toolbarArrangement, $0.editorNameResource.key, anchor: $0.rawValue)
        }
        for format in DocumentsChapter.formats {
            let controls = DocumentsChapter.rows(for: format)
            if !controls.isEmpty {
                rows += controls.map { row in
                    .init(
                        .documents, row.id.label.key, format: format,
                        identifiers: row.instructions.map { $0.syntax.lowercased() }
                            + DocumentsChapter.extensions(for: format))
                }
                // Manuscript-only syntax locates the format's header without offering an ineffective control.
                let shown = Set(controls.map(\.id))
                let otherSyntax = ReadingCatalogue.rows(for: format).filter { !shown.contains($0.id) }
                    .flatMap(\.instructions).map { $0.syntax.lowercased() }
                rows.append(.init(.documents, "Defaults for New Documents", format: format, identifiers: otherSyntax))
            }
            if format == .plainText {
                rows += CodeNumberRow.allCases.map { .init(.documents, $0.label.key, format: format) }
            }
            if format != .org && format != .html {
                rows.append(.init(.documents, "Reset to Defaults…", format: format))
            }
        }
        for group in OrgReadingGroup.allCases {
            rows += group.settings.map { id in
                let token = id.token.lowercased()
                let aliases = orgSearchWords(for: id) + (group == .textAndMarkup ? formerOrgTextHeadings : [])
                return .init(
                    .documents, id.label.key, format: .org, words: aliases,
                    identifiers: [token, token + ":", ".org"]
                        + (ReadingCatalogue.rows(for: .org).first { $0.id == id }?.instructions.map {
                            $0.syntax.lowercased()
                        } ?? []),
                    heading: group.title.key)
            }
        }
        rows += [
            .init(.documents, "Use Emacs Defaults…", format: .org),
            .init(.documents, "Reset to Defaults…", format: .org),
            .init(.documents, "Default HTML Preset", format: .html, identifiers: [".html", ".htm"]),
            .init(.documents, "Allow JavaScript in HTML", format: .html),
            .init(.documents, "Open Presets Folder", format: .html),
            .init(.documents, "Reload", format: .html, anchor: "Open Presets Folder"),
        ]
        rows += ClipboardSettings.recognizable.map {
            .init(
                .clipboard, ClipboardSettings.labelKey($0),
                words: ["Formats to Recognize Automatically"])
        }
        rows.append(.init(.clipboard, "Back to Standard"))
        for group in shortcutGroups {
            rows += ShortcutOperation.catalog.filter { $0.group == group }.map { shortcut($0) }
        }
        rows += ShortcutFixedKey.catalog.map {
            .init(
                .keyboardShortcuts, ShortcutText.fixedResource($0.behavior).key,
                anchor: $0.behavior.rawValue, words: ["Fixed Keys"])
        }
        rows += ShortcutOperation.catalog.filter(\.isGlobal).map { shortcut($0) }
        return rows
    }()

    // Keep retired translations searchable when the display catalog no longer contains their keys.
    private static let formerOrgTextHeadings = [
        "Body Text Formatting", "Text Formatting", "文字", "Text", "Texto", "Texte", "문자", "텍스트",
        "Formatierung des Fließtexts",
        "Formato del cuerpo del texto", "Mise en forme du corps du texte",
    ]

    private static func orgSearchWords(for id: OrgSettingID) -> [String] {
        switch id {
        case .tableOfContents:
            ["Lead Contents", "Sommaire en début de document", "문서 앞의 목차", "文首目录", "文件開頭的目錄"]
        case .headlineLevels:
            [
                "Heading Depth", "見出しの深さ", "Gliederungstiefe", "Profundidad de los títulos", "Profondeur des titres",
                "제목 깊이", "标题层级", "標題層級", "Profundidad de títulos", "Niveles que se muestran como títulos",
                "Niveaux affichés comme titres",
            ]
        case .tags:
            [
                "Schlagwörter der Überschriften", "Etiquetas de los títulos", "Étiquettes des titres",
                "Except in Contents", "Außer im Inhaltsverzeichnis", "Sauf dans le sommaire", "목차에서만 숨기기", "目录中隐藏",
                "目錄中隱藏",
            ]
        case .scripts:
            [
                "Only with { }", "{ } があるときだけ", "Nur mit { }", "Solo con { }", "Seulement avec { }", "{ }가 있을 때만",
                "仅在有 { } 时", "僅在有 { } 時", "Only in { }", "Only When Enclosed in { }", "{ } で囲んだときだけ",
                "Nur in { } eingeschlossen", "Solo si se encierra entre { }", "仅当用 { } 括起时", "僅在以 { } 括住時",
            ]
        case .emphasis:
            [
                "Text Emphasis", "文字の強調", "Texthervorhebungen", "Énfasis del texto", "Mise en valeur du texte",
                "텍스트 강조", "文字强调", "文字強調", "Fett, kursiv und weitere Hervorhebungen", "Negrita, cursiva y otros estilos",
                "Gras, italique et autres mises en valeur", "粗体、斜体等文字修饰", "粗體、斜體等文字裝飾",
            ]
        case .statistics:
            [
                "Statistics Cookies", "進捗の割合と件数", "Fortschrittsangaben", "Indicadores de progreso",
                "Indicateurs de progression", "진행률 및 개수", "进度与计数", "進度與計數", "Abschluss in Prozent und Anzahl",
                "Porcentaje y número de tareas completadas", "Pourcentage et nombre de tâches terminées", "완료율과 완료 건수",
                "完成率和计数",
            ]
        case .tasks:
            [
                "Include Tasks", "含めるタスク", "Einbezogene Aufgaben", "Tareas que se incluyen", "Tâches à inclure",
                "포함할 작업", "包含的任务", "包含的任務", "Tareas que se muestran", "Completed Only", "Terminées uniquement",
                "Unfinished Only", "Non terminées uniquement",
            ]
        case .title:
            [
                "Document Title", "文書の表題", "Dokumenttitel", "Título del documento", "Titre du document", "문서 제목",
                "文档标题", "文件標題",
            ]
        case .date: ["Document Date"]
        case .fixedWidth: ["Zeilen mit fester Zeichenbreite"]
        case .math:
            [
                "Typeset", "Componer", "Composer", "排版", "Show Source", "Show Formula Source", "数式の原文",
                "Código de la fórmula", "Source de la formule", "公式源码", "公式原始碼",
            ]
        case .drawers: ["서랍"]
        case .properties: ["속성 서랍"]
        case .archived:
            [
                "Arborescences archivées", "Entire Tree", "Toute l’arborescence", "본문 포함", "包含正文", "包含內文",
                "Heading Only", "見出しだけ",
            ]
        case .timestamps:
            [
                "Standalone Timestamps", "Alleinstehende Zeitstempel", "Active Only", "Actifs uniquement", "仅活动时间戳",
                "僅作用中時間戳記", "Inactive Only",
                "Inactifs uniquement", "仅非活动时间戳", "僅非作用中時間戳記",
            ]
        case .clocks: ["Arbeitszeitprotokolle"]
        case .preserveBreaks: ["Conservar los saltos de línea", "Conserver les sauts de ligne"]
        default: []
        }
    }

    private static func shortcut(_ operation: ShortcutOperation) -> SettingsSearchRow {
        .init(
            .keyboardShortcuts, ShortcutText.nameResource(operation.id).key, anchor: operation.id.rawValue,
            words: operation.isGlobal ? ["Global"] : [])
    }

    static func search(
        _ query: String, in rows: [SettingsSearchRow],
        localize: (String) -> String = { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) }
    ) -> SettingsSearchResults {
        typealias Rank = SettingsSearchResults.Rank
        let needle = folded(query)
        guard !needle.isEmpty else { return SettingsSearchResults() }
        var labels: [String: Rank.Match] = [:]
        var misses: Set<String> = []
        func match(_ key: String) -> Rank.Match? {
            if let cached = labels[key] { return cached }
            if misses.contains(key) { return nil }
            let spellings = [folded(key), folded(localize(key))]
            let result: Rank.Match
            if spellings.contains(needle) {
                result = .exact
            } else if spellings.contains(where: { $0.hasPrefix(needle) }) {
                result = .prefix
            } else if spellings.contains(where: { $0.contains(needle) }) {
                result = .substring
            } else {
                misses.insert(key)
                return nil
            }
            labels[key] = result
            return result
        }

        var results = SettingsSearchResults()
        for row in rows {
            let rank: Rank
            if row.identifiers.contains(needle) {
                rank = Rank(source: .identifier, match: .exact)
            } else if let quality = row.format.flatMap({ match(DocumentsChapter.title($0)) }) {
                rank = Rank(source: .section, match: quality)
            } else if match(row.section.rawValue) != nil {
                rank = Rank(source: .section, match: .exact)
            } else {
                let isCommand = row.section == .keyboardShortcuts || row.section == .toolbarArrangement
                let quality: Rank.Match
                if let heading = row.heading.flatMap({ match($0) }) {
                    quality = min(heading, match(row.label) ?? heading)
                } else if let label = match(row.label) {
                    quality = label
                } else if row.words.contains(where: { match($0) != nil })
                    || (row.format != nil && needle.count >= 3 && row.identifiers.contains { $0.contains(needle) })
                {
                    quality = .keyword
                } else {
                    continue
                }
                rank = Rank(source: isCommand ? .command : .setting, match: quality)
            }
            if let format = row.format { results.documentMatches[format, default: []].append((row.anchor, rank)) }
            results.rows.append(row)
            results.ranks[row.section] = min(results.ranks[row.section] ?? rank, rank)
        }
        return results
    }

    private static func folded(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        guard folded.unicodeScalars.contains(where: { (0x3041...0x309F).contains($0.value) }) else { return folded }
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }
}
