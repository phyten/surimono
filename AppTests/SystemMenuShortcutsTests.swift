import AppKit
import Observation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct SystemMenuShortcutsTests {
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
        var trackingDepth = 0
        var activeWindow: NSWindow?
        var activeModel: DocumentViewModel?
        let menu = NSMenu()
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
            controller: controller, preferences: { [unowned self] in preferences },
            externalKey: { [unowned self] item in
                item.title == "test:Reload" ? external : ""
            })
        lazy var dispatcher = ShortcutDispatcher(
            controller: controller, menus: menus, keyWindow: { [unowned self] in activeWindow },
            model: { [unowned self] in activeModel }, menuTrackingDepth: { [unowned self] in trackingDepth })

        init() {
            window.isReleasedWhenClosed = false
            activeWindow = window
            controller.start(preferences: preferences)
            for _ in 0..<7 {
                let item = NSMenuItem()
                item.submenu = NSMenu()
                menu.addItem(item)
            }
            let reload = NSMenuItem(title: "test:Reload", action: nil, keyEquivalent: "r")
            menu.items[4].submenu?.addItem(reload)
            menus.register(reload, for: .documentReload)
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

        /// Build the same immutable input the main menu publishes before tracking begins.
        func refresh() {
            menus.readKeys(in: menu)
            menus.menuState.publish(
                MenuSnapshot.Content(
                    model: activeModel, preferences: preferences, library: activeModel?.library, controller: controller,
                    textInput: ShortcutDispatcher.isTextInput(activeWindow?.firstResponder)))
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
        f.refresh()
        let snapshot = f.menus.menuState.snapshot
        func rows(_ snapshot: MenuSnapshot) -> [DocumentMenuDescriptor] {
            func flatten(_ rows: [DocumentMenuDescriptor]) -> [DocumentMenuDescriptor] {
                rows.flatMap { [$0] + flatten($0.children) }
            }
            return flatten(
                DocumentMenuDescriptor.Section.allCases.flatMap { DocumentMenuDescriptor.rows(for: $0, in: snapshot) })
        }
        let noDocument = rows(snapshot)
        #expect(try #require(noDocument.first { $0.id == .menu("Export") }).isEnabled == false)
        #expect(
            try #require(noDocument.first { $0.id == .menu("Setting Sets") }).isEnabled)
        for op: ShortcutOperationID in [
            .documentPrint, .documentGoToPage, .documentExportHTML, .viewOptions, .viewSelectText, .settingSetSave,
        ] {
            #expect(try #require(noDocument.first { $0.operation == op }).isEnabled == false)
        }
        let setting = try #require(noDocument.first { if case .action(.setting) = $0.id { true } else { false } })
        #expect(setting.isEnabled == false)
        #expect(
            try #require(noDocument.first { $0.operation == .settingSetManage }).isEnabled)
        f.trackingDepth = 1
        let model = f.document()
        f.dispatcher.perform(.documentReload)
        f.dispatcher.perform(.documentExportHTML)
        f.dispatcher.perform(.documentGoToPage)
        #expect(f.calls == [.documentReload])
        let pdf = MenuSnapshot(
            version: 1, content: .init(model: model, preferences: f.preferences, controller: f.controller))
        let document = rows(pdf)
        #expect(
            try #require(document.first { $0.operation == .documentExportHTML }).isEnabled == false)
        #expect(
            try #require(document.first { $0.operation == .documentPrint }).isEnabled
        )
        #expect(try #require(document.first { $0.id == setting.id }).isEnabled)
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
        #expect(row.isEnabled == (pages > 1))
        f.dispatcher.performFromMenu(.documentGoToPage, event: nil)
        #expect(f.model.isGoToPagePresented == (pages == 2))
    }

    @Test("HTMLの書き出しとコピーは単独のテーマ文書だけで有効", arguments: ["document", "images", "binder", "clipboard"])
    func htmlAvailability(kind: String) {
        let f = Fixture()
        defer { f.close() }
        _ = f.document(kind: kind)
        f.refresh()
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
    func absentConditionalShortcut() {
        let f = Fixture()
        defer { f.close() }
        let model = f.document(kind: "clipboard")
        #expect(!f.dispatcher.handle(f.event("T", flags: [.shift, .command])))
        let data = Data("sample".utf8)
        let id = ContentHash.of(data)
        f.refresh()
        f.trackingDepth = 1
        f.preferences.closedClipboardDocuments.remember(.init(model: model, hash: id, data: data, date: .now))
        #expect(!f.dispatcher.handle(f.event("T", flags: [.shift, .command])))
        f.trackingDepth = 0
        f.refresh()
        #expect(f.dispatcher.handle(f.event("T", flags: [.shift, .command])))
        f.preferences.closedClipboardDocuments.remove(id)
        f.dispatcher.performFromMenu(.clipboardReopen, event: nil)
        #expect(f.calls == [.clipboardReopen])
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
        fixture.refresh()
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
        #expect(!fixture.dispatcher.canPerform(.operation(.appOpen)))
        #expect(!fixture.dispatcher.canPerform(.operation(.documentReload)))
        #expect(fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls.isEmpty)
        editor.unmarkText()
        #expect(fixture.dispatcher.canPerform(.operation(.documentReload)))
        #expect(!fixture.dispatcher.canPerform(.operation(.viewOptions)))
        fixture.dispatcher.perform(.viewOptions)
        #expect(fixture.calls.isEmpty)
        #expect(!editor.hasMarkedText())
        #expect(fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls == [.documentReload])
        fixture.calls = []
        try fixture.controller.edit(.documentReload, keys: [.init(key: .character("k"), modifiers: .control)])
        fixture.refresh()
        #expect(fixture.menus.menuState.snapshot.shortcut(for: .documentReload) == nil)
        #expect(!fixture.dispatcher.handle(fixture.event("k", flags: .control)))
        #expect(fixture.calls.isEmpty)
        try fixture.controller.edit(.documentReload, keys: nil)
        fixture.hotKeys.beginRecording()
        #expect(!fixture.dispatcher.canPerform(.operation(.appSettings)))
        #expect(!fixture.dispatcher.canPerform(.operation(.documentReload)))
        #expect(!fixture.dispatcher.handle(fixture.event("r", code: 15)))
        fixture.hotKeys.endRecording()
        #expect(fixture.dispatcher.canPerform(.operation(.appSettings)))
        #expect(fixture.calls.isEmpty)
        #expect(fixture.dispatcher.handle(fixture.event("r", code: 15)))
        #expect(fixture.calls == [.documentReload])
    }

    @Test("実メニューを更新すると文書・設定・シートで開く・設定・再読み込みの有効状態が切り替わる")
    func installedMenuValidation() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let model = fixture.document(kind: "clipboard")
        let documentController = MemoryDocumentWindowController(model: model) {}
        let document = try #require(documentController.window)
        defer { documentController.close() }
        let settings = SettingsWindowController.makeWindow(
            for: SettingsView(
                preferences: fixture.preferences, library: model.library,
                arrangementEditor: BandArrangementEditorSession(preferences: fixture.preferences)))
        defer { settings.close() }
        let main = try #require(NSApp.mainMenu)
        let app = try #require(main.item(at: 0)?.submenu)
        let file = try #require(main.item(at: 1)?.submenu)
        let documentMenu = try #require(main.item(at: 4)?.submenu)
        let toggle = try #require(app.items.first { $0.action == #selector(AppKitShell.toggleSettings(_:)) })
        let open = try #require(
            file.items.first { $0.identifier?.rawValue == SystemMenuShortcuts.accessibilityID(.appOpen) })
        let reload = try #require(
            documentMenu.items.first { $0.identifier?.rawValue == SystemMenuShortcuts.accessibilityID(.documentReload) }
        )
        let dispatcher = ShortcutDispatcher.shared
        let systemKeyWindow = dispatcher.keyWindow
        // An inactive CI host cannot acquire a key window. Inject only that value, keeping the
        // production document registry, responders, sheets, installed menu and AppKit validation.
        var selected: NSWindow?
        dispatcher.keyWindow = { NSApp.isActive ? systemKeyWindow() : selected }
        defer { dispatcher.keyWindow = systemKeyWindow }

        func update(_ window: NSWindow, canOpen: Bool, canReload: Bool) throws {
            selected = window
            window.makeKeyAndOrderFront(nil)
            try #require(dispatcher.keyWindow() === window)
            app.update()
            file.update()
            documentMenu.update()
            #expect(toggle.isEnabled == canOpen)
            #expect(open.isEnabled == canOpen)
            #expect(reload.isEnabled == canReload)
        }
        try update(document, canOpen: true, canReload: true)
        try update(settings, canOpen: true, canReload: false)
        try update(document, canOpen: true, canReload: true)

        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        document.beginSheet(sheet)
        defer {
            document.endSheet(sheet)
            sheet.orderOut(nil)
        }
        try #require(sheet.sheetParent === document && document.attachedSheet === sheet)
        try update(sheet, canOpen: false, canReload: false)
    }

    @Test("適用する設定セットが消えたら実行できず、組み込みの設定セットは選べる")
    func removedSettingSet() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        _ = fixture.document()
        let set = PrintSettingSet(name: "Test", settings: DocumentSettings())
        #expect(!fixture.dispatcher.canPerform(.setting(set.id)))
        fixture.preferences.savePrintSettingSet(set)
        #expect(fixture.dispatcher.canPerform(.setting(set.id)))
        _ = fixture.preferences.removePrintSettingSet(set.id)
        #expect(!fixture.dispatcher.canPerform(.setting(set.id)))
        let builtIn = try #require(PrintSettingSet.builtIns(language: "en").first)
        #expect(fixture.dispatcher.canPerform(.setting(builtIn.id)))
    }

    @Test("macOSが上書きした実効キーを保護し他の割当との衝突を停止する")
    func externalOwner() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try fixture.controller.edit(.appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)])
        let parent = try #require(fixture.menu.items[4].submenu)
        parent.removeAllItems()
        let externalItem = NSMenuItem(title: "test:Reload", action: nil, keyEquivalent: "k")
        parent.addItem(externalItem)
        fixture.menus.register(externalItem, for: .documentReload)
        fixture.external = "k"
        fixture.refresh()
        #expect(
            fixture.controller.externalMenuKeys[.documentReload] == .init(key: .character("k"), modifiers: .command))
        let snapshot = fixture.menus.menuState.snapshot
        let reload = try #require(
            DocumentMenuDescriptor.rows(for: .document, in: snapshot).first { $0.operation == .documentReload })
        let help = try #require(
            DocumentMenuDescriptor.rows(for: .help, in: snapshot).first { $0.operation == .appKeyGuide })
        #expect(reload.shortcut?.key.character == "k")
        #expect(help.shortcut == nil)
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
        fixture.refresh()
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
        let open = file.addItem(
            withTitle: "test:Open…", action: nil, keyEquivalent: "o")
        let settings = app.addItem(
            withTitle: "Settings…", action: nil, keyEquivalent: ",")
        f.menus.register(open, for: .appOpen)
        f.menus.register(settings, for: .appSettings)
        f.refresh()
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

    @Test("地域化された実効キーは配送に使い、項目には元のキーを一度だけ地域化して表示する")
    func localizedEquivalent() throws {
        let f = Fixture()
        defer { f.close() }
        _ = f.document()
        let reload = try #require(f.menu.items[4].submenu?.items.first { $0.title == "test:Reload" })
        reload.keyEquivalent = "j"
        reload.keyEquivalentModifierMask = .command
        f.refresh()
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

    @Test("同名のレイアウトがあっても、登録した項目からのみmacOSの割り当てを読み取る")
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
        layouts.addItem(withTitle: four.title, action: nil, keyEquivalent: "o")
        let reader = SystemMenuShortcuts(
            controller: f.controller, preferences: { f.preferences },
            externalKey: { $0 === duplex || $0 === four ? $0.keyEquivalent : "" })
        reader.register(duplex, for: .printLayoutDuplex)
        reader.register(four, for: .printLayoutFourUp)
        reader.readKeys(in: f.menu)
        #expect(f.controller.externalMenuKeys[.printLayoutDuplex]?.key == .character("j"))
        #expect(f.controller.externalMenuKeys[.printLayoutFourUp]?.key == .character("k"))
        #expect(f.controller.externalMenuKeys[.printLayoutSingle] == nil)
        #expect(duplex.target == nil && four.target == nil)
    }

    @Test(
        "表示オプション・文字選択・一覧から除くの変更キーを行に反映し、裸キーをメニュー全体へ割り当てない",
        arguments: [ShortcutOperationID.viewOptions, .viewSelectText, .listRemove])
    func customRowModifiers(operation: ShortcutOperationID) throws {
        let f = Fixture()
        defer { f.close() }
        _ = f.document(kind: "binder")
        f.refresh()
        func row() throws -> DocumentMenuDescriptor {
            let state = f.menus.menuState.snapshot
            let view = DocumentMenuDescriptor.rows(for: .view, in: state)
            let list = DocumentMenuDescriptor.rows(for: .document, in: state).flatMap { $0.children }
            return try #require((view + list).first { $0.operation == operation })
        }
        #expect(try row().shortcut == nil)
        try f.controller.edit(operation, keys: [.init(key: .character("k"), modifiers: .command)])
        f.refresh()
        let resolved = try row()
        #expect(resolved.shortcut?.key.character == "k")
        #expect(resolved.isEnabled == (operation != .listRemove))
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
        fixture.refresh()
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
        var absent: Set<ShortcutOperationID> = [.appSettings, .documentOpenBinder]
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
        let dispatcher = ShortcutDispatcher(
            controller: fixture.controller, menus: fixture.menus, keyWindow: { fixture.activeWindow })
        defer { dispatcher.stop() }
        var calls: [ShortcutOperationID] = []
        dispatcher.executeOverride = { calls.append($0) }
        DocumentWindows.shared.register(model, for: fixture.window)
        fixture.activeWindow = fixture.window
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

    @Test("文書A・Bを開いたまま束・クリップボード・設定・開始画面へ切り替え、クリックもキーも対象の窓だけを変更する")
    func commandsFollowTheKeyWindow() throws {
        let f = Fixture()
        defer { f.close() }
        var windows: [NSWindow] = []
        var models: [DocumentViewModel] = []
        defer {
            for model in models { model.stop() }
            for window in windows { window.close() }
        }
        for kind in ["document", "document", "images", "clipboard", "welcome", "settings"] {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            if kind == "welcome" || kind == "settings" { continue }
            let model = f.document(kind: kind)
            model.window = window
            model.setLayout(.single)
            DocumentWindows.shared.register(model, for: window)
            models.append(model)
        }
        let dispatcher = ShortcutDispatcher(controller: f.controller, menus: f.menus, keyWindow: { f.activeWindow })
        try f.controller.edit(.viewSpread, keys: [.init(key: .character("k"), modifiers: .command)])
        for (index, window) in windows.enumerated() {
            f.activeWindow = window
            if index.isMultiple(of: 2) {
                dispatcher.performFromMenu(.viewSpread, event: nil)
            } else {
                _ = dispatcher.handle(f.event("k"))
                _ = dispatcher.handle(f.event("k", type: .keyUp))
            }
            for (offset, model) in models.enumerated() {
                #expect(model.viewOptions.layout == (offset == index ? .spread : .single))
            }
            dispatcher.performFromMenu(.viewSingle, event: nil)
        }
    }

    @Test("macOSで標準の編集項目に割り当てたキーは文書の追加キーと重なってもAppKitへ渡す")
    func nativeAppShortcut() throws {
        let f = Fixture()
        defer { f.close() }
        _ = f.document()
        let copy = f.menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "k")
        let registry = SystemMenuShortcuts(
            controller: f.controller, preferences: { f.preferences }, externalKey: { $0 === copy ? "k" : "" })
        try f.controller.edit(.documentReload, keys: [.init(key: .character("k"), modifiers: .command)])
        registry.readKeys(in: f.menu)
        let dispatcher = ShortcutDispatcher(
            controller: f.controller, menus: registry, keyWindow: { f.activeWindow }, model: { f.activeModel })
        dispatcher.executeOverride = { _ in Issue.record("The native Edit item owns this press") }
        #expect(!dispatcher.handle(f.event("k")))
        #expect(copy.target == nil)
        #expect(f.controller.localKeys(for: .documentReload).isEmpty)
        #expect(throws: ShortcutModelError.self) {
            try f.controller.edit(.appKeyGuide, keys: [.init(key: .character("k"), modifiers: .command)])
        }
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
