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

    @Test("今の状態の写しは文書型つきの HTML と閉じた折りたたみの数を JSON で返す")
    func snapshotReturnsDocument() {
        let script = HTMLSnapshotScript.javaScript
        #expect(script.contains("JSON.stringify({ html: doctype + copy.outerHTML, closedDetails })"))
    }

    @Test("写しの結果から HTML と閉じた折りたたみの数を読む")
    func snapshotResult() {
        let snapshot = HTMLSnapshot(scriptResult: #"{"html":"<!DOCTYPE html><p>Now</p>","closedDetails":3}"#)
        #expect(snapshot == HTMLSnapshot(html: "<!DOCTYPE html><p>Now</p>", closedDetailsCount: 3))
    }

    @Test("写しの結果として読めない値は写しにしない", arguments: ["", "<p>Now</p>", #"{"html":"<p>Now</p>"}"#, "[]"])
    func invalidSnapshotResult(_ value: String) {
        #expect(HTMLSnapshot(scriptResult: value) == nil)
    }

    @Test("折りたたみを開く処理は名前つきの組を外してから全部を開く")
    func openDetailsScript() throws {
        let script = HTMLSnapshotScript.openDetailsJavaScript
        let ungroup = try #require(script.range(of: "removeAttribute('name')"))
        let open = try #require(script.range(of: "details.open = true"))
        #expect(ungroup.upperBound <= open.lowerBound)
        #expect(!script.contains("return"))
    }
}
