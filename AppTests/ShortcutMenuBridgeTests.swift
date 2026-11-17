import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct ShortcutMenuBridgeTests {
    @MainActor
    private final class ExternalMenuItem: NSMenuItem {
        var externalValue: String?
        override var keyEquivalent: String {
            get { externalValue ?? super.keyEquivalent }
            set { super.keyEquivalent = newValue }
        }
    }

    @MainActor
    private final class Fixture {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let hotKeys = GlobalHotKeys(register: { _, _ in
            Issue.record("Unexpected global registration")
            return nil
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        lazy var windowController = NSWindowController(window: window)
        let lifecycleNotifications = NotificationCenter()
        var activeWindow: NSWindow?
        var activeModel: DocumentViewModel?
        var menu = NSMenu()
        var calls: [ShortcutOperationID] = []
        var external = ""
        lazy var preferences = AppPreferences(defaults: suite.defaults)
        lazy var controller = ShortcutController(
            hotKeys: hotKeys, reservations: { [] },
            keyboardLayout: {
                ShortcutKeyboardLayout.project { code, flags in
                    switch code {
                    case 15: "r"
                    case 40: "k"
                    case 38: "j"
                    default: nil
                    }
                }
            })
        lazy var bridge = ShortcutMenuBridge(
            controller: controller, menu: { [unowned self] in menu },
            keyWindow: { [unowned self] in activeWindow }, model: { [unowned self] in activeModel },
            lifecycleNotifications: lifecycleNotifications,
            localize: { "test:" + $0 },
            externalKey: { [unowned self] item in
                item.title == "test:Reload" ? external : ""
            })
        lazy var dispatcher = ShortcutDispatcher(
            controller: controller, bridge: bridge, keyWindow: { [unowned self] in activeWindow },
            model: { [unowned self] in activeModel })

        init() {
            window.isReleasedWhenClosed = false
            activeWindow = window
            controller.start(preferences: preferences)
            for _ in 0..<7 {
                let item = NSMenuItem()
                item.submenu = NSMenu()
                menu.addItem(item)
            }
            for (index, title) in [
                (1, "Open from Clipboard"), (4, "Reload"), (6, "Keys and Gestures"), (3, "Single Page"), (3, "Spread"),
            ] {
                menu.items[index].submenu?.addItem(NSMenuItem(title: "test:" + title, action: nil, keyEquivalent: ""))
            }
            dispatcher.executeOverride = { [unowned self] in calls.append($0) }
            bridge.reconcile()
        }

        func document(kind: String = "document", printMode: Bool = false) -> DocumentViewModel {
            let binder =
                kind == "binder"
                ? BinderModel(orderedURLs: [directory.appendingPathComponent("a.md")], read: { _ in Data() }) : nil
            let bundle = kind == "images" ? ImageBundleModel(urls: [directory.appendingPathComponent("a.png")]) : nil
            let model = DocumentViewModel(
                data: kind == "clipboard" ? Data("# Clipboard".utf8) : Data(),
                fileURL: kind == "clipboard" ? nil : directory.appendingPathComponent("document.pdf"),
                format: kind == "clipboard" ? .markdown : .pdf, preferences: preferences,
                library: UserLibrary(root: directory), imageBundle: bundle,
                binder: binder)
            model.printSubmit = { _, _, _ in Issue.record("Printing is forbidden") }
            model.outputOverride = { _, _ in Issue.record("Output is forbidden") }
            model.window = window
            model.mode = printMode ? .print : .view
            activeModel = model
            return model
        }

        func event(
            _ key: String, code: UInt16 = 40, flags: NSEvent.ModifierFlags = .command,
            type: NSEvent.EventType = .keyDown, repeatKey: Bool = false
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: activeWindow?.windowNumber ?? 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: code)!
        }

        /// Item changes are reconciled on the next turn of the main queue, after AppKit's notification has returned.
        func afterMenuNotifications() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        func close() {
            dispatcher.stop()
            activeModel?.stop()
            hotKeys.stop()
            activeModel = nil
            activeWindow = nil
            windowController.close()
            window.contentView = nil
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("再読み込みの変更はメニューを一度も開かず直ちに一度だけ実行され旧キーは実行されない")
    func changeWithoutOpening() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        try fixture.controller.edit(
            .documentReload, keys: [.init(key: .character("k"), modifiers: [.command, .shift])])
        let item = try #require(fixture.bridge.items[.documentReload])
        #expect(item.keyEquivalent == "k")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        #expect(fixture.dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        #expect(!fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls == [.documentReload])
        #expect(!fixture.dispatcher.handle(fixture.event("k", flags: [.command, .shift], type: .keyUp)))
        #expect(fixture.dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        #expect(fixture.calls == [.documentReload, .documentReload])
    }

    @Test("再生成した項目もイベント前に識別し解除したキーを復活させない")
    func rebuiltAndCleared() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        try fixture.controller.edit(.documentReload, keys: [.init(key: .character("k"), modifiers: .command)])
        let parent = try #require(fixture.menu.items[4].submenu)
        parent.removeAllItems()
        let rebuilt = NSMenuItem(title: "test:Reload", action: nil, keyEquivalent: "r")
        parent.addItem(rebuilt)
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(rebuilt.identifier?.rawValue == "surimono.shortcut.document.reload")
        #expect(rebuilt.keyEquivalent == "k")
        try fixture.controller.edit(.documentReload, keys: [])
        #expect(rebuilt.keyEquivalent.isEmpty)
        #expect(!fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(!fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.calls == [.documentReload])
    }

    @Test("メニュー追跡と項目の追加変更とキー窓とアクティブ化で再帰せず再同期する")
    func notifications() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.bridge.start()
        try fixture.controller.edit(.appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)])
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSApplication.didBecomeActiveNotification,
        ] {
            fixture.lifecycleNotifications.post(
                name: name, object: name == NSApplication.didBecomeActiveNotification ? NSApp : fixture.window)
            #expect(fixture.bridge.items[.appKeyGuide]?.keyEquivalent == "k")
        }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        let parent = try #require(fixture.menu.items[6].submenu)
        parent.removeAllItems()
        let item = NSMenuItem(title: "test:Keys and Gestures", action: nil, keyEquivalent: "")
        parent.addItem(item)
        await fixture.afterMenuNotifications()
        #expect(item.keyEquivalent == "k")
        item.keyEquivalent = "z"
        await fixture.afterMenuNotifications()
        #expect(item.keyEquivalent == "k")
    }

    @Test("項目の変更通知の中ではキーを書き戻さず、通知が終わってから再同期する")
    func deferredItemChanges() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.bridge.start()
        try fixture.controller.edit(.appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)])
        let item = try #require(fixture.bridge.items[.appKeyGuide])
        // AppKit changes key equivalents while it holds a lock (it did so while filling the Services menu).
        // Writing the key back inside that notification deadlocked the main thread.
        item.keyEquivalent = "z"
        #expect(item.keyEquivalent == "z")
        await fixture.afterMenuNotifications()
        #expect(item.keyEquivalent == "k")
        // A key event does not wait for the deferred pass: the dispatcher reconciles before it decides.
        item.keyEquivalent = "z"
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(item.keyEquivalent == "k")
        #expect(fixture.calls == [.appKeyGuide])
    }

    @Test("窓のない起動後に完成したメニューを取り付けてもアプリ更新で保存済みキーを反映する")
    func installedMenuWithoutWindow() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.activeWindow = nil
        try fixture.controller.edit(.documentReload, keys: [.init(key: .character("k"), modifiers: .command)])
        let assembled = fixture.menu
        fixture.menu = NSMenu()
        fixture.bridge.start()
        #expect(fixture.bridge.items.isEmpty)
        // No item notification follows this assignment: SwiftUI has already assembled the tree off to the side.
        fixture.menu = assembled
        fixture.lifecycleNotifications.post(name: NSApplication.didUpdateNotification, object: NSApp)
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "k")
        #expect(fixture.bridge.items[.clipboardOpen]?.keyEquivalent == "n")
        try fixture.controller.edit(.documentReload, keys: [])
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "")
        fixture.bridge.stop()
        let item = try #require(fixture.bridge.items[.documentReload])
        item.keyEquivalent = "z"
        fixture.lifecycleNotifications.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        #expect(item.keyEquivalent == "z")
    }

    @Test("起動時の同期は同じターンで取り付けたメニューを窓やアクティブ化なしで拾う")
    func deferredLaunchReconciliation() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.activeWindow = nil
        let assembled = fixture.menu
        fixture.menu = NSMenu()
        fixture.bridge.start()
        fixture.menu = assembled
        // A FIFO main-queue barrier waits for the bridge's queued pass; no sleep or activation is involved.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "r")
        #expect(fixture.bridge.items[.viewSingle]?.keyEquivalent == "1")
        #expect(fixture.bridge.items[.viewSpread]?.keyEquivalent == "2")
        #expect(fixture.bridge.items[.clipboardOpen]?.keyEquivalent == "n")
    }

    @Test("WindowReaderは窓を閉じて階層を外した後に遅延通知せずビューも解放する")
    func readerTeardown() async {
        var reports = 0
        weak var releasedReader: WindowReader.ReaderView?
        // Run teardown from AppKit's usual main-queue boundary, rather than inside the test's Swift task.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                autoreleasepool {
                    let window = NSWindow(
                        contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let controller = NSWindowController(window: window)
                    let reader = WindowReader.ReaderView { _ in reports += 1 }
                    releasedReader = reader
                    window.contentView = reader
                    controller.close()
                    window.contentView = nil
                }
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(releasedReader == nil)
        #expect(reports == 0)
    }

    @Test("接続済み操作だけ競合を移譲でき解除後に既定キーが復活しない")
    func transferAndRestore() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let r = ShortcutCombination(key: .character("r"), modifiers: .command)
        #expect(throws: ShortcutModelError.self) { try fixture.controller.edit(.appKeyGuide, keys: [r]) }
        try fixture.controller.edit(.appKeyGuide, keys: [r], takeConflicts: true)
        #expect(fixture.controller.snapshot.keys(for: .documentReload).isEmpty)
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "")
        #expect(throws: ShortcutModelError.self) { try fixture.controller.edit(.documentReload, keys: nil) }
        try fixture.controller.edit(.documentReload, keys: nil, takeConflicts: true)
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "r")
        #expect(fixture.bridge.items[.appKeyGuide]?.keyEquivalent == "")
        try fixture.controller.edit(.documentPrint, keys: [])
        try fixture.controller.edit(.printSettings, keys: [])
    }

    @Test(
        "文書と束と合本とクリップボードの両モードで即時配送し設定とウェルカムには文書操作を流さない",
        arguments: ["document", "images", "binder", "clipboard", "welcome", "settings"], [false, true])
    func windowKinds(kind: String, printMode: Bool) throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: kind, printMode: printMode)
        defer { model.stop() }
        try fixture.controller.edit(.documentReload, keys: [.init(key: .character("k"), modifiers: .command)])
        if ["welcome", "settings"].contains(kind) {
            let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let otherController = NSWindowController(window: other)
            defer {
                fixture.activeWindow = fixture.window
                otherController.close()
            }
            fixture.activeWindow = other
            // Even a stale activeModel must not route to the previous window.
            #expect(fixture.dispatcher.handle(fixture.event("k")))
            #expect(fixture.calls.isEmpty)
        } else {
            #expect(fixture.dispatcher.handle(fixture.event("k")))
            #expect(fixture.calls == [.documentReload])
        }
        #expect(fixture.bridge.items[.viewSingle]?.keyEquivalent == "1")
        #expect(fixture.bridge.items[.viewSpread]?.keyEquivalent == "2")
    }

    @Test("入力欄の裸キーと矢印と空白は通しIME変換中と記録中は文書操作を呼ばない")
    func typingAndRecorder() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        let editor = NSTextView(frame: .zero)
        fixture.window.contentView = editor
        #expect(fixture.window.makeFirstResponder(editor))
        #expect(fixture.window.firstResponder === editor)
        #expect(!editor.hasMarkedText())
        for key in ["m", "v", "t", " ", "\u{F700}", "k"] {
            #expect(!fixture.dispatcher.handle(fixture.event(key, flags: [])))
        }
        #expect(!fixture.dispatcher.handle(fixture.event("a")))
        #expect(!fixture.dispatcher.handle(fixture.event("c")))
        #expect(fixture.calls.isEmpty)
        #expect(fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls == [.documentReload])
        fixture.calls = []
        editor.setMarkedText(
            "あ", selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls.isEmpty)
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        #expect(fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls == [.documentReload])
        fixture.calls = []
        try fixture.controller.edit(.documentReload, keys: [.init(key: .character("k"), modifiers: .control)])
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "")
        #expect(!fixture.dispatcher.handle(fixture.event("k", flags: .control)))
        #expect(fixture.calls.isEmpty)
        try fixture.controller.edit(.documentReload, keys: nil)
        fixture.hotKeys.beginRecording()
        #expect(!fixture.dispatcher.handle(fixture.event("r", code: 15)))
        fixture.hotKeys.endRecording()
        #expect(fixture.calls.isEmpty)
        #expect(fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls == [.documentReload])
    }

    @Test("macOSが上書きした実効キーを保護し他の割当との衝突を停止する")
    func externalOwner() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try fixture.controller.edit(.appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)])
        let parent = try #require(fixture.menu.items[4].submenu)
        parent.removeAllItems()
        let externalItem = ExternalMenuItem(title: "test:Reload", action: nil, keyEquivalent: "r")
        externalItem.externalValue = "k"
        parent.addItem(externalItem)
        fixture.external = "k"
        fixture.bridge.reconcile()
        #expect(
            fixture.controller.externalMenuKeys[.documentReload] == .init(key: .character("k"), modifiers: .command))
        #expect(externalItem.keyEquivalent == "k")
        #expect(fixture.bridge.items[.appKeyGuide]?.keyEquivalent == "")
        #expect(
            fixture.controller.snapshot.keys(for: .appKeyGuide) == [.init(key: .character("k"), modifiers: .command)])
        #expect(!fixture.controller.status(for: .appKeyGuide).isEmpty)
        #expect(throws: ShortcutController.EditError.self) { try fixture.controller.edit(.documentReload, keys: []) }
        #expect(throws: ShortcutModelError.self) {
            try fixture.controller.edit(
                .appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)], takeConflicts: true)
        }
        externalItem.externalValue = nil
        fixture.external = ""
        fixture.bridge.reconcile()
        try fixture.controller.edit(.documentReload, keys: [])
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "")
        #expect(fixture.bridge.items[.appKeyGuide]?.keyEquivalent == "k")
    }

    @Test("曖昧な同名項目は勝手に識別せず隠した文書保存キーも有効にしない")
    func ambiguousAndHidden() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = try #require(fixture.menu.items[4].submenu)
        parent.addItem(NSMenuItem(title: "test:Reload", action: nil, keyEquivalent: "r"))
        let save = NSMenuItem(title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        parent.addItem(save)
        fixture.bridge.reconcile()
        #expect(fixture.bridge.ambiguous == [.documentReload])
        #expect(fixture.bridge.items[.documentReload] == nil)
        #expect(parent.items.filter { $0.title == "test:Reload" }.allSatisfy { $0.keyEquivalent == "r" })
        #expect(save.isHidden && !save.allowsKeyEquivalentWhenHidden)
    }

    @Test("SwiftUIが生成した実メニューでも開かず変更を反映しクリックとキーを同じ操作に届ける")
    func generatedMenuWithoutOpening() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        let sharedBridge = ShortcutDispatcher.shared.bridge
        sharedBridge.stop()
        let live = ShortcutMenuBridge(
            controller: fixture.controller, keyWindow: { fixture.activeWindow }, model: { model },
            lifecycleNotifications: fixture.lifecycleNotifications)
        let dispatcher = ShortcutDispatcher(
            controller: fixture.controller, bridge: live,
            keyWindow: { fixture.window }, model: { model })
        defer {
            dispatcher.stop()
            sharedBridge.start()
        }
        var calls: [ShortcutOperationID] = []
        dispatcher.executeOverride = { calls.append($0) }
        live.start()
        try fixture.controller.edit(
            .documentReload, keys: [.init(key: .character("k"), modifiers: [.command, .shift])])
        let item = try #require(live.items[.documentReload])
        #expect(item.keyEquivalent == "k")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        #expect(dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        #expect(!dispatcher.handle(fixture.event("r", code: 15)))
        #expect(calls == [.documentReload])
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(calls == [.documentReload, .documentReload])
        try fixture.controller.edit(.documentReload, keys: [])
        #expect(item.keyEquivalent.isEmpty)
        #expect(!dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        // Conditional SwiftUI nodes must exist even before a binder/image menu was ever opened.
        for operation: ShortcutOperationID in [
            .documentSaveAsFile, .documentOpenBinder, .listToggle, .listMoveUp, .listMoveDown, .binderOddPageStarts,
        ] {
            #expect(live.items[operation] != nil)
        }
        #expect(calls == [.documentReload, .documentReload])
    }

    @Test(
        "実メニュー全体の既定キーは文書種別と表示印刷モードを変えても従来どおり",
        arguments: ["document", "images", "binder", "clipboard", "welcome", "settings"], [false, true])
    func generatedDefaultsInEveryWindow(kind: String, printMode: Bool) throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: kind, printMode: printMode)
        defer { model.stop() }
        if ["welcome", "settings"].contains(kind) { fixture.activeModel = nil }
        let sharedBridge = ShortcutDispatcher.shared.bridge
        sharedBridge.stop()
        let live = ShortcutMenuBridge(
            controller: fixture.controller, keyWindow: { fixture.activeWindow }, model: { fixture.activeModel },
            lifecycleNotifications: fixture.lifecycleNotifications)
        defer {
            live.stop()
            sharedBridge.start()
        }
        live.start()
        let menu = try #require(NSApp.mainMenu)
        // Default-key checks alone could pass via SwiftUI's fallback even if the bridge never owned these items.
        for operation in [ShortcutOperationID.documentPrint, .documentPrintSystem, .documentExportPDF, .printSettings]
            + ShortcutPrintLayouts.operations
        {
            let item = try #require(live.items[operation], "Unmanaged menu operation: \(operation)")
            #expect(item.target === live)
            #expect(item.identifier == ShortcutMenuBridge.identifier(operation))
        }
        let items = ShortcutMenuBaselineTests.items(menu)
        let before = items.map { ShortcutMenuKey(item: $0) }
        live.reconcile()
        for (item, expected) in zip(items, before) {
            #expect(item.keyEquivalent == expected.key)
            #expect(item.keyEquivalentModifierMask == expected.modifiers)
        }
        #expect(live.items[.documentSaveAsFile]?.isHidden == (kind != "clipboard"))
        #expect(live.items[.listToggle]?.isHidden == !["images", "binder"].contains(kind))
        try ShortcutMenuBaselineTests().defaultMenuKeys()
    }

    @Test("接続した表示のキーは実モデルの単ページと見開きを従来どおり変える")
    func actualViewOperation() {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        fixture.dispatcher.executeOverride = nil
        fixture.dispatcher.perform(.viewSingle)
        #expect(model.viewOptions.layout == .single)
        fixture.dispatcher.perform(.viewSpread)
        #expect(model.viewOptions.layout == .spread)
    }

    @Test("記録とイベントの論理キーはShift付き文字とDeleteと矢印を同じ意味に揃える")
    func logicalEventKeys() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        #expect(
            ShortcutDispatcher.combination(fixture.event("K", flags: [.command, .shift, .capsLock]))
                == .init(key: .character("k"), modifiers: [.command, .shift]))
        #expect(
            ShortcutDispatcher.combination(fixture.event("\u{7F}", code: 51))
                == .init(key: .named(.deleteBackward), modifiers: .command))
        #expect(
            ShortcutDispatcher.combination(fixture.event("\u{F700}", code: 126, flags: [.command, .option, .function]))
                == .init(key: .named(.upArrow), modifiers: [.command, .option]))
        #expect(ShortcutDispatcher.combination(fixture.event("k", flags: [.command, .function])) == nil)
        #expect(
            try fixture.controller.logicalKey(.init(key: .macVirtualKey(40), modifiers: [.command, .option]))
                == .init(key: .character("k"), modifiers: [.command, .option]))
    }

    @Test(
        "注入したキー窓を切り替えてもメニューを開かず現在の登録文書だけに配送する",
        arguments: ["document", "images", "binder", "clipboard"])
    func actualKeyWindowRouting(kind: String) throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: kind)
        defer { model.stop() }
        let sharedBridge = ShortcutDispatcher.shared.bridge
        sharedBridge.stop()
        let live = ShortcutMenuBridge(
            controller: fixture.controller, keyWindow: { fixture.activeWindow },
            lifecycleNotifications: fixture.lifecycleNotifications)
        let dispatcher = ShortcutDispatcher(
            controller: fixture.controller, bridge: live, keyWindow: { fixture.activeWindow })
        defer {
            dispatcher.stop()
            sharedBridge.start()
        }
        var calls: [ShortcutOperationID] = []
        dispatcher.executeOverride = { calls.append($0) }
        DocumentWindows.shared.register(model, for: fixture.window)
        fixture.activeWindow = fixture.window
        live.start()
        try fixture.controller.edit(
            .documentReload, keys: [.init(key: .character("k"), modifiers: [.command, .shift])])
        #expect(live.items[.documentReload]?.keyEquivalent == "k")
        #expect(dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        _ = dispatcher.handle(fixture.event("k", flags: [.command, .shift], type: .keyUp))
        #expect(calls == [.documentReload])

        let unrelated = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        unrelated.isReleasedWhenClosed = false
        let unrelatedController = NSWindowController(window: unrelated)
        defer { unrelatedController.close() }
        fixture.activeWindow = unrelated
        #expect(DocumentWindows.shared.model(for: fixture.activeWindow) == nil)
        #expect(dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        _ = dispatcher.handle(fixture.event("k", flags: [.command, .shift], type: .keyUp))
        #expect(calls == [.documentReload])

        fixture.activeWindow = fixture.window
        #expect(dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        #expect(calls == [.documentReload, .documentReload])
        fixture.activeWindow = nil
        #expect(!dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        dispatcher.perform(.documentReload)
        #expect(calls == [.documentReload, .documentReload])
    }

    @Test("モードを変えるキーは離すまで再実行せず縮小などの連続操作はリピートを保つ")
    func repeatPolicy() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        try fixture.controller.edit(.viewHtmlPresentation, keys: [.init(key: .character("k"), modifiers: .command)])
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.dispatcher.handle(fixture.event("k", repeatKey: true)))
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.calls == [.viewHtmlPresentation])
        _ = fixture.dispatcher.handle(fixture.event("k", type: .keyUp))
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.calls == [.viewHtmlPresentation, .viewHtmlPresentation])
        fixture.calls = []
        #expect(fixture.dispatcher.handle(fixture.event("-", code: 27)))
        #expect(fixture.dispatcher.handle(fixture.event("-", code: 27, repeatKey: true)))
        #expect(fixture.calls == [.viewZoomOut, .viewZoomOut])
    }

}
