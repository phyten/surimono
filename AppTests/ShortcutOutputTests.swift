import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct ShortcutOutputTests {
    @Test("既定の印刷キーは押し続けても刷り台へ入るだけで、離して押し直すと一度だけ送る", .timeLimit(.minutes(1)))
    func defaultPrint() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        #expect(f.dispatcher.handle(f.event("p")))
        #expect(f.model.mode == .print)
        try await f.render()
        #expect(f.submissions.count == 0)
        #expect(f.dispatcher.handle(f.event("p", repeating: true)))
        #expect(f.dispatcher.handle(f.event("p")))
        f.bridge.reconcile()
        f.dispatcher.performFromMenu(.documentPrint, event: f.event("p"))
        #expect(f.submissions.count == 0)
        f.release()
        f.allowsPrint = true
        #expect(f.dispatcher.handle(f.event("p")))
        #expect(f.submissions.count == 1)
        #expect(f.submissions.first?.showsPanel == false)
        #expect(f.dispatcher.handle(f.event("p", repeating: true)))
        #expect(f.submissions.count == 1 && f.exports == 0)
    }

    @Test("印刷を移したキーは両画面で同じ二段階になり、旧キーと古いメニュー項目からは印刷しない", .timeLimit(.minutes(1)))
    func movedPrint() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        try f.controller.edit(.documentPrint, keys: [.init(key: .character("k"), modifiers: .command)])
        #expect(!f.dispatcher.handle(f.event("p")))
        #expect(f.model.mode == .view)
        f.dispatcher.performFromMenu(.documentPrint, event: f.event("p"))
        #expect(f.model.mode == .view)
        #expect(f.dispatcher.handle(f.event("k", code: 40)))
        try await f.render()
        #expect(f.submissions.count == 0)
        // A binding edit must not forget a key held through the transition.
        try f.controller.edit(.printSettings, keys: [])
        #expect(f.dispatcher.handle(f.event("k", code: 40)))
        #expect(f.submissions.count == 0)
        f.release(40)
        f.allowsPrint = true
        f.dispatcher.performFromMenu(.documentPrint, event: f.event("k", code: 40))
        #expect(f.submissions.count == 1)
        f.release()
        #expect(!f.dispatcher.handle(f.event("p")))
        #expect(f.submissions.count == 1)
        try f.controller.edit(.documentPrint, keys: [])
        f.release(40)
        #expect(!f.dispatcher.handle(f.event("k", code: 40)))
        #expect(f.submissions.count == 1 && f.exports == 0)
    }

    @Test("レイアウトの全キーは刷り台に入るだけで、変更と解除は旧キーも止める", .timeLimit(.minutes(1)))
    func layoutsNeverPrint() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        for (index, expected) in ["a4Single", "a4Duplex", "a3BookletA4", "a4BookletA5", "a3TwoUp", "a4Handout3"]
            .enumerated()
        {
            f.release()
            #expect(f.dispatcher.handle(f.event(String(index + 1))))
            #expect(f.model.layoutID == expected)
            #expect(f.model.mode == .print)
            #expect(f.dispatcher.handle(f.event(String(index + 1), repeating: true)))
        }
        try await f.render()
        try f.controller.edit(.printLayoutSingle, keys: [.init(key: .character("j"), modifiers: .command)])
        f.release()
        #expect(!f.dispatcher.handle(f.event("1")))
        f.dispatcher.performFromMenu(.printLayoutSingle, event: f.event("1"))
        #expect(f.model.layoutID == "a4Handout3")
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        #expect(f.model.layoutID == "a4Single")
        try f.controller.edit(.printLayoutSingle, keys: [])
        f.release(38)
        #expect(!f.dispatcher.handle(f.event("j", code: 38)))
        for (series, two, four): (PaperSeries, String, String) in [
            (.a, "a4TwoUp", "a4FourUp"), (.b, "b5TwoUp", "b5FourUp"), (.letter, "letterTwoUp", "letterFourUp"),
        ] {
            f.model.choosePaperSeries(series, remembers: false)
            f.dispatcher.perform(.printLayoutTwoUpSmall)
            #expect(f.model.layoutID == two)
            f.dispatcher.perform(.printLayoutFourUp)
            #expect(f.model.layoutID == four)
        }
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("システム印刷は既存の準備を通ってダイアログ要求を一度だけ渡し、旧キーとリピートは止まる", .timeLimit(.minutes(1)))
    func systemPrint() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        try f.controller.edit(
            .documentPrintSystem, keys: [.init(key: .character("j"), modifiers: [.command, .option])])
        #expect(!f.dispatcher.handle(f.event("p", flags: [.command, .option])))
        f.dispatcher.performFromMenu(.documentPrintSystem, event: f.event("p", flags: [.command, .option]))
        #expect(f.model.mode == .view && f.submissions.count == 0 && f.exports == 0)
        f.allowsPrint = true
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38)))
        #expect(f.model.mode == .print)
        #expect(f.submissions.count == 0)
        try await f.render()
        try await f.wait { f.submissions.count == 1 }
        #expect(f.submissions.first?.showsPanel == true)
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38, repeating: true)))
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38)))
        #expect(f.submissions.count == 1 && f.exports == 0)
    }

    @Test("PDF書き出しは既存の準備を通り一度だけ要求し、プリンター送信はゼロ", .timeLimit(.minutes(1)))
    func exportPDF() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        try f.controller.edit(.documentExportPDF, keys: [.init(key: .character("j"), modifiers: [.command, .shift])])
        #expect(!f.dispatcher.handle(f.event("e", flags: [.command, .shift], code: 14)))
        f.dispatcher.performFromMenu(.documentExportPDF, event: f.event("e", flags: [.command, .shift], code: 14))
        #expect(f.model.mode == .view && f.submissions.count == 0 && f.exports == 0)
        f.allowsExport = true
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .shift], code: 38)))
        #expect(f.model.mode == .print)
        try await f.render()
        try await f.wait { f.exports == 1 }
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .shift], code: 38, repeating: true)))
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .shift], code: 38)))
        #expect(f.submissions.count == 0 && f.exports == 1)
    }

    @Test("入力変換中・記録中・シート・別窓では出力せず、押したまま保護が終わっても出力しない", .timeLimit(.minutes(1)))
    func protectedContexts() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        f.model.enterPrintMode()
        try await f.render()
        let text = NSTextView()
        f.responder = text
        text.setMarkedText(
            "かな", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.dispatcher.handle(f.event("p")))
        text.unmarkText()
        #expect(f.dispatcher.handle(f.event("p")))
        #expect(f.submissions.count == 0)
        f.release()
        f.hotKeys.beginRecording()
        #expect(!f.dispatcher.handle(f.event("p")))
        f.hotKeys.endRecording()
        #expect(f.dispatcher.handle(f.event("p")))
        f.release()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let owner = NSWindowController(window: sheet)
        defer {
            if f.window.attachedSheet === sheet { f.window.endSheet(sheet) }
            owner.close()
        }
        f.window.beginSheet(sheet, completionHandler: nil)
        #expect(!f.dispatcher.handle(f.event("p")))
        f.dispatcher.perform(.documentPrintSystem)
        f.window.endSheet(sheet)
        try await f.wait { f.window.attachedSheet == nil }
        #expect(f.dispatcher.handle(f.event("p")))
        f.release()
        f.activeWindow = sheet
        f.dispatcher.perform(.documentPrint)
        f.dispatcher.perform(.documentExportPDF)
        #expect(!f.dispatcher.handle(f.event("p")))
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("印刷中・不正なページ範囲・未準備の用紙は送信しない", .timeLimit(.minutes(1)))
    func modelGuards() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        f.model.enterPrintMode()
        f.dispatcher.perform(.documentPrint)
        f.dispatcher.perform(.documentExportPDF)
        #expect(f.submissions.count == 0 && f.exports == 0)
        try await f.render()
        try #require(f.model.beginPDFExport())
        for operation: ShortcutOperationID in [
            .documentPrint, .documentPrintSystem, .documentExportPDF, .printManualDuplex, .printDuplexTest,
        ] {
            f.dispatcher.perform(operation)
        }
        f.model.completePDFExport(to: nil)
        f.model.setPageRangeText("5--12")
        #expect(!f.model.canOutput)
        f.dispatcher.perform(.documentPrint)
        f.dispatcher.perform(.documentExportPDF)
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("グローバルとローカルのクリップボード印刷画面操作は、繰り返しても送信しない", .timeLimit(.minutes(1)))
    func globalNeverPrints() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        var id: UInt32?
        var openings: [Bool] = []
        let hotKeys = GlobalHotKeys(
            register: { _, value in
                id = value
                return {}
            }, activate: {},
            openClipboard: { printing in
                openings.append(printing)
                if printing { f.model.enterPrintMode() }
            })
        defer { hotKeys.stop() }
        let controller = ShortcutController(
            hotKeys: hotKeys, reservations: { [] }, keyboardLayout: { ShortcutOutputFixture.keyboardLayout })
        controller.start(preferences: f.preferences)
        try controller.edit(
            .globalClipboardPrintScreen,
            keys: [.init(key: .macVirtualKey(38), modifiers: [.command, .option, .control])])
        hotKeys.handle(try #require(id))
        try await f.render()
        hotKeys.handle(try #require(id))
        f.dispatcher.openClipboardPrintScreen = {
            openings.append(true)
            f.model.enterPrintMode()
        }
        f.dispatcher.perform(.clipboardOpenPrintScreen)
        f.dispatcher.perform(.clipboardOpenPrintScreen)
        #expect(openings == [true, true, true, true])
        #expect(f.model.mode == .print)
        #expect(f.submissions.count == 0 && f.exports == 0)
    }
}

