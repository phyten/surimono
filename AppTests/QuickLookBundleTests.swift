import Foundation
import Testing

struct QuickLookBundleTests {
    @Test("アプリにデータ方式の Quick Look 拡張を埋め込み、対応する文書の型だけを登録する")
    func embeddedProvider() throws {
        let host = Bundle.main
        let plugins = try #require(host.builtInPlugInsURL)
        let bundle = try #require(Bundle(url: plugins.appendingPathComponent("SurimonoQuickLook.appex")))
        let identifier = try #require(host.bundleIdentifier)
        #expect(bundle.bundleIdentifier == identifier + ".QuickLook")
        let info = try #require(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        #expect(info["NSExtensionPointIdentifier"] as? String == "com.apple.quicklook.preview")
        #expect(info["NSExtensionPrincipalClass"] as? String == "SurimonoQuickLook.PreviewProvider")
        let attributes = try #require(info["NSExtensionAttributes"] as? [String: Any])
        #expect(attributes["QLIsDataBasedPreview"] as? Bool == true)
        let identifiers = try #require(attributes["QLSupportedContentTypes"] as? [String])
        let expected: Set<String> = [
            "net.daringfireball.markdown", "org.orgmode.org", "app.surimono.restructuredtext", "org.tug.tex",
            "org.jupyter.ipynb", "org.quarto.qmarkdown", "org.rstudio.rmarkdown",
        ]
        #expect(Set(identifiers) == expected && identifiers.count == expected.count)
        // Bundle.module in the provider resolves resources relative to the extension.
        for (name, resource, suffix) in [
            ("SurimonoKit_SurimonoCore", "standard", "css"),
            ("SurimonoKit_SurimonoFormats", "SurimonoMathMain-Regular", "otf"),
        ] {
            let resourceURL = try #require(bundle.url(forResource: name, withExtension: "bundle"))
            let resources = try #require(Bundle(url: resourceURL))
            #expect(resources.url(forResource: resource, withExtension: suffix) != nil)
        }
        #expect(Set(bundle.localizations).isSuperset(of: ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"]))
    }
}
