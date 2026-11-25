import SurimonoCore
import Testing

struct PreviewPrintRequestTests {
    @Test("先頭だけのページ数にプラスを添え、全文の総数に切り替える")
    func indicator() {
        #expect(PageIndicator.text(pages: [1], pageCount: 53, provisional: true) == "1 / 53+")
        #expect(PageIndicator.text(pages: [1], pageCount: 16_194) == "1 / 16194")
        #expect(PageIndicator.text(pages: [2, 3], pageCount: 53, provisional: true) == "2–3 / 53+")
    }

    @Test("印刷とレイアウトの再操作で待機を取り消し、完成時は一度だけ選択を受け取る")
    func toggleAndFulfill() {
        var request = PreviewPrintRequest()
        request.press(.currentLayout)
        #expect(request.destination == .currentLayout)
        request.press(.layout("booklet"))
        #expect(request.take() == nil)
        request.press(.layout("booklet"))
        #expect(request.take() == .layout("booklet"))
        #expect(request.take() == nil)
    }

    @Test("Esc・閉じる・読み直し・失敗で取り消した要求は、後から完成しても実行しない")
    func drop() {
        var request = PreviewPrintRequest()
        request.press(.currentLayout)
        request.cancel()
        #expect(request.destination == nil && request.take() == nil)
    }
}
