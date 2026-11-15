import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

/// The Settings editor of the toolbar's arrangement: its draft, history, saved sets, drops and recovery.
@MainActor
@Suite(.serialized)
struct BandArrangementEditorTests {
    @MainActor private struct Environment {
        let suite = TestDefaultsSuite()
        let preferences: AppPreferences
        let session: BandArrangementEditorSession

        init(stored: Data? = nil) {
            if let stored { suite.defaults.set(stored, forKey: "bandArrangementStore") }
            preferences = AppPreferences(defaults: suite.defaults)
            session = BandArrangementEditorSession(preferences: preferences)
        }

        func cleanUp() { suite.remove() }
    }

    private func location(_ destination: BandDestination, _ index: Int) -> BandEntryLocation {
        BandEntryLocation(destination: destination, index: index)
    }

    // MARK: - Editing the draft

    @Test("同じ領域の後ろへ移すと取り除いたあとの位置に入り保存はしない")
    func moveWithinZone() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.mode == .split)
        // Standard bottom left: presentation | style outline | layout transition | zoom thumbnails.
        #expect(session.move(location(.zone(.bottomLeft), 2), to: .zone(.bottomLeft), at: 6))
        #expect(
            session.draft.split.bottomLeft == [
                .part(.presentation), .separator, .part(.outline), .separator, .part(.layout), .part(.style),
                .part(.transition), .separator, .part(.zoom), .part(.thumbnails),
            ])
        #expect(session.selection == .part(.style))
        #expect(session.message == .moved(BandLayout.Item.style.editorName, BandZoneID.bottomLeft.editorName, 6, 10))
        #expect(session.isDirty)
        #expect(environment.preferences.bandArrangementStore.activeLayouts == BandArrangementVariants())
        #expect(environment.suite.defaults.object(forKey: "bandArrangementStore") == nil)
    }

    @Test("区切り線は何本でも足せて動かせて消せる")
    func separators() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.insertSeparator(in: .topLeft, at: 1))
        #expect(session.insertSeparator(in: .topLeft, at: 1))
        #expect(session.draft.split.topLeft == [.part(.formatBadge), .separator, .separator])
        #expect(session.selection == .separator(.topLeft, 1))
        // A trailing separator and a doubled one stay in the draft, though the toolbar draws neither.
        #expect(session.separatorIsIdle(at: 1, in: .topLeft) && session.separatorIsIdle(at: 2, in: .topLeft))
        #expect(session.hasIdleSeparators)
        #expect(session.move(location(.zone(.topLeft), 2), to: .zone(.topRight), at: 1))
        #expect(session.draft.split.topRight == [.part(.floatOnTop), .separator, .part(.print)])
        #expect(session.selection == .separator(.topRight, 1))
        #expect(!session.separatorIsIdle(at: 1, in: .topRight))
        session.removeSelection()
        #expect(session.draft.split.topRight == [.part(.floatOnTop), .part(.print)])
        #expect(session.message == .separatorDeleted)
        #expect(!session.draft.split.unused.contains(.print))
    }

    @Test("前へと後ろへは領域の中で一つずつ動かし端では動かない")
    func earlierAndLater() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.pageTurn))
        session.moveSelection(by: -1)
        #expect(session.draft.split.bottomRight == [.part(.pageTurn), .part(.pageIndicator)])
        #expect(!session.canMove(location(.zone(.bottomRight), 0), by: -1))
        session.moveSelection(by: -1)
        #expect(session.draft.split.bottomRight == [.part(.pageTurn), .part(.pageIndicator)])
        session.moveSelection(by: 1)
        #expect(session.draft.split.bottomRight == [.part(.pageIndicator), .part(.pageTurn)])
        session.moveSelection(to: .zone(.topLeft))
        #expect(session.draft.split.topLeft == [.part(.formatBadge), .part(.pageTurn)])
        session.insertSeparatorAfterSelection()
        #expect(session.draft.split.topLeft == [.part(.formatBadge), .part(.pageTurn), .separator])
    }

    @Test("印刷は動かせるが使わない部品へは移せず理由を伝える")
    func printIsRequired() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.print))
        session.removeSelection()
        #expect(session.draft == BandArrangementVariants())
        #expect(session.message == .printIsRequired)
        #expect(!session.canUndo)
        session.moveSelection(to: .zone(.bottomRight))
        #expect(session.draft.split.bottomRight == [.part(.pageIndicator), .part(.pageTurn), .part(.print)])
    }

    @Test("上だけの組み方では下の領域を選べず二つの下書きはそれぞれ残る")
    func variants() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.outline))
        session.moveSelection(to: .unused)
        session.mode = .top
        #expect(session.zones == [.topLeft, .topRight])
        #expect(session.selection == nil)
        #expect(!session.move(location(.zone(.topRight), 0), to: .zone(.bottomLeft), at: 0))
        #expect(session.move(location(.unused, 0), to: .zone(.topLeft), at: 0))
        #expect(session.draft.top.topLeft.first == .part(.pageTurn))
        #expect(session.draft.split.unused == [.outline])
    }

    // MARK: - History

    @Test("取り消しとやり直しで下書きと選択が戻る")
    func undoAndRedo() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.zoom))
        session.moveSelection(to: .zone(.topLeft))
        session.insertSeparator(in: .topLeft, at: 1)
        #expect(session.canUndo && !session.canRedo)
        session.undo()
        #expect(session.draft.split.topLeft == [.part(.formatBadge), .part(.zoom)])
        session.undo()
        #expect(session.draft == BandArrangementVariants())
        #expect(session.selection == .part(.zoom))
        #expect(!session.canUndo && session.canRedo)
        session.redo()
        session.redo()
        #expect(session.draft.split.topLeft == [.part(.formatBadge), .separator, .part(.zoom)])
        #expect(!session.canRedo)
    }

    @Test("一回のドロップは一回の取り消しで戻る")
    func oneDropOneStep() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let payload = session.beginDrag(.entry(location(.zone(.bottomLeft), 0), .part(.presentation)))
        #expect(session.drop(payload, on: .zone(.topRight, index: 1)))
        #expect(session.draft.split.topRight == [.part(.floatOnTop), .part(.presentation), .part(.print)])
        session.undo()
        #expect(session.draft == BandArrangementVariants())
        #expect(!session.canUndo)
    }

    @Test("標準に戻すは保存せず取り消しで編集中の配置に戻る")
    func backToStandard() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.print, to: .zone(.bottomLeft), for: .split)
        #expect(session.duplicate(named: "Reading") == nil)
        session.select(.part(.print))
        session.moveSelection(to: .zone(.bottomLeft))
        let edited = session.draft
        session.backToStandard()
        #expect(session.draft == BandArrangementVariants())
        #expect(session.message == .backToStandard)
        #expect(environment.preferences.bandArrangementStore.activeLayouts == BandArrangementVariants())
        session.undo()
        #expect(session.draft == edited && session.draft.split == layouts.split)
    }

    // MARK: - Leaving a draft

    @Test("未保存の変更があると配置の切り替えや画面の移動は答えを待つ")
    func dirtyDraftWaits() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.duplicate(named: "Reading") == nil)
        let reading = session.active
        session.request(.section(.general))
        #expect(environment.preferences.settingsSection == .general && session.pendingLeave == nil)
        environment.preferences.settingsSection = .toolbarArrangement
        session.select(.part(.zoom))
        session.moveSelection(to: .unused)
        session.request(.selectSet(.standard))
        #expect(session.pendingLeave == .selectSet(.standard))
        #expect(session.active == reading)
        // Cancel
        session.pendingLeave = nil
        #expect(session.isDirty && session.active == reading)
        session.request(.section(.printing))
        #expect(environment.preferences.settingsSection == .toolbarArrangement)
    }

    @Test("破棄して離れると保存した配置は変わらず取り消しで下書きが戻る")
    func discardAndLeave() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.duplicate(named: "Reading") == nil)
        let saved = environment.preferences.bandArrangementStore
        session.select(.part(.zoom))
        session.moveSelection(to: .unused)
        let edited = session.draft
        session.request(.selectSet(.standard))
        session.discardChanges()
        session.proceed()
        #expect(session.active == .standard && !session.isDirty)
        #expect(environment.preferences.bandArrangementStore.sets == saved.sets)
        session.undo()
        session.undo()
        #expect(session.draft == edited)
    }

    @Test("保存して離れると使用中の配置を上書きしてから切り替える")
    func saveAndLeave() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.duplicate(named: "Reading") == nil)
        let reading = try #require(environment.preferences.bandArrangementStore.sets.first)
        session.select(.part(.zoom))
        session.moveSelection(to: .unused)
        session.request(.selectSet(.standard))
        #expect(session.saveForLeaving())
        session.proceed()
        #expect(session.active == .standard)
        let saved = try #require(environment.preferences.bandArrangementStore.sets.first)
        #expect(saved.id == reading.id && saved.name == "Reading")
        #expect(saved.layouts.split.unused == [.zoom])
    }

    @Test("標準を変えて保存すると名前を付けた複製になり標準は変わらない")
    func savingStandardMakesACopy() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.floatOnTop))
        session.moveSelection(to: .unused)
        session.request(.section(.styles))
        #expect(!session.saveForLeaving())
        #expect(session.dialog == .saveCopy)
        #expect(
            session.proposedCopyName() == String(format: String(localized: "%@ Copy"), String(localized: "Standard")))
        #expect(session.duplicate(named: session.proposedCopyName()) == nil)
        session.dialog = nil
        session.proceed()
        #expect(environment.preferences.settingsSection == .styles)
        let copy = try #require(environment.preferences.bandArrangementStore.sets.first)
        #expect(session.active == .user(copy.id) && copy.layouts.split.unused == [.floatOnTop])
        #expect(environment.preferences.bandArrangementStore.contains(.standard))
    }

    @Test("未保存の変更があると設定の窓は閉じる前に確かめ元の窓の代理に残りを任せる")
    func windowGuard() {
        final class Original: NSObject, NSWindowDelegate {
            var closes = 0
            var resized = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool {
                closes += 1
                return true
            }
            func windowDidResize(_ notification: Notification) { resized += 1 }
        }
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let original = Original()
        window.delegate = original
        let windowGuard = SettingsWindowGuard.install(
            on: window,
            shouldClose: {
                guard session.isDirty else { return true }
                session.pendingLeave = .closeWindow
                return false
            },
            undoManager: { session.history })
        #expect(window.delegate === windowGuard && windowGuard.original === original)
        // Installing again keeps the one guard and takes the new closures.
        #expect(SettingsWindowGuard.install(on: window, shouldClose: { true }, undoManager: { nil }) === windowGuard)
        windowGuard.shouldClose = {
            guard session.isDirty else { return true }
            session.pendingLeave = .closeWindow
            return false
        }
        windowGuard.undoManager = { session.history }
        #expect(windowGuard.windowShouldClose(window))
        #expect(original.closes == 1)
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(!windowGuard.windowShouldClose(window))
        #expect(session.pendingLeave == .closeWindow && original.closes == 1)
        // Everything else still reaches SwiftUI's own delegate.
        #expect(windowGuard.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        window.setContentSize(NSSize(width: 260, height: 120))
        #expect(original.resized >= 1)
        #expect(window.undoManager === session.history)
    }

    // MARK: - Saved sets

    @Test("複製は未保存の変更を含み新規は標準から始まりどちらも使用中になる")
    func duplicateAndNew() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.thumbnails))
        session.moveSelection(to: .unused)
        #expect(session.duplicate(named: "  Reading ") == nil)
        let store = environment.preferences.bandArrangementStore
        let reading = try #require(store.sets.first)
        #expect(reading.name == "Reading" && store.active == .user(reading.id))
        #expect(reading.layouts.split.unused == [.thumbnails])
        #expect(!session.isDirty)
        #expect(session.duplicate(named: "reading") != nil)
        let newName = String(localized: "New Arrangement")
        #expect(session.proposedNewName() == newName)
        #expect(session.createSet(named: newName) == nil)
        let new = try #require(environment.preferences.bandArrangementStore.sets.last)
        #expect(new.layouts == BandArrangementVariants() && session.active == .user(new.id))
        #expect(session.draft == BandArrangementVariants())
        #expect(session.proposedNewName() == newName + " 2")
    }

    @Test("上書きは名前と識別子を保ち名前の変更は選択を変えない")
    func overwriteAndRename() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.duplicate(named: "Reading") == nil)
        let id = try #require(environment.preferences.bandArrangementStore.sets.first?.id)
        #expect(!session.canOverwrite)
        session.select(.part(.style))
        session.moveSelection(to: .unused)
        #expect(session.canOverwrite)
        #expect(session.overwrite() == nil)
        #expect(session.message == .saved("Reading"))
        let saved = try #require(environment.preferences.bandArrangementStore.sets.first)
        #expect(saved.id == id && saved.name == "Reading" && saved.layouts.split.unused == [.style])
        #expect(session.rename(to: "Slides") == nil)
        #expect(environment.preferences.bandArrangementStore.active == .user(id))
        #expect(session.activeName == "Slides")
        #expect(session.nameProblem("slides", excluding: session.active) == nil)
        #expect(session.nameProblem(" ") != nil)
    }

    @Test("標準は上書きも名前の変更も削除もできない")
    func standardIsReadOnly() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.style))
        session.moveSelection(to: .unused)
        #expect(!session.canOverwrite)
        #expect(session.overwrite() == nil)
        #expect(session.rename(to: "Mine") != nil)
        #expect(session.deleteActive(replacement: .standard) != nil)
        #expect(environment.preferences.bandArrangementStore.sets.isEmpty)
        #expect(environment.suite.defaults.object(forKey: "bandArrangementStore") == nil)
    }

    @Test("使用中の配置を削除すると選んだ代わりを使い取り消しで保存内容と選択も戻る")
    func deleteWithReplacement() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.createSet(named: "Printing") == nil)
        let printing = session.active
        session.select(.part(.outline))
        session.moveSelection(to: .unused)
        #expect(session.duplicate(named: "Reading") == nil)
        let reading = session.active
        #expect(session.replacements == [.standard, printing])
        #expect(session.deleteActive(replacement: printing) == nil)
        #expect(session.active == printing)
        #expect(environment.preferences.bandArrangementStore.sets.map(\.name) == ["Printing"])
        #expect(session.draft == BandArrangementVariants())
        session.undo()
        #expect(session.active == reading)
        #expect(environment.preferences.bandArrangementStore.sets.map(\.name) == ["Printing", "Reading"])
        #expect(session.draft.split.unused == [.outline])
        session.redo()
        #expect(session.active == printing)
    }

    @Test("保存した変更は開いている窓の帯にすぐ届き下書きは届かない")
    func savedChangeReachesWindows() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = DocumentRenderer(paginate: { _ in
            try #require(PDFDocument(data: TestFixtures.textPDF(["First"])))
        })
        let model = DocumentViewModel(
            data: Data("# First\n".utf8), fileURL: nil, format: .markdown, preferences: environment.preferences,
            library: UserLibrary(root: directory.appendingPathComponent("Library")), renderer: renderer,
            settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        let menu = OverlayMenuState()
        #expect(BandPlans(model: model, menu: menu).top.trailing == [.floatOnTop, .print])
        let session = environment.session
        #expect(session.duplicate(named: "Reading") == nil)
        session.select(.part(.print))
        session.moveSelection(to: .zone(.bottomLeft))
        #expect(BandPlans(model: model, menu: menu).top.trailing == [.floatOnTop, .print])
        #expect(session.overwrite() == nil)
        let plans = BandPlans(model: model, menu: menu)
        #expect(plans.top.trailing == [.floatOnTop])
        #expect(plans.bottom?.leading.last == .print)
    }

    // MARK: - Drops

    @Test("ドロップは部品の前に入り領域の末尾に足し使わない部品へ外す")
    func dropRules() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        var payload = session.beginDrag(.entry(location(.zone(.bottomRight), 1), .part(.pageTurn)))
        #expect(session.proposal(for: .zone(.topLeft, index: 0)) == .move)
        #expect(session.drop(payload, on: .zone(.topLeft, index: 0)))
        #expect(session.draft.split.topLeft == [.part(.pageTurn), .part(.formatBadge)])
        payload = session.beginDrag(.entry(location(.zone(.topLeft), 0), .part(.pageTurn)))
        #expect(session.drop(payload, on: .zone(.topRight, index: 2)))
        #expect(session.draft.split.topRight == [.part(.floatOnTop), .part(.print), .part(.pageTurn)])
        payload = session.beginDrag(.entry(location(.zone(.topRight), 2), .part(.pageTurn)))
        #expect(session.drop(payload, on: .unused))
        #expect(session.draft.split.unused == [.pageTurn])
        payload = session.beginDrag(.newSeparator)
        #expect(session.proposal(for: .zone(.bottomRight, index: 1)) == .copy)
        #expect(session.proposal(for: .unused) == .forbidden)
        #expect(session.drop(payload, on: .zone(.bottomRight, index: 1)))
        #expect(session.draft.split.bottomRight == [.part(.pageIndicator), .separator])
        // A separator dragged off the zones is taken away; a part dragged there stays.
        payload = session.beginDrag(.entry(location(.zone(.bottomRight), 1), .separator))
        #expect(session.proposal(for: .outside) == .move)
        #expect(session.drop(payload, on: .outside))
        #expect(session.draft.split.bottomRight == [.part(.pageIndicator)])
        payload = session.beginDrag(.entry(location(.zone(.bottomRight), 0), .part(.pageIndicator)))
        #expect(session.proposal(for: .outside) == .forbidden)
        #expect(!session.drop(payload, on: .outside))
        #expect(session.draft.split.bottomRight == [.part(.pageIndicator)])
    }

    @Test("印刷を使わない部品へ落とすと断って理由を伝える")
    func printDropRefused() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let payload = session.beginDrag(.entry(location(.zone(.topRight), 1), .part(.print)))
        #expect(session.proposal(for: .unused) == .forbidden)
        #expect(session.message == .printIsRequired)
        #expect(!session.drop(payload, on: .unused))
        #expect(session.draft == BandArrangementVariants() && !session.canUndo)
    }

    @Test("古いドラッグやほかの編集画面と他のアプリの内容は受け付けない")
    func stalePayloads() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let stale = session.beginDrag(.entry(location(.zone(.topRight), 0), .part(.floatOnTop)))
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(!session.drop(stale, on: .zone(.topLeft, index: 0)))
        let other = BandArrangementEditorSession(preferences: environment.preferences)
        let foreign = other.beginDrag(.entry(location(.zone(.topRight), 0), .part(.floatOnTop)))
        #expect(!session.drop(foreign, on: .zone(.topLeft, index: 0)))
        let lying = BandEditorPayload(
            session: session.id, revision: session.revision, mode: .split,
            source: .entry(location(.zone(.topRight), 0), .part(.print)))
        #expect(!session.drop(lying, on: .zone(.topLeft, index: 0)))
        #expect(session.draft.split.topRight == [.part(.floatOnTop), .part(.print)])
        let current = session.beginDrag(.entry(location(.zone(.topRight), 0), .part(.floatOnTop)))
        let parsed = try #require(BandEditorPayload(string: current.string))
        #expect(parsed == current)
        #expect(
            BandEditorPayload(
                string: BandEditorPayload(session: session.id, revision: 0, mode: .top, source: .newSeparator).string)?
                .source == .newSeparator)
        for text in [
            "Contents", "", "surimono.band-entry/1", "surimono.band-entry/2;\(session.id.uuidString);0;split;new",
            "surimono.band-entry/1;\(session.id.uuidString);0;split;topLeft;0;futurePart",
            "surimono.band-entry/1;\(session.id.uuidString);0;split;middle;0;print",
            "surimono.band-entry/1;\(session.id.uuidString);0;split;topLeft;-1;print",
        ] {
            #expect(BandEditorPayload(string: text) == nil, "\(text)")
        }
    }

    @Test("ドロップの位置はポインタの行で次の部品の前になり行の終わりなら後ろになる")
    func insertionIndex() {
        // Two lines: three chips, then two.
        let frames = [
            CGRect(x: 0, y: 0, width: 30, height: 26), CGRect(x: 33, y: 0, width: 30, height: 26),
            CGRect(x: 66, y: 0, width: 30, height: 26), CGRect(x: 0, y: 30, width: 30, height: 26),
            CGRect(x: 33, y: 30, width: 30, height: 26),
        ]
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: 5, y: 10), frames: frames) == 0)
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: 40, y: 10), frames: frames) == 1)
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: 90, y: 10), frames: frames) == 3)
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: 50, y: 40), frames: frames) == 5)
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: 10, y: 90), frames: frames) == 3)
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: 10, y: 10), frames: []) == 0)
        #expect(BandEditorDrop.marker(at: 3, frames: frames) == CGRect(x: -2.75, y: 30, width: 2.5, height: 26))
        #expect(BandEditorDrop.marker(at: 5, frames: frames) == CGRect(x: 63.25, y: 30, width: 2.5, height: 26))
    }

    // MARK: - Recovery

    @Test("読めない保存データは書き換えず始め直すと別のキーに残して標準から始める")
    func recovery() throws {
        let unreadable = Data(#"{"schemaVersion":9,"sets":[]}"#.utf8)
        let environment = Environment(stored: unreadable)
        defer { environment.cleanUp() }
        let session = environment.session
        let defaults = environment.suite.defaults
        #expect(session.needsRecovery)
        #expect(session.createSet(named: "Reading") == BandArrangementEditorSession.Message.cannotSave.text)
        #expect(defaults.data(forKey: "bandArrangementStore") == unreadable)
        session.startOver()
        #expect(!session.needsRecovery && session.active == .standard)
        #expect(defaults.data(forKey: "bandArrangementStore") == nil)
        #expect(defaults.array(forKey: AppPreferences.unreadableBandArrangementsKey) as? [Data] == [unreadable])
        #expect(session.createSet(named: "Reading") == nil)
        #expect(AppPreferences(defaults: defaults).bandArrangementStore.sets.map(\.name) == ["Reading"])
    }
}
