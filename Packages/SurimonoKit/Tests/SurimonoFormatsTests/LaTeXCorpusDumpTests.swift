import LaTeXCorpusSupport
import Testing

@testable import SurimonoFormats

struct LaTeXCorpusDumpTests {
    // Private furniture state also affects later pages. Sort unordered containers while preserving array order.
    private func stable(_ value: Any) -> String {
        if let string = value as? String { return string.debugDescription }
        let mirror = Mirror(reflecting: value)
        let fields = mirror.children.map { child in
            (child.label.map { $0 + "=" } ?? "") + stable(child.value)
        }
        switch mirror.displayStyle {
        case .optional: return fields.first ?? "nil"
        case .dictionary, .set: return "[" + fields.sorted().joined(separator: ",") + "]"
        case .struct, .tuple, .collection: return "[" + fields.joined(separator: ",") + "]"
        default: return String(describing: value)
        }
    }

    @Test("コーパスの本文と組版の各項目を書き出す")
    func typesetting() throws {
        try LaTeXCorpus.dump(extension: "txt") { fragment in
            let info = try #require(fragment.latexClass)
            let computed: [(String, Any)] = [
                ("pageBox", info.pageBox), ("textWidth", info.pageBox.textWidth),
                ("textHeight", info.pageBox.textHeight),
                ("isJSArticle", info.isJSArticle), ("spacingPointSize", info.spacingPointSize),
                ("pageHeadFont", info.pageHeadFont as Any), ("pageNumberFont", info.pageNumberFont as Any),
                ("journalFrontMatter", info.journalFrontMatter), ("label", info.pageNumbers.label),
                ("header", info.pageNumbers.header), ("footer", info.pageNumbers.footer),
                ("needsExamTotals", info.pageNumbers.needsExamTotals), ("showsFooter", info.pageNumbers.showsFooter),
                ("needsRunningMarks", info.pageNumbers.needsRunningMarks),
                ("usesClassPlain", info.pageNumbers.usesClassPlain),
                ("usesFancyFields", info.pageNumbers.usesFancyFields), ("body", fragment.body),
            ]
            let fields: [(String, Any)] = [
                ("name", info.name as Any),
                ("isJapanese", info.isJapanese as Any),
                ("usesAMSA4Layout", info.usesAMSA4Layout as Any),
                ("hidesTitlePageNumber", info.hidesTitlePageNumber as Any),
                ("hasChapters", info.hasChapters as Any),
                ("styleVariables", info.styleVariables as Any),
                ("localFontFaces", info.localFontFaces as Any),
                ("pageNumbers", info.pageNumbers as Any),
                ("mainFontName", info.mainFontName as Any),
                ("columns", info.columns as Any),
                ("hasSeparateTitlePage", info.hasSeparateTitlePage as Any),
                ("usesJSChapterSpacing", info.usesJSChapterSpacing as Any),
                ("jsMagnification", info.jsMagnification as Any),
                ("japaneseMainFontName", info.japaneseMainFontName as Any),
                ("headerStrutDepth", info.headerStrutDepth as Any),
                ("pointSize", info.pointSize as Any),
                ("mainLanguage", info.mainLanguage as Any),
                ("resolvedPageBox", info.resolvedPageBox as Any),
                ("usesNativeCJKHeadings", info.usesNativeCJKHeadings as Any),
                ("journalStyle", info.journalStyle as Any),
                ("publication", info.publication as Any),
                ("bookStyle", info.bookStyle as Any),
                ("isKOMA", info.isKOMA as Any),
                ("usesTraditionalJapaneseNames", info.usesTraditionalJapaneseNames as Any),
            ]
            return (fields + computed).sorted { $0.0 < $1.0 }.map { $0 + "=" + stable($1) }.joined(separator: "\n")
                + "\n"
        }
    }
}
