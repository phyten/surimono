import AppKit
import Observation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct SystemMenuShortcutsTests {
    @MainActor
    private final class SaveTarget: NSObject {
        var saves = 0
        @objc func renameDocument(_ sender: Any?) { saves += 1 }
        @objc func moveDocument(_ sender: Any?) { saves += 1 }
        @objc func duplicateDocument(_ sender: Any?) { saves += 1 }
        @objc func saveDocument(_ sender: Any?) { saves += 1 }
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
        lazy var menus = SystemMenuShortcuts(
            controller: controller, menu: { [unowned self] in menu },
            keyWindow: { [unowned self] in activeWindow }, model: { [unowned self] in activeModel },
            lifecycleNotifications: lifecycleNotifications, preferences: { [unowned self] in preferences },
            localize: { "test:" + $0 },
            externalKey: { [unowned self] item in
                item.title == "test:Reload" ? external : ""
            })
        lazy var dispatcher = ShortcutDispatcher(
            controller: controller, menus: menus, keyWindow: { [unowned self] in activeWindow },
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

        }

        func document(kind: String = "document", printMode: Bool = false) -> DocumentViewModel {
            let binder =
                kind == "binder"
                ? BinderModel(orderedURLs: [directory.appendingPathComponent("a.md")], read: { _, _ in Data() }) : nil
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
        #expect(fixture.dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        #expect(!fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls == [.documentReload])
        #expect(!fixture.dispatcher.handle(fixture.event("k", flags: [.command, .shift], type: .keyUp)))
        #expect(fixture.dispatcher.handle(fixture.event("k", flags: [.command, .shift])))
        #expect(fixture.calls == [.documentReload, .documentReload])
    }

    @Test("項目が再生成されてもキー配送はその項目を書き換えず、解除したキーも復活させない")
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
        #expect(rebuilt.identifier == nil)
        #expect(rebuilt.keyEquivalent == "r")
        try fixture.controller.edit(.documentReload, keys: [])
        fixture.dispatcher.performFromMenu(.documentReload, event: fixture.event("r"))
        #expect(rebuilt.keyEquivalent == "r")
        #expect(!fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(!fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.calls == [.documentReload])
    }

    @Test("追跡中に追加された編集項目だけを三属性で直し、通常項目・キー・公開版は変えない")
    func notifications() async throws {
        let f = Fixture()
        defer { f.close() }
        let model = f.document()
        f.menus.start()
        await f.afterMenuNotifications()
        let before = f.menus.menuState.snapshot
        let hider = f.menus.updates.hider
        var expected = hider.writes.counts
        let file = try #require(f.menu.items[1].submenu)
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: f.menu)
        #expect(hider.writes.counts == expected)
        let edit = NSMenuItem(title: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "s")
        edit.keyEquivalentModifierMask = [.command, .shift]
        edit.isAlternate = true
        edit.allowsKeyEquivalentWhenHidden = true
        file.addItem(edit)
        for property in ["isAlternate", "allowsKeyEquivalentWhenHidden", "isHidden"] {
            expected[property, default: 0] += 1
        }
        #expect(hider.writes.counts == expected)
        #expect(edit.isHidden && !edit.isAlternate && !edit.allowsKeyEquivalentWhenHidden)
        edit.isHidden = false
        expected["isHidden", default: 0] += 1
        #expect(edit.isHidden && hider.writes.counts == expected)
        let other = file.addItem(withTitle: "test:Print…", action: nil, keyEquivalent: "z")
        model.mode = .print
        await f.afterMenuNotifications()
        #expect(f.menus.menuState.snapshot == before)
        center.post(name: NSMenu.didEndTrackingNotification, object: f.menu)
        await f.afterMenuNotifications()
        #expect(f.menus.menuState.snapshot.version == before.version + 1)
        #expect(edit.keyEquivalent == "s" && edit.keyEquivalentModifierMask == [.command, .shift])
        #expect(other.keyEquivalent == "z" && other.action == nil && other.identifier == nil && !other.isHidden)
        #expect(hider.writes.counts == expected)
    }

    @Test("実メニューは追跡中と終了後のどちらも保存・複製・名称変更・移動のキーを実行しない")
    func hiddenEditKeyDispatch() async throws {
        let app = try #require(NSApp as? ViewerApplication)
        let updates = ShortcutDispatcher.shared.menus.updates
        updates.start()
        let center = NotificationCenter.default
        for (action, key, flags, code): (Selector, String, NSEvent.ModifierFlags, UInt16) in [
            (#selector(SaveTarget.saveDocument(_:)), "s", .command, 1),
            (#selector(SaveTarget.duplicateDocument(_:)), "s", [.command, .shift], 1),
            (#selector(SaveTarget.renameDocument(_:)), "j", [.control, .command], 38),
            (#selector(SaveTarget.moveDocument(_:)), "k", [.control, .command], 40),
        ] {
            let name = NSStringFromSelector(action)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                    isARepeat: false, keyCode: code))
            let target = SaveTarget()
            let row = NSMenuItem(title: "Fixture", action: action, keyEquivalent: key)
            row.target = target
            row.keyEquivalentModifierMask = flags
            // The document group's existing Save and Duplicate also match these keys. Isolate the positive control
            // so a true result can only mean that this exact selector reached our counting target.
            let control = NSMenu()
            control.addItem(row)
            try #require(control.performKeyEquivalent(with: event), "\(name)")
            try #require(target.saves == 1, "\(name)")
            control.removeItem(row)

            let main = try #require(app.mainMenu)
            let initialDepth = updates.trackingDepth
            defer { row.menu?.removeItem(row) }
            do {
                center.post(name: NSMenu.didBeginTrackingNotification, object: main)
                defer { center.post(name: NSMenu.didEndTrackingNotification, object: main) }
                try #require(updates.trackingDepth == initialDepth + 1, "\(name)")
                // Resolve the installed File submenu after begin; SwiftUI can replace its previous items on open.
                let trackingMenu = try #require(app.mainMenu)
                let file = try #require(trackingMenu.item(at: 1)?.submenu)
                row.allowsKeyEquivalentWhenHidden = true
                file.addItem(row)
                try #require(row.menu === file && file.supermenu === trackingMenu, "\(name)")
                try #require(DocumentEditMenu.isInFileMenu(row.menu, of: trackingMenu), "\(name)")
                try #require(row.isHidden && !row.allowsKeyEquivalentWhenHidden, "\(name)")
                try #require(row.keyEquivalent == key && row.keyEquivalentModifierMask == flags, "\(name)")
                _ = trackingMenu.performKeyEquivalent(with: event)
                #expect(!app.sendAction(action, to: target, from: row), "\(name)")
                #expect(target.saves == 1, "\(name)")
            }
            #expect(updates.trackingDepth == initialDepth)
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            #expect(row.isHidden && !row.allowsKeyEquivalentWhenHidden && row.keyEquivalent == key, "\(name)")
            let settledMenu = try #require(app.mainMenu)
            _ = settledMenu.performKeyEquivalent(with: event)
            #expect(!app.sendAction(action, to: target, from: row), "\(name)")
            #expect(target.saves == 1, "\(name)")
        }
    }

    @Test("終了直後の再開は待機中の公開を次の終了まで保留し、照合は一度だけ行う")
    func reopenedBeforeDeferredPass() async throws {
        let f = Fixture()
        defer { f.close() }
        let model = f.document()
        var passes = 0
        let state = MenuState()
        let updates = MenuUpdates(
            state: state, root: { f.menu }, model: { model }, preferences: { f.preferences },
            lifecycle: f.lifecycleNotifications, apply: { _ in passes += 1 })
        updates.start()
        defer { updates.stop() }
        await f.afterMenuNotifications()
        let initial = passes
        let version = state.snapshot.version
        let child = try #require(f.menu.item(at: 1)?.submenu)
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: f.menu)
        model.mode = .print
        center.post(name: NSMenu.didEndTrackingNotification, object: f.menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: child)
        await f.afterMenuNotifications()
        #expect(passes == initial && state.snapshot.version == version)
        center.post(name: NSMenu.didEndTrackingNotification, object: f.menu)
        #expect(passes == initial)
        await f.afterMenuNotifications()
        #expect(passes == initial + 1 && state.snapshot.version == version + 1 && state.snapshot.content.printing)
    }

    @Test("メインメニュー以外の開始が残っても、次のターンに設定と編集項目を反映する")
    func ignoresUnrelatedTracking() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
        let version = state.snapshot.version
        let center = NotificationCenter.default
        let popup = NSMenu()
        center.post(name: NSMenu.didBeginTrackingNotification, object: popup)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: popup) }
        center.post(name: NSMenu.didEndTrackingNotification, object: fixture.menu)
        let file = try #require(fixture.menu.items[1].submenu)
        let edit = file.addItem(withTitle: "Move", action: #selector(NSDocument.move(_:)), keyEquivalent: "m")
        fixture.preferences.recordRecentBinder(RecentBinder(files: [.init(path: "/a.md"), .init(path: "/b.md")]))
        #expect(edit.isHidden && !edit.allowsKeyEquivalentWhenHidden && edit.keyEquivalent == "m")
        await fixture.afterMenuNotifications()
        #expect(edit.keyEquivalent == "m")
        #expect(state.snapshot.version == version + 1)
        #expect(state.snapshot.content.recentBinders.map(\.id) == [Set(["/a.md", "/b.md"])])
    }

    @Test("同じルートの二度の開始と子の開始は別々に数え、最後のルート終了で子を解放する")
    func rootEndClosesChildren() async throws {
        let f = Fixture()
        defer { f.close() }
        f.menus.start()
        let child = try #require(f.menu.item(at: 1)?.submenu)
        let updates = f.menus.updates
        let center = NotificationCenter.default
        for menu in [f.menu, child, f.menu] { center.post(name: NSMenu.didBeginTrackingNotification, object: menu) }
        #expect(updates.trackingDepth == 3)
        center.post(name: NSMenu.didEndTrackingNotification, object: f.menu)
        #expect(updates.trackingDepth == 2)
        center.post(name: NSMenu.didEndTrackingNotification, object: f.menu)
        center.post(name: NSMenu.didEndTrackingNotification, object: child)
        #expect(updates.trackingDepth == 0 && !updates.allowsWrites)
        await f.afterMenuNotifications()
        #expect(updates.allowsWrites)
    }

    @Test("外側の追跡開始後に通常ループが待機しメニューが交代しても、元の終了通知まで公開しない")
    func waitsForOriginalTree() async {
        let f = Fixture()
        defer { f.close() }
        f.menus.start()
        let state = f.menus.menuState
        let before = state.snapshot
        let original = f.menu
        let center = NotificationCenter.default
        ShortcutMenuBaselineTests.trackingTurn {
            center.post(name: NSMenu.didBeginTrackingNotification, object: original)
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        f.menu = NSMenu()
        f.preferences.recordRecentBinder(.init(files: [.init(path: "/a.md"), .init(path: "/b.md")]))
        f.lifecycleNotifications.post(name: NSApplication.didUpdateNotification, object: NSApp)
        center.post(name: NSMenu.didBeginTrackingNotification, object: f.menu)
        center.post(name: NSMenu.didEndTrackingNotification, object: f.menu)
        await f.afterMenuNotifications()
        #expect(f.menus.updates.trackingDepth == 1 && state.snapshot == before)
        center.post(name: NSMenu.didEndTrackingNotification, object: original)
        await f.afterMenuNotifications()
        #expect(state.snapshot.version == before.version + 1)
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
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
        let version = state.snapshot.version
        #expect(state.snapshot.content.visibility.canSaveAsFile == !gainingFocus)
        // Cocoa may still report the old key window from inside the notification.
        let applicationEvent =
            name == NSApplication.didBecomeActiveNotification || name == NSApplication.didResignActiveNotification
        fixture.lifecycleNotifications.post(name: name, object: applicationEvent ? NSApp as AnyObject : fixture.window)
        fixture.activeModel = gainingFocus ? model : nil
        #expect(state.snapshot.version == version)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 1)
        #expect(state.snapshot.content.visibility.canSaveAsFile == gainingFocus)
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
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
        let before = state.snapshot
        #expect(before.content.visibility.canSaveAsFile && before.content.history.isEmpty)
        clipboard.close()
        fixture.activeModel = hasRemainingDocument ? remaining : nil
        #expect(state.snapshot == before)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == before.version + 1)
        #expect(state.snapshot.content.history.map(\.id) == [.of(bytes)])
        #expect(!state.snapshot.content.visibility.canSaveAsFile)
        #expect(state.snapshot.content.region == (hasRemainingDocument ? .paperReading : nil))
    }

    @Test("モデルの観察は各ターンで再登録され、表示・一覧・チェックの変更を届ける")
    func publishesModelChanges() async {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: "binder")
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
        let before = state.snapshot
        model.mode = .print
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
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
        let version = state.snapshot.version
        #expect(state.snapshot.content.visibility.hasImages && !state.snapshot.content.visibility.hasBinder)
        let binder = fixture.document(kind: "binder")
        defer { binder.stop() }
        fixture.lifecycleNotifications.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        await fixture.afterMenuNotifications()
        #expect(
            state.snapshot.version == version + 1 && !state.snapshot.content.visibility.hasImages
                && state.snapshot.content.visibility.hasBinder)
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
        defer { updates.stop() }
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
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
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
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
        let version = state.snapshot.version
        let binder = RecentBinder(files: [.init(path: "/a.md"), .init(path: "/b.md")])
        fixture.preferences.recordRecentBinder(binder)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 1 && state.snapshot.content.recentBinders.map(\.id) == [binder.id])
        fixture.preferences.clearRecentBinders()
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 2 && state.snapshot.content.recentBinders.isEmpty)
    }

    @Test("キー割り当ての変更を次のターンに一度だけ公開する")
    func publishesShortcutPreferences() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.menus.start()
        await fixture.afterMenuNotifications()
        let state = fixture.menus.menuState
        let version = state.snapshot.version
        let keys = [ShortcutCombination(key: .character("k"), modifiers: .command)]
        try fixture.controller.edit(.documentReload, keys: keys)
        await fixture.afterMenuNotifications()
        #expect(state.snapshot.version == version + 1 && state.snapshot.content.effectiveKeys[.documentReload] == keys)
    }

    @Test("同じ表示内容は公開せず、変化して元に戻ったときにも版は進む")
    func snapshotRevisions() {
        let fixture = Fixture()
        defer { fixture.close() }
        let state = fixture.menus.menuState
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

    @Test("文書と操作の条件は行の無効表示とクリック・キーに共通で、追跡中の実行も現在の文書を使う")
    func commandAvailability() throws {
        let f = Fixture()
        defer { f.close() }
        f.menus.start()
        let snapshot = f.menus.menuState.snapshot
        func rows(_ snapshot: MenuSnapshot) -> [DocumentMenuDescriptor] {
            func flatten(_ rows: [DocumentMenuDescriptor]) -> [DocumentMenuDescriptor] {
                rows.flatMap { [$0] + flatten($0.children) }
            }
            return flatten(
                DocumentMenuDescriptor.Section.allCases.flatMap { DocumentMenuDescriptor.rows(for: $0, in: snapshot) })
        }
        let noDocument = rows(snapshot)
        #expect(try #require(noDocument.first { $0.id == .menu("Export") }).modifiers(inMenuBar: true).disabled)
        #expect(
            try #require(noDocument.first { $0.id == .menu("Setting Sets") }).modifiers(inMenuBar: true).disabled
                == false)
        for op: ShortcutOperationID in [
            .documentPrint, .documentGoToPage, .documentExportHTML, .viewOptions, .viewSelectText, .settingSetSave,
        ] {
            #expect(try #require(noDocument.first { $0.operation == op }).modifiers(inMenuBar: true).disabled)
        }
        let setting = try #require(noDocument.first { if case .action(.setting) = $0.id { true } else { false } })
        #expect(setting.modifiers(inMenuBar: true).disabled)
        #expect(
            try #require(noDocument.first { $0.operation == .settingSetManage }).modifiers(inMenuBar: true).disabled
                == false)
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: f.menu)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: f.menu) }
        let model = f.document()
        f.dispatcher.perform(.documentReload)
        f.dispatcher.perform(.documentExportHTML)
        f.dispatcher.perform(.documentGoToPage)
        #expect(f.calls == [.documentReload])
        let pdf = MenuSnapshot(
            version: 1, content: .init(model: model, preferences: f.preferences, controller: f.controller))
        let document = rows(pdf)
        #expect(
            try #require(document.first { $0.operation == .documentExportHTML }).modifiers(inMenuBar: true).disabled)
        #expect(
            try #require(document.first { $0.operation == .documentPrint }).modifiers(inMenuBar: true).disabled == false
        )
        #expect(try #require(document.first { $0.id == setting.id }).modifiers(inMenuBar: true).disabled == false)
        #expect(f.menus.menuState.snapshot == snapshot)
        f.activeModel = nil
        f.dispatcher.performFromMenu(.documentReload, event: nil)
        #expect(f.calls == [.documentReload])
    }

    @Test("ページへ移動は二ページ以上のときだけ選べ、実行時にも同じページ数を確認する", arguments: [1, 2])
    func goToPageAvailability(pages: Int) async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        f.model.replaceContent(TestFixtures.pdf("Pages", pages: pages), format: .pdf)
        try await f.render()
        let snapshot = MenuSnapshot(
            version: 1, content: .init(model: f.model, preferences: f.preferences, controller: f.controller))
        let row = try #require(
            DocumentMenuDescriptor.rows(for: .view, in: snapshot).first { $0.operation == .documentGoToPage })
        #expect(row.modifiers(inMenuBar: true).disabled == (pages == 1))
        f.dispatcher.performFromMenu(.documentGoToPage, event: nil)
        #expect(f.model.isGoToPagePresented == (pages == 2))
    }

    @Test("HTMLの書き出しとコピーは単独のテーマ文書だけで有効", arguments: ["document", "images", "binder", "clipboard"])
    func htmlAvailability(kind: String) {
        let f = Fixture()
        defer { f.close() }
        _ = f.document(kind: kind)
        f.menus.start()
        for operation: ShortcutOperationID in [.documentExportHTML, .documentCopyHTML, .documentCopyRichText] {
            let allowed = kind == "clipboard"
            #expect(f.menus.menuState.snapshot.content.enabled.contains(operation) == allowed)
            f.calls = []
            f.dispatcher.performFromMenu(operation, event: nil)
            #expect(f.calls == (allowed ? [operation] : []))
        }
    }

    @Test(
        "キー窓のないアプリ操作はメニューを開く前もクリックと同じ操作へ届く",
        arguments: [
            ShortcutOperationID.clipboardOpen, .appOpenURL, .appOpen, .appSettings, .appKeyGuide, .appStreamingPreview,
        ])
    func windowlessCommands(operation: ShortcutOperationID) throws {
        let f = Fixture()
        defer { f.close() }
        f.activeWindow = nil
        try f.controller.edit(operation, keys: [.init(key: .character("k"), modifiers: .command)])
        #expect(f.dispatcher.handle(f.event("k")))
        f.dispatcher.performFromMenu(operation, event: nil)
        #expect(f.calls == [operation, operation])
    }

    @Test("履歴のない再オープンは実行せず、キーとクリックは現在の履歴を再確認する")
    func absentConditionalShortcut() async {
        let f = Fixture()
        defer { f.close() }
        let model = f.document(kind: "clipboard")
        #expect(!f.dispatcher.handle(f.event("T", flags: [.shift, .command])))
        let data = Data("sample".utf8)
        let id = ContentHash.of(data)
        f.menus.start()
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: f.menu)
        f.preferences.closedClipboardDocuments.remember(.init(model: model, hash: id, data: data, date: .now))
        #expect(!f.dispatcher.handle(f.event("T", flags: [.shift, .command])))
        center.post(name: NSMenu.didEndTrackingNotification, object: f.menu)
        await f.afterMenuNotifications()
        #expect(f.dispatcher.handle(f.event("T", flags: [.shift, .command])))
        f.preferences.closedClipboardDocuments.remove(id)
        f.dispatcher.performFromMenu(.clipboardReopen, event: nil)
        #expect(f.calls == [.clipboardReopen])
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
        fixture.menus.start()
        fixture.menu = assembled
        // A FIFO main-queue barrier waits for the queued assembly pass; no sleep or activation is involved.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(fixture.controller.localKeys(for: .documentReload).first?.key == .character("r"))
        #expect(edit.isHidden && !edit.allowsKeyEquivalentWhenHidden && edit.keyEquivalent == "r")
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
        #expect(fixture.controller.localKeys(for: .documentReload).isEmpty)
        #expect(throws: ShortcutModelError.self) { try fixture.controller.edit(.documentReload, keys: nil) }
        try fixture.controller.edit(.documentReload, keys: nil, takeConflicts: true)
        #expect(fixture.controller.localKeys(for: .documentReload).first?.key == .character("r"))
        #expect(fixture.controller.localKeys(for: .appKeyGuide).isEmpty)
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
    }

    @Test("入力欄の裸キーと矢印と空白は通しIME変換中と記録中は文書操作を呼ばない")
    func typingAndRecorder() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document()
        defer { model.stop() }
        let editor = NSTextView(frame: .zero)
        fixture.window.contentView = editor
        #expect(fixture.window.makeFirstResponder(editor))
        #expect(fixture.window.firstResponder === editor)
        #expect(!editor.hasMarkedText())
        fixture.menus.start()
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
        await fixture.afterMenuNotifications()
        #expect(fixture.menus.menuState.snapshot.shortcut(for: .documentReload) == nil)
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
    func externalOwner() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try fixture.controller.edit(.appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)])
        let parent = try #require(fixture.menu.items[4].submenu)
        parent.removeAllItems()
        let externalItem = NSMenuItem(title: "test:Reload", action: nil, keyEquivalent: "k")
        parent.addItem(externalItem)
        fixture.external = "k"
        fixture.menus.start()
        #expect(
            fixture.controller.externalMenuKeys[.documentReload] == .init(key: .character("k"), modifiers: .command))
        let snapshot = fixture.menus.menuState.snapshot
        let reload = try #require(
            DocumentMenuDescriptor.rows(for: .document, in: snapshot).first { $0.operation == .documentReload })
        let help = try #require(
            DocumentMenuDescriptor.rows(for: .help, in: snapshot).first { $0.operation == .appKeyGuide })
        #expect(reload.modifiers(inMenuBar: true).shortcut?.key.character == "k")
        #expect(help.modifiers(inMenuBar: true).shortcut == nil)
        #expect(externalItem.keyEquivalent == "k")
        #expect(fixture.controller.localKeys(for: .appKeyGuide).isEmpty)
        #expect(
            fixture.controller.snapshot.keys(for: .appKeyGuide) == [.init(key: .character("k"), modifiers: .command)])
        #expect(!fixture.controller.status(for: .appKeyGuide).isEmpty)
        #expect(throws: ShortcutController.EditError.self) { try fixture.controller.edit(.documentReload, keys: []) }
        #expect(throws: ShortcutModelError.self) {
            try fixture.controller.edit(
                .appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)], takeConflicts: true)
        }
        externalItem.keyEquivalent = "r"
        fixture.external = ""
        parent.itemChanged(externalItem)
        await fixture.afterMenuNotifications()
        try fixture.controller.edit(.documentReload, keys: [])
        #expect(fixture.controller.localKeys(for: .documentReload).isEmpty)
        #expect(fixture.controller.localKeys(for: .appKeyGuide).first?.key == .character("k"))
    }

    @Test("標準の開くと設定は表示キーと追加キーを両方配送し、他の操作に表示キーを渡さない")
    func standardMenuKeys() throws {
        let f = Fixture()
        defer { f.close() }
        f.activeWindow = nil
        let file = try #require(f.menu.item(at: 1)?.submenu)
        let app = try #require(f.menu.item(at: 0)?.submenu)
        let open = file.addItem(withTitle: "Open…", action: NSSelectorFromString("openDocument:"), keyEquivalent: "o")
        let settings = app.addItem(
            withTitle: "Settings…", action: NSSelectorFromString("showSettingsWindow:"), keyEquivalent: ",")
        f.menus.start()
        for (op, item, native, alias): (ShortcutOperationID, NSMenuItem, String, String) in [
            (.appOpen, open, "o", "k"), (.appSettings, settings, ",", "j"),
        ] {
            f.calls = []
            try f.controller.edit(op, keys: [.init(key: .character(alias), modifiers: .command)])
            #expect(item.keyEquivalent == native)
            #expect(f.dispatcher.handle(f.event(native)))
            #expect(f.dispatcher.handle(f.event(alias)))
            #expect(f.calls == [op, op])
            #expect(throws: ShortcutModelError.self) {
                try f.controller.edit(
                    .appKeyGuide, keys: [.init(key: .character(native), modifiers: .command)], takeConflicts: true)
            }
            try f.controller.edit(op, keys: [])
            #expect(!f.dispatcher.handle(f.event(alias)))
            #expect(f.dispatcher.handle(f.event(native)))
            #expect(f.calls == [op, op, op])
        }
    }

    @Test("地域化された既定キーは配送に使い、SwiftUI への指定は元のキーを一度だけ地域化する")
    func localizedEquivalent() throws {
        let f = Fixture()
        defer { f.close() }
        _ = f.document()
        let reload = try #require(f.menu.items[4].submenu?.items.first { $0.title == "test:Reload" })
        reload.keyEquivalent = "j"
        reload.keyEquivalentModifierMask = .command
        f.menus.start()
        let snapshot = f.menus.menuState.snapshot
        #expect(snapshot.content.effectiveKeys[.documentReload]?.first?.key == .character("j"))
        #expect(snapshot.content.automaticMenuKeys[.documentReload]?.key == .character("r"))
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        #expect(!f.dispatcher.handle(f.event("r", code: 15)))
        #expect(f.calls == [.documentReload])
        try f.controller.edit(.appKeyGuide, keys: [.init(key: .character("j"), modifiers: .command)])
        #expect(f.controller.localKeys(for: .documentReload).isEmpty)
        _ = f.dispatcher.handle(f.event("j", code: 38, type: .keyUp))
        #expect(f.dispatcher.handle(f.event("j", code: 38)))
        #expect(f.calls == [.documentReload, .appKeyGuide])
        try f.controller.edit(.appKeyGuide, keys: [])
        #expect(f.controller.localKeys(for: .documentReload).first?.key == .character("j"))
    }

    @Test("途中のレイアウトが欠けても、項目名とアクセシビリティ識別子からmacOSの割り当てを読み取る")
    func partialPrintLayoutMenu() throws {
        let f = Fixture()
        defer { f.close() }
        let document = try #require(f.menu.items[4].submenu)
        let group = document.addItem(withTitle: "test:Print Layout", action: nil, keyEquivalent: "")
        let layouts = NSMenu()
        group.submenu = layouts
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let duplex = layouts.addItem(
            withTitle: PrintLayout.a4Duplex.displayName(language: language), action: nil, keyEquivalent: "j")
        let four = layouts.addItem(withTitle: "Different title", action: nil, keyEquivalent: "k")
        four.setAccessibilityIdentifier(SystemMenuShortcuts.accessibilityID(.printLayoutFourUp))
        let reader = SystemMenuShortcuts(
            controller: f.controller, menu: { f.menu }, model: { nil },
            lifecycleNotifications: f.lifecycleNotifications, preferences: { f.preferences },
            localize: { "test:" + $0 },
            externalKey: { $0 === duplex || $0 === four ? $0.keyEquivalent : "" })
        reader.start()
        defer { reader.stop() }
        #expect(f.controller.externalMenuKeys[.printLayoutDuplex]?.key == .character("j"))
        #expect(f.controller.externalMenuKeys[.printLayoutFourUp]?.key == .character("k"))
        #expect(f.controller.externalMenuKeys[.printLayoutSingle] == nil)
        #expect(duplex.target == nil && four.target == nil)
    }

    @Test(
        "表示オプション・文字選択・一覧から除くの変更キーを行に反映し、裸キーをメニュー全体へ割り当てない",
        arguments: [ShortcutOperationID.viewOptions, .viewSelectText, .listRemove])
    func customRowModifiers(operation: ShortcutOperationID) async throws {
        let f = Fixture()
        defer { f.close() }
        _ = f.document(kind: "binder")
        f.menus.start()
        func row() throws -> DocumentMenuDescriptor {
            let state = f.menus.menuState.snapshot
            let view = DocumentMenuDescriptor.rows(for: .view, in: state)
            let list = DocumentMenuDescriptor.rows(for: .document, in: state).flatMap { $0.children }
            return try #require((view + list).first { $0.operation == operation })
        }
        #expect(try row().modifiers(inMenuBar: true).shortcut == nil)
        try f.controller.edit(operation, keys: [.init(key: .character("k"), modifiers: .command)])
        await f.afterMenuNotifications()
        let resolved = try row()
        #expect(resolved.modifiers(inMenuBar: true).shortcut?.key.character == "k")
        #expect(resolved.modifiers(inMenuBar: false).shortcut == nil)
        #expect(resolved.modifiers(inMenuBar: true).disabled == (operation == .listRemove))
    }

    @Test("曖昧な同名項目は勝手に識別せず隠した文書保存キーも有効にしない")
    func ambiguousAndHidden() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = try #require(fixture.menu.items[4].submenu)
        parent.addItem(NSMenuItem(title: "test:Reload", action: nil, keyEquivalent: "r"))
        let save = NSMenuItem(title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        fixture.menu.items[1].submenu?.addItem(save)
        fixture.menus.start()
        #expect(fixture.controller.menuAmbiguities == [.documentReload])
        #expect(parent.items.filter { $0.title == "test:Reload" }.map(\.keyEquivalent) == ["", "r"])
        #expect(save.isHidden && !save.allowsKeyEquivalentWhenHidden)
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
        fixture.menus.start()
        let snapshot = fixture.menus.menuState.snapshot
        let facts = snapshot.content
        #expect(facts.region == (hasDocument ? (printMode ? .printSheet : .paperReading) : nil))
        #expect(facts.printing == (hasDocument && printMode))
        #expect(facts.visibility.hasBinder == binder)
        #expect(facts.visibility.hasImages == images)
        #expect(facts.visibility.canSaveAsFile == clipboard)
        #expect(!facts.visibility.canOpenBinder)
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
        #expect(printRow.isEnabled == (hasDocument && !printMode))
        #expect(rows.first { $0.operation == .appOpenURL }?.isEnabled == true)
        let options = try #require(rows.first { $0.operation == .viewOptions })
        #expect(options.isEnabled == (hasDocument && !printMode))
        #expect(rows.contains { $0.operation == .documentSaveAsFile } == clipboard)
        #expect(!rows.contains { $0.operation == .documentOpenBinder })
        #expect(rows.contains { $0.id == .menu("Binder") } == binder)
        #expect(rows.contains { $0.id == .menu("Images") } == images)
        #expect(rows.contains { $0.operation == .listRemove } == binder)
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
        if !facts.visibility.canCheckUpdates { absent.insert(.appCheckUpdates) }
        if !clipboard { absent.insert(.documentSaveAsFile) }
        if !binder { absent.formUnion([.binderOddPageStarts, .listRemove]) }
        if !binder && !images { absent.formUnion([.listToggle, .listMoveUp, .listMoveDown, .listSortByName]) }
        let operations = rows.compactMap(\.operation)
        #expect(operations.count == Set(operations).count)
        #expect(Set(operations) == SystemMenuShortcuts.operations.subtracting(absent))
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
        let sharedMenus = ShortcutDispatcher.shared.menus
        sharedMenus.stop()
        let live = SystemMenuShortcuts(
            controller: fixture.controller, keyWindow: { fixture.activeWindow },
            lifecycleNotifications: fixture.lifecycleNotifications)
        let dispatcher = ShortcutDispatcher(
            controller: fixture.controller, menus: live, keyWindow: { fixture.activeWindow })
        defer {
            dispatcher.stop()
            sharedMenus.start()
        }
        var calls: [ShortcutOperationID] = []
        dispatcher.executeOverride = { calls.append($0) }
        DocumentWindows.shared.register(model, for: fixture.window)
        fixture.activeWindow = fixture.window
        live.start()
        try fixture.controller.edit(
            .documentReload, keys: [.init(key: .character("k"), modifiers: [.command, .shift])])
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
        try fixture.controller.edit(.printLayoutSingle, keys: [.init(key: .character("k"), modifiers: .command)])
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.dispatcher.handle(fixture.event("k", repeatKey: true)))
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.calls == [.printLayoutSingle])
        _ = fixture.dispatcher.handle(fixture.event("k", type: .keyUp))
        #expect(fixture.dispatcher.handle(fixture.event("k")))
        #expect(fixture.calls == [.printLayoutSingle, .printLayoutSingle])
        fixture.calls = []
        #expect(fixture.dispatcher.handle(fixture.event("-", code: 27)))
        #expect(fixture.dispatcher.handle(fixture.event("-", code: 27, repeatKey: true)))
        #expect(fixture.calls == [.viewZoomOut, .viewZoomOut])
    }

}
