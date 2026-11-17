import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
final class ShortcutSurfaceFixture {
    let suite = TestDefaultsSuite()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let hotKeys = GlobalHotKeys(register: { _, _ in
        Issue.record("Global registration is forbidden")
        return nil
    })
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 594),
        styleMask: [.titled], backing: .buffered, defer: false)
    let paper = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
    lazy var owner = NSWindowController(window: window)
    lazy var preferences = AppPreferences(defaults: suite.defaults)
    lazy var controller = ShortcutController(
        hotKeys: hotKeys, reservations: { [] },
        keyboardLayout: {
            ShortcutKeyboardLayout.project { code, _ in
                switch code {
                case 38: "j"
                case 40: "k"
                case 7: "x"
                case 24: "="
                default: nil
                }
            }
        })
    lazy var bridge = ShortcutMenuBridge(
        controller: controller, menu: { NSMenu() },
        keyWindow: { [unowned self] in activeWindow },
        model: { [unowned self] in model })
    lazy var dispatcher = ShortcutDispatcher(
        controller: controller, bridge: bridge,
        keyWindow: { [unowned self] in activeWindow },
        model: { [unowned self] in model },
        firstResponder: { [unowned self] _ in responder })
    var activeWindow: NSWindow?
    var responder: NSResponder?
    var model: DocumentViewModel!
    var operations: [ShortcutOperationID] = []
    var nativeKeys: [String] = []

    init(format: DocumentFormat = .markdown, binder: Bool = false) throws {
        window.isReleasedWhenClosed = false
        activeWindow = window
        window.contentView = paper
        window.makeFirstResponder(paper)
        responder = paper
        controller.start(preferences: preferences)
        model = DocumentViewModel(
            data: Data(), fileURL: format == .html ? directory.appendingPathComponent("page.html") : nil,
            format: format, preferences: preferences,
            library: UserLibrary(root: directory),
            settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")),
            binder: binder
                ? BinderModel(
                    orderedURLs: [
                        directory.appendingPathComponent("a.md"),
                        directory.appendingPathComponent("b.md"),
                    ],
                    read: { _ in Data() }) : nil)
        model.printSubmit = { _, _, _ in Issue.record("Printing is forbidden") }
        model.outputOverride = { _, _ in Issue.record("Output is forbidden") }
        model.window = window
        paper.shortcutController = controller
        paper.onShortcut = { [unowned self] in operations.append($0) }
        paper.nativeKeyHandler = { [unowned self] in nativeKeys.append($0.charactersIgnoringModifiers ?? "") }
        let document = try #require(PDFDocument(data: TestFixtures.pdf("keys", pages: 6)))
        paper.show(document, at: 2)
        paper.apply(ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false))
        paper.goToPage(index: 2)
        paper.dispatchKey = { [unowned self] in dispatcher.handle($0) }
    }

    func event(_ text: String, flags: NSEvent.ModifierFlags = [], code: UInt16 = 40) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    func close() {
        dispatcher.stop()
        model.stop()
        hotKeys.stop()
        suite.remove()
        paper.dispatchKey = { _ in false }
        paper.onShortcut = nil
        paper.nativeKeyHandler = nil
        owner.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct ShortcutSurfaceTests {
    @Test("紙のM・V・TとShift別名を明示し、変更すると両方の旧キーが止まる")
    func movedLetters() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        for (operation, letter): (ShortcutOperationID, String) in [
            (.viewToolbarToggle, "m"), (.viewOptions, "v"), (.viewSelectText, "t"),
        ] {
            #expect(f.dispatcher.handle(f.event(letter)))
            #expect(f.dispatcher.handle(f.event(letter.uppercased(), flags: .shift)))
            #expect(f.operations.suffix(2) == [operation, operation])
            #expect(!f.dispatcher.handle(f.event(letter, flags: .option)))
            try f.controller.edit(operation, keys: [.init(key: .character("k"))])
            f.operations = []
            #expect(!f.dispatcher.handle(f.event(letter)))
            #expect(!f.dispatcher.handle(f.event(letter.uppercased(), flags: .shift)))
            #expect(f.dispatcher.handle(f.event("k")))
            #expect(f.operations == [operation])
            try f.controller.edit(operation, keys: [])
            #expect(!f.dispatcher.handle(f.event("k")))
        }
    }

    @Test("ページ送りの変更後は新キーだけが動き旧矢印はPDFKitにも渡らない")
    func movedNavigation() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        try f.controller.edit(.readingRight, keys: [.init(key: .character("j"))])
        #expect(f.dispatcher.handle(f.event("j")))
        #expect(f.paper.currentPageIndex == 3)
        #expect(f.dispatcher.handle(f.event("\u{F703}", code: 124)))
        #expect(f.paper.currentPageIndex == 3)
        f.paper.keyDown(with: f.event("\u{F703}", code: 124))
        #expect(f.paper.currentPageIndex == 3)
        #expect(f.nativeKeys.isEmpty)
        // An arbitrary modified arrow must never be a hidden page-turn alias.
        #expect(f.dispatcher.handle(f.event("\u{F702}", flags: [.option, .shift], code: 123)))
        #expect(f.paper.currentPageIndex == 3)
    }

    @Test("選択モードは標準の矢印をPDFKitへ返し明示したCommandキーだけで送る")
    func selection() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        f.paper.selectsText = true
        #expect(!f.dispatcher.handle(f.event("\u{F703}", code: 124)))
        #expect(!f.dispatcher.handle(f.event("\u{F703}", flags: .shift, code: 124)))
        f.paper.keyDown(with: f.event("\u{F703}", code: 124))
        #expect(f.nativeKeys == ["\u{F703}"])
        #expect(f.dispatcher.handle(f.event("t")))
        #expect(f.operations == [.viewSelectText])
        try f.controller.edit(.readingRight, keys: [.init(key: .character("k"), modifiers: .command)])
        #expect(f.dispatcher.handle(f.event("k", flags: .command)))
        #expect(f.paper.currentPageIndex == 3)
    }

    @Test("拡大中と連続スクロールの上下・Spaceは元のPDFKit処理を保つ", arguments: [false, true])
    func scrolling(continuous: Bool) throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        f.paper.apply(
            ViewOptions(
                layout: .single, scrollAxis: .vertical,
                transition: continuous ? .scroll : .instant, showsCoverAlone: false))
        if !continuous { f.paper.setZoom(2, anchor: nil) }
        for (key, code): (String, UInt16) in [("\u{F700}", 126), ("\u{F701}", 125), (" ", 49)] {
            #expect(f.dispatcher.handle(f.event(key, code: code)))
        }
        #expect(f.dispatcher.handle(f.event(" ", flags: .shift, code: 49)))
        #expect(f.nativeKeys == ["\u{F700}", "\u{F701}", " ", " "])
    }

    @Test("PageUp・PageDown・Home・Endは既定のPDFKit処理を保ち移動で旧キーを止める")
    func nativeNavigation() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        for (operation, key, code): (ShortcutOperationID, String, UInt16) in [
            (.readingPageUp, "\u{F72C}", 116), (.readingPageDown, "\u{F72D}", 121),
            (.readingFirst, "\u{F729}", 115), (.readingLast, "\u{F72B}", 119),
        ] {
            f.nativeKeys = []
            #expect(f.dispatcher.handle(f.event(key, code: code)))
            #expect(f.nativeKeys == [key])
            try f.controller.edit(operation, keys: [.init(key: .character("k"))])
            f.nativeKeys = []
            #expect(f.dispatcher.handle(f.event(key, code: code)))
            f.paper.keyDown(with: f.event(key, code: code))
            #expect(f.nativeKeys.isEmpty)
            #expect(f.dispatcher.handle(f.event("k")))
            #expect(f.nativeKeys == [key])
            try f.controller.edit(operation, keys: [])
            #expect(!f.dispatcher.handle(f.event("k")))
            // Native selection navigation remains available, even after the reading binding moved.
            f.paper.selectsText = true
            #expect(!f.dispatcher.handle(f.event(key, code: code)))
            f.paper.keyDown(with: f.event(key, code: code))
            #expect(f.nativeKeys == [key, key])
            f.paper.selectsText = false
        }
    }

    @Test("入力欄・別窓・ポップオーバーでは紙の裸キーを実行しない")
    func focusProtection() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        f.responder = NSTextView()
        for key in ["m", "v", "t", " ", "\u{F703}"] { #expect(!f.dispatcher.handle(f.event(key))) }
        f.responder = NSButton()
        #expect(!f.dispatcher.handle(f.event("m")))
        f.responder = f.paper
        f.activeWindow = nil
        #expect(!f.dispatcher.handle(f.event("m")))
        f.activeWindow = f.window
        f.model.isViewOptionsPresented = true
        #expect(!f.dispatcher.handle(f.event("m")))
        f.model.isViewOptionsPresented = false
        f.model.mode = .compare
        #expect(!f.dispatcher.handle(f.event("m")))
        f.model.mode = .print
        #expect(!f.dispatcher.handle(f.event("m")))
        #expect(f.operations.isEmpty)
    }

    @Test("IME変換中はCommandの別名も実行しない")
    func markedText() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        let editor = NSTextView()
        editor.setMarkedText(
            "composing", selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        f.responder = editor
        var calls: [ShortcutOperationID] = []
        f.dispatcher.executeOverride = { calls.append($0) }
        #expect(f.dispatcher.handle(f.event("=", flags: [.option, .command], code: 24)))
        #expect(calls.isEmpty)
        #expect(f.model.textScale == 1)
        try f.controller.edit(.viewOptions, keys: [.init(key: .character("k"), modifiers: .command)])
        #expect(!f.dispatcher.handle(f.event("k", flags: .command)))
        #expect(!f.dispatcher.handle(f.event("m")))
        #expect(f.operations.isEmpty)
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        #expect(f.dispatcher.handle(f.event("=", flags: [.option, .command], code: 24)))
        #expect(calls == [.textIncrease])
    }

    @Test("文字サイズと拡大の両別名を区別し、比較の拡大は配送せず変更で旧キーを止める")
    func zoomAliases() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        var calls: [ShortcutOperationID] = []
        f.dispatcher.executeOverride = { calls.append($0) }
        for mode: ViewerMode in [.view, .print, .compare] {
            f.model.mode = mode
            for symbol in ["+", "="] {
                calls = []
                #expect(f.dispatcher.handle(f.event(symbol, flags: [.option, .command], code: 24)))
                #expect(calls == [.textIncrease], "mode: \(mode), text alias: \(symbol)")
                calls = []
                #expect(f.dispatcher.handle(f.event(symbol, flags: .command, code: 24)))
                #expect(calls == (mode == .compare ? [] : [.viewZoomIn]), "mode: \(mode), zoom alias: \(symbol)")
            }
        }
        for (operation, flags): (ShortcutOperationID, NSEvent.ModifierFlags) in [
            (.textIncrease, [.option, .command]), (.viewZoomIn, .command),
        ] {
            try f.controller.edit(operation, keys: [.init(key: .character("k"), modifiers: .command)])
            for mode: ViewerMode in [.view, .print, .compare] {
                f.model.mode = mode
                calls = []
                _ = f.dispatcher.handle(f.event("=", flags: flags, code: 24))
                _ = f.dispatcher.handle(f.event("+", flags: flags, code: 24))
                #expect(calls.isEmpty, "mode: \(mode), old aliases: \(operation)")
                #expect(f.dispatcher.handle(f.event("k", flags: .command)))
                let expected: [ShortcutOperationID] = mode == .compare && operation == .viewZoomIn ? [] : [operation]
                #expect(calls == expected, "mode: \(mode), new key: \(operation)")
            }
            try f.controller.edit(operation, keys: [])
        }
    }

    @Test("文字サイズ別名は表示と刷り台で一段ずつ増やし比較の拡大は何もしない")
    func modelActions() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        #expect(f.dispatcher.handle(f.event("=", flags: [.option, .command], code: 24)))
        #expect(f.model.textScale == 1.1)
        f.model.mode = .print
        #expect(f.dispatcher.handle(f.event("=", flags: [.option, .command], code: 24)))
        #expect(f.model.textScale == 1.25)
        f.model.mode = .compare
        let before = f.paper.zoom
        #expect(f.dispatcher.handle(f.event("=", flags: .command, code: 24)))
        #expect(f.paper.zoom == before)
    }

    @Test("カタログの全操作は接続済みで、印刷の旧キーも明示して移譲できる")
    func printingBoundary() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        for operation in ShortcutOperation.catalog { #expect(f.controller.isConnected(operation.id)) }
        try f.controller.edit(
            .readingNext, keys: [.init(key: .character("p"), modifiers: .command)], takeConflicts: true)
        #expect(f.controller.snapshot.keys(for: .documentPrint).isEmpty)
        #expect(f.model.mode == .view)
    }

}

