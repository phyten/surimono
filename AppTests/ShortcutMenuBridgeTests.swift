import AppKit
import Observation
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
    private final class SaveTarget: NSObject {
        var saves = 0
        @objc func saveDocument(_ sender: Any?) { saves += 1 }
    }

    private nonisolated final class MainMenu: NSMenu {
        var holdsHighlight = false
        override var highlightedItem: NSMenuItem? {
            holdsHighlight ? items.first : super.highlightedItem
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
        var menu: NSMenu = MainMenu()
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
            lifecycleNotifications: lifecycleNotifications, preferences: { [unowned self] in preferences },
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
        // The synthetic session stays open while the test yields to the ordinary host run loop.
        try #require(fixture.menu as? MainMenu).holdsHighlight = true
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
        let model = fixture.document()
        fixture.bridge.reconcile()
        let parent = try #require(fixture.menu.items[6].submenu)
        let center = NotificationCenter.default
        // The bridge has outstanding work when AppKit starts rebuilding the File menu.
        let stale = try #require(fixture.bridge.items[.appKeyGuide])
        stale.keyEquivalent = "x"
        let edit = NSMenuItem(title: "Move", action: #selector(NSDocument.move(_:)), keyEquivalent: "m")
        let file = try #require(fixture.menu.items[1].submenu)
        edit.allowsKeyEquivalentWhenHidden = true
        edit.isAlternate = true
        edit.keyEquivalentModifierMask = [.shift, .command]
        let passes = fixture.bridge.reconcilePasses
        let writes = fixture.bridge.writes.counts
        let hides = fixture.bridge.updates.hider.writes.counts
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        #expect(fixture.bridge.reconcilePasses == passes)
        #expect(fixture.bridge.writes.counts == writes)
        #expect(fixture.bridge.updates.hider.writes.counts == hides)
        file.addItem(edit)
        var expected = hides
        for property in ["isHidden", "isAlternate", "allowsKeyEquivalentWhenHidden"] {
            expected[property, default: 0] += 1
        }
        #expect(fixture.bridge.updates.hider.writes.counts == expected)
        #expect(edit.isHidden && !edit.isAlternate && !edit.allowsKeyEquivalentWhenHidden)
        #expect(edit.keyEquivalent == "m" && edit.keyEquivalentModifierMask == [.shift, .command])
        #expect(stale.keyEquivalent == "x")
        edit.isHidden = false
        expected["isHidden", default: 0] += 1
        #expect(edit.isHidden && fixture.bridge.updates.hider.writes.counts == expected)
        let export = NSMenuItem(title: String(localized: "Export"), action: nil, keyEquivalent: "")
        export.submenu = NSMenu()
        file.addItem(export)
        #expect(!export.isHidden && fixture.bridge.updates.hider.writes.counts == expected)
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        parent.removeItem(stale)
        let item = NSMenuItem(title: "test:Keys and Gestures", action: nil, keyEquivalent: "z")
        parent.addItem(item)
        model.mode = .print
        try fixture.controller.edit(.appKeyGuide, keys: [.init(key: .character("j"), modifiers: .command)])
        center.post(name: NSMenu.didEndTrackingNotification, object: parent)
        await fixture.afterMenuNotifications()
        #expect(fixture.bridge.reconcilePasses == passes)
        #expect(fixture.bridge.writes.counts == writes)
        #expect(fixture.bridge.updates.hider.writes.counts == expected)
        #expect(!fixture.bridge.menuState.snapshot.content.printing)
        #expect(edit.isHidden && item.keyEquivalent == "z")
        center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
        #expect(fixture.bridge.reconcilePasses == passes)
        await fixture.afterMenuNotifications()
        #expect(fixture.bridge.reconcilePasses == passes + 1)
        #expect(edit.isHidden && edit.keyEquivalent.isEmpty && item.keyEquivalent == "j")
        expected["keyEquivalent", default: 0] += 1
        #expect(fixture.bridge.updates.hider.writes.counts == expected)
        #expect(fixture.bridge.menuState.snapshot.content.printing)
        #expect(["isHidden", "title", "state", "isEnabled"].allSatisfy { fixture.bridge.writes.counts[$0] == nil })
        let repaired = fixture.bridge.updates.hider.writes.counts
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        #expect(fixture.bridge.updates.hider.writes.counts == repaired)
        center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
        await fixture.afterMenuNotifications()
    }

    @Test("標準の保存キーは通知内では変更せず、追跡終了後はAppKitからも実行できない")
    func hiddenSaveKeyDispatch() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let file = try #require(fixture.menu.items[1].submenu)
        let target = SaveTarget()
        let save = NSMenuItem(title: "Save", action: #selector(SaveTarget.saveDocument(_:)), keyEquivalent: "s")
        save.target = target
        let event = fixture.event("s", code: 1)
        file.addItem(save)
        #expect(fixture.menu.performKeyEquivalent(with: event) && target.saves == 1)
        file.removeItem(save)

        fixture.bridge.start()
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        file.addItem(save)
        #expect(save.isHidden && !save.isAlternate && !save.allowsKeyEquivalentWhenHidden)
        #expect(save.keyEquivalent == "s")
        center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
        #expect(save.keyEquivalent == "s")
        await fixture.afterMenuNotifications()
        #expect(save.keyEquivalent.isEmpty)
        #expect(!fixture.menu.performKeyEquivalent(with: event))
        #expect(target.saves == 1)
    }

    @Test("終了直後に別の追跡が始まれば待機中の照合も公開も次の終了まで一度だけ保留する")
    func reopenedBeforeDeferredPass() async throws {
        let fixture = Fixture()
        // The synthetic session stays open while the test yields to the ordinary host run loop.
        try #require(fixture.menu as? MainMenu).holdsHighlight = true
        defer { fixture.close() }
        let model = fixture.document()
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let center = NotificationCenter.default
        let state = fixture.bridge.menuState
        let before = state.snapshot
        let passes = fixture.bridge.reconcilePasses
        let writes = fixture.bridge.writes.counts
        let hides = fixture.bridge.updates.hider.writes.counts
        let item = try #require(fixture.bridge.items[.appKeyGuide])
        let secondMenu = try #require(fixture.menu.items[1].submenu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        let save = NSMenuItem(title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        save.allowsKeyEquivalentWhenHidden = false
        secondMenu.addItem(save)
        #expect(save.isHidden && save.keyEquivalent == "s")
        model.mode = .print
        item.keyEquivalent = "z"
        center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: secondMenu)
        await fixture.afterMenuNotifications()
        fixture.bridge.reconcile()
        #expect(state.snapshot == before)
        #expect(fixture.bridge.reconcilePasses == passes)
        #expect(fixture.bridge.writes.counts == writes)
        var expectedHides = hides
        expectedHides["isHidden", default: 0] += 1
        #expect(fixture.bridge.updates.hider.writes.counts == expectedHides)
        #expect(save.keyEquivalent == "s")
        #expect(item.keyEquivalent == "z")
        center.post(name: NSMenu.didEndTrackingNotification, object: secondMenu)
        #expect(state.snapshot == before)
        await fixture.afterMenuNotifications()
        #expect(fixture.bridge.reconcilePasses == passes + 1)
        #expect(state.snapshot.version == before.version + 1)
        #expect(state.snapshot.content.printing)
        #expect(!before.content.printing)
        #expect(item.keyEquivalent != "z" && save.keyEquivalent.isEmpty)
    }

    @Test("メインメニュー以外の開始が残っても、次のターンに設定と編集項目を反映する")
    func ignoresUnrelatedTracking() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let version = state.snapshot.version
        let center = NotificationCenter.default
        let popup = NSMenu()
        center.post(name: NSMenu.didBeginTrackingNotification, object: popup)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: popup) }
        center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
        let file = try #require(fixture.menu.items[1].submenu)
        let edit = file.addItem(withTitle: "Move", action: #selector(NSDocument.move(_:)), keyEquivalent: "m")
        fixture.preferences.recordRecentBinder(RecentBinder(files: [.init(path: "/a.md"), .init(path: "/b.md")]))
        fixture.bridge.reconcile()
        #expect(edit.isHidden && !edit.allowsKeyEquivalentWhenHidden && edit.keyEquivalent == "m")
        await fixture.afterMenuNotifications()
        #expect(edit.keyEquivalent.isEmpty)
        #expect(state.snapshot.version == version + 1)
        #expect(state.snapshot.content.recentBinders.map(\.id) == [Set(["/a.md", "/b.md"])])
    }

    @Test("子の終了が欠けても、ルートを閉じると照合を一度だけ再開する")
    func rootEndClosesChildren() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let passes = fixture.bridge.reconcilePasses
        let center = NotificationCenter.default
        let file = try #require(fixture.menu.items[1].submenu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: file)
        center.post(name: NSMenu.didBeginTrackingNotification, object: file)
        let edit = file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
        center.post(name: NSMenu.didEndTrackingNotification, object: file)
        #expect(edit.isHidden && edit.keyEquivalent == "s")
        #expect(fixture.bridge.reconcilePasses == passes)
        await fixture.afterMenuNotifications()
        #expect(fixture.bridge.reconcilePasses == passes + 1)
        #expect(edit.keyEquivalent.isEmpty)
    }

    @Test("終了通知が欠けてもメインメニューの追跡と強調表示が終わればキーを再同期する", arguments: [false, true])
    func recoversAfterNativeTrackingLoop(enteredTrackingMode: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.bridge.start()
        let file = try #require(fixture.menu.items[1].submenu)
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu) }
        let edit = file.addItem(withTitle: "Move", action: #selector(NSDocument.move(_:)), keyEquivalent: "m")
        #expect(edit.isHidden && edit.keyEquivalent == "m")
        let keyGuide = try #require(fixture.bridge.items[.appKeyGuide])
        let originalKey = keyGuide.keyEquivalent
        keyGuide.keyEquivalent = "z"
        if enteredTrackingMode {
            ShortcutMenuBaselineTests.trackingTurn {
                // A nested default-mode loop is still inside the enclosing menu tracking frame.
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                fixture.bridge.reconcile()
                #expect(keyGuide.keyEquivalent == "z")
            }
        }
        #expect(keyGuide.keyEquivalent == "z")
        try await ShortcutMenuBaselineTests.waitForMenu { keyGuide.keyEquivalent == originalKey }
    }

    @Test(
        "キー窓・メイン窓・閉鎖・アプリの切り替えは次のターンの窓から表示を公開する",
        arguments: [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification, NSWindow.willCloseNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ])
    func publishesSettledWindow(name: Notification.Name) async {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: "clipboard")
        defer { model.stop() }
        let gainingFocus = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSApplication.didBecomeActiveNotification,
        ].contains(name)
        if gainingFocus { fixture.activeModel = nil }
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let version = state.snapshot.version
        #expect(state.snapshot.content.canSaveAsFile == !gainingFocus)
        // Cocoa may still report the old key window from inside the notification.
        let applicationEvent =
            name == NSApplication.didBecomeActiveNotification || name == NSApplication.didResignActiveNotification
        fixture.lifecycleNotifications.post(name: name, object: applicationEvent ? NSApp as AnyObject : fixture.window)
        fixture.activeModel = gainingFocus ? model : nil
        #expect(state.snapshot.version == version)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 1)
        #expect(state.snapshot.content.canSaveAsFile == gainingFocus)
        #expect(state.snapshot.content.region == (gainingFocus ? .paperReading : nil))
    }

    @Test("クリップボード窓を閉じると次のターンに履歴と戻り先の文書が一緒に公開される", arguments: [false, true])
    func publishesClipboardClose(hasRemainingDocument: Bool) async {
        let fixture = Fixture()
        defer { fixture.close() }
        let remaining = fixture.document()
        defer { remaining.stop() }
        let windows = ClipboardWindows(openFiles: { _, _, _ in }, warn: { _ in }, closeWelcome: {})
        windows.preferences = fixture.preferences
        windows.library = remaining.library
        let presentation = ClipboardWindowFixture(windows)
        defer { presentation.close() }
        let bytes = Data("Clipboard fixture".utf8)
        let clipboard = windows.open(bytes, format: .plainText, title: "Clipboard")
        fixture.activeModel = clipboard.model
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let before = state.snapshot
        #expect(before.content.canSaveAsFile && before.content.history.isEmpty)
        clipboard.close()
        fixture.activeModel = hasRemainingDocument ? remaining : nil
        #expect(state.snapshot == before)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == before.version + 1)
        #expect(state.snapshot.content.history.map(\.id) == [.of(bytes)])
        #expect(!state.snapshot.content.canSaveAsFile)
        #expect(state.snapshot.content.region == (hasRemainingDocument ? .paperReading : nil))
    }

    @Test("モデルの観察は照合を挟んでも各ターンで再登録され、表示・一覧・チェックの変更を届ける")
    func publishesModelChanges() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: "binder")
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let before = state.snapshot
        model.mode = .print
        fixture.bridge.reconcile()
        #expect(state.snapshot == before)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == before.version + 1 && state.snapshot.content.printing)
        model.isDrawerOpen = !before.content.drawerOpen
        await fixture.afterMenuNotifications()
        #expect(
            state.snapshot.version == before.version + 2
                && state.snapshot.content.drawerOpen != before.content.drawerOpen)
        model.binderStartsOnFront = !before.content.oddStarts
        model.showsOnAllSpaces = !before.content.allSpaces
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == before.version + 3)
        #expect(
            state.snapshot.content.oddStarts != before.content.oddStarts
                && state.snapshot.content.allSpaces != before.content.allSpaces)
    }

    @Test("画像の束・合本・HTMLへ窓が交代すると観察先が切り替わりスライドの検出も公開する")
    func observesReplacementModels() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let images = fixture.document(kind: "images")
        defer { images.stop() }
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let version = state.snapshot.version
        #expect(state.snapshot.content.hasImages && !state.snapshot.content.hasBinder)
        let binder = fixture.document(kind: "binder")
        defer { binder.stop() }
        fixture.lifecycleNotifications.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        await fixture.afterMenuNotifications()
        #expect(
            state.snapshot.version == version + 1 && !state.snapshot.content.hasImages
                && state.snapshot.content.hasBinder)
        let html = DocumentViewModel(
            data: Data("<p>Fixture</p>".utf8), fileURL: fixture.directory.appendingPathComponent("slide.html"),
            format: .html, preferences: fixture.preferences, library: binder.library)
        fixture.activeModel = html
        fixture.lifecycleNotifications.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 2 && !state.snapshot.content.showsSlides)
        html.slideDeckDidChange(SlideDeck(size: CGSize(width: 640, height: 480), count: 3, currentIndex: 0))
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 3 && state.snapshot.content.showsSlides)
    }

    @Test("地域の単位変更は設定セットの副題に反映し、同じ単位なら版を進めない")
    func publishesLocaleChange() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let set = PrintSettingSet(
            name: "Margins", settings: DocumentSettings(printOptions: PrintOptions(marginsInMillimeters: 25.4)))
        fixture.preferences.savePrintSettingSet(set)
        var unit = MarginUnit.millimeters
        let state = MenuState()
        let updates = MenuUpdates(
            state: state, root: { nil }, model: { nil }, preferences: { fixture.preferences },
            lifecycle: fixture.lifecycleNotifications, marginUnit: { unit }, apply: { _ in })
        updates.start()
        defer { updates.stop {} }
        await fixture.afterMenuNotifications()
        let before = state.snapshot
        let subtitle = try #require(before.content.savedSets.first?.subtitle)
        unit = .inches
        fixture.lifecycleNotifications.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        #expect(state.snapshot == before)
        await fixture.afterMenuNotifications()
        #expect(
            state.snapshot.version == before.version + 1 && state.snapshot.content.savedSets.first?.subtitle != subtitle
        )
        fixture.lifecycleNotifications.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == before.version + 1)
    }

    @Test("設定セットの保存とスタイルの再読み込みは次のターンに名前と副題を公開する")
    func publishesSettingAndLibraryChanges() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let version = state.snapshot.version
        let set = PrintSettingSet(name: "Menu fixture", settings: DocumentSettings(themeID: "user:MenuFixture.css"))
        fixture.preferences.savePrintSettingSet(set)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 1 && state.snapshot.content.savedSets.first?.id == set.id)
        let styles = model.library.root.appendingPathComponent("Styles")
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        try Data("body { color: black; }".utf8).write(to: styles.appendingPathComponent("MenuFixture.css"))
        model.library.reload()
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 2)
        #expect(state.snapshot.content.savedSets.first?.subtitle.contains("MenuFixture") == true)
    }

    @Test("最近の合本はメニューを開かずに登録と消去を公開する")
    func publishesRecentBinders() async {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let version = state.snapshot.version
        let binder = RecentBinder(files: [.init(path: "/a.md"), .init(path: "/b.md")])
        fixture.preferences.recordRecentBinder(binder)
        fixture.bridge.reconcile()
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 1 && state.snapshot.content.recentBinders.map(\.id) == [binder.id])
        fixture.preferences.clearRecentBinders()
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 2 && state.snapshot.content.recentBinders.isEmpty)
    }

    @Test("キー割り当ての同期照合が設定の公開予約を消費しない")
    func publishesShortcutPreferences() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.bridge.start()
        await fixture.afterMenuNotifications()
        let state = fixture.bridge.menuState
        let version = state.snapshot.version
        let keys = [ShortcutCombination(key: .character("k"), modifiers: .command)]
        try fixture.controller.edit(.documentReload, keys: keys)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 1 && state.snapshot.content.overrides[.documentReload] == keys)
    }

    @Test("同じ表示内容は公開せず、変化して元に戻ったときにも版は進む")
    func snapshotRevisions() {
        let fixture = Fixture()
        defer { fixture.close() }
        let state = fixture.bridge.menuState
        var invalidations = 0
        let before = withObservationTracking {
            state.snapshot
        } onChange: {
            MainActor.assumeIsolated { invalidations += 1 }
        }
        state.publish(before.content)
        #expect(state.snapshot == before)
        #expect(invalidations == 0)
        let changed = MenuSnapshot.Content(model: fixture.document(printMode: true), preferences: fixture.preferences)
        state.publish(changed)
        let printed = state.snapshot
        #expect(invalidations == 1)
        #expect(printed.version == before.version + 1)
        state.publish(MenuSnapshot.Content(model: fixture.activeModel, preferences: fixture.preferences))
        #expect(state.snapshot == printed)
        state.publish(before.content)
        #expect(state.snapshot.content == before.content)
        #expect(state.snapshot.version == printed.version + 1)
        #expect(printed.content.printing)
    }

    @Test("検証と実行はキー窓の文書をその場で確認し、文書がなくてもアプリの操作は有効")
    func validatesCurrentWindow() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let file = try #require(fixture.menu.items[1].submenu)
        file.addItem(withTitle: "test:Print…", action: nil, keyEquivalent: "")
        let export = file.addItem(withTitle: "test:Export", action: nil, keyEquivalent: "")
        export.submenu = NSMenu()
        export.submenu?.addItem(withTitle: "test:PDF for Reading…", action: nil, keyEquivalent: "")
        fixture.menu.items[3].submenu?.addItem(withTitle: "test:Go to Page…", action: nil, keyEquivalent: "")
        fixture.menu.items[4].submenu?.addItem(withTitle: "test:Choose Style…", action: nil, keyEquivalent: "")
        fixture.bridge.reconcile()
        let operations: [ShortcutOperationID] = [
            .documentPrint, .documentExportReadingPDF, .documentGoToPage, .styleChoose,
        ]
        let documents = try operations.map { operation in try #require(fixture.bridge.items[operation]) }
        let reload = try #require(fixture.bridge.items[.documentReload])
        let help = try #require(fixture.bridge.items[.appKeyGuide])
        let action = try #require(reload.action)
        reload.isEnabled = false
        fixture.bridge.reconcile()
        #expect(!reload.isEnabled)
        fixture.bridge.start()
        let snapshot = fixture.bridge.menuState.snapshot
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu) }
        #expect(!fixture.bridge.validateMenuItem(reload))
        #expect(documents.allSatisfy { !fixture.bridge.validateMenuItem($0) })
        #expect(fixture.bridge.validateMenuItem(help))
        NSApp.sendAction(action, to: reload.target, from: reload)
        #expect(fixture.calls.isEmpty)
        let model = fixture.document(kind: "clipboard")
        defer { model.stop() }
        #expect(fixture.bridge.menuState.snapshot == snapshot)
        #expect(fixture.bridge.validateMenuItem(reload))
        #expect(documents.allSatisfy { fixture.bridge.validateMenuItem($0) })
        NSApp.sendAction(action, to: reload.target, from: reload)
        #expect(fixture.calls == [.documentReload])
        fixture.activeModel = nil
        NSApp.sendAction(action, to: reload.target, from: reload)
        #expect(!fixture.bridge.validateMenuItem(reload))
        #expect(fixture.calls == [.documentReload])
        #expect(fixture.bridge.menuState.snapshot == snapshot)
    }

    @Test("履歴があってもメニューに存在しない再オープンの割り当ては実行しない")
    func absentConditionalShortcut() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: "clipboard")
        let data = Data("sample".utf8)
        fixture.preferences.closedClipboardDocuments.remember(
            .init(model: model, hash: .of(data), data: data, date: Date()))
        fixture.bridge.reconcile()
        #expect(!fixture.bridge.commandIsPresent(.clipboardReopen))
        #expect(!fixture.dispatcher.handle(fixture.event("T", flags: [.shift, .command])))
        #expect(fixture.calls.isEmpty)
        let file = try #require(fixture.menu.items[1].submenu)
        fixture.bridge.start()
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu) }
        let item = file.addItem(withTitle: "test:Reopen Closed Clipboard Document", action: nil, keyEquivalent: "")
        let writes = fixture.bridge.writes.counts
        _ = fixture.dispatcher.handle(fixture.event("T", type: .keyUp))
        #expect(fixture.dispatcher.handle(fixture.event("T", flags: [.shift, .command])))
        #expect(fixture.calls == [.clipboardReopen])
        file.removeItem(item)
        fixture.dispatcher.perform(.clipboardReopen)
        #expect(fixture.calls == [.clipboardReopen])
        #expect(fixture.bridge.writes.counts == writes)
    }

    @Test("印刷レイアウトの途中の項目がなくても対応する操作にだけキーを結ぶ")
    func partialPrintLayoutMenu() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let document = try #require(fixture.menu.items[4].submenu)
        let parent = NSMenuItem(title: "test:Print Layout", action: nil, keyEquivalent: "")
        let layouts = NSMenu()
        parent.submenu = layouts
        document.addItem(parent)
        let language = fixture.bridge.menuState.snapshot.content.language
        layouts.addItem(withTitle: PrintLayout.a4Duplex.displayName(language: language), action: nil, keyEquivalent: "")
        let compact = layouts.addItem(withTitle: "AX fixture", action: nil, keyEquivalent: "")
        compact.setAccessibilityIdentifier("surimono.shortcut." + ShortcutOperationID.printLayoutFourUp.rawValue)
        fixture.bridge.reconcile()
        #expect(fixture.bridge.items[.printLayoutSingle] == nil)
        #expect(fixture.bridge.items[.printLayoutDuplex] === layouts.items[0])
        #expect(layouts.items[0].keyEquivalent == "2")
        #expect(fixture.bridge.items[.printLayoutFourUp] === compact)
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
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
    }

    @Test("起動時の同期は同じターンで取り付けたメニューを窓やアクティブ化なしで拾う")
    func deferredLaunchReconciliation() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.activeWindow = nil
        let assembled = fixture.menu
        fixture.menu = NSMenu()
        let file = try #require(assembled.items[1].submenu)
        let edit = file.addItem(withTitle: "Rename", action: #selector(NSDocument.rename(_:)), keyEquivalent: "r")
        edit.allowsKeyEquivalentWhenHidden = true
        fixture.bridge.start()
        fixture.menu = assembled
        // A FIFO main-queue barrier waits for the bridge's queued pass; no sleep or activation is involved.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(fixture.bridge.items[.documentReload]?.keyEquivalent == "r")
        #expect(edit.isHidden && !edit.allowsKeyEquivalentWhenHidden && edit.keyEquivalent.isEmpty)
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
            lifecycleNotifications: fixture.lifecycleNotifications,
            preferences: { fixture.preferences })
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
        #expect(calls == [.documentReload, .documentReload])
    }

    @Test("何も変わらなければ照合は止まり、自分の書き込みで次の照合を呼ばない", .timeLimit(.minutes(1)))
    func idleMenuStopsReconciling() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        let sharedBridge = ShortcutDispatcher.shared.bridge
        sharedBridge.stop()
        // AppKit posts an item change for what a pass writes; posting one from inside the pass stands for that.
        let live = ShortcutMenuBridge(
            controller: fixture.controller, keyWindow: { fixture.activeWindow }, model: { model },
            lifecycleNotifications: fixture.lifecycleNotifications,
            localize: { key in
                NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: NSApp.mainMenu)
                return Bundle.main.localizedString(forKey: key, value: key, table: nil)
            })
        defer {
            live.stop()
            sharedBridge.start()
        }
        live.start()
        // Let the pass scheduled after menu assembly run, then watch an idle stretch of the main queue.
        try await Task.sleep(for: .milliseconds(300))
        let settled = live.reconcilePasses
        try await Task.sleep(for: .milliseconds(500))
        #expect(live.reconcilePasses == settled)
        #expect(settled < 10)
        let writes = live.writes.counts
        let hides = live.updates.hider.writes.counts
        live.reconcile()
        #expect(live.writes.counts == writes)
        #expect(live.updates.hider.writes.counts == hides)
        #expect(["isHidden", "title", "state", "isEnabled"].allSatisfy { writes[$0] == nil })
    }

    @Test(
        "各ウィンドウの表示・印刷状態から作る全コマンドは従来の既定キーを保つ",
        arguments: ["document", "images", "binder", "clipboard", "welcome", "settings"], [false, true])
    func generatedDefaultsInEveryWindow(kind: String, printMode: Bool) throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: kind, printMode: printMode)
        defer { model.stop() }
        let hasDocument = !["welcome", "settings"].contains(kind)
        let binder = kind == "binder"
        let images = kind == "images"
        let clipboard = kind == "clipboard"
        if !hasDocument { fixture.activeModel = nil }
        model.isDrawerOpen = printMode
        model.binderStartsOnFront = printMode
        let data = Data("History".utf8)
        fixture.preferences.closedClipboardDocuments.remember(
            .init(model: model, hash: .of(data), data: data, date: .now))
        fixture.bridge.start()
        let snapshot = fixture.bridge.menuState.snapshot
        let facts = snapshot.content
        #expect(facts.region == (hasDocument ? (printMode ? .printSheet : .paperReading) : nil))
        #expect(facts.printing == (hasDocument && printMode))
        #expect(facts.hasBinder == binder)
        #expect(facts.hasImages == images)
        #expect(facts.canSaveAsFile == clipboard)
        #expect(!facts.canOpenBinder)
        #expect(facts.drawerOpen == (hasDocument && printMode))
        #expect(facts.oddStarts == (hasDocument && printMode))
        let sections = DocumentMenuDescriptor.Section.allCases.flatMap {
            DocumentMenuDescriptor.rows(for: $0, in: snapshot)
        }
        func flatten(_ rows: [DocumentMenuDescriptor]) -> [DocumentMenuDescriptor] {
            rows.flatMap { [$0] + flatten($0.children) }
        }
        let rows = flatten(sections)
        let printRow = try #require(rows.first { $0.operation == .documentPrint })
        #expect(printRow.title == (hasDocument && printMode ? "Print" : "Print…"))
        #expect(printRow.isEnabled == hasDocument)
        #expect(rows.first { $0.operation == .appOpenURL }?.isEnabled == true)
        let options = try #require(rows.first { $0.id == .action(.viewOptions) })
        #expect(options.isEnabled == (hasDocument && !printMode))
        #expect(rows.contains { $0.operation == .documentSaveAsFile } == clipboard)
        #expect(!rows.contains { $0.operation == .documentOpenBinder })
        #expect(rows.contains { $0.id == .menu("Binder") } == binder)
        #expect(rows.contains { $0.id == .menu("Images") } == images)
        #expect(rows.contains { $0.id == .action(.removeFromList) } == binder)
        #expect(rows.first { $0.operation == .binderOddPageStarts }?.checked == (binder ? printMode : nil))
        #expect(rows.first { $0.operation == .listToggle }?.checked == (binder || images ? printMode : nil))
        if binder || images {
            #expect(
                rows.first { $0.operation == .listMoveUp }?.title == (binder ? "Move Document Up" : "Move Image Up"))
            #expect(
                rows.first { $0.operation == .listMoveDown }?.title
                    == (binder ? "Move Document Down" : "Move Image Down"))
        }
        var absent: Set<ShortcutOperationID> = [.appOpen, .appSettings, .documentOpenBinder]
        if !facts.canCheckUpdates { absent.insert(.appCheckUpdates) }
        if !clipboard { absent.insert(.documentSaveAsFile) }
        if !binder { absent.insert(.binderOddPageStarts) }
        if !binder && !images { absent.formUnion([.listToggle, .listMoveUp, .listMoveDown, .listSortByName]) }
        let operations = rows.compactMap(\.operation)
        #expect(operations.count == Set(operations).count)
        #expect(Set(operations) == ShortcutMenuBridge.operations.subtracting(absent))
        try ShortcutMenuBaselineTests.checkDescriptorKeys(rows)
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
