import SurimonoRendering
import Testing

struct RenderingStageTests {
    @Test("描画モジュールが未実装であることを明示する")
    func reportsFoundationStage() {
        #expect(RenderingStage.current == .foundation)
    }
}