@MainActor
extension ShortcutSurfaceTests {
    @Test("固定Tabはキーボードアクセスを優先しEscは検索を先に閉じる", arguments: [false, true])
    func fixedKeys(alwaysVisible: Bool) throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        var fixed: [KeyGuideEntry] = []
        f.paper.onKey = { event in
            guard let entry = KeyGuideEntry.fixedPaperAction(for: event) else { return false }
            fixed.append(entry)
            return true
        }
        f.paper.fullKeyboardAccess = { false }
        f.paper.keyDown(with: f.event("\t", code: 48))
        f.paper.keyDown(with: f.event("\t", flags: .shift, code: 48))
        #expect(fixed == [.menu, .menu])
        f.paper.fullKeyboardAccess = { true }
        f.paper.keyDown(with: f.event("\t", code: 48))
        #expect(fixed == [.menu, .menu])
        #expect(f.nativeKeys == ["\t"])
        f.paper.keyDown(with: f.event("\u{1b}", code: 53))
        #expect(fixed.last == .escape)
        f.paper.keyDown(with: f.event("\r", code: 36))
        #expect(f.nativeKeys.last == "\r")
        f.model.isBandAlwaysVisible = alwaysVisible
        #expect(f.model.isBandAlwaysVisible == alwaysVisible)
        let menu = OverlayMenuState()
        menu.showFull()
        f.model.find.open()
        #expect(f.model.find.isPresented)
        f.paper.onKey = { f.model.handleFixedPaperKey($0, menu: menu) }
        f.paper.keyDown(with: f.event("\u{1b}", code: 53))
        #expect(!f.model.find.isPresented)
        #expect(menu.stage == .full)
        f.paper.keyDown(with: f.event("\u{1b}", code: 53))
        #expect(menu.stage == (alwaysVisible ? .full : .hidden))
    }

    @Test("紙の帯・オプション・文字選択は既存モデルの動作を使う")
    func paperActions() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        f.model.isBandAlwaysVisible = false
        let menu = OverlayMenuState()
        f.paper.onShortcut = { f.model.performPaperShortcut($0, menu: menu) }
        #expect(f.dispatcher.handle(f.event("m")))
        #expect(menu.stage == .full)
        #expect(f.dispatcher.handle(f.event("m")))
        #expect(menu.stage == .hidden)
        #expect(f.dispatcher.handle(f.event("t")))
        #expect(f.model.isSelectingText)
        #expect(f.dispatcher.handle(f.event("v")))
        #expect(f.model.isViewOptionsPresented)
        #expect(menu.stage == .full)
    }

    @Test("画像の紙は文字選択に入らない")
    func imageSelection() throws {
        let f = try ShortcutSurfaceFixture(format: .image)
        defer { f.close() }
        let menu = OverlayMenuState()
        f.paper.onShortcut = { f.model.performPaperShortcut($0, menu: menu) }
        #expect(f.dispatcher.handle(f.event("t")))
        #expect(!f.model.isSelectingText)
    }

    @Test("検索入力では紙のキーを奪わずCommand検索と拡大は届く")
    func findField() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        f.model.find.open()
        f.responder = NSTextView()
        #expect(!f.dispatcher.handle(f.event("v")))
        #expect(!f.dispatcher.handle(f.event(" ")))
        var calls: [ShortcutOperationID] = []
        f.dispatcher.executeOverride = { calls.append($0) }
        #expect(f.dispatcher.handle(f.event("g", flags: .command)))
        #expect(f.dispatcher.handle(f.event("=", flags: .command, code: 24)))
        #expect(calls == [.documentFindNext, .viewZoomIn])
        // The paper, while the Find bar is visible, still owns its own keys when focus returns to it.
        f.responder = f.paper
        #expect(f.dispatcher.handle(f.event("m")))
        #expect(f.operations == [.viewToolbarToggle])
    }

    @Test("記録中とシート表示中は紙も等号別名も実行しない")
    func recorderAndSheet() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        f.hotKeys.beginRecording()
        #expect(!f.dispatcher.handle(f.event("m")))
        #expect(!f.dispatcher.handle(f.event("=", flags: .command)))
        f.hotKeys.endRecording()
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let owner = NSWindowController(window: sheet)
        defer {
            f.window.endSheet(sheet)
            owner.close()
        }
        f.window.beginSheet(sheet)
        #expect(!f.dispatcher.handle(f.event("m")))
        #expect(!f.dispatcher.handle(f.event("=", flags: .command)))
        #expect(f.operations.isEmpty)
    }

    @Test(
        "一覧の削除はフォーカスを要し移動後のDeleteでは消えず最後の一件を残す",
        arguments: SingleDocumentBinderPolicy.allCases)
    func binderRemoval(_ policy: SingleDocumentBinderPolicy) throws {
        let f = try ShortcutSurfaceFixture(binder: true)
        defer { f.close() }
        f.preferences.singleDocumentBinderPolicy = policy
        var questions = 0
        var opens = 0
        f.model.binderExit.ask = { _, completion in
            questions += 1
            completion(.init(leave: false, suppress: false))
        }
        // Keep the source window available to test its last-row key even under the leave policy.
        f.model.binderExit.router = OpenRouter(
            openDocument: { _, completion in
                opens += 1
                completion(false)
            }, openBundle: { _, _ in nil }, openBinder: { _, _ in nil }, warn: { _ in },
            hasOpenWindows: { true }, showWelcome: {}, openWindows: { [] }, isActive: { false })
        let binder = try #require(f.model.binder)
        binder.selection = binder.items.first?.url
        // Represent the focused native list responder; paper focus must not activate list deletion.
        #expect(!f.dispatcher.handle(f.event("\u{7f}", code: 51)))
        #expect(binder.items.count == 2)
        f.model.shortcutListFocused = true
        f.responder = NSTableView()
        try f.controller.edit(.listRemove, keys: [.init(key: .character("x"))])
        #expect(!f.dispatcher.handle(f.event("\u{7f}", code: 51)))
        #expect(binder.items.count == 2)
        #expect(f.dispatcher.handle(f.event("x")))
        #expect(binder.items.count == 1)
        binder.selection = binder.items.first?.url
        #expect(f.dispatcher.handle(f.event("x")))
        #expect(binder.items.count == 1)
        #expect(questions == (policy == .ask ? 1 : 0))
        #expect(opens == (policy == .leave ? 1 : 0))
        #expect(f.window.attachedSheet == nil)
        f.responder = NSTextView()
        #expect(!f.dispatcher.handle(f.event("x")))
    }

    @Test(
        "折り見本と紙は同じキーを共有でき、移動後の旧矢印は折り見本を送らない",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func foldedPreview(rightBound: Bool) async throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        let book = FoldBook()
        let fold = FoldPDFView(frame: f.paper.frame)
        fold.book = book
        book.attach(fold)
        defer { book.detach() }
        let document = try #require(PDFDocument(data: TestFixtures.pdf("fold", pages: 8)))
        await book.load(
            document, pageSize: CGSize(width: 300, height: 420), blankLabel: "blank", rightBound: rightBound)
        fold.document = book.document
        fold.displayMode = .twoUp
        fold.displaysAsBook = true
        fold.displaysRTL = rightBound
        f.window.contentView = fold
        f.responder = fold
        f.model.mode = .print
        f.model.showsFold = true
        let operation: ShortcutOperationID = rightBound ? .foldLeft : .foldRight
        #expect(f.dispatcher.handle(f.event(rightBound ? "\u{F702}" : "\u{F703}", code: rightBound ? 123 : 124)))
        #expect(book.row == 1)
        #expect(f.dispatcher.handle(f.event(rightBound ? "\u{F703}" : "\u{F702}", code: rightBound ? 124 : 123)))
        #expect(book.row == 0)
        try f.controller.edit(operation, keys: [.init(key: .character("j"))])
        try f.controller.edit(.readingRight, keys: [.init(key: .character("j"))])
        #expect(f.dispatcher.handle(f.event("j")))
        #expect(book.row == 1)
        #expect(f.dispatcher.handle(f.event(rightBound ? "\u{F702}" : "\u{F703}", code: rightBound ? 123 : 124)))
        #expect(book.row == 1)
        f.responder = NSTextView()
        #expect(!f.dispatcher.handle(f.event("j")))
        #expect(book.row == 1)
        f.window.contentView = f.paper
        f.responder = f.paper
        f.model.mode = .view
        #expect(f.dispatcher.handle(f.event("j")))
        #expect(f.paper.currentPageIndex == 3)
    }

    @Test("刷り台の拡大もメニューと等号別名が同じ倍率を変更する")
    func trayZoom() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        let zoomer = TrayZoomer()
        zoomer.context = TrayGeometry.Context(
            layout: .a4Single, mixedOrientations: false,
            rows: [.init(sheets: 1, sides: 1, paper: PaperSize.a4.size)],
            showsCaptions: false, width: 1000, height: 700,
            headerHeight: 80, headingHeight: 18)
        f.model.trayZoomer = zoomer
        f.model.mode = .print
        #expect(f.dispatcher.handle(f.event("=", flags: .command, code: 24)))
        #expect(abs(zoomer.zoom - 1.25) < 0.0001)
        #expect(f.dispatcher.handle(f.event("+", flags: [.shift, .command], code: 24)))
        #expect(abs(zoomer.zoom - 1.5625) < 0.0001)
    }
}

