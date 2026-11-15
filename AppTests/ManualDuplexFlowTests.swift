import AppKit
import ApplicationServices
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct ManualDuplexFlowTests {
    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let renderer = DocumentRenderer()
        var sent: [ManualDuplexSubmission] = []
        var callbacks: [(ManualDuplexSubmissionResult) -> Void] = []
        var ordinary: [(RenderResult, PrintRequest)] = []

        init() {
            preferences = AppPreferences(defaults: suite.defaults)
            preferences.layoutID = "a4Duplex"
        }

        func model() -> DocumentViewModel {
            let model = DocumentViewModel(
                data: TestFixtures.textPDF(["ONE", "TWO", "THREE", "FOUR", "FIVE"]), fileURL: nil, format: .pdf,
                preferences: preferences, library: UserLibrary(root: root), renderer: renderer)
            model.printerListSource = { .init(names: ["A", "B"], defaultName: "A") }
            model.printerCapabilitiesSource = { _ in nil }
            model.printerCapabilities = ["A": .init(duplex: false)]
            model.manualDuplexSubmit = { [weak self] submission, complete in
                self?.sent.append(submission)
                self?.callbacks.append(complete)
            }
            model.printSubmit = { [weak self] result, request, _ in self?.ordinary.append((result, request)) }
            model.duplexTestSubmit = { _, _, _, complete in complete(nil) }
            return model
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            suite.remove()
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func start(_ model: DocumentViewModel) async throws {
        model.enterPrintMode()
        model.start()
        try await wait { model.canOutput }
    }

    @Test("両面なしの印刷とショートカットは表を送り成功までシートを出さない", .timeLimit(.minutes(1)))
    func handoffAndDoubleClicks() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        model.printDocument(quick: true)
        model.printDocument(quick: false)
        model.printDuplexTest()
        try await wait { fixture.sent.count == 1 }
        let session = try #require(model.manualDuplexSession)
        #expect(!session.showsReload)
        #expect(!model.canPerformPrintCommand && !model.canPrintDuplexTest)
        #expect(fixture.sent[0].pass == .fronts)
        #expect(fixture.sent[0].document.pageCount == 3)
        fixture.callbacks[0](.handedOff(printerName: "A"))
        #expect(session.showsReload)
        fixture.callbacks[0](.cancelledOrFailed)
        #expect(model.manualDuplexSession?.id == session.id)
        model.performPrintCommand()
        model.printManualDuplexBacks()
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 2 }
        #expect(fixture.sent[1].pass == .backs)
        #expect(fixture.sent[1].pageOrder == .firstSheetFirst)
        fixture.callbacks[1](.handedOff(printerName: "A"))
        #expect(model.manualDuplexSession == nil)
        #expect(model.toast != nil)
        #expect(fixture.ordinary.isEmpty)
    }

    @Test("用紙を戻すシートは待機中と裏の準備中だけに出す")
    func reloadSheetPhases() throws {
        let layout = PrintLayout.a4Duplex
        let session = ManualDuplexSession(
            printerName: "A", layout: layout, imposition: Imposition.plan(pageCount: 4, layout: layout), copies: 1,
            pageOrder: .lastSheetFirst, jobTitle: "Job", language: "ja", correction: .init())
        var shown: [ManualDuplexSession.Phase: Bool] = [session.phase: session.showsReload]
        let steps: [(ManualDuplexSession.Phase, ManualDuplexSession.Phase)] = [
            (.preparing, .sendingFronts), (.sendingFronts, .awaitingReload), (.awaitingReload, .preparingBacks),
            (.preparingBacks, .closingSheet), (.closingSheet, .sendingBacks),
        ]
        for (from, to) in steps {
            try #require(session.transition(from: from, to: to))
            shown[to] = session.showsReload
        }
        #expect(
            shown == [
                .preparing: false, .sendingFronts: false, .awaitingReload: true, .preparingBacks: true,
                .closingSheet: false, .sendingBacks: false,
            ])
    }

    @Test("裏を送る間はシートを閉じ、送り始められなければエラーとともに戻し、送信後の失敗では終える", .timeLimit(.minutes(1)))
    func sheetClosesWhileBacksAreSent() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        let session = try #require(model.manualDuplexSession)
        #expect(session.showsReload)
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 2 }
        #expect(session.phase == .sendingBacks)
        #expect(!session.showsReload)
        fixture.callbacks[1](.notStarted)
        #expect(session.showsReload)
        #expect(session.error?.contains("A") == true)
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 3 }
        #expect(!session.showsReload)
        fixture.callbacks[2](.cancelledOrFailed)
        #expect(model.manualDuplexSession == nil)
        #expect(model.outputError != nil)
        #expect(fixture.ordinary.isEmpty)
    }

    @Test("手動両面の経路は準備がなければ何も送らず、自動両面として送らない", .timeLimit(.minutes(1)))
    func manualRouteNeverSendsAutomaticDuplex() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        let result = try #require(model.printResult)
        let request = PrintRequest(printerName: "A", showsPanel: false)
        model.sendPrint(
            result, route: .manualDuplex(request), request: request, prepared: nil, pageOrder: .lastSheetFirst,
            intent: .quick)
        #expect(fixture.ordinary.isEmpty)
        #expect(fixture.sent.isEmpty)
        #expect(model.manualDuplexSession == nil)
        #expect(model.outputError != nil)
    }

    @Test("裏は用紙を戻すシートが窓から外れてから送り始め、送り始められなければシートを戻す", .timeLimit(.minutes(1)))
    func backsStartAfterTheSheetHasLeft() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // The same presentation the document window carries, hosted alone so the real sheet attaches to `window`.
        window.contentViewController = NSHostingController(
            rootView: Color.clear.frame(width: 640, height: 480).modifier(ManualDuplexPresentation(model: model)))
        window.orderFront(nil)
        var attachedAtSend: [Bool] = []
        model.manualDuplexSubmit = { submission, complete in
            attachedAtSend.append(window.attachedSheet != nil)
            fixture.sent.append(submission)
            fixture.callbacks.append(complete)
        }
        try await start(model)
        model.window = window
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        try await wait { window.attachedSheet != nil }
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 2 }
        #expect(attachedAtSend == [false, false])
        fixture.callbacks[1](.notStarted)
        try await wait { window.attachedSheet != nil }
        #expect(model.manualDuplexSession?.phase == .awaitingReload)
        model.cancelManualDuplex()
        try await wait { window.attachedSheet == nil }
    }

    @Test("シートが窓から外れないままなら裏を送らず、エラーとともに待機へ戻す", .timeLimit(.minutes(1)))
    func backsWaitForTheSheetOnlySoLong() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        let session = try #require(model.manualDuplexSession)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        let stuck = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.beginSheet(stuck) { _ in }
        defer { window.endSheet(stuck) }
        try await wait { window.attachedSheet === stuck }
        model.window = window
        let started = ContinuousClock.now
        model.printManualDuplexBacks()
        try await wait { session.phase == .closingSheet }
        try await wait { session.phase == .awaitingReload }
        #expect(ContinuousClock.now - started >= DocumentViewModel.manualDuplexSheetDetachLimit)
        #expect(session.error != nil)
        #expect(fixture.sent.count == 1)
        #expect(fixture.preferences.printerProfiles.isEmpty)
    }

    @Test("自動両面対応のプリンターでも手動両面を選べる", .timeLimit(.minutes(1)))
    func explicitManual() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        model.printerCapabilities["A"] = .init(duplex: true)
        try await start(model)
        model.printDocument(intent: .manualDuplex)
        try await wait { fixture.sent.count == 1 }
        #expect(fixture.ordinary.isEmpty)
    }

    @Test("描画待ちをまたいでも明示した手動両面の意図を保つ", .timeLimit(.minutes(1)))
    func intentSurvivesRendering() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        model.printerCapabilities["A"] = .init(duplex: true)
        try await start(model)
        model.exitPrintMode()
        model.layoutID = "a4BookletA5"
        model.printDocument(intent: .manualDuplex)
        #expect(model.outputAfterReview == .manualDuplex)
        model.render()
        try await wait { fixture.sent.count == 1 }
        #expect(fixture.ordinary.isEmpty)
        #expect(model.manualDuplexSession?.binding == .shortEdge)
    }

    @Test("表の送信後に原文と範囲と部数と日付と別窓の設定が変わっても同じ裏を送る", .timeLimit(.minutes(1)))
    func frozenJob() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        fixture.renderer.now = { date }
        model.chooseFurniture(.nameAndDate)
        try await start(model)
        model.copies = 2
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        let session = try #require(model.manualDuplexSession)
        let expected = session.backs?.string
        #expect(session.sheetCount == 6)
        date += 24 * 60 * 60
        #expect(model.showsStaleDate)
        model.calendarDayDidChange()
        model.replaceContent(Data("broken PDF".utf8), format: .pdf)
        model.setPageRangeText("3-4")
        model.copies = 7
        model.layoutID = "a3BookletA4"
        fixture.preferences.setPrinterPageOrder(.firstSheetFirst, for: "A")
        fixture.preferences.setManualDuplexCorrection(.init(reversesBackOrder: true), for: "A", duplex: .longEdge)
        fixture.preferences.printerName = "B"
        model.calendarDayDidChange()
        model.failToOpen("Synthetic render failure")
        #expect(!model.canOutput)
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 2 }
        let backs = fixture.sent[1]
        #expect(backs.document.pageCount == 6)
        #expect(backs.document.string == expected)
        #expect(backs.request == .init(printerName: "A", showsPanel: false, copies: 1))
        #expect(backs.layout.sheet == .a4 && backs.layout.sentDuplex == .none)
        #expect(session.correction == .init())
        #expect(fixture.ordinary.isEmpty)
    }

    @Test("裏の送信先が消えても別のプリンターへ送らず接続後にだけ再試行する", .timeLimit(.minutes(1)))
    func missingBackPrinter() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        model.printerListSource = { .init(names: ["B"], defaultName: "B") }
        model.printManualDuplexBacks()
        #expect(model.manualDuplexSession?.phase == .awaitingReload)
        #expect(model.manualDuplexSession?.error?.contains("A") == true)
        #expect(fixture.sent.count == 1 && fixture.ordinary.isEmpty)
        model.printerListSource = { .init(names: ["A"], defaultName: "A") }
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 2 }
    }

    @Test("表の送信前にプリンターが消えたら全文書のシステム画面へ戻る", .timeLimit(.minutes(1)))
    func vanishedBeforeFronts() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        model.printerListSource = { .init(names: ["B"], defaultName: "B") }
        try await wait { fixture.ordinary.count == 1 }
        #expect(fixture.sent.isEmpty)
        #expect(fixture.ordinary[0].0.sheetDocument.pageCount == 6)
        #expect(fixture.ordinary[0].1.showsPanel)
        #expect(model.manualDuplexSession == nil)
    }

    @Test("最後のプリンター構築で表が未送信なら全文書へ戻り裏が未送信ならシートを残す", .timeLimit(.minutes(1)))
    func notStarted() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.notStarted)
        try await wait { fixture.ordinary.count == 1 }
        #expect(model.manualDuplexSession == nil)
        #expect(fixture.ordinary[0].0.sheetDocument.pageCount == 6)
        #expect(fixture.ordinary[0].1.showsPanel)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 2 }
        fixture.callbacks[1](.handedOff(printerName: "A"))
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 3 }
        fixture.callbacks[2](.notStarted)
        #expect(model.manualDuplexSession?.phase == .awaitingReload)
        #expect(fixture.ordinary.count == 1)
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 4 }
        fixture.callbacks[2](.cancelledOrFailed)
        #expect(model.manualDuplexSession?.phase == .sendingBacks)
        fixture.callbacks[3](.handedOff(printerName: "A"))
        #expect(model.manualDuplexSession == nil)
    }

    @Test("窓を閉じた後の完了通知はシートを再表示しない", .timeLimit(.minutes(1)))
    func staleCallback() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        model.stop()
        fixture.callbacks[0](.handedOff(printerName: "A"))
        #expect(model.manualDuplexSession == nil)
    }

    @Test("送信失敗後に裏を自動で再送せずキャンセルした補正と進捗を保存しない", .timeLimit(.minutes(1)))
    func failureAndCancellation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        model.manualDuplexSession?.correction = .init(reversesBackOrder: true, rotatesBackSides: true)
        model.cancelManualDuplex()
        #expect(fixture.preferences.printerProfile(for: "A").manualCorrection(for: .longEdge) == .init())
        model.performPrintCommand()
        try await wait { fixture.sent.count == 2 }
        fixture.callbacks[1](.handedOff(printerName: "A"))
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 3 }
        fixture.callbacks[2](.cancelledOrFailed)
        #expect(model.manualDuplexSession == nil)
        #expect(model.outputError != nil)
        model.printManualDuplexBacks()
        #expect(fixture.sent.count == 3)
        let reopened = fixture.model()
        defer { reopened.stop() }
        #expect(reopened.manualDuplexSession == nil)
    }

    @Test("裏の補正は固定したプリンターととじ方へ保存し裏だけを作り直す", .timeLimit(.minutes(1)))
    func correctionDraft() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        let session = try #require(model.manualDuplexSession)
        session.correction = .init(reversesBackOrder: true, rotatesBackSides: true)
        model.layoutID = "a4BookletA5"
        fixture.preferences.printerName = "B"
        model.printManualDuplexBacks()
        try await wait { fixture.sent.count == 2 }
        #expect(session.plan?.backs.map(\.sourceSideIndex) == [5, 3, 1])
        #expect(session.plan?.backs.allSatisfy { $0.rotates180 } == true)
        #expect(
            fixture.preferences.printerProfile(for: "A").manualCorrection(for: .longEdge)
                == .init(reversesBackOrder: true, rotatesBackSides: true))
        #expect(fixture.preferences.printerProfile(for: "A").manualCorrection(for: .shortEdge) == .init())
        #expect(fixture.preferences.printerProfile(for: "B").manualCorrection(for: .longEdge) == .init())
    }

    @Test("裏を準備できなければ何も送らず再試行できるシートを残す", .timeLimit(.minutes(1)))
    func backPreparationFailure() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        let session = try #require(model.manualDuplexSession)
        // Deliberately damage only the session's private copy to exercise preparation failure without a printer.
        let neutral = try #require(session.neutral)
        for _ in 0..<neutral.pageCount { neutral.removePage(at: 0) }
        model.printManualDuplexBacks()
        try await wait { session.phase == .awaitingReload }
        #expect(session.error != nil)
        #expect(fixture.sent.count == 1)
    }

    @Test("待機中のPDF書き出しは追加で制限しない", .timeLimit(.minutes(1)))
    func exportRemainsAvailable() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        fixture.callbacks[0](.handedOff(printerName: "A"))
        var exported = false
        model.outputOverride = { output, _ in exported = output == .exportPDF }
        model.exportPDF()
        #expect(exported)
    }

    @Test("手動両面の両パスは片面1部全ページで操作を構築し実行しない", .timeLimit(.minutes(1)))
    func operationsOnly() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.copies = 2
        model.performPrintCommand()
        try await wait { fixture.sent.count == 1 }
        let session = try #require(model.manualDuplexSession)
        for pass in [ManualDuplexPass.fronts, .backs] {
            let submission = try session.submission(for: pass)
            let operation = try #require(model.makeManualDuplexOperation(submission))
            #expect(!operation.showsPrintPanel)
            #expect(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] as? Bool == true)
            #expect(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.copies] as? Int == 1)
            var duplex = PMDuplexMode(kPMDuplexNoTumble)
            let settings = OpaquePointer(operation.printInfo.pmPrintSettings())
            #expect(PMGetDuplex(settings, &duplex) == noErr)
            #expect(duplex == PMDuplexMode(kPMDuplexNone))
            #expect(submission.document.pageCount == 6)
        }
    }

    #if DEBUG
        @Test("手動両面のスナップショットは、同じ窓で次に始めた手動両面でも実機への送信と設定の保存をしない", .timeLimit(.minutes(1)))
        func safeSnapshot() async throws {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            let model = fixture.model()
            defer { model.stop() }
            let before = fixture.suite.defaults.dictionaryRepresentation()
            try await DebugSnapshot.installManualDuplexFixture(model, sheets: 3)
            let session = try #require(model.manualDuplexSession)
            #expect(session.phase == .awaitingReload && session.sheetCount == 3)
            #expect(model.printerListSource().names == ["Snapshot Printer"])
            #expect(await model.printerCapabilitiesSource("Snapshot Printer")?.duplex == false)
            model.manualDuplexSubmit = { _, _ in Issue.record("通常の送信経路を呼んだ") }
            session.correction = .init(reversesBackOrder: true, rotatesBackSides: true)
            model.printManualDuplexBacks()
            try await wait { model.manualDuplexSession == nil }
            #expect(NSDictionary(dictionary: fixture.suite.defaults.dictionaryRepresentation()).isEqual(to: before))
            #expect(fixture.sent.isEmpty && fixture.ordinary.isEmpty)
            // A session started afterwards in the same window keeps the fixture's isolation of saved corrections.
            model.manualDuplexSubmit = { submission, complete in
                complete(.handedOff(printerName: submission.request.printerName ?? ""))
            }
            try await start(model)
            let profiles = fixture.preferences.printerProfiles
            model.printDocument(intent: .manualDuplex)
            try await wait { model.manualDuplexSession?.phase == .awaitingReload }
            let second = try #require(model.manualDuplexSession)
            #expect(second.id != session.id && second.printerName == "Snapshot Printer")
            second.correction = .init(reversesBackOrder: true, rotatesBackSides: true)
            model.printManualDuplexBacks()
            try await wait { model.manualDuplexSession == nil }
            #expect(fixture.preferences.printerProfiles == profiles)
            #expect(
                fixture.preferences.printerProfile(for: "Snapshot Printer").manualCorrection(for: .longEdge) == .init())
            #expect(fixture.sent.isEmpty && fixture.ordinary.isEmpty)
        }
    #endif
}
