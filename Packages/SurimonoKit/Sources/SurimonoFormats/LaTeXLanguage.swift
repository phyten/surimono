import Foundation

/// Babel's caption identifiers also name ordinary control words in the source.
enum LaTeXLanguage {
    static let captions: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "latex-captions", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let names = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return names
    }()

    private static let aliases = [
        "english": "en", "american": "en-US", "usenglish": "en-US", "americanenglish": "en-US",
        "british": "en-GB", "ukenglish": "en-GB", "britishenglish": "en-GB",
        "ngerman": "de", "german": "de", "french": "fr", "frenchb": "fr", "francais": "fr",
        "spanish": "es", "italian": "it", "portuguese": "pt", "portuges": "pt", "brazil": "pt-BR",
        "brazilian": "pt-BR", "brazilianportuguese": "pt-BR", "dutch": "nl", "russian": "ru",
        "ukrainian": "uk", "polish": "pl", "czech": "cs", "swedish": "sv", "turkish": "tr",
        "greek": "el", "monotonicgreek": "el", "arabic": "ar", "hebrew": "he", "japanese": "ja",
        "korean": "ko", "chinese": "zh-Hans", "zh": "zh-Hans", "chinese-simplified": "zh-Hans",
        "chinese-hans": "zh-Hans", "simplifiedchinese": "zh-Hans", "zh-cn": "zh-Hans",
        "chinese-traditional": "zh-Hant", "chinese-hant": "zh-Hant", "traditionalchinese": "zh-Hant",
        "zh-tw": "zh-Hant",
    ]

    static func tag(_ language: String, options: String = "") -> String? {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let options = options.lowercased()
        if key == "english" && options.contains("british") { return "en-GB" }
        if key == "english" && options.contains("american") { return "en-US" }
        if key == "portuguese" && options.contains("brazil") { return "pt-BR" }
        if key == "chinese" && (options.contains("traditional") || options.contains("hant")) { return "zh-Hant" }
        return aliases[key] ?? captions.keys.first { $0.lowercased() == key }
    }

    static func attributes(_ tag: String) -> String {
        let direction = tag == "ar" || tag == "he" ? "rtl" : "ltr"
        return "lang=\"\(tag)\" dir=\"\(direction)\""
    }

    // csquotes.def supplies distinct inner quotation marks for nested quotations.
    static func quotes(_ tag: String, inner: Bool) -> (String, String) {
        switch tag {
        case "de", "cs": return inner ? ("‚", "‘") : ("„", "“")
        case "pl": return inner ? ("«", "»") : ("„", "”")
        case "fr": return inner ? ("“", "”") : ("«\u{00A0}", "\u{00A0}»")
        case "ru", "uk": return inner ? ("„", "“") : ("«", "»")
        case "es", "it", "pt", "pt-PT", "el", "ar": return inner ? ("“", "”") : ("«", "»")
        case "en-GB": return inner ? ("“", "”") : ("‘", "’")
        case "ja", "zh-Hant": return inner ? ("『", "』") : ("「", "」")
        case "sv": return inner ? ("’", "’") : ("”", "”")
        case "he": return inner ? ("׳", "׳") : ("״", "״")
        default: return inner ? ("‘", "’") : ("“", "”")
        }
    }

    static func today(_ tag: String, date: Date = Date(), classicBabel: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: tag)
        formatter.calendar = Calendar(identifier: .gregorian)
        switch tag {
        case "en-GB" where classicBabel:
            let day = formatter.calendar.component(.day, from: date)
            let suffix = (11...13).contains(day) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
            formatter.dateFormat = "d'\(suffix)' MMMM y"
        case "en", "en-US": formatter.dateFormat = "MMMM d, y"
        case "de", "cs": formatter.dateFormat = "d. MMMM y"
        case "ja", "zh-Hant", "zh-Hans": formatter.dateFormat = "y年M月d日"
        case "ko": formatter.dateFormat = "y년 M월 d일"
        case "he": formatter.dateFormat = "d בMMMM y"
        case "ru": formatter.dateFormat = "d MMMM y 'г.'"
        case "uk": formatter.dateFormat = "d MMMM y 'р.'"
        case "es", "pt", "pt-PT", "pt-BR": formatter.dateFormat = "d 'de' MMMM 'de' y"
        case "fr" where formatter.calendar.component(.day, from: date) == 1: formatter.dateFormat = "d'er' MMMM y"
        default: formatter.dateFormat = "d MMMM y"
        }
        return formatter.string(from: date)
    }
}