@MainActor
extension ShortcutSurfaceTests {
    @Test("Web表示は紙の裸キーを扱わずCommand拡大だけを配送する")
    func webPresentation() throws {
        let f = try ShortcutSurfaceFixture(format: .html)
        defer { f.close() }
        #expect(f.model.showsWeb)
        for key in ["m", "v", "t"] { #expect(!f.dispatcher.handle(f.event(key))) }
        var calls: [ShortcutOperationID] = []
        f.dispatcher.executeOverride = { calls.append($0) }
        #expect(f.dispatcher.handle(f.event("=", flags: .command, code: 24)))
        #expect(calls == [.viewZoomIn])
        #expect(f.operations.isEmpty)
    }

    @Test("紙と一覧の裸キーは共有できても重なる紙の操作には割り当てられない")
    func scopeConflicts() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        let key = ShortcutCombination(key: .character("j"))
        try f.controller.edit(.readingRight, keys: [key])
        try f.controller.edit(.listRemove, keys: [key])
        try f.controller.edit(.foldRight, keys: [key])
        #expect(throws: ShortcutModelError.self) { try f.controller.edit(.viewOptions, keys: [key]) }
        #expect(f.controller.snapshot.keys(for: .readingRight) == [key])
        #expect(f.controller.snapshot.keys(for: .listRemove) == [key])
    }
}

