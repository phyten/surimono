import AppKit
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

    @Test("大きすぎる目次は印刷時に省く範囲を選択言語で知らせる")
    func contentsOmission() {
        let issue = PrintIssue(id: "0", kind: .contentsLimit, detail: "")
        let english = PrintIssueText.title(issue, language: "en")
        #expect(english == "The table of contents is too large, so part or all of it will be left out when printing.")
        #expect(PrintIssueText.title(issue, language: "ja") == "目次は大きすぎるため、一部または全部を省いて印刷します。")
        for language in ["de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            #expect(PrintIssueText.title(issue, language: language) != english)
        }
    }

    @Test("見つからない相互参照は名前を並べて選択言語で知らせる")
    func unresolvedReferences() {
        let issue = PrintIssue(id: "0", kind: .reference, detail: "fig:plan, tab:sizes")
        let english = PrintIssueText.title(issue, language: "en")
        #expect(english == "Cross-references not found: fig:plan, tab:sizes")
        #expect(PrintIssueText.title(issue, language: "ja") == "見つからない相互参照：fig:plan, tab:sizes")
        for language in ["de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            let title = PrintIssueText.title(issue, language: language)
            #expect(title != english)
            #expect(title.hasSuffix("fig:plan, tab:sizes"))
            #expect(!title.contains("%@"))
        }
        #expect(issue.group == .content)
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
            #expect(!model.canOutput)
            #expect(model.printIssueCount == (issues == "[]" ? 0 : 1))
            model.reviewPrintIssues()
            #expect(model.isPrintIssuesPresented == (issues != "[]"))
            #expect(model.mode == (issues == "[]" ? .view : .print))
            #expect(model.toast == nil)
        }
    }

    @Test("フォルダを選ぶ通知は時間切れにならず、閉じたあとも印刷前の確認から選べる", .timeLimit(.minutes(1)))
    func folderAccessNotice() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        let issue = PrintIssue(id: "image", kind: .image, detail: "figure.png", imageFailure: .folderAccess)
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            var result = WebPaginator.Result(document: try #require(PDFDocument(data: TestFixtures.pdf("Image"))))
            result.issues = [issue]
            return result
        })
        let model = DocumentViewModel(
            data: Data("Image".utf8), fileURL: file, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer { model.stop() }
        model.render()
        try await waitUntil { model.isUpToDate }
        let notice = Toast.folderAccess
        model.showToast(notice, dismissAfter: .zero)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.toast == notice && notice.showsDismissButton)
        model.showToast(Toast(systemImage: "checkmark", title: "Done"), dismissAfter: .milliseconds(1))
        try await waitUntil { model.toast == notice }
        model.dismissToast(closingFolderNotice: true)
        #expect(model.toast == nil)
        model.reviewPrintIssues()
        #expect(model.isPrintIssuesPresented)
        #expect(model.printIssues.first?.imageFailure == .folderAccess)
        #expect(model.fileNeedingFolderAccess == file)
        #expect(PrintIssueText.advice(issue, language: "ja") == "画像を表示するには、フォルダを読む許可が必要です")
    }

    @Test(
        "サンドボックスの外でも、文書のフォルダーの外の文献は許可を求め、許可すると組まれて確認が消える",
        .timeLimit(.minutes(1)))
    func outsideFolderBibliography() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["doc", "assets"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("@book{key, title={Outside edition}}".utf8).write(to: root.appendingPathComponent("assets/s.bib"))
        let markdown = Data("---\nbibliography: ../assets/s.bib\n---\n[@key]\n".utf8)
        let file = root.appendingPathComponent("doc/a.md")
        try markdown.write(to: file)
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginateWithResult: { _ in
                WebPaginator.Result(document: try #require(PDFDocument(data: TestFixtures.pdf("Text"))))
            })
        let model = DocumentViewModel(
            data: markdown, fileURL: file, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root),
            renderer: renderer)
        defer { model.stop() }
        model.render()
        try await waitUntil { model.isUpToDate && model.toast != nil }
        #expect(model.toast?.title == Toast.outsideFolderAccess.title)
        #expect(model.toast?.action == .allowFolderAccess)
        let issue = try #require(model.printIssues.first)
        #expect(model.printIssues.count == 1)
        #expect(issue.outsideFile == "../assets/s.bib")
        #expect(model.fileNeedingFolderAccess == file)
        #expect(PrintIssueText.title(issue, language: "ja") == "文献ファイル ../assets/s.bib は、文書のフォルダの外にあります。")
        #expect(
            PrintIssueText.advice(issue, language: "ja") == "読むには、文書とそのファイルの両方を含むフォルダを選んで許可してください。")

        // What the panel's Allow Access does once the folder is chosen.
        model.useDocumentFolder(FolderAccess.Lease(url: root, release: {}))
        model.renderer.clearCache()
        model.render()
        try await waitUntil { model.isUpToDate && model.printIssues.isEmpty }
        #expect(model.result?.requiredFolderAccess == nil)
        #expect(try Data(contentsOf: file) == markdown)
    }

    @Test("縦書きの注記は組版をやり直しても一覧に残り、通知は開いたときの一度だけ", .timeLimit(.minutes(1)))
    func verticalWritingNote() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            var result = WebPaginator.Result(document: try #require(PDFDocument(data: TestFixtures.pdf("Body"))))
            result.issues = [PrintIssue(id: "vertical-writing", kind: .verticalWriting, detail: "")]
            return result
        })
        let model = DocumentViewModel(
            data: Data("Body".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer { model.stop() }
        model.render()
        try await waitUntil { !model.isRendering && model.toast != nil }
        let issue = try #require(model.printIssues.first)
        #expect(PrintIssueText.title(issue, language: "ja") == "縦書きには未対応なので、横書きで表示しています")
        #expect(model.toast?.title == PrintIssueText.title(issue, language: model.language))
        #expect(model.toast?.action == nil && model.toast?.showsDismissButton == false)
        model.dismissToast()
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(model.printIssues.map(\.kind) == [.verticalWriting])
        #expect(model.toast == nil)
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

    @Test("冊子の問題は表示へ戻っても同じページを示し、組版し直さない", .timeLimit(.minutes(1)))
    func bookletUsesSamePages() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            WebPaginator.Result(
                document: try #require(PDFDocument(data: TestFixtures.pdf("Body", pages: 12))),
                preparationResult:
                    #"{"previous":null,"issues":[{"id":"0","kind":"math","detail":"x","pageNumber":9}]}"#)
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
        let pages = try #require(model.result?.logicalDocument)
        model.showPrintIssue(try #require(model.printIssues.first))
        #expect(model.mode == .view)
        #expect(model.currentPageIndex == 8)
        #expect(model.isUpToDate)
        #expect(model.result?.logicalDocument === pages)
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("開いて刷った折りたたみの後ろの問題は、表示へ戻って閉じたまま組み直してから同じ問題へ移る", .timeLimit(.minutes(1)))
    func openedDetailsIssueWaitsForClosedPages() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("page.html")
        let data = Data("<p>File</p>".utf8)
        try data.write(to: file)
        // The opened details push the problem further back: page 9 when opened, page 3 when closed.
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let opened = request.preparationScript?.contains(HTMLSnapshotScript.openDetailsJavaScript) == true
            let issues = [
                PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: opened ? 9 : 3, locationKey: "math:x:0")
            ]
            let json = String(decoding: try JSONEncoder().encode(issues), as: UTF8.self)
            return WebPaginator.Result(
                document: try #require(PDFDocument(data: TestFixtures.pdf("Body", pages: opened ? 12 : 4))),
                preparationResult: "{\"previous\":null,\"issues\":\(json)}")
        })
        let model = DocumentViewModel(
            data: data, fileURL: file, format: .html, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")), renderer: renderer)
        defer { model.stop() }
        model.snapshotSource = {
            .captured(HTMLSnapshot(html: "<details><summary>Q</summary>A</details><p>x</p>", closedDetailsCount: 1))
        }
        // The live page is copied for the paper only in a window.
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 848),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        model.window = window
        model.layoutID = PrintLayout.a4BookletA5.id
        model.start()
        try await waitUntil { model.result != nil && !model.isRendering }
        model.setHTMLPresentation(.paper)
        try await waitUntil { model.rendersSnapshot && !model.isCapturingWeb && model.isUpToDate }
        model.enterPrintMode()
        #expect(model.mode == .print)
        model.setOpensClosedDetails(true)
        model.render()
        try await waitUntil { model.isUpToDate && model.canOutput }
        let issue = try #require(model.printIssues.first)
        #expect(issue.pageNumber == 9)

        model.showPrintIssue(issue)
        #expect(model.mode == .view)
        #expect(!model.opensClosedDetails)
        try await waitUntil { model.isUpToDate && model.result?.logicalDocument.pageCount == 4 }
        #expect(model.currentPageIndex == 2)
    }

    @Test("問題の検出後にレイアウトを変えたら組版を待ち、同じ問題へ移るか位置を近似する", .timeLimit(.minutes(1)), arguments: [true, false])
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
        model.layoutID = PrintLayout.a4Single.id
        model.showPrintIssue(issue)
        try await waitUntil { gate.viewRequested }
        #expect(model.mode == .view)
        #expect(model.currentPageIndex == 0)
        #expect(!model.isUpToDate)
        gate.releaseView = true
        try await waitUntil { model.isUpToDate }
        #expect(model.currentPageIndex == (hasMatchingIssue ? 1 : 4))
    }

    private func waitUntil(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
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

    @Test("未読コマンド名は表示言語で説明し、画像化の案内は描けなかった図だけに出す")
    func latexCommandsAndPictures() {
        let issue = PrintIssue(id: "0", kind: .latex, detail: #"commands not read: \memo"#)
        let picture = PrintIssue(id: "1", kind: .latex, detail: "TikZ", element: .figure)
        for language in ["en", "ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            let title = PrintIssueText.title(issue, language: language)
            #expect(title.contains(#"\memo"#))
            if language != "en" { #expect(title != PrintIssueText.title(issue, language: "en")) }
            #expect(
                PrintIssueText.advice(issue, language: language) != PrintIssueText.advice(picture, language: language))
        }
        #expect(PrintIssueText.title(issue, language: "ja") == #"読み取れなかった LaTeX コマンド：\memo"#)
    }

    @Test("入れ子が深すぎて省く部分は、選択言語で知らせ、操作の案内を出さない")
    func nestingOmission() {
        let issue = PrintIssue(id: "0", kind: .nestingOmission, detail: "Nesting limit reached; part left out")
        for language in ["en", "ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            if language != "en" {
                #expect(PrintIssueText.title(issue, language: language) != PrintIssueText.title(issue, language: "en"))
            }
            #expect(PrintIssueText.advice(issue, language: language).isEmpty)
        }
        #expect(PrintIssueText.title(issue, language: "ja") == "入れ子が深すぎる部分は、省いて印刷します。")
        #expect(issue.group == .content)
    }

    @Test("入れ子が深すぎて文字のまま刷る部分は、選択言語で知らせ、操作の案内を出さない")
    func nestingLimit() {
        let issue = PrintIssue(id: "0", kind: .nestingLimit, detail: "Nesting limit reached")
        for language in ["en", "ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            if language != "en" {
                #expect(PrintIssueText.title(issue, language: language) != PrintIssueText.title(issue, language: "en"))
            }
            #expect(PrintIssueText.advice(issue, language: language).isEmpty)
        }
        #expect(PrintIssueText.title(issue, language: "ja") == "入れ子が深すぎる部分は、原文のまま印刷します。")
        #expect(issue.group == .content)
    }

    @Test("ページ番号を特定できなかったときは印刷前の確認に選択言語で知らせる")
    func unresolvedLaTeXPages() {
        let issue = PrintIssue.unresolvedLaTeXPages
        #expect(PrintIssueText.title(issue, language: "ja") == "LaTeX 文書の一部のページ番号を特定できませんでした。")
        for language in ["ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
            #expect(PrintIssueText.title(issue, language: language) != PrintIssueText.title(issue, language: "en"))
        }
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

    @Test("問題の検出後にレイアウトを変えたら、同じ問題が再び見つかったときだけ枠を出す", .timeLimit(.minutes(1)), arguments: [true, false])
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
        model.layoutID = PrintLayout.a4Single.id
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
