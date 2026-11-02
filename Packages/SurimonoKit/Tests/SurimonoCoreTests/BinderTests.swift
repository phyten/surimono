import Foundation
import SurimonoCore
import Testing

struct BinderTests {
    @Test("合本の鍵は順序によらず画像の束とは異なり重複を数える")
    func hash() {
        let a = ContentHash.of(Data("a".utf8))
        let b = ContentHash.of(Data("b".utf8))
        #expect(ContentHash.binderSet([a, b]) == ContentHash.binderSet([b, a]))
        #expect(ContentHash.binderSet([a, b]) != ContentHash.imageSet([a, b]))
        #expect(ContentHash.binderSet([a, a, b]) != ContentHash.binderSet([a, b]))
    }

    @Test("表面開始は奇数枚の文書の後ろだけに白紙を入れ最後には足さない")
    func starts() {
        #expect(BinderPagination.offsets(pageCounts: [1, 2, 1], startsOnFront: false) == [0, 1, 3])
        #expect(BinderPagination.offsets(pageCounts: [1, 2, 1], startsOnFront: true) == [0, 2, 4])
        #expect(BinderPagination.offsets(pageCounts: [3, 0, 1, 2], startsOnFront: true) == [0, 3, 4, 6])
        #expect(BinderPagination.offsets(pageCounts: [], startsOnFront: true).isEmpty)
    }

    @Test("合本の並び順と表面開始を保存し古い設定や不正な値も読める")
    func settings() throws {
        let saved = DocumentSettings(binderOrder: ["b", "a"], binderStartsOnFront: true)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: data) == saved)
        let old = try JSONDecoder().decode(DocumentSettings.self, from: Data("{}".utf8))
        #expect(old.binderStartsOnFront == nil)
        let invalid = try JSONDecoder().decode(
            DocumentSettings.self, from: Data(#"{"binderOrder":42,"binderStartsOnFront":"yes","zoom":2}"#.utf8))
        #expect(invalid.binderOrder == nil)
        #expect(invalid.binderStartsOnFront == nil)
        #expect(invalid.zoom == 2)
        #expect(ImageOrder.apply(["b", "a", "a"], to: ["a", "b", "a"], digest: { $0 }) == ["b", "a", "a"])
    }
}
