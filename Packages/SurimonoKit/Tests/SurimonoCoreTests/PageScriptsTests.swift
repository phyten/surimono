import SurimonoCore
import Testing

struct PageScriptsTests {
    @Test("紙面の整えは値を返さず、後に続くプリセットの処理を止めない")
    func paperCleanupReturnsNothing() {
        let script = PaperCleanupScript.javaScript
        #expect(!script.contains("return"))
        #expect(script.hasPrefix("{"))
    }

    @Test("紙面の整えは追従と画面の高さを直し、印刷の指定と @page には触れない")
    func paperCleanupLeavesPrintRules() {
        let script = PaperCleanupScript.javaScript
        #expect(script.contains("'static'"))
        #expect(script.contains("'auto'"))
        #expect(script.contains(#"/\bprint\b/i"#))
        #expect(script.contains("PAGE_RULE"))
    }

    @Test("前の処理の後で紙面を整え、前の処理の結果を返す")
    func cleanupFollowsAScript() throws {
        let script = PaperCleanupScript.following("return 'found';")
        let body = try #require(script.range(of: "return 'found';"))
        let cleanup = try #require(script.range(of: PaperCleanupScript.javaScript))
        #expect(body.upperBound <= cleanup.lowerBound)
        #expect(script.hasSuffix("return surimonoPreparationResult;"))
    }

    @Test("今の状態の写しは文書型つきの HTML を返す")
    func snapshotReturnsDocument() {
        let script = HTMLSnapshotScript.javaScript
        #expect(script.contains("return doctype + copy.outerHTML;"))
    }
}
