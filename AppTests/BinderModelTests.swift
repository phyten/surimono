import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct BinderModelTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixture/" + name) }

    @Test("合本を並べ替え取り除いて追加し名前順に戻せる")
    func editing() {
        let model = BinderModel(urls: [url("1.md"), url("2.pdf")])
        model.moveSelection(by: 1)
        #expect(model.urls == [url("2.pdf"), url("1.md")])
        model.removeSelection()
        #expect(model.urls == [url("2.pdf")])
        model.add([url("10.txt"), url("3.org"), url("2.pdf"), url("excluded.zip")])
        #expect(model.urls == [url("2.pdf"), url("3.org"), url("10.txt")])
        #expect(model.excludedURLs == [url("excluded.zip")])
        model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.urls.first == url("10.txt"))
        model.sortByName()
        #expect(model.urls == [url("2.pdf"), url("3.org"), url("10.txt")])
    }

    @Test("合本の鍵は順序に依らず内容で並び順を復元する")
    func restore() async throws {
        let model = BinderModel(urls: [url("1.md"), url("2.pdf")], read: { Data($0.lastPathComponent.utf8) })
        _ = try await model.source()
        let hash = model.setHash
        let order = try #require(model.orderDigests)
        model.moveSelection(by: 1)
        #expect(model.setHash == hash)
        #expect(model.applyOrder(order))
        #expect(model.urls == [url("1.md"), url("2.pdf")])
        #expect(!model.applyOrder(["missing"]))
        model.stop()
    }

    @Test("読み取りに失敗した子は除いて一覧へ伝える")
    func unreadable() async throws {
        let model = BinderModel(
            urls: [url("a.md"), url("b.pdf")],
            read: {
                if $0.pathExtension == "pdf" { throw CocoaError(.fileReadCorruptFile) }
                return Data("# A".utf8)
            })
        let source = try await model.source()
        #expect(source.children?.count == 1)
        #expect(model.unreadableURLs == [url("b.pdf")])
        #expect(model.setHash == nil)
        model.stop()
    }
    @Test("再読み込みまで子の原文を保ち再読み込みで内容と鍵を更新する")
    func reload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.md")
        try Data("first".utf8).write(to: url)
        let model = BinderModel(urls: [url])
        defer { model.stop() }
        _ = try await model.source()
        let original = model.setHash
        try Data("second".utf8).write(to: url)
        _ = try await model.source()
        #expect(model.setHash == original)
        model.clearCache()
        let reloaded = try await model.source()
        #expect(model.setHash != original)
        #expect(reloaded.children?.first?.data == Data("second".utf8))
    }

}
