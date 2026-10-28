import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ImageBundleModelTests {
    private let urls = ["富士.jpg", "2.png", "10.png"].map { URL(fileURLWithPath: "/fixtures/" + $0) }

    @Test("ドラッグによる並び替えを描画要求の順番に反映する")
    func move() async throws {
        let model = ImageBundleModel(urls: urls, readImage: { Data($0.lastPathComponent.utf8) })
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        let source = try await model.source()
        #expect(source.images?.map(\.fileURL) == [urls[1], urls[2], urls[0]])
        #expect(source.images?.first?.data == Data("2.png".utf8))
    }

    @Test("選択画像を前後へ動かし先頭と末尾では動かさない")
    func keyboard() {
        let model = ImageBundleModel(urls: urls)
        model.selection = urls[0]
        #expect(!model.canMoveSelection(by: -1))
        model.moveSelection(by: -1)
        #expect(model.urls == urls)
        model.moveSelection(by: 1)
        #expect(model.urls == [urls[1], urls[0], urls[2]])
        #expect(model.selection == urls[0])
        model.moveSelection(by: 1)
        #expect(!model.canMoveSelection(by: 1))
        model.moveSelection(by: 1)
        #expect(model.urls == [urls[1], urls[2], urls[0]])
        model.selection = nil
        #expect(!model.canMoveSelection(by: -1))
    }

    @Test("タイトルと書き出し名は枚数と現在の先頭画像とレイアウトを含む")
    func names() {
        let model = ImageBundleModel(urls: urls)
        #expect(model.title(language: "ja") == "画像 3 枚 — 富士.jpg")
        #expect(model.title(language: "en") == "3 images — 富士.jpg")
        #expect(model.exportName(layout: .a4Single, language: "ja") == "富士 ほか 2 枚（A4 片面）.pdf")
        #expect(model.exportName(layout: .a4Single, language: "en") == "富士 and 2 more（A4 Single-sided）.pdf")
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(model.title(language: "ja") == "画像 3 枚 — 2.png")
    }

    @Test("画像の束の全URLをPDFとスナップショット共通の原本保護に含める")
    func protectedSources() throws {
        let suite = "SurimonoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = UserLibrary(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image,
            preferences: AppPreferences(defaults: defaults), library: library, imageBundle: ImageBundleModel(urls: urls)
        )
        for url in urls {
            #expect(!DocumentViewModel.canExport(to: url, sourceURLs: model.protectedSourceURLs))
        }
        #expect(
            DocumentViewModel.canExport(
                to: URL(fileURLWithPath: "/fixtures/export.pdf"),
                sourceURLs: model.protectedSourceURLs))
    }

    @Test("読み取りに失敗してもURLを描画へ渡して失敗した名前を保持できる")
    func failedRead() async throws {
        let model = ImageBundleModel(urls: urls, readImage: { _ in throw CocoaError(.fileReadNoPermission) })
        let source = try await model.source()
        #expect(source.images?.map(\.fileURL) == urls)
        #expect(source.images?.allSatisfy { $0.data.isEmpty } == true)
    }
}
