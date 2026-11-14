import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

/// The printed header and footer on the view mode's paper: how often the paper is made again, and the day they show.
@MainActor
struct ViewFurnitureTests {
    @MainActor private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @MainActor private final class Counter {
        var calls = 0
    }

    /// Holds the typing pause open until the test lets it go, so that no real time decides the test.
    @MainActor private final class Pause {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }

        func wait() async {
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            let held = waiting
            waiting = []
            for continuation in held { continuation.resume() }
        }
    }

    @MainActor private struct Environment {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = Clock()
        let counter = Counter()

        func model() -> DocumentViewModel {
            let counter = counter
            let clock = clock
            let renderer = DocumentRenderer(paginate: { request in
                counter.calls += 1
                let data = TestFixtures.textPDF(["本文"])
                let document = try #require(PDFDocument(data: data))
                // Pages of the logical size, which the paper draws the header and footer on.
                document.page(at: 0)?.setBounds(CGRect(origin: .zero, size: request.pageSize), for: .mediaBox)
                document.page(at: 0)?.setBounds(CGRect(origin: .zero, size: request.pageSize), for: .cropBox)
                return document
            })
            renderer.now = { clock.date }
            return DocumentViewModel(
                data: Data("本文".utf8), fileURL: nil, format: .markdown,
                preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: directory.appendingPathComponent("Library")), renderer: renderer,
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func render(_ model: DocumentViewModel) async throws {
        model.render()
        try await waitUntil { !model.isRendering && model.result != nil }
    }

    @Test("ヘッダーの文字を続けて打っても、表示の紙は打つ手が止まってから一度だけ作り直す", .timeLimit(.minutes(1)))
    func typingWaitsForAPause() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        defer { model.stop() }
        let pause = Pause()
        model.awaitTypingPause = { await pause.wait() }
        model.printOptions.furniture.topLeft = "見出し"
        model.printOptions.furniture.topRight = "右"
        try await render(model)
        #expect(model.paperFurniture[0]?.lines.top == ["見出し", "", "右"])
        let changes = model.shownFurnitureChangeCount
        let texts = ["見出しA", "見出しAB", "見出しABC", "見出しABCD", "見出しABCDE"]
        for text in texts {
            model.printOptions.furniture.topLeft = text
            try await render(model)
        }
        // Every keystroke waited for the pause, and none reached the paper: it still has the text from before.
        try await waitUntil { pause.count == texts.count }
        #expect(model.shownFurnitureChangeCount == changes)
        #expect(model.paperFurniture[0]?.lines.top == ["見出し", "", "右"])
        #expect(model.result?.viewFurniture[0]?.lines.top == ["見出しABCDE", "", "右"])
        pause.release()
        try await waitUntil { model.paperFurniture[0]?.lines.top == ["見出しABCDE", "", "右"] }
        // The earlier waits were cancelled by the next keystroke, so only the last one changed the paper.
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.shownFurnitureChangeCount == changes + 1)
        #expect(environment.counter.calls == 1)
    }

    @Test("型を選び替えたときは、表示の紙にすぐ出す")
    func presetsApplyAtOnce() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        defer { model.stop() }
        try await render(model)
        model.chooseFurniture(.number)
        try await render(model)
        #expect(model.paperFurniture[0]?.lines.bottom == ["", "1", ""])
        model.chooseFurniture(.name)
        try await render(model)
        #expect(model.paperFurniture[0]?.lines.bottom == ["", "1 / 1", ""])
    }

    @Test("日付を出すヘッダーは日が替わると組版し直さずに今日の日付になる", .timeLimit(.minutes(1)))
    func dayChangeRefreshesTheDate() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        defer { model.stop() }
        model.chooseFurniture(.nameAndDate)
        model.start()
        try await waitUntil { !model.isRendering && model.result != nil }
        let yesterday = try #require(model.paperFurniture[0]?.lines.top[2])
        environment.clock.date += 24 * 60 * 60
        #expect(model.showsStaleDate)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        try await waitUntil { !model.isRendering && model.paperFurniture[0]?.lines.top[2] != yesterday }
        #expect(!model.showsStaleDate)
        #expect(model.result?.furnitureDate == model.paperFurniture[0]?.lines.top[2])
        #expect(environment.counter.calls == 1)
    }

    @Test("日が替わってから何も変えずに刷り台から書き出しても、今日の日付の用紙を出す", .timeLimit(.minutes(1)))
    func outputAfterMidnightShowsToday() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model()
        defer { model.stop() }
        model.chooseFurniture(.nameAndDate)
        model.enterPrintMode()
        try await render(model)
        try await waitUntil { model.canOutput }
        environment.clock.date += 24 * 60 * 60
        var dates: [String] = []
        model.outputOverride = { _, _ in dates.append(model.result?.furnitureDate ?? "") }
        model.exportPDF()
        try await waitUntil { !dates.isEmpty }
        let today = PageFurniture.nameAndDate.dateText(environment.clock.date, language: model.language)
        #expect(dates == [today])
        #expect(environment.counter.calls == 1)
    }
}