@MainActor
extension ShortcutSurfaceTests {
    @Test("既定Deleteはフォーカスのある合本一覧から一件を外す")
    func defaultBinderDelete() throws {
        let f = try ShortcutSurfaceFixture(binder: true)
        defer { f.close() }
        let binder = try #require(f.model.binder)
        binder.selection = binder.items.first?.url
        f.model.shortcutListFocused = true
        f.responder = NSTableView()
        #expect(f.dispatcher.handle(f.event("\u{7f}", code: 51)))
        #expect(binder.items.count == 1)
    }

    @Test("画像一覧には削除ショートカットを追加しない")
    func noImageDeletion() throws {
        let f = try ShortcutSurfaceFixture(format: .image)
        defer { f.close() }
        f.model.shortcutListFocused = true
        f.responder = NSTableView()
        #expect(!f.dispatcher.handle(f.event("\u{7f}", code: 51)))
        #expect(f.operations.isEmpty)
    }
}

@MainActor
extension ShortcutSurfaceTests {
    @Test("案内のM・V・Tと削除は現在の割当を示し解除後も固定Tabだけは残る")
    func guideUsesBindings() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        try f.controller.edit(.viewToolbarToggle, keys: [])
        #expect(KeyGuideEntry.menu.trigger(controller: f.controller) == "Tab / ⇧Tab")
        try f.controller.edit(.viewOptions, keys: [.init(key: .character("k"), modifiers: .command)])
        #expect(KeyGuideEntry.viewOptions.trigger(controller: f.controller) == "⌘K")
        #expect(KeyGuideEntry.paperAction(for: f.event("v"), controller: f.controller) == nil)
        #expect(KeyGuideEntry.paperAction(for: f.event("k", flags: .command), controller: f.controller) == .viewOptions)
        try f.controller.edit(.listRemove, keys: [.init(key: .character("x"))])
        #expect(KeyGuideEntry.removeFromList.trigger(controller: f.controller) == "X")
    }
}
