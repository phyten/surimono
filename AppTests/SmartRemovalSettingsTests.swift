import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct SmartRemovalSettingsTests {
    private let candidatesJSON = #"""
        [{"id":"#cookie","category":"cookieBanner","excerpt":"Cookie を使います","reason":"position: fixed"},
         {"id":"body > aside:nth-of-type(1)","category":"relatedLinks","excerpt":"あわせて読みたい","reason":"link density 0.9"}]
        """#

    private func environment() throws -> (AppPreferences, UserLibrary, DocumentSettingsStore, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        return (
            AppPreferences(defaults: suite.defaults), UserLibrary(root: directory.appendingPathComponent("Library")),
            DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")),
            {
                try? FileManager.default.removeItem(at: directory)
                suite.remove()
            }
        )
    }

    /// An HTML document whose pagination reports two detected parts without running WebKit.
    private func model(
        _ preferences: AppPreferences, _ library: UserLibrary, _ store: DocumentSettingsStore?, format: DocumentFormat
    ) -> DocumentViewModel {
        let pages = TestFixtures.pdf("html", pages: 2)
        let json = candidatesJSON
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            WebPaginator.Result(document: PDFDocument(data: pages) ?? PDFDocument(), preparationResult: json)
        })
        return DocumentViewModel(
            data: Data("<p>本文</p>".utf8), fileURL: nil, format: format, preferences: preferences, library: library,
            renderer: renderer, settingsStore: store)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test("HTML でスマート削除をオンにすると、残す一覧と確かめる状態を描画に渡す")
    func renderSettingsCarryTheRequest() throws {
        let (preferences, library, _, cleanUp) = try environment()
        defer { cleanUp() }
        let html = model(preferences, library, nil, format: .html)
        #expect(html.renderSettings?.smartRemoval == nil)
        html.setSmartRemoval(enabled: true)
        html.toggleKeep("#cookie")
        #expect(html.renderSettings?.smartRemoval == SmartRemovalRequest(keptIDs: ["#cookie"]))
        html.reviewSmartRemoval()
        #expect(html.renderSettings?.smartRemoval?.highlightsCandidates == true)
        html.toggleKeep("#cookie")
        #expect(html.renderSettings?.smartRemoval?.keptIDs == [])
        html.setSmartRemoval(enabled: false)
        #expect(html.renderSettings?.smartRemoval == nil)
        #expect(!html.isReviewingSmartRemoval)

        let markdown = model(preferences, library, nil, format: .markdown)
        markdown.setSmartRemoval(enabled: true)
        #expect(markdown.renderSettings?.smartRemoval == nil)
    }

    @Test("スマート削除の状態と残す部分を内容のハッシュで覚え、次に開いたときに戻す", .timeLimit(.minutes(1)))
    func remembersSmartRemoval() async throws {
        let (preferences, library, store, cleanUp) = try environment()
        defer { cleanUp() }
        let first = model(preferences, library, store, format: .html)
        first.start()
        try await waitUntil { first.contentHash != nil && first.result != nil && !first.isRendering }
        first.setSmartRemoval(enabled: true)
        first.render()
        try await waitUntil { !first.isRendering && first.renderedSettings?.smartRemoval != nil }
        #expect(first.smartRemovalCandidates.map(\.id) == ["#cookie", "body > aside:nth-of-type(1)"])
        #expect(first.removedPartCount == 2)
        #expect(first.toast == nil)
        first.toggleKeep("#cookie")
        #expect(first.removedPartCount == 1)
        first.rememberedSettingsDidChange()
        first.stop()

        let reopened = model(preferences, library, store, format: .html)
        reopened.start()
        try await waitUntil { reopened.contentHash != nil && reopened.result != nil && !reopened.isRendering }
        #expect(reopened.isSmartRemovalEnabled)
        #expect(reopened.hasSavedSettings)
        #expect(reopened.toast == nil)
        #expect(reopened.smartRemovalKeptIDs == ["#cookie"])
        reopened.stop()
    }

    @Test("既定に戻すとスマート削除をオフにして、残す一覧も消す")
    func resetClearsSmartRemoval() throws {
        let (preferences, library, _, cleanUp) = try environment()
        defer { cleanUp() }
        let html = model(preferences, library, nil, format: .html)
        html.setSmartRemoval(enabled: true)
        html.toggleKeep("#cookie")
        html.reviewSmartRemoval()
        html.resetDocumentSettings()
        #expect(!html.isSmartRemovalEnabled)
        #expect(html.smartRemovalKeptIDs.isEmpty)
        #expect(!html.isReviewingSmartRemoval)
    }

    @Test("HTML でスマート削除がオンのときだけ、取り除いた部分を確かめられる")
    func reviewNeedsSmartRemovalOnHTML() throws {
        let (preferences, library, _, cleanUp) = try environment()
        defer { cleanUp() }
        let html = model(preferences, library, nil, format: .html)
        html.reviewSmartRemoval()
        #expect(!html.isReviewingSmartRemoval)
        let markdown = model(preferences, library, nil, format: .markdown)
        markdown.setSmartRemoval(enabled: true)
        markdown.reviewSmartRemoval()
        #expect(!markdown.isReviewingSmartRemoval)
    }

    /// Draws the review: the detected parts outlined instead of removed.
    private func reviewing(_ preferences: AppPreferences, _ library: UserLibrary) async throws -> DocumentViewModel {
        let html = model(preferences, library, nil, format: .html)
        html.setSmartRemoval(enabled: true)
        html.reviewSmartRemoval()
        html.render()
        try await waitUntil { !html.isRendering && html.renderedSettings?.smartRemoval?.highlightsCandidates == true }
        return html
    }

    /// The view draws again whenever the settings change; without a view the test does it.
    private func drawWithoutOutlines(_ html: DocumentViewModel) async throws {
        html.render()
        try await waitUntil { !html.isRendering && html.renderedSettings?.smartRemoval?.highlightsCandidates == false }
    }

    @Test("確認中の輪郭つきのページは、印刷にも PDF の書き出しにも使わない", .timeLimit(.minutes(1)))
    func reviewPagesAreNotOutput() async throws {
        let (preferences, library, _, cleanUp) = try environment()
        defer { cleanUp() }
        let html = try await reviewing(preferences, library)
        #expect(html.isUpToDate)
        #expect(!html.canOutput)
        #expect(!html.beginPDFExport())
    }

    @Test("確認中に ⌘P で印刷モードへ入ると確認を終え、刷り台には輪郭のないページを出す", .timeLimit(.minutes(1)))
    func enteringPrintModeEndsTheReview() async throws {
        let (preferences, library, _, cleanUp) = try environment()
        defer { cleanUp() }
        let html = try await reviewing(preferences, library)
        html.performPrintCommand()
        #expect(html.mode == .print)
        #expect(!html.isReviewingSmartRemoval)
        try await drawWithoutOutlines(html)
        #expect(html.canOutput)
    }

    @Test("確認中にすぐ印刷か PDF の書き出しを選ぶと、確認を終えて輪郭のないページができてから出力する", .timeLimit(.minutes(1)))
    func outputDuringReviewWaitsForPagesWithoutOutlines() async throws {
        let (preferences, library, _, cleanUp) = try environment()
        defer { cleanUp() }
        let requests: [(DocumentViewModel.Output, (DocumentViewModel) -> Void)] = [
            (.print(quick: true), { $0.printDocument(quick: true) }),
            (.exportPDF, { $0.exportPDF() }),
        ]
        for (output, request) in requests {
            let html = try await reviewing(preferences, library)
            request(html)
            #expect(!html.isReviewingSmartRemoval)
            #expect(html.outputAfterReview == output)
            try await drawWithoutOutlines(html)
            #expect(html.outputAfterReview == nil)
            #expect(html.canOutput)
        }
    }

    @Test("刷り台でスマート削除をオンにしても知らせず、メニューの確認操作で表示モードのパネルを開く", .timeLimit(.minutes(1)))
    func reviewFromTheTrayOpensThePanel() async throws {
        let (preferences, library, _, cleanUp) = try environment()
        defer { cleanUp() }
        let html = model(preferences, library, nil, format: .html)
        html.enterPrintMode()
        html.setSmartRemoval(enabled: true)
        html.render()
        try await waitUntil { !html.isRendering && html.renderedSettings?.smartRemoval != nil }
        #expect(html.toast == nil)
        #expect(html.removedPartCount == 2)
        html.reviewSmartRemoval()
        #expect(html.mode == .view)
        #expect(html.isReviewingSmartRemoval)
        #expect(html.toast == nil)
    }
}