extension LaTeXDocument {
    func setLocalizedCaption(_ value: String, name: String, language tag: String) {
        localizedCaptions[tag, default: [:]][name] = value
        if tag == language { macros[name] = nil }
    }

    func defaultCaption(_ name: String) -> String? {
        if language == "en" || language.hasPrefix("en-"), let label = classInfo.journalStyle?.englishLabel(name) {
            return label
        }
        if name == "lstlistingname" { return "Listing" }
        if name == "jsParagraphMark", let mark = classInfo.profile.headings.defaultParagraphMark { return mark }
        // jsclasses do not translate amsthm. A language package or a document macro can do so.
        if name == "proofname", language == "ja", !classicBabelLanguages.contains("ja"),
            let proofName = classInfo.profile.body.untranslatedProofName
        {
            return proofName
        }
        if classicBabelLanguages.contains(language) {
            if language == "es", hasChapters, name == "contentsname" { return "Índice general" }
            if language == "pl" {
                // The distributed polish.ldf and babel-pl.ini have different table, part and index names.
                let classic = [
                    "tablename": "Tabela", "listtablename": "Spis tabel", "indexname": "Skorowidz", "partname": "Część",
                ]
                if let value = classic[name] { return value }
            }
        }
        if language == nativeCaptionLanguage {
            if language == "ko" {
                let native = ["abstractname": "요약", "contentsname": "차례", "refname": "참고문헌", "bibname": "참고문헌"]
                if let value = native[name] { return value }
            } else if language == "zh-Hant" {
                let native = [
                    "abstractname": "摘要", "contentsname": "目錄", "refname": "參考文獻", "bibname": "參考文獻",
                    "appendixname": "附錄", "listfigurename": "插圖", "listtablename": "表格", "indexname": "索引",
                ]
                if let value = native[name] { return value }
            } else if classInfo.usesTraditionalJapaneseNames {
                // pLaTeX's jclasses.dtx uses inter-character spaces and a different book bibliography title.
                let native = [
                    "contentsname": "目 次", "listfigurename": "図 目 次", "listtablename": "表 目 次",
                    "bibname": "関連図書", "abstractname": "概 要", "appendixname": "付 録", "indexname": "索 引",
                ]
                if let value = native[name] { return value }
            }
        }
        return LaTeXLanguage.captions[language]?[name]
    }
}

extension LaTeXReader {
    func useMainLanguage(_ tag: String) {
        document.language = tag
        document.classInfo.mainLanguage = tag
    }

    func readLanguagePackages(_ packages: [String], options: [String]) {
        for package in packages {
            switch package {
            case "babel":
                let all = document.classLanguageOptions + options
                if all.contains("bidi=basic") { document.basicBidiTables = true }
                if !Set(all).isDisjoint(with: ["es-nosectiondot", "es-nolayout"]) {
                    document.spanishSectionDots = false
                }
                let main = all.last(where: { $0.hasPrefix("main=") }).map { String($0.dropFirst(5)) }
                document.classicBabelLanguages.formUnion(all.compactMap { LaTeXLanguage.tag($0) })
                if let tag = main.flatMap({ LaTeXLanguage.tag($0) }) ?? all.compactMap({ LaTeXLanguage.tag($0) }).last {
                    document.classicBabelLanguages.insert(tag)
                    useMainLanguage(tag)
                }
            case "ctex", "kotex":
                document.classInfo.usesNativeCJKHeadings = true
                let tag = package == "kotex" ? "ko" : options.contains("traditional") ? "zh-Hant" : "zh-Hans"
                document.nativeCaptionLanguage = tag
                useMainLanguage(tag)
            default: break
            }
        }
    }

    func captionName(_ name: String) -> String {
        inline("\\" + name)
    }

    func numberedHeading(_ name: String, number: String) -> String {
        let caption = captionName(name + "name")
        let number = HTML.escape(number)
        let label = document.classInfo.profile.headings.chapterLabel
        if label == .traditionalJapaneseNumber, name == "chapter", document.language == "ja" {
            // The explicit spaces share the searchable chapter label's text run.
            return "第 " + number + " " + caption
        }
        if label == .spacedJapaneseNumber || label == .traditionalJapaneseNumber,
            name == "chapter" || document.classInfo.profile.structure.formatsContentsChapterNames,
            document.language == "ja"
        {
            // LuaTeX-ja inserts a quarter-em xkanjiskip on both sides of the Western number.
            let skip = #"<span class="latex-xkanjiskip"> </span>"#
            if name == "appendix" { return caption + skip + number }
            return "第" + skip + number + skip + caption
        }
        if ["ja", "zh-Hans", "zh-Hant"].contains(document.language) {
            return name == "appendix" ? caption + number : "第" + number + caption
        }
        if document.language == "ko", name != "appendix" { return "제 " + number + " " + caption }
        return caption + " " + number
    }

