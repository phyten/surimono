import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct SmartRemovalWebTests {
    private func fixture() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "smart-removal", withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("主本文と別記事を残し長いCookie通知などの不要部分を除去して選んだ部分を復元できる", .timeLimit(.minutes(1)))
    func removesAndKeeps() async throws {
        _ = NSApplication.shared
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"), smartRemoval: SmartRemovalRequest())
        let source = DocumentSource(data: Data(try fixture().utf8), format: .html)
        let renderer = DocumentRenderer()
        let removed = try await renderer.render(source, settings: settings)
        #expect(
            removed.smartRemovalCandidates.map(\.category) == [
                .stickyHeader, .advertisement, .socialButtons, .newsletter, .relatedLinks, .cookieBanner,
            ])
        #expect(
            removed.smartRemovalCandidates.map(\.id) == [
                "#site-header", "#ad-slot", "#share", "#newsletter", "#related", "#cookie",
            ])
        #expect(removed.logicalDocument.string?.contains("The paper garden blooms under an imaginary moon.") == true)
        #expect(removed.smartRemovalCandidates.contains { $0.id == "#advertising" } == false)
        #expect(removed.logicalDocument.string?.contains("Advertising economics") == true)
        #expect(removed.logicalDocument.string?.contains("Our fictional study follows the cost") == true)
        #expect(removed.smartRemovalCandidates.contains { $0.id == "#advertising-history" } == false)
        #expect(
            removed.logicalDocument.string?.contains("The paper village once printed notices on folded leaves.") == true
        )
        #expect(removed.logicalDocument.string?.contains("AD-MARKER") == false)
        #expect(removed.logicalDocument.string?.contains("RELATED-MARKER") == false)
        #expect(removed.logicalDocument.string?.contains("COOKIE-MARKER") == false)
        #expect(removed.logicalDocument.string?.contains("NEWSLETTER-MARKER") == false)
        settings.smartRemoval?.keptIDs = ["#newsletter"]
        let kept = try await renderer.render(source, settings: settings)
        #expect(kept.smartRemovalCandidates == removed.smartRemovalCandidates)
        #expect(kept.logicalDocument.string?.contains("NEWSLETTER-MARKER") == true)
        #expect(kept.logicalDocument.string?.contains("COOKIE-MARKER") == false)
    }

    @Test("隣り合うボタンの抜粋は、語の間を空けて並べる", .timeLimit(.minutes(1)))
    func excerptSeparatesAdjacentButtons() async throws {
        _ = NSApplication.shared
        let html = """
            <html><body><article><h1>Paper notes</h1>
            <p>A fictional note about folding paper into small books for friends and neighbours.</p>
            <p>Each page is cut, folded and stitched by hand before the weekend market opens.</p></article>
            <div id="share" class="share-buttons"><button>Share</button><button>Read later</button></div>
            </body></html>
            """
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"), smartRemoval: SmartRemovalRequest())
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(html.utf8), format: .html), settings: settings)
        let share = try #require(result.smartRemovalCandidates.first { $0.id == "#share" })
        #expect(share.excerpt == "Share Read later")
    }

    @Test("URL の記事を紙に組み、相対リンク、本文、プリセットとスマート削除の結果を PDF で確かめる", .timeLimit(.minutes(1)))
    func downloadedPaper() async throws {
        _ = NSApplication.shared
        let base = URL(string: "https://fixture.invalid/news/article.html")!
        let original = try fixture()
        let html = original.replacingOccurrences(
            of: "<h1>A garden made of paper</h1>",
            with: "<h1>A garden made of paper</h1><a href='next.html'>Read more</a><p class='omit'>PRESET-MARKER</p>")
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "article", name: "Article"), smartRemoval: SmartRemovalRequest())
        settings.preset.removeSelectors = [".omit"]
        let source = DocumentSource(data: Data(html.utf8), format: .html, htmlBaseURL: base)
        let result = try await DocumentRenderer().render(source, settings: settings)
        let pdf = result.logicalDocument
        let text = try #require(pdf.string)
        #expect(text.contains("A garden made of paper"))
        #expect(!text.contains("PRESET-MARKER"))
        #expect(!text.contains("COOKIE-MARKER"))
        #expect(result.smartRemovalCandidates.contains { $0.id == "#cookie" })
        let links = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }
        #expect(
            links.contains {
                (($0.action as? PDFActionURL)?.url ?? $0.url)?.absoluteString
                    == "https://fixture.invalid/news/next.html"
            })
    }

    @Test("本文を段落から見つけ確認モードでは残す部分を別の輪郭で示す", .timeLimit(.minutes(1)))
    func reviewsWithoutRemoval() async throws {
        _ = NSApplication.shared
        let html = try fixture().replacingOccurrences(of: "<article", with: "<div")
            .replacingOccurrences(of: "</article>", with: "</div>")
            .replacingOccurrences(of: "id=\"share\"", with: "")
        let script = SmartRemovalScript.javaScript(
            for: SmartRemovalRequest(keptIDs: ["#newsletter"], highlightsCandidates: true))
        let inspection = """
            const candidates = (() => { \(script) })();
            return JSON.stringify({
              candidates: JSON.parse(candidates),
              cookieOutline: document.getElementById('cookie').style.outlineStyle,
              keptOutline: document.getElementById('newsletter').style.outlineStyle,
              storyOutline: document.getElementById('story').style.outlineStyle,
              historyOutline: document.getElementById('advertising-history').style.outlineStyle
            });
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595.28, height: 841.89),
            margins: .uniform(millimeters: 15), allowsJavaScript: false, preparationScript: inspection)
        let json = try #require(result.preparationResult)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["candidates"] as? [Any])?.count == 6)
        let candidates = try #require(object["candidates"] as? [[String: Any]])
        #expect(candidates[2]["id"] as? String == "body > div:nth-of-type(1) > div:nth-of-type(1)")
        #expect(object["cookieOutline"] as? String == "dashed")
        #expect(object["keptOutline"] as? String == "solid")
        #expect(object["storyOutline"] as? String == "")
        #expect(object["historyOutline"] as? String == "")
        #expect(result.document.string?.contains("The paper village once printed notices on folded leaves.") == true)
        #expect(result.document.string?.contains("COOKIE-MARKER") == true)
        #expect(result.document.string?.contains("NEWSLETTER-MARKER") == true)
        #expect(result.document.string?.contains("The paper garden blooms under an imaginary moon.") == true)
    }

    @Test("主本文の外でも広告を含む文章は残し自身が広告枠やダイアログの文章だけを候補にする", .timeLimit(.minutes(1)))
    func protectsOutsideProseUnlessItHasOwnWidgetEvidence() async throws {
        _ = NSApplication.shared
        let prose = """
            The imaginary village prints its history on folded paper leaves.
            Each fictional chapter describes how the gardeners share their tools and preserve the old stories.
            Readers compare the chapters and discuss the different ways to care for a garden made entirely of paper.
            """
        let html = """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; style-src 'unsafe-inline'; frame-src 'none'">
              <style>
                body { font: 12px sans-serif; }
                iframe { width: 100px; height: 20px; }
                dialog { position: static; margin: 0; }
              </style>
            </head>
            <body>
              <main id="story"><h1>The paper village</h1><p>A fictional gardener folds a new leaf.</p></main>
              <section id="essay">
                <h2>A separate essay</h2>
                <p>The essay keeps its own voice. \(prose)</p>
                <div id="frame-holder">
                  <iframe title="Advertisement" src="https://ads.doubleclick.net/fictional"></iframe>
                </div>
              </section>
              <section id="placement" class="ad-slot"><h2>A fictional placement</h2><p>\(prose)</p></section>
              <dialog open id="notice"><h2>A fictional notice</h2><p>\(prose)</p></dialog>
              <div role="dialog" id="notice-role"><h2>Another fictional notice</h2><p>\(prose)</p></div>
            </body>
            </html>
            """
        let script = SmartRemovalScript.javaScript(for: SmartRemovalRequest())
        let preparation = """
            const candidates = (() => { \(script) })();
            return candidates;
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595.28, height: 841.89),
            margins: .uniform(millimeters: 15), allowsJavaScript: false, preparationScript: preparation)
        let json = try #require(result.preparationResult)
        let candidates = SmartRemovalScript.candidates(fromJSON: json)
        #expect(candidates.map(\.id) == ["#frame-holder", "#placement", "#notice", "#notice-role"])
        #expect(candidates.map(\.category) == [.advertisement, .advertisement, .popup, .popup])
        #expect(!candidates.contains { $0.id == "#essay" })
        let output = try #require(result.document.string)
        #expect(output.contains("The essay keeps its own voice."))
        #expect(output.contains("A fictional gardener folds a new leaf."))
        #expect(!output.contains("A fictional placement"))
        #expect(!output.contains("A fictional notice"))
        #expect(!output.contains("Another fictional notice"))
    }
}
