import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct PrintIssueTests {
    @MainActor private final class RenderGate {
        var viewRequested = false
        var releaseView = false
    }

    @Test("問題がなければ札もメニューも出さず、問題があれば件数を示す", .timeLimit(.minutes(1)))
    func count() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for issues in ["[]", #"[{"id":"0","kind":"math","detail":"x"}]"#] {
            let renderer = DocumentRenderer(paginateWithResult: { _ in
                WebPaginator.Result(
                    document: try #require(PDFDocument(data: TestFixtures.pdf("Body", pages: 3))),
                    preparationResult: "{\"previous\":null,\"issues\":\(issues)}")
            })
            let model = DocumentViewModel(
                data: Data("Body".utf8), fileURL: nil, format: .markdown,
                preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
                renderer: renderer)
            defer { model.stop() }
            model.render()
            for _ in 0..<500 {
                if !model.isRendering { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(model.error == nil)
            #expect(model.isUpToDate)
            #expect(model.canOutput)
            #expect(model.printIssueCount == (issues == "[]" ? 0 : 1))
            model.reviewPrintIssues()
            #expect(model.isPrintIssuesPresented == (issues != "[]"))
            #expect(model.mode == (issues == "[]" ? .view : .print))
            #expect(model.toast == nil)
        }
    }

    @Test("そのページへ戻ると表示モードになり横向きと文字の縮小も選べる")
    func actions() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: Data("Body".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        model.enterPrintMode()
        model.isPrintIssuesPresented = true
        model.showPrintIssue(PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: 3))
        #expect(model.mode == .view)
        #expect(model.currentPageIndex == 2)
        #expect(!model.isPrintIssuesPresented)
        model.useLandscapeForPrintIssue()
        #expect(model.paperOrientation == .landscape)
        model.decreaseTextSize()
        #expect(model.textScale == 0.9)
        #expect(model.toast == nil)
    }

    @Test("冊子からは表示の組版を待ち同じ問題のページへ移り、消えた問題は位置を近似する", .timeLimit(.minutes(1)), arguments: [true, false])
    func bookletDestination(hasMatchingIssue: Bool) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RenderGate()
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let booklet = request.pageSize.width < 450
            if !booklet {
                gate.viewRequested = true
                while !gate.releaseView { try await Task.sleep(for: .milliseconds(10)) }
            }
            let issues: [PrintIssue]
            if booklet {
                issues = [PrintIssue(id: "1", kind: .math, detail: "x", pageNumber: 9, locationKey: "math:x:1")]
            } else if hasMatchingIssue {
                issues = [
                    PrintIssue(id: "1", kind: .math, detail: "x", pageNumber: 6, locationKey: "math:x:0"),
                    PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: 2, locationKey: "math:x:1"),
                ]
            } else {
                issues = []
            }
            let json = String(decoding: try JSONEncoder().encode(issues), as: UTF8.self)
            return WebPaginator.Result(
                document: try #require(PDFDocument(data: TestFixtures.pdf("Body", pages: booklet ? 12 : 6))),
                preparationResult: "{\"previous\":null,\"issues\":\(json)}")
        })
        let model = DocumentViewModel(
            data: Data("Body".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer { model.stop() }
        model.layoutID = PrintLayout.a4BookletA5.id
        model.enterPrintMode()
        model.render()
        try await waitUntil { model.isUpToDate }
        let issue = try #require(model.printIssues.first)
        model.showPrintIssue(issue)
        try await waitUntil { gate.viewRequested }
        #expect(model.mode == .view)
        #expect(model.currentPageIndex == 0)
        #expect(!model.isUpToDate)
        gate.releaseView = true
        try await waitUntil { model.isUpToDate }
        #expect(model.currentPageIndex == (hasMatchingIssue ? 1 : 4))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test("問題の見出しと直し方と件数を日本語で組み立てる")
    func japaneseText() {
        let issue = PrintIssue(id: "0", kind: .image, detail: "images/flow.png", imageFailure: .missing)
        #expect(PrintIssueText.title(issue, language: "ja") == "画像を読めませんでした：images/flow.png")
        #expect(PrintIssueText.advice(issue, language: "ja") == "画像ファイルが見つかりません。元の文書でファイル名と場所を確認してください。")
        #expect(PrintModeText.format("Check %lld", language: "ja", 3) == "確認 3 件")
        #expect(PrintModeText.format("Before Printing (%lld)…", language: "ja", 3) == "印刷前の確認（3）…")
    }
}
