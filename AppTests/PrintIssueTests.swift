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

    @Test("該当箇所を確認すると表示モードに戻り、横向きと文字の縮小も選べる")
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

    @Test("問題の組は、内容を刷れないものと、配置を確かめるものに、日本語で名前を付ける")
    func groupTitles() {
        #expect(PrintIssueText.groupTitle(.content, language: "ja") == "内容を刷れない")
        #expect(PrintIssueText.groupTitle(.layout, language: "ja") == "配置を確かめる")
        for language in ["ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            #expect(
                PrintIssueText.groupTitle(.content, language: language)
                    != PrintIssueText.groupTitle(.content, language: "en"))
            #expect(
                PrintIssueText.groupTitle(.layout, language: language)
                    != PrintIssueText.groupTitle(.layout, language: "en"))
        }
    }

    @Test("問題の場所へ移るボタンは、移ったあとに何を見るかが分かる名前にする")
    func locationButtonName() {
        #expect(PrintModeText.string("Check Location", language: "ja") == "該当箇所を確認")
    }

    @Test("図の失敗には8言語でタイトルと修正方法を出す")
    func mermaidTranslations() {
        let issue = PrintIssue(id: "0", kind: .mermaid, detail: "flowchart LR")
        #expect(PrintIssueText.title(issue, language: "ja") == "図を描けませんでした：flowchart LR")
        for language in ["ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            #expect(PrintIssueText.title(issue, language: language) != PrintIssueText.title(issue, language: "en"))
            #expect(PrintIssueText.advice(issue, language: language) != PrintIssueText.advice(issue, language: "en"))
        }
    }

    /// A model with its three pages laid out, since the paper is only asked to frame a spot of pages that exist.
    private func renderedSpotModel(_ suite: TestDefaultsSuite, directory: URL) async throws -> DocumentViewModel {
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            WebPaginator.Result(
                document: try #require(PDFDocument(data: TestFixtures.pdf("Body", pages: 3))),
                preparationResult: #"{"previous":null,"issues":[]}"#)
        })
        let model = DocumentViewModel(
            data: Data("Body".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        model.render()
        try await waitUntil { model.isUpToDate }
        return model
    }

    @Test("該当箇所を確認すると、問題の印があるときに、そのページの紙に枠を出すよう頼む", .timeLimit(.minutes(1)))
    func framesTheSpot() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await renderedSpotModel(suite, directory: directory)
        defer { model.stop() }
        var requested: [PaperSpot] = []
        model.spotPresenter = { spot in
            requested.append(spot)
            return true
        }
        let anchor = CGRect(x: 40, y: 700, width: 0.5, height: 0.5)
        model.enterPrintMode()
        model.showPrintIssue(PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: 3, rect: anchor))
        try await waitUntil { !requested.isEmpty }
        let spot = try #require(requested.first)
        #expect(requested.count == 1)
        #expect(spot.pageIndex == 2)
        #expect(spot.anchor == anchor)
        // The request is for the pages the paper is made of, not for whichever pages come to be shown later.
        #expect(spot.document === model.result?.viewDocument)
    }

    @Test("印のない問題や、場所の分からない問題には、枠を出すよう頼まない", .timeLimit(.minutes(1)))
    func noFrameWithoutAMark() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await renderedSpotModel(suite, directory: directory)
        defer { model.stop() }
        var requested: [PaperSpot] = []
        model.spotPresenter = { spot in
            requested.append(spot)
            return true
        }
        model.enterPrintMode()
        model.showPrintIssue(PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: 3))
        model.enterPrintMode()
        model.showPrintIssue(
            PrintIssue(id: "1", kind: .math, detail: "x", rect: CGRect(x: 1, y: 2, width: 1, height: 1)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(requested.isEmpty)
    }

    @Test("紙がまだ出ていなければ、受け付けられるまで頼み直し、受け付けられたら止める", .timeLimit(.minutes(1)))
    func asksAgainUntilThePaperTakesIt() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await renderedSpotModel(suite, directory: directory)
        defer { model.stop() }
        var asked = 0
        model.spotPresenter = { _ in
            asked += 1
            return asked >= 3
        }
        model.enterPrintMode()
        model.showPrintIssue(
            PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: 1, rect: CGRect(x: 1, y: 2, width: 1, height: 1)))
        try await waitUntil { asked >= 3 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(asked == 3)
    }

    @Test("冊子からの確認は、表示の組版で同じ問題が見つかったときだけ、その印へ枠を出す", .timeLimit(.minutes(1)), arguments: [true, false])
    func framesTheSameProblemFoundAgain(hasMatchingIssue: Bool) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let found = CGRect(x: 10, y: 20, width: 0.5, height: 0.5)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let booklet = request.pageSize.width < 450
            let issues: [PrintIssue]
            if booklet {
                issues = [
                    PrintIssue(
                        id: "1", kind: .math, detail: "x", pageNumber: 9,
                        rect: CGRect(x: 1, y: 2, width: 0.5, height: 0.5),
                        locationKey: "math:x:1")
                ]
            } else if hasMatchingIssue {
                issues = [
                    PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: 2, rect: found, locationKey: "math:x:1")
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
        var requested: [PaperSpot] = []
        model.spotPresenter = { spot in
            requested.append(spot)
            return true
        }
        model.layoutID = PrintLayout.a4BookletA5.id
        model.enterPrintMode()
        model.render()
        try await waitUntil { model.isUpToDate }
        model.showPrintIssue(try #require(model.printIssues.first))
        try await waitUntil { model.mode == .view && model.isUpToDate }
        try await Task.sleep(for: .milliseconds(500))
        #expect(requested.map(\.pageIndex) == (hasMatchingIssue ? [1] : []))
        #expect(requested.map(\.anchor) == (hasMatchingIssue ? [found] : []))
        #expect(requested.allSatisfy { $0.document === model.result?.viewDocument })
    }

    private let spotIssue = PrintIssue(
        id: "0", kind: .math, detail: "x", pageNumber: 2, rect: CGRect(x: 40, y: 700, width: 0.5, height: 0.5))

    @Test("頼んだあとに組み直されて文書が替わったら、待っていた要求は取り下げ、新しい文書へは頼まない", .timeLimit(.minutes(1)))
    func newPagesWithdrawTheWaitingRequest() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await renderedSpotModel(suite, directory: directory)
        defer { model.stop() }
        let first = try #require(model.result?.viewDocument)
        var requested: [PaperSpot] = []
        model.spotPresenter = { spot in
            requested.append(spot)
            return false
        }
        model.enterPrintMode()
        model.showPrintIssue(spotIssue)
        try await waitUntil { !requested.isEmpty }
        // Another style lays the same pages out again, as a reload would: the old rectangle no longer marks anything.
        model.selectTheme("mincho")
        model.render()
        try await waitUntil { model.isUpToDate && model.result?.viewDocument !== first }
        let asked = requested.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(requested.count == asked)
        #expect(requested.allSatisfy { $0.document === first })
    }

    @Test("stop のあとは、頼まれていた枠を、遅れて頼まない", .timeLimit(.minutes(1)))
    func stopWithdrawsTheRequest() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await renderedSpotModel(suite, directory: directory)
        var asked = 0
        model.spotPresenter = { _ in
            asked += 1
            return false
        }
        model.enterPrintMode()
        model.showPrintIssue(spotIssue)
        try await waitUntil { asked >= 1 }
        model.stop()
        let atStop = asked
        try await Task.sleep(for: .milliseconds(400))
        #expect(asked == atStop)
    }

    @Test("印刷モードへ入り直したら、待っていた要求は捨て、表示へ戻っても頼まない", .timeLimit(.minutes(1)))
    func leavingTheViewWithdrawsTheRequest() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await renderedSpotModel(suite, directory: directory)
        defer { model.stop() }
        var asked = 0
        model.spotPresenter = { _ in
            asked += 1
            return false
        }
        model.enterPrintMode()
        model.showPrintIssue(spotIssue)
        try await waitUntil { asked >= 1 }
        model.enterPrintMode()
        model.exitPrintMode()
        let atExit = asked
        try await Task.sleep(for: .milliseconds(400))
        #expect(asked == atExit)
    }
}