    func handleLanguage(_ name: String) -> Bool {
        switch name {
        case "setdefaultlanguage", "setmainlanguage", "setotherlanguage", "babelprovide":
            let options = optional() ?? ""
            let value = argument() ?? ""
            let isMain =
                name != "setotherlanguage"
                && (name != "babelprovide"
                    || options.split(separator: ",").contains {
                        $0.trimmingCharacters(in: .whitespaces) == "main"
                    })
            if let tag = LaTeXLanguage.tag(value, options: options) {
                document.classicBabelLanguages.remove(tag)
                if isMain { useMainLanguage(tag) }
            }
        case "selectlanguage":
            if let tag = LaTeXLanguage.tag(argument() ?? "") {
                if inPreamble { useMainLanguage(tag) } else { switchTextLanguage(tag) }
            }
        case "foreignlanguage":
            _ = optional()
            let value = argument() ?? ""
            let body = argument() ?? ""
            appendHTML(localized(body, language: value, block: false))
        case "enquote":
            let inner = star() || !document.quoteDepth.isMultiple(of: 2)
            let marks = LaTeXLanguage.quotes(document.language, inner: inner)
            document.quoteDepth += 1
            let quoted = inline(argument() ?? "")
            document.quoteDepth -= 1
            appendHTML(marks.0 + quoted + marks.1)
        case "glqq": appendText("„")
        case "grqq": appendText("“")
        case "og": appendText("«\u{00A0}")
        case "fg": closeFrenchQuote()
        case "frenchspacing", "nonfrenchspacing":
            if inPreamble { document.requestsFrenchSpacing = name == "frenchspacing" }
        case "setlocalecaption":
            _ = star()
            let language = argument() ?? ""
            let key = argument() ?? ""
            let value = argument() ?? ""
            if let tag = LaTeXLanguage.tag(language), LaTeXLanguage.captions["en"]?[key + "name"] != nil {
                document.setLocalizedCaption(value, name: key + "name", language: tag)
            }
        case "addto", "gappto", "appto":
            let target = argument() ?? ""
            let body = argument() ?? ""
            let prefix = target.hasPrefix("\\date") ? "\\date" : "\\captions"
            if target.hasPrefix(prefix), let tag = LaTeXLanguage.tag(String(target.dropFirst(prefix.count))) {
                // Inspect only caption definitions. Hooks for other languages must not run arbitrary preamble code.
                let hook = LaTeXReader(body, document: document, isBlock: false)
                hook.skipSpaces()
                while hook.peek() == "\\" {
                    let command = hook.controlToken()
                    guard ["\\renewcommand", "\\newcommand", "\\providecommand", "\\def"].contains(command) else {
                        break
                    }
                    _ = hook.star()
                    let key = String((hook.argument() ?? "").dropFirst())
                    let value = hook.argument() ?? ""
                    if command != "\\providecommand", key == "today" || LaTeXLanguage.captions["en"]?[key] != nil {
                        document.setLocalizedCaption(value, name: key, language: tag)
                    }
                    hook.skipSpaces()
                }
            }
        case "ctexset":
            let options = argument()
            // ctex can select traditional names without selecting a different class or OS font set.
            if document.nativeCaptionLanguage == "zh-Hans",
                option("figurename", in: options) == "圖" || option("contentsname", in: options) == "目錄"
            {
                document.nativeCaptionLanguage = "zh-Hant"
                useMainLanguage("zh-Hant")
            }
            for key in LaTeXLanguage.captions["en"]?.keys ?? [:].keys {
                if let value = option(key, in: options) {
                    document.setLocalizedCaption(value, name: key, language: document.language)
                }
            }
        default:
            if let value = document.localizedCaptions[document.language]?[name] {
                insertExpansion(value)
            } else if let value = document.defaultCaption(name) {
                appendText(value)
            } else {
                return false
            }
        }
        return true
    }

    func localized(_ body: String, language: String, block: Bool) -> String {
        guard let tag = LaTeXLanguage.tag(language) else { return block ? blocks(body) : inline(body) }
        let previous = document.language
        document.language = tag
        defer { document.language = previous }
        let element = block ? "div" : "span"
        return "<\(element) \(LaTeXLanguage.attributes(tag))>" + (block ? blocks(body) : inline(body)) + "</\(element)>"
    }
}
