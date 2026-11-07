import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

/// Lining the comparison stage's pages up on one heading or code block.
@MainActor
struct ComparePlaceTests {
    private let text = """
        # 星見図書室

        ## 借り方

        本を借りる手順です。

        ## 返し方

        本を返す手順です。

        ```
        let book = 1
        ```
        """

    private func model(_ suite: TestDefaultsSuite) -> DocumentViewModel {
        DocumentViewModel(
            data: Data(text.utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        )
    }

    @Test("文書の見出しとコードを、比べる箇所として読み取る", .timeLimit(.minutes(1)))
    func readsThePlaces() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        await model.followComparePlaces()
        #expect(model.themeSamples.places.map(\.title) == ["星見図書室", "借り方", "返し方", "let book = 1"])
    }

    @Test("箇所の見本は 1 ページ目の見本とは別に描き、箇所を変えても 1 ページ目は描き直さない", .timeLimit(.minutes(1)))
    func samplesByPlace() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        let standard = try #require(model.theme("standard"))
        await model.followComparePlaces()
        let place = try #require(model.themeSamples.places.first { $0.title == "返し方" })

        await model.themeSamples.load(standard)
        let first = try #require(model.themeSamples.page(for: standard))
        #expect(model.themeSamples.page(for: standard, at: place) == nil)
        #expect(model.themeSamples.taskID(for: standard, at: place) != model.themeSamples.taskID(for: standard))

        await model.themeSamples.load(standard, at: place)
        let sample = try #require(model.themeSamples.page(for: standard, at: place))
        #expect(sample.string?.hasPrefix("返し方") == true)
        #expect(model.themeSamples.page(for: standard) === first)
    }

    @Test("文書が変わると、選んだ箇所は同じ言葉の箇所へ移る", .timeLimit(.minutes(1)))
    func followsTheWords() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        await model.followComparePlaces()
        model.comparePlace = try #require(model.themeSamples.places.first { $0.title == "返し方" })

        model.replaceContent(Data(("# 目次\n\n" + text).utf8), format: .markdown)
        await model.followComparePlaces()
        #expect(model.comparePlace?.title == "返し方")
        #expect(model.comparePlace?.index == 3)
    }

    @Test("選んだ箇所の言葉がなくなると、1 ページ目に戻る", .timeLimit(.minutes(1)))
    func goneWordsGoBackToTheFirstPage() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        await model.followComparePlaces()
        model.comparePlace = try #require(model.themeSamples.places.first { $0.title == "返し方" })

        model.replaceContent(Data("# 星見図書室\n\n本文だけになりました。".utf8), format: .markdown)
        await model.followComparePlaces()
        #expect(model.comparePlace == nil)
        #expect(model.themeSamples.places.map(\.title) == ["星見図書室"])
    }

    @Test("箇所を読み直している途中で見比べ台を出ても、選んだ箇所と一覧は消えない", .timeLimit(.minutes(1)))
    func cancelledReadingKeepsThePlace() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        let standard = try #require(model.theme("standard"))
        await model.followComparePlaces()
        let place = try #require(model.themeSamples.places.first { $0.title == "返し方" })
        model.comparePlace = place

        // A sample is being drawn from the new text, so reading the places has to wait for it, and is given up there.
        model.replaceContent(Data(("# 目次\n\n" + text).utf8), format: .markdown)
        let drawing = Task { await model.themeSamples.load(standard) }
        let reading = Task { await model.followComparePlaces() }
        reading.cancel()
        await reading.value
        await drawing.value
        #expect(model.comparePlace == place)
        #expect(!model.themeSamples.places.isEmpty)
    }

    @Test("見比べ台を出ると箇所の一覧は閉じ、選んだ箇所は窓のあいだ残る", .timeLimit(.minutes(1)))
    func keepsThePlaceWhileTheWindowLives() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = model(suite)
        await model.followComparePlaces()
        let place = try #require(model.themeSamples.places.last)
        model.comparePlace = place
        model.mode = .compare
        model.isComparePlacePickerPresented = true

        model.exitCompareMode()
        #expect(!model.isComparePlacePickerPresented)
        #expect(model.comparePlace == place)
    }
}
