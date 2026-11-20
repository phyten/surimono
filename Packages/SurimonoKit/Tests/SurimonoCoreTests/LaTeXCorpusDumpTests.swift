import LaTeXCorpusSupport
import SurimonoCore
import Testing

struct LaTeXCorpusDumpTests {
    @Test("コーパスの既定スタイルによる HTML 全文を書き出す")
    func html() throws {
        var themes: [PrintTheme]?
        try LaTeXCorpus.dump(extension: "html") { fragment in
            if themes == nil { themes = try PrintThemeLibrary.load() }
            let info = try #require(fragment.latexClass)
            let id = PrintThemeLibrary.defaultLaTeXStyle(for: info)
            let theme = try #require(themes?.first { $0.id == id })
            return HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        }
    }
}