@MainActor
extension ShortcutOutputTests {
    @Test("手動両面キーは表を一度だけ送り、待機中の印刷キーと固定Returnを裏の送信にしない", .timeLimit(.minutes(1)))
    func manualDuplex() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        var fronts = 0
        f.model.manualDuplexSubmit = { submission, complete in
            #expect(submission.pass == .fronts)
            fronts += 1
            if fronts > 1 { Issue.record("Unexpected second manual pass") }
            complete(.handedOff(printerName: "Test Printer"))
        }
        try f.controller.edit(.printManualDuplex, keys: [.init(key: .character("j"), modifiers: [.command, .option])])
        // It is print-screen-only, even when assigned.
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38)))
        #expect(f.model.mode == .view && fronts == 0)
        f.model.chooseLayout("a4Duplex")
        try await f.render()
        f.release(38)
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38)))
        try await f.wait { f.model.manualDuplexSession?.showsReload == true }
        #expect(fronts == 1)
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38, repeating: true)))
        f.dispatcher.perform(.documentPrint)
        f.dispatcher.perform(.documentPrintSystem)
        f.dispatcher.perform(.printManualDuplex)
        f.dispatcher.perform(.printDuplexTest)
        #expect(!f.dispatcher.handle(f.event("\r", flags: [], code: 36)))
        #expect(fronts == 1 && f.submissions.count == 0 && f.exports == 0)
        #expect(f.model.manualDuplexSession?.showsReload == true)
    }

    @Test("両面テストキーはテスト送信口へ一度だけ渡し、保持中と回答待ちは再送しない", .timeLimit(.minutes(1)))
    func duplexTest() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        var tests = 0
        f.model.duplexTestSubmit = { _, _, _, complete in
            tests += 1
            if tests > 1 { Issue.record("Unexpected second duplex test") }
            complete(.init(printerName: "Test Printer", duplex: .longEdge))
        }
        try f.controller.edit(.printDuplexTest, keys: [.init(key: .character("j"), modifiers: [.command, .option])])
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38)))
        #expect(tests == 0 && f.model.mode == .view)
        f.model.chooseLayout("a4Duplex")
        try await f.render()
        f.release(38)
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38)))
        try await f.wait { f.model.duplexTestResult != nil }
        #expect(tests == 1)
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38, repeating: true)))
        f.release(38)
        #expect(f.dispatcher.handle(f.event("j", flags: [.command, .option], code: 38)))
        f.dispatcher.perform(.documentPrint)
        f.dispatcher.perform(.documentPrintSystem)
        f.dispatcher.perform(.printManualDuplex)
        #expect(tests == 1 && f.submissions.count == 0 && f.exports == 0)
    }

    @Test("印刷メニューは変更・再生成・系列変更の直後に現在のキーとカード名を示す")
    func menuRecreation() throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        func buildMenu(printTitle: String = "Print…") {
            f.menu.removeAllItems()
            for _ in 0..<7 {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.submenu = NSMenu()
                f.menu.addItem(item)
            }
            let file = f.menu.items[1].submenu!
            for (title, key, flags): (String, String, NSEvent.ModifierFlags) in [
                (printTitle, "p", .command), ("Print with System Dialog…", "p", [.command, .option]),
            ] {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
                item.keyEquivalentModifierMask = flags
                file.addItem(item)
            }
            let exports = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
            exports.submenu = NSMenu()
            file.addItem(exports)
            exports.submenu!.addItem(NSMenuItem(title: "PDF for Reading…", action: nil, keyEquivalent: ""))
            let sheets = NSMenuItem(title: "PDF of the Sheets…", action: nil, keyEquivalent: "e")
            sheets.keyEquivalentModifierMask = [.command, .shift]
            exports.submenu!.addItem(sheets)
            let layouts = NSMenuItem(title: "Print Layout", action: nil, keyEquivalent: "")
            layouts.submenu = NSMenu()
            f.menu.items[4].submenu!.addItem(layouts)
            for index in 0..<8 {
                layouts.submenu!.addItem(
                    NSMenuItem(title: "Layout \(index)", action: nil, keyEquivalent: index < 6 ? String(index + 1) : "")
                )
            }
            f.bridge.reconcile()
        }
        buildMenu()
        #expect(f.bridge.items[.documentPrint]?.keyEquivalent == "p")
        #expect(
            ShortcutPrintLayouts.operations.prefix(6).compactMap { f.bridge.items[$0]?.keyEquivalent } == [
                "1", "2", "3", "4", "5", "6",
            ])
        try f.controller.edit(.documentPrint, keys: [.init(key: .character("k"), modifiers: .command)])
        try f.controller.edit(.documentPrintSystem, keys: [])
        try f.controller.edit(.documentExportPDF, keys: [.init(key: .character("j"), modifiers: [.command, .shift])])
        try f.controller.edit(.documentExportReadingPDF, keys: [.init(key: .character("u"), modifiers: .command)])
        try f.controller.edit(.printLayoutSingle, keys: [])
        buildMenu()
        #expect(f.bridge.items[.documentPrint]?.keyEquivalent == "k")
        #expect(f.bridge.items[.documentPrintSystem]?.keyEquivalent == "")
        #expect(f.bridge.items[.documentExportPDF]?.keyEquivalent == "j")
        #expect(f.bridge.items[.documentExportReadingPDF]?.keyEquivalent == "u")
        #expect(f.bridge.items[.documentExportPDF]?.keyEquivalentModifierMask == [.command, .shift])
        #expect(f.bridge.items[.printLayoutSingle]?.keyEquivalent == "")
        f.model.choosePaperSeries(.b, remembers: false)
        f.model.enterPrintMode()
        buildMenu(printTitle: "Print")
        #expect(f.bridge.items[.documentPrint]?.title == "Print")
        #expect(f.bridge.items[.documentPrint]?.keyEquivalent == "k")
        #expect(
            f.bridge.items[.printLayoutHandout]?.title == PrintLayout.a4Handout3.displayName(language: f.model.language)
        )
        #expect(
            f.bridge.items[.printLayoutTwoUpSmall]?.title == PrintLayout.b5TwoUp.displayName(language: f.model.language)
        )
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("スタイル比較のキーは表示画面から開き、シャッフルは選んだ群を使い比較中だけ実行する")
    func comparisonCommands() throws {
        let f = ShortcutOutputFixture(format: .markdown)
        defer { f.close() }
        let chosen = Array(f.model.library.themes.filter(\.isBuiltIn).prefix(5).map(\.id))
        try #require(chosen.count == 5)
        for id in chosen { f.preferences.toggleFavoriteTheme(id) }
        try f.controller.edit(.styleCompare, keys: [.init(key: .character("k"), modifiers: .command)])
        try f.controller.edit(.compareShuffle, keys: [.init(key: .character("j"), modifiers: .command)])
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        #expect(f.model.mode == .view && f.model.themeComparison == nil)
        #expect(f.dispatcher.handle(f.event("k", code: 40)))
        #expect(f.model.mode == .compare)
        f.model.compareFilterID = "favorites"
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        let comparison = try #require(f.model.themeComparison)
        #expect(comparison.candidates.count == 4)
        #expect(comparison.candidates.contains(f.model.themeID))
        #expect(Set(comparison.candidates).isSubset(of: Set(chosen + [f.model.themeID])))
        var zoomActions: [ShortcutOperationID] = []
        f.dispatcher.executeOverride = { zoomActions.append($0) }
        for key in ["+", "=", "-", "0"] { #expect(f.dispatcher.handle(f.event(key))) }
        #expect(zoomActions.isEmpty)
        f.dispatcher.executeOverride = nil
        f.dispatcher.perform(.printSettings)
        #expect(!f.model.isPrintFinishPresented)
        let wasFavorite = f.model.isFavoriteTheme
        f.dispatcher.perform(.styleFavorite)
        #expect(f.model.isFavoriteTheme != wasFavorite)
        #expect(!f.dispatcher.handle(f.event("\u{1B}", flags: [], code: 53)))
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("残りの操作は既存の形式とモードの条件を保って開く")
    func remainingCommands() {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        f.dispatcher.perform(.viewOutline)
        #expect(!f.model.isOutlinePresented)
        f.dispatcher.perform(.viewDocumentInfo)
        #expect(f.model.isFiguresPresented)
        f.dispatcher.perform(.printSettings)
        #expect(f.model.isPrintFinishPresented)
        f.dispatcher.perform(.styleCompare)
        #expect(f.model.mode == .view)
        let favorite = f.model.isFavoriteTheme
        f.dispatcher.perform(.styleFavorite)
        #expect(f.model.isFavoriteTheme == favorite)
        f.dispatcher.perform(.htmlSmartRemoval)
        #expect(!f.model.isSmartRemovalEnabled)
        f.dispatcher.perform(.htmlReviewRemoval)
        #expect(!f.model.isReviewingSmartRemoval)
        f.model.chooseLayout("a4Single")
        f.dispatcher.perform(.printFoldPreview)
        #expect(!f.model.showsFold)
        f.model.chooseLayout("a4BookletA5")
        f.dispatcher.perform(.printFoldPreview)
        #expect(f.model.showsFold)
        f.dispatcher.perform(.printReviewIssues)
        #expect(!f.model.isPrintIssuesPresented)
        f.model.isFiguresPresented = false
        f.dispatcher.perform(.viewDocumentInfo)
        #expect(!f.model.isFiguresPresented)
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("HTMLの削除キーは有効化と確認に接続し、出力しない")
    func htmlCommands() {
        let f = ShortcutOutputFixture(format: .html)
        defer { f.close() }
        f.dispatcher.perform(.htmlSmartRemoval)
        #expect(f.model.isSmartRemovalEnabled)
        f.dispatcher.perform(.htmlReviewRemoval)
        #expect(f.model.isReviewingSmartRemoval)
        f.dispatcher.perform(.htmlSmartRemoval)
        #expect(!f.model.isSmartRemovalEnabled && !f.model.isReviewingSmartRemoval)
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("出力キーの変更と復元の提案には印刷の説明があり、固定Returnと裸キーは割り当てられない")
    func assignmentSafeguards() throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        for operation: ShortcutOperationID in [
            .documentPrint, .documentPrintSystem, .documentExportPDF, .printManualDuplex, .printDuplexTest,
        ] {
            #expect(ShortcutText.outputWarning(operation) != nil)
            #expect(throws: (any Error).self) { try f.controller.edit(operation, keys: [.init(key: .character("j"))]) }
            #expect(throws: (any Error).self) {
                try f.controller.edit(operation, keys: [.init(key: .named(.return), modifiers: .command)])
            }
            _ = try f.controller.proposal(operation, keys: [.init(key: .character("j"), modifiers: .command)])
        }
        #expect(f.submissions.count == 0 && f.exports == 0)
    }
}

@MainActor
extension ShortcutOutputTests {
    @Test("画面が重ならない比較と折り見本の操作は同じキーを共有できる")
    func disjointStageKeys() throws {
        let f = ShortcutOutputFixture(format: .markdown)
        defer { f.close() }
        let key = ShortcutCombination(key: .character("j"), modifiers: .command)
        try f.controller.edit(.compareShuffle, keys: [key])
        try f.controller.edit(.printFoldPreview, keys: [key])
        var actions: [ShortcutOperationID] = []
        f.dispatcher.executeOverride = { actions.append($0) }
        f.model.mode = .compare
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        #expect(actions == [.compareShuffle])
        f.release(38)
        f.model.mode = .print
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        #expect(actions == [.compareShuffle, .printFoldPreview])
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test(
        "残りのメニュー外操作も割当と解除を即時に配送へ反映する",
        arguments: [
            ShortcutOperationID.viewOutline, .viewDocumentInfo, .styleCompare, .styleFavorite, .compareShuffle,
            .printFoldPreview, .printReviewIssues, .htmlSmartRemoval, .htmlReviewRemoval,
            .printManualDuplex, .printDuplexTest,
        ])
    func remainingBindings(operation: ShortcutOperationID) throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        if operation == .compareShuffle { f.model.mode = .compare }
        if [.printFoldPreview, .printManualDuplex, .printDuplexTest].contains(operation) { f.model.mode = .print }
        var actions: [ShortcutOperationID] = []
        f.dispatcher.executeOverride = { actions.append($0) }
        try f.controller.edit(operation, keys: [.init(key: .character("j"), modifiers: .command)])
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        #expect(actions == [operation])
        try f.controller.edit(operation, keys: [])
        f.release(38)
        #expect(!f.dispatcher.handle(f.event("j", code: 38)))
        #expect(actions == [operation])
        #expect(f.submissions.count == 0 && f.exports == 0)
    }
}

@MainActor
extension ShortcutOutputTests {
    @Test("追跡中のメニューに窓なしで届く印刷キーも離すまで送信せず、固定のメニュー確定は保つ", .timeLimit(.minutes(1)))
    func menuKeyWithoutWindow() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        f.dispatcher.performFromMenu(.printSettings, event: f.event("\r", flags: [], code: 36))
        #expect(f.model.isPrintFinishPresented)
        let key = f.event("p", inWindow: false)
        try #require(key.window == nil)
        #expect(!f.dispatcher.handle(key))
        f.dispatcher.performFromMenu(.documentPrint, event: key)
        #expect(f.model.mode == .print)
        try await f.render()
        f.dispatcher.performFromMenu(.documentPrint, event: key)
        #expect(f.submissions.count == 0)
        f.release()
        f.allowsPrint = true
        f.dispatcher.performFromMenu(.documentPrint, event: key)
        #expect(f.submissions.count == 1 && f.exports == 0)
    }
}
