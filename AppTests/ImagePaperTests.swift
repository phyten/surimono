import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ImagePaperTests {
    @Test(
        "余白0の画像は、印刷レイアウトによらず表示モードの紙と窓が画像の形になる", .timeLimit(.minutes(1)),
        arguments: [PrintLayout.a4Single, .a4BookletA5, .a4Handout3])
    func imagePaperHasImageShape(layout: PrintLayout) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: TestFixtures.png(red: 1), fileURL: nil, format: .image,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        model.layoutID = layout.id
        model.printOptions.marginsInMillimeters = 0
        model.render()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }

        // A 4:3 image up the height of landscape A4 (595.28 pt), without the paper left and right of it.
        let size = try #require(model.paperUnitSize)
        #expect(abs(size.width - 793.71) < 0.1)
        #expect(abs(size.height - 595.28) < 0.1)
        let page = try #require(model.paperDocument?.page(at: 0))
        #expect(abs(page.bounds(for: .cropBox).width - 793.71) < 0.1)
        let printed = try #require(model.result?.logicalDocument.page(at: 0))
        #expect(abs(printed.bounds(for: .cropBox).width - 841.89) < 0.1)
    }
}
