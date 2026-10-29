import AppKit
import Foundation
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

    @Test("広告についての本文を残し広告枠と関連記事カードを除去して選んだ部分を復元できる", .timeLimit(.minutes(1)))
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
              storyOutline: document.getElementById('story').style.outlineStyle
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
        #expect(result.document.string?.contains("COOKIE-MARKER") == true)
        #expect(result.document.string?.contains("NEWSLETTER-MARKER") == true)
        #expect(result.document.string?.contains("The paper garden blooms under an imaginary moon.") == true)
    }
}
