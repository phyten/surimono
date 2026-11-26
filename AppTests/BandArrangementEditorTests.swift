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
            // The suite's own name: a language choice in a test must never reach the app's real preferences.
            preferences = AppPreferences(defaults: suite.defaults, domainName: suite.name)
            session = BandArrangementEditorSession(preferences: preferences)
        }

        func cleanUp() { suite.remove() }
    }

    private func location(_ destination: BandDestination, _ index: Int) -> BandEntryLocation {
        BandEntryLocation(destination: destination, index: index)
    }

    @Test("部品の表示は下書きや履歴を作らず標準に戻してもセットを切り替えても保たれる")
    func namesAreIndependentOfDraft() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        environment.preferences.bandNames = .hidden
        #expect(!session.isDirty && !session.canUndo)
        // Exercise an actual reset of a changed arrangement and its history.
        #expect(session.insertSeparator(in: .topLeft, at: 0))
        #expect(session.duplicate(named: "Reading") == nil)
        session.backToStandard()
        #expect(session.isDirty && environment.preferences.bandNames == .hidden)
        session.undo()
        #expect(!session.isDirty && environment.preferences.bandNames == .hidden)
        session.redo()
        #expect(session.isDirty && environment.preferences.bandNames == .hidden)
        #expect(session.overwrite() == nil)
        session.selectSet(.standard)
        #expect(session.active == .standard && environment.preferences.bandNames == .hidden)
    }

    @Test("未使用の分類は全29部品を正しい群に一度ずつ元の順と添字で投影する")
    func paletteProjection() {
        let unused: [BandLayout.Item] = [
            .keysAndGestures, .saveAsFile, .viewOptions, .ignoreSlides, .beforePrinting,
            .margins, .alwaysShowToolbar, .selectText, .cover, .paperSeries, .paperOrientation,
            .readingSettings, .scrollDirection, .readingDirection, .printSettings, .print, .pageTurn, .floatOnTop,
            .showOnAllSpaces,
            .thumbnails, .zoom, .transition, .layout, .outline, .style, .presentation,
            .pageIndicator, .formatBadge, .chapter,
        ]
        let groups = BandPaletteGroup.project(unused)
        #expect(groups.map(\.id) == [.movement, .display, .reading, .bodyAndPaper, .window, .printingAndSaving, .help])
        #expect(
            groups.map { $0.parts.map(\.id) } == [
                [.pageTurn, .thumbnails, .outline, .pageIndicator, .formatBadge, .chapter],
                [.zoom, .transition, .layout, .presentation],
                [.selectText, .cover, .readingSettings, .scrollDirection, .readingDirection],
                [.ignoreSlides, .margins, .paperSeries, .paperOrientation, .style],
                [.viewOptions, .alwaysShowToolbar, .floatOnTop, .showOnAllSpaces],
                [.saveAsFile, .beforePrinting, .printSettings, .print], [.keysAndGestures],
            ])
        let parts = groups.flatMap(\.parts)
        #expect(parts.count == 29 && Set(parts.map(\.id)).count == 29)
        for part in parts {
            #expect(part.location.destination == .unused)
            #expect(unused[part.location.index] == part.id)
        }
        #expect(BandPaletteGroup.project([]).isEmpty)
        #expect(BandPaletteGroup.project([.cover, .selectText]).map(\.id) == [.reading])
    }

    @Test("標準の未使用パレットは空の群を出さず表示だけでは下書きや履歴を変えない")
    func standardPaletteDoesNotEdit() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let before = session.draft
        let groups = BandPaletteGroup.project(session.arrangement.unused)
        #expect(groups.map(\.id) == [.display, .reading, .bodyAndPaper, .window, .printingAndSaving, .help])
        #expect(
            groups.map { $0.parts.map(\.id) } == [
                [.transition], [.readingDirection, .scrollDirection, .cover, .selectText],
                [.paperOrientation, .paperSeries, .margins, .ignoreSlides],
                [.floatOnTop, .showOnAllSpaces, .alwaysShowToolbar, .viewOptions],
                [.printSettings, .beforePrinting, .saveAsFile],
                [.keysAndGestures],
            ])
        #expect(session.draft == before && !session.isDirty && !session.canUndo)
        #expect(session.selection == nil)
    }

    @Test("群からのドロップは元の未使用添字を使い選択を保ち一度で取り消せる", arguments: [MenuArrangement.top, .split])
    func groupedDrop(mode: MenuArrangement) throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.mode = mode
        let before = session.draft
        let part = try #require(
            BandPaletteGroup.project(session.arrangement.unused)
                .flatMap(\.parts).first { $0.id == .viewOptions })
        #expect(part.location.index > 0)
        let payload = session.beginDrag(.entry(part.location, .part(part.id)))
        #expect(session.drop(payload, on: .zone(.topLeft, index: 0)))
        #expect(session.arrangement.topLeft.first == .part(.viewOptions))
        #expect(!session.arrangement.unused.contains(.viewOptions))
        #expect(session.selection == .part(.viewOptions))
        #expect(session.selectionRevealRevision == 0)
        session.undo()
        #expect(session.draft == before && !session.canUndo)
        session.redo()
        #expect(session.selection == .part(.viewOptions))
    }

    @Test("群の部品をボタンで往復し領域内の前後にも動かすと選択と一操作の履歴を保つ", arguments: [MenuArrangement.top, .split])
    func groupedMoves(mode: MenuArrangement) throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.mode = mode
        let part = try #require(
            BandPaletteGroup.project(session.arrangement.unused)
                .flatMap(\.parts).first { $0.id == .saveAsFile })
        session.select(.part(part.id))
        for destination: BandDestination in [.zone(.topLeft), .zone(.topRight), .unused] {
            let before = session.draft
            let reveal = session.selectionRevealRevision
            session.moveSelection(to: destination)
            let after = session.draft
            #expect(session.selectedLocation?.destination == destination)
            #expect(session.selection == .part(.saveAsFile))
            #expect(session.selectionRevealRevision == reveal + 1)
            session.undo()
            #expect(session.draft == before)
            session.redo()
            #expect(session.draft == after && session.selection == .part(.saveAsFile))
        }
        session.moveSelection(to: .zone(.topRight))
        for offset in [-1, 1] {
            let before = session.draft
            let index = try #require(session.selectedLocation).index
            session.moveSelection(by: offset)
            #expect(session.selectedLocation?.index == index + offset)
            #expect(session.selection == .part(.saveAsFile))
            session.undo()
            #expect(session.draft == before)
            session.redo()
        }
    }

    @Test("標準復帰は両配置の追加部品と最前面とめくり方を未使用へ戻し一度の取り消しで変更と閉じる前の確認を戻す")
    func restoreGroupedParts() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        for mode in [MenuArrangement.top, .split] {
            session.mode = mode
            for item in BandTestCatalog.standardUnused {
                session.select(.part(item))
                session.moveSelection(to: .zone(.topLeft))
            }
        }
        let before = session.draft
        let window = settingsWindow()
        let controller = SettingsWindowController(window: window, editor: session)
        #expect(!controller.windowShouldClose(window))
        #expect(session.pendingLeave == .closeWindow)
        session.cancelLeave()
        session.backToStandard()
        #expect(session.draft.top.unused == [.pageTurn] + BandTestCatalog.standardUnused)
        #expect(session.draft.split.unused == BandTestCatalog.standardUnused)
        #expect(!session.isDirty && controller.windowShouldClose(window))
        session.undo()
        #expect(session.draft == before)
        #expect(!controller.windowShouldClose(window) && session.pendingLeave == .closeWindow)
        session.redo()
        #expect(session.draft == BandArrangementVariants())
    }

    // MARK: - Editing the draft

    @Test("同じ領域の後ろへ移すと取り除いたあとの位置に入り保存はしない")
    func moveWithinZone() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.mode == .split)
        // Standard bottom left: presentation | style outline | layout | zoom thumbnails.
        #expect(session.move(location(.zone(.bottomLeft), 2), to: .zone(.bottomLeft), at: 6))
        #expect(
            session.draft.split.bottomLeft == [
                .part(.presentation), .separator, .part(.outline), .separator, .part(.layout), .part(.style),
                .separator, .part(.zoom), .part(.thumbnails),
            ])
        #expect(session.selection == .part(.style))
        #expect(session.message == .moved(BandLayout.Item.style.editorName, BandZoneID.bottomLeft.editorName, 6, 9))
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
        session.select(.part(.floatOnTop))
        session.moveSelection(to: .zone(.topRight))
        #expect(session.move(location(.zone(.topLeft), 2), to: .zone(.topRight), at: 1))
        #expect(session.draft.split.topRight == [.part(.print), .separator, .part(.floatOnTop)])
        #expect(session.selection == .separator(.topRight, 1))
        #expect(!session.separatorIsIdle(at: 1, in: .topRight))
        session.removeSelection()
        #expect(session.draft.split.topRight == [.part(.print), .part(.floatOnTop)])
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
        #expect(
            session.draft.split.bottomRight == [
                .part(.chapter), .part(.pageTurn), .part(.pageIndicator), .part(.readingSettings),
            ])
        #expect(!session.canMove(location(.zone(.bottomRight), 0), by: -1))
        session.moveSelection(by: -1)
        #expect(
            session.draft.split.bottomRight == [
                .part(.pageTurn), .part(.chapter), .part(.pageIndicator), .part(.readingSettings),
            ])
        session.moveSelection(by: -1)
        #expect(
            session.draft.split.bottomRight == [
                .part(.pageTurn), .part(.chapter), .part(.pageIndicator), .part(.readingSettings),
            ])
        session.moveSelection(by: 1)
        session.moveSelection(by: 1)
        #expect(
            session.draft.split.bottomRight == [
                .part(.chapter), .part(.pageIndicator), .part(.pageTurn), .part(.readingSettings),
            ])
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
        #expect(
            session.draft.split.bottomRight == [
                .part(.chapter), .part(.pageIndicator), .part(.pageTurn), .part(.readingSettings), .part(.print),
            ])
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
        #expect(session.draft.split.unused == BandTestCatalog.standardUnused + [.outline])
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
        #expect(session.drop(payload, on: .zone(.topRight, index: 0)))
        #expect(session.draft.split.topRight == [.part(.presentation), .part(.print)])
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
        #expect(saved.layouts.split.unused == BandTestCatalog.standardUnused + [.zoom])
    }

    @Test("標準を変えて保存すると名前を付けた複製になり標準は変わらない")
    func savingStandardMakesACopy() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.formatBadge))
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
        #expect(
            session.active == .user(copy.id)
                && copy.layouts.split.unused == BandTestCatalog.standardUnused + [.formatBadge])
        #expect(environment.preferences.bandArrangementStore.contains(.standard))
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
        #expect(reading.layouts.split.unused == BandTestCatalog.standardUnused + [.thumbnails])
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
        #expect(
            saved.id == id && saved.name == "Reading"
                && saved.layouts.split.unused == BandTestCatalog.standardUnused + [.style])
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
        #expect(session.draft.split.unused == BandTestCatalog.standardUnused + [.outline])
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
        #expect(BandPlans(model: model, menu: menu).top.trailing == [.print])
        let session = environment.session
        #expect(session.duplicate(named: "Reading") == nil)
        session.select(.part(.print))
        session.moveSelection(to: .zone(.bottomLeft))
        #expect(BandPlans(model: model, menu: menu).top.trailing == [.print])
        #expect(session.overwrite() == nil)
        let plans = BandPlans(model: model, menu: menu)
        #expect(plans.top.trailing.isEmpty)
        #expect(plans.bottom?.leading.last == .print)
    }

    // MARK: - Drops

    @Test("ドロップは部品の前に入り領域の末尾に足し使わない部品へ外す")
    func dropRules() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        var payload = session.beginDrag(.entry(location(.zone(.bottomRight), 2), .part(.pageTurn)))
        #expect(session.proposal(for: .zone(.topLeft, index: 0)) == .move)
        #expect(session.drop(payload, on: .zone(.topLeft, index: 0)))
        #expect(session.draft.split.topLeft == [.part(.pageTurn), .part(.formatBadge)])
        payload = session.beginDrag(.entry(location(.zone(.topLeft), 0), .part(.pageTurn)))
        #expect(session.drop(payload, on: .zone(.topRight, index: 1)))
        #expect(session.draft.split.topRight == [.part(.print), .part(.pageTurn)])
        payload = session.beginDrag(.entry(location(.zone(.topRight), 1), .part(.pageTurn)))
        #expect(session.drop(payload, on: .unused))
        #expect(session.draft.split.unused == BandTestCatalog.standardUnused + [.pageTurn])
        payload = session.beginDrag(.newSeparator)
        #expect(session.proposal(for: .zone(.bottomRight, index: 2)) == .copy)
        #expect(session.proposal(for: .unused) == .copy)
        #expect(session.drop(payload, on: .unused))
        payload = session.beginDrag(.newSeparator)
        #expect(session.drop(payload, on: .zone(.bottomRight, index: 2)))
        #expect(
            session.draft.split.bottomRight == [
                .part(.chapter), .part(.pageIndicator), .separator, .part(.readingSettings),
            ])
        // A separator dragged off the zones is taken away; a part dragged there stays.
        payload = session.beginDrag(.entry(location(.zone(.bottomRight), 2), .separator))
        #expect(session.proposal(for: .outside) == .move)
        #expect(session.drop(payload, on: .outside))
        #expect(session.draft.split.bottomRight == [.part(.chapter), .part(.pageIndicator), .part(.readingSettings)])
        payload = session.beginDrag(.entry(location(.zone(.bottomRight), 1), .part(.pageIndicator)))
        #expect(session.proposal(for: .outside) == .forbidden)
        #expect(!session.drop(payload, on: .outside))
        #expect(session.draft.split.bottomRight == [.part(.chapter), .part(.pageIndicator), .part(.readingSettings)])
    }

    @Test("新しい区切り線と配置済みの区切り線を各領域のすべての挿入位置へ落とせる")
    func separatorDropPositions() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        for mode in MenuArrangement.allCases {
            session.mode = mode
            for zone in session.zones {
                let original = session.arrangement[zone]
                for index in 0...original.count {
                    let target = BandEditorDropTarget.zone(zone, index: index)
                    let new = session.beginDrag(.newSeparator)
                    #expect(session.proposal(for: target) == .copy)
                    #expect(session.drop(new, on: target))
                    var expected = original
                    expected.insert(.separator, at: index)
                    #expect(session.arrangement[zone] == expected)
                    let source: BandZoneID = zone == .topLeft ? .topRight : .topLeft
                    #expect(session.drop(session.beginDrag(.newSeparator), on: .zone(source, index: 0)))
                    let moved = session.beginDrag(.entry(location(.zone(source), 0), .separator))
                    #expect(session.proposal(for: target) == .move)
                    #expect(session.drop(moved, on: target))
                    expected.insert(.separator, at: index)
                    #expect(session.arrangement[zone] == expected)
                    session.undo()
                    session.undo()
                    session.undo()
                    #expect(session.arrangement[zone] == original)
                }
            }
        }
    }

    @Test("空の領域に線を追加して別の線を移し、使わない部品に落とした線だけを消す")
    func emptyZoneDrop() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.formatBadge))
        session.removeSelection()
        let empty = BandEditorDropTarget.zone(.topLeft, index: 0)
        #expect(session.drop(session.beginDrag(.newSeparator), on: empty))
        let added = session.beginDrag(.entry(location(.zone(.topLeft), 0), .separator))
        #expect(session.drop(added, on: .unused))
        #expect(session.arrangement.topLeft.isEmpty)
        #expect(session.drop(session.beginDrag(.newSeparator), on: .zone(.bottomLeft, index: 0)))
        let moved = session.beginDrag(.entry(location(.zone(.bottomLeft), 0), .separator))
        #expect(session.drop(moved, on: empty))
        #expect(session.arrangement.topLeft == [.separator])
    }

    @Test("未選択のパレットからも区切りを追加でき、以後は選択中の線の後ろに足す")
    func addSeparatorWithoutSelection() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.insertSeparatorAfterSelection()
        session.insertSeparatorAfterSelection()
        #expect(session.arrangement.topLeft == [.part(.formatBadge), .separator, .separator])
        #expect(session.selection == .separator(.topLeft, 2))
    }

    @Test("帯の端・余白・左右の間も近い領域へ入り、未計測のチップは末尾へ入る")
    func wholeBandDropTarget() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.layoutFrames = [
            "topBand": CGRect(x: 10, y: 40, width: 400, height: 50),
            "topLeft": CGRect(x: 80, y: 46, width: 65, height: 30),
            "topRight": CGRect(x: 300, y: 46, width: 90, height: 30),
            "palette": CGRect(x: 10, y: 120, width: 400, height: 80),
        ]
        session.chipFrames[.topLeft] = [CGRect(x: 3, y: 3, width: 24, height: 24)]
        session.chipFrames[.topRight] = [CGRect(x: 20, y: 3, width: 24, height: 24)]
        func target(_ x: CGFloat, _ y: CGFloat) -> BandEditorDropTarget {
            BandEditorDrop.placement(at: CGPoint(x: x, y: y), in: session).target
        }
        #expect(target(11, 41) == .zone(.topLeft, index: 0))
        #expect(target(98, 55) == .zone(.topLeft, index: 1))
        #expect(target(175, 55) == .zone(.topLeft, index: 1))
        #expect(target(270, 55) == .zone(.topRight, index: 0))
        #expect(target(409, 89) == .zone(.topRight, index: 1))
        session.chipFrames[.topRight] = []
        #expect(target(300, 55) == .zone(.topRight, index: 1))
        #expect(target(20, 115) == .outside)
        #expect(target(20, 121) == .unused)
        session.layoutFrames["topRight"] = CGRect(x: 80, y: 80, width: 220, height: 10)
        #expect(target(85, 87) == .zone(.topRight, index: 1))
    }

    @Test("印刷の前は固定の「…」より手前に線とマーカーを置く", arguments: [false, true])
    func insertBeforeDockedPrint(wrapped: Bool) {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let zone = BandZoneID.topRight
        let band = CGRect(x: 10, y: 20, width: 200, height: 80)
        session.layoutFrames = ["topBand": band, zone.rawValue: band]
        let lock = CGRect(x: 3, y: 3, width: 24, height: 26)
        let button = CGRect(x: wrapped ? 3 : 30, y: wrapped ? 33 : 3, width: 40, height: 26)
        session.dockedMoreFrame = lock
        session.chipFrames[zone] = [button]
        for local in [CGPoint(x: lock.maxX - 1, y: lock.midY), CGPoint(x: button.minX + 1, y: button.midY)] {
            let placement = BandEditorDrop.placement(
                at: CGPoint(x: local.x + band.minX, y: local.y + band.minY), in: session)
            #expect(placement.target == .zone(zone, index: 0))
            #expect(placement.marker == CGRect(x: 0.25, y: 3, width: 2.5, height: 26))
            #expect(session.drop(session.beginDrag(.newSeparator), on: placement.target))
            #expect(session.arrangement[zone] == [.separator, .part(.print)])
            session.undo()
        }
    }

    @Test("VoiceOverの移動先を次の操作の起点にすると連続する線を越え、別の領域にも進める")
    func accessibilityMoveDestination() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.formatBadge))
        session.insertSeparatorAfterSelection()
        session.insertSeparatorAfterSelection()
        session.performAccessibilityAction(on: .separator(.topLeft, 2)) { session.moveSelection(by: -1) }
        #expect(session.accessibilityFocusDestination == .separator(.topLeft, 1))
        session.performAccessibilityAction(on: session.accessibilityFocusDestination) { session.moveSelection(by: -1) }
        #expect(session.accessibilityFocusDestination == .separator(.topLeft, 0))
        #expect(session.arrangement.topLeft == [.separator, .part(.formatBadge), .separator])
        session.performAccessibilityAction(on: session.accessibilityFocusDestination) {
            session.moveSelection(to: .zone(.topRight))
        }
        #expect(session.accessibilityFocusDestination == .separator(.topRight, 1))
    }

    @Test("同じ領域の連続する線を越えて選択を動かし、キー操作で端から端まで移せる")
    func movingPastIdenticalSeparators() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.select(.part(.formatBadge))
        session.insertSeparatorAfterSelection()
        session.insertSeparatorAfterSelection()
        session.select(.part(.zoom))
        session.moveSelection(to: .zone(.topLeft))
        #expect(!session.separatorIsIdle(at: 1, in: .topLeft))
        #expect(session.separatorIsIdle(at: 2, in: .topLeft))
        session.select(.separator(.topLeft, 2))
        session.moveSelection(by: -1)
        #expect(session.selection == .separator(.topLeft, 1))
        session.moveSelection(by: -1)
        #expect(session.arrangement.topLeft == [.separator, .part(.formatBadge), .separator, .part(.zoom)])
        for index in 0...4 {
            let moved = session.beginDrag(.entry(location(.zone(.topLeft), 0), .separator))
            #expect(session.drop(moved, on: .zone(.topLeft, index: index)))
            #expect(session.selection == .separator(.topLeft, max(0, index - 1)))
            if index > 1 { session.undo() }
        }
    }

    @Test("印刷を使わない部品へ落とすと断って理由を伝える")
    func printDropRefused() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let payload = session.beginDrag(.entry(location(.zone(.topRight), 0), .part(.print)))
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
        let stale = session.beginDrag(.entry(location(.zone(.topRight), 0), .part(.print)))
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(session.proposal(for: .zone(.topLeft, index: 0)) == .forbidden)
        #expect(session.message == .dropFailed)
        #expect(!session.drop(stale, on: .zone(.topLeft, index: 0)))
        let other = BandArrangementEditorSession(preferences: environment.preferences)
        let foreign = other.beginDrag(.entry(location(.zone(.topRight), 0), .part(.print)))
        #expect(!session.drop(foreign, on: .zone(.topLeft, index: 0)))
        let lying = BandEditorPayload(
            session: session.id, revision: session.revision, mode: .split,
            source: .entry(location(.zone(.topRight), 0), .part(.zoom)))
        #expect(!session.drop(lying, on: .zone(.topLeft, index: 0)))
        #expect(session.draft.split.topRight == [.part(.print)])
        let current = session.beginDrag(.entry(location(.zone(.topRight), 0), .part(.print)))
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
        // The gap between lines used to match both rows and could jump past the entire second row.
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: 200, y: 27), frames: frames) == 3)
        #expect(BandEditorDrop.insertionIndex(at: CGPoint(x: -5, y: 29), frames: frames) == 3)
        #expect(BandEditorDrop.marker(at: 3, frames: frames) == CGRect(x: -2.75, y: 30, width: 2.5, height: 26))
        #expect(
            BandEditorDrop.marker(at: 3, frames: frames, pointerY: 27) == CGRect(x: 96.25, y: 0, width: 2.5, height: 26)
        )
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
        #expect(defaults.data(forKey: "bandArrangementStore") != unreadable)
        #expect(defaults.array(forKey: AppPreferences.unreadableBandArrangementsKey) as? [Data] == [unreadable])
        #expect(session.createSet(named: "Reading") == nil)
        #expect(
            AppPreferences(defaults: defaults, domainName: environment.suite.name).bandArrangementStore.sets.map(\.name)
                == ["Reading"])
    }

    @Test("始め直した直後に起動し直しても旧設定の移行は繰り返さず標準のまま")
    func startOverThenRelaunch() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(false, forKey: "showsOutlineOnBand")
        suite.defaults.set(Data(#"{"schemaVersion":9,"sets":[]}"#.utf8), forKey: "bandArrangementStore")
        let session = BandArrangementEditorSession(
            preferences: AppPreferences(defaults: suite.defaults, domainName: suite.name))
        session.startOver()
        let relaunched = AppPreferences(defaults: suite.defaults, domainName: suite.name)
        #expect(relaunched.bandArrangementStore.active == .standard)
        #expect(relaunched.bandArrangementStore.sets.isEmpty)
        #expect(relaunched.retainedBandArrangementData == nil)
    }

    // MARK: - Repairs

    /// One record without a name, and a set whose Top Only layout is not a layout.
    private static let damaged = Data(
        #"""
        {"schemaVersion":1,"active":{"kind":"user","id":"5C6B1D2E-0F4A-4E8B-9C7D-2A1B3C4D5E6F"},
        "sets":[{"id":"5C6B1D2E-0F4A-4E8B-9C7D-2A1B3C4D5E6F","name":"Reading",
        "layouts":{"split":{"topRight":["print"]},"top":7}},
        {"id":"6D7C2E3F-1A5B-4F9C-8D6E-3B2C4D5E6F70","name":""}]}
        """#.utf8)

    @Test("読み込みで直した内容を伝え最初の保存の前に元のデータを別に残す")
    func lossyRepair() throws {
        let environment = Environment(stored: Self.damaged)
        defer { environment.cleanUp() }
        let defaults = environment.suite.defaults
        let notices = environment.preferences.bandArrangementNotices
        #expect(notices.contains(.invalidRecord(1)) && notices.contains(.recoveredVariant(.top)))
        let lines = Set(notices.filter(\.losesData).compactMap(\.editorText))
        #expect(lines.count == 2)
        #expect(defaults.object(forKey: AppPreferences.repairedBandArrangementsKey) == nil)
        #expect(environment.session.createSet(named: "Printing") == nil)
        #expect(defaults.array(forKey: AppPreferences.repairedBandArrangementsKey) as? [Data] == [Self.damaged])
        #expect(environment.preferences.bandArrangementNotices.isEmpty)
        #expect(environment.session.createSet(named: "Slides") == nil)
        #expect((defaults.array(forKey: AppPreferences.repairedBandArrangementsKey) as? [Data])?.count == 1)
    }

    @Test("新しい版の部品が使わない部品に足されただけなら元のデータを残さない")
    func additiveRepair() throws {
        // A store written before Zoom Level existed: the part is in neither layout.
        var store = BandArrangementStore()
        try store.insert(BandArrangementSet(name: "Reading"))
        let written = String(decoding: try JSONEncoder().encode(store), as: UTF8.self)
        let older = Data(written.replacingOccurrences(of: #""zoom","#, with: "").utf8)
        #expect(older != Data(written.utf8))
        let environment = Environment(stored: older)
        defer { environment.cleanUp() }
        #expect(environment.preferences.bandArrangementNotices == [.addedToUnused(.zoom), .addedToUnused(.zoom)])
        let losesData = environment.preferences.bandArrangementNotices.contains { $0.losesData }
        #expect(!losesData)
        #expect(environment.session.createSet(named: "Printing") == nil)
        #expect(environment.suite.defaults.object(forKey: AppPreferences.repairedBandArrangementsKey) == nil)
    }

    // MARK: - Changes saved elsewhere

    @Test("別の画面で使う配置が変わると下書きは別の配置に上書きされず複製として残せる")
    func conflictWithAnotherSession() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let first = environment.session
        #expect(first.duplicate(named: "A") == nil)
        let a = first.active
        first.select(.part(.zoom))
        first.moveSelection(to: .unused)
        let second = BandArrangementEditorSession(preferences: environment.preferences)
        #expect(second.createSet(named: "B") == nil)
        let b = second.active
        #expect(first.hasConflict && !first.canOverwrite)
        #expect(first.overwrite() == BandArrangementEditorSession.Message.conflict.text)
        let store = environment.preferences.bandArrangementStore
        #expect(store.active == b)
        #expect(store.sets.allSatisfy { $0.layouts == BandArrangementVariants() })
        #expect(first.rename(to: "C") != nil && first.deleteActive(replacement: .standard) != nil)
        #expect(store.sets.map(\.name) == ["A", "B"] && store.contains(a))
        first.request(.selectSet(.standard))
        #expect(!first.saveForLeaving())
        #expect(first.dialog == .saveCopy)
    }

    @Test("同じ配置が外で保存し直されると上書きせず保存済みに合わせられる")
    func conflictWithOutsideUpdate() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.duplicate(named: "A") == nil)
        session.select(.part(.zoom))
        session.moveSelection(to: .unused)
        var outside = BandArrangementVariants()
        outside.split = try outside.split.moving(.style, to: .unused, for: .split)
        try environment.preferences.overwriteBandArrangement(session.active, layouts: outside)
        #expect(session.hasConflict)
        #expect(session.overwrite() == BandArrangementEditorSession.Message.conflict.text)
        #expect(environment.preferences.bandArrangementStore.activeLayouts == outside)
        session.discardChanges()
        #expect(!session.hasConflict && session.draft == outside)
    }

    @Test("変更のない下書きは外で選ばれた配置にそのまま従う")
    func followsOutsideWhileClean() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.print, to: .zone(.bottomRight), for: .split)
        let set = BandArrangementSet(name: "Outside", layouts: layouts)
        try environment.preferences.saveBandArrangement(set)
        session.refresh()
        #expect(session.base == .user(set.id) && session.draft == layouts && !session.isDirty)
    }

    @Test("ほかの経路で保存が進んだあとの取り消しはその変更を消さずに断る")
    func undoRefusesAfterOutsideChange() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let first = environment.session
        #expect(first.duplicate(named: "A") == nil)
        let second = BandArrangementEditorSession(preferences: environment.preferences)
        #expect(second.createSet(named: "B") == nil)
        first.undo()
        #expect(environment.preferences.bandArrangementStore.sets.map(\.name) == ["A", "B"])
        #expect(first.message == .historyConflict)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!first.canUndo && !first.canRedo)
        // The other editor's own step still undoes: nothing was saved after it.
        second.undo()
        #expect(environment.preferences.bandArrangementStore.sets.map(\.name) == ["A"])
    }

    // MARK: - Settings window

    private func settingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        return window
    }

    @Test("設定の窓が先に取り消しの履歴を作っていても配置画面の取り消しは編集画面の履歴に行く")
    func undoRoutedAfterWindowHistory() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let window = settingsWindow()
        let windowHistory = try #require(window.undoManager)
        let otherSection = UndoProbe()
        otherSection.register(on: windowHistory)
        let editor = EditorShown(true)
        let router = SettingsUndoRouter.install(
            on: window, history: { editor.shown ? session.history : nil }, undo: { session.undo() },
            redo: { session.redo() })
        #expect(SettingsUndoRouter.install(on: window, history: { nil }, undo: {}, redo: {}) === router)
        router.history = { editor.shown ? session.history : nil }
        router.performUndo = { session.undo() }
        router.performRedo = { session.redo() }
        session.insertSeparator(in: .topLeft, at: 0)
        let content = try #require(window.contentView)
        #expect(content.tryToPerform(#selector(SettingsUndoRouter.undo(_:)), with: nil))
        #expect(session.draft == BandArrangementVariants())
        #expect(otherSection.undone == 0 && windowHistory.canUndo)
        let item = NSMenuItem(title: "Undo", action: #selector(SettingsUndoRouter.redo(_:)), keyEquivalent: "")
        #expect(router.validateMenuItem(item) && item.title == session.history.redoMenuItemTitle)
        // Another section: the window's own history, exactly as before.
        editor.shown = false
        #expect(!router.responds(to: #selector(SettingsUndoRouter.undo(_:))))
        #expect(content.tryToPerform(#selector(SettingsUndoRouter.undo(_:)), with: nil))
        #expect(otherSection.undone == 1)
        #expect(session.canRedo)
    }

    @Test("ほかの区分で操作してから配置画面に来ても取り消しは混ざらない")
    func otherSectionThenEditor() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let window = settingsWindow()
        let editor = EditorShown(false)
        SettingsUndoRouter.install(
            on: window, history: { editor.shown ? session.history : nil }, undo: { session.undo() },
            redo: { session.redo() })
        let otherSection = UndoProbe()
        otherSection.register(on: try #require(window.undoManager))
        editor.shown = true
        session.insertSeparator(in: .topLeft, at: 0)
        let content = try #require(window.contentView)
        #expect(content.tryToPerform(#selector(SettingsUndoRouter.undo(_:)), with: nil))
        #expect(session.draft == BandArrangementVariants() && otherSection.undone == 0)
        // Nothing left in the editor's history: Undo is not taken from the other section.
        #expect(!session.canUndo)
        #expect(window.undoManager?.canUndo == true)
    }

    @Test("名前などの文字を編集している間は文字の取り消しを使う")
    func textKeepsItsUndo() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let window = settingsWindow()
        let router = SettingsUndoRouter.install(
            on: window, history: { session.history }, undo: { session.undo() }, redo: { session.redo() })
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(router.activeHistory === session.history)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        #expect(router.activeHistory == nil)
        #expect(!router.responds(to: #selector(SettingsUndoRouter.undo(_:))))
        #expect(session.canUndo)
    }

    @Test("設定の窓は編集中のセッションに閉じる判断を委ねる")
    func settingsWindowOwnsClose() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let window = settingsWindow()
        let session = environment.session
        let controller = SettingsWindowController(window: window, editor: session)
        #expect(window.delegate === controller && session.settingsController === controller)
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(!controller.windowShouldClose(window) && session.pendingLeave == .closeWindow)
        session.cancelLeave()
        #expect(session.isDirty && session.pendingLeave == nil)
        session.discardChanges()
        #expect(controller.windowShouldClose(window))
    }

    // MARK: - Quitting

    @MainActor private final class Replies {
        var values: [Bool] = []
        var shown = 0
    }

    private func quitting(_ session: BandArrangementEditorSession) -> Replies {
        let replies = Replies()
        session.replyToTermination = { replies.values.append($0) }
        session.showSettings = { replies.shown += 1 }
        return replies
    }

    @Test("未保存の変更がなければすぐに終了する")
    func quitWhenClean() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let replies = quitting(environment.session)
        #expect(environment.session.shouldTerminate() == .terminateNow)
        #expect(replies.values.isEmpty && replies.shown == 0)
    }

    @Test("未保存の変更があると終了を待たせ取り消すと終了しない")
    func quitCancelled() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let replies = quitting(session)
        environment.preferences.settingsSection = .general
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(session.shouldTerminate() == .terminateLater)
        #expect(session.pendingLeave == .quit && environment.preferences.settingsSection == .toolbarArrangement)
        #expect(replies.shown == 1)
        session.cancelLeave()
        #expect(replies.values == [false] && session.pendingLeave == nil && session.isDirty)
    }

    @Test("破棄して終了すると保存せずに終了する")
    func quitDiscarding() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let replies = quitting(session)
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(session.shouldTerminate() == .terminateLater)
        session.discardChanges()
        session.proceed()
        #expect(replies.values == [true])
        #expect(environment.suite.defaults.object(forKey: "bandArrangementStore") == nil)
    }

    @Test("保存して終了すると使用中の配置を上書きしてから終了する")
    func quitSaving() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        #expect(session.duplicate(named: "Reading") == nil)
        let replies = quitting(session)
        session.select(.part(.zoom))
        session.moveSelection(to: .unused)
        #expect(session.shouldTerminate() == .terminateLater)
        #expect(session.saveForLeaving())
        session.proceed()
        #expect(replies.values == [true])
        #expect(
            environment.preferences.bandArrangementStore.activeLayouts.split.unused == BandTestCatalog.standardUnused
                + [.zoom])
    }

    @Test("標準を変えて終了するとき複製の名前を取り消すと終了しない")
    func quitNamingCancelled() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let replies = quitting(session)
        session.insertSeparator(in: .topLeft, at: 0)
        #expect(session.shouldTerminate() == .terminateLater)
        #expect(!session.saveForLeaving() && session.dialog == .saveCopy)
        session.cancelLeave()
        session.dialog = nil
        #expect(replies.values == [false])
        #expect(environment.preferences.bandArrangementStore.sets.isEmpty && session.isDirty)
    }

    // MARK: - Follow-ups

    @MainActor private final class Relaunch {
        var asked = 0
        var launched = 0
        var terminated = 0
        var dirtyAtLaunch: Bool?
    }

    private func relaunch(
        _ environment: Environment, answer: BandArrangementEditorSession.RelaunchAnswer, record: Relaunch
    ) async throws -> Bool {
        let session = environment.session
        return try await LanguageRelaunchFlow.relaunch(
            editor: session, preferences: environment.preferences, previousLanguage: nil,
            askAboutDraft: { _ in
                record.asked += 1
                return answer
            },
            launch: {
                record.launched += 1
                record.dirtyAtLaunch = session.isDirty
            },
            terminate: { record.terminated += 1 })
    }

    @Test("言語を変える再起動は未保存の配置を先に聞き取り消すと何も起動せず言語を戻す")
    func relaunchCancelled() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.languageOverride = "de"
        environment.session.insertSeparator(in: .topLeft, at: 0)
        let record = Relaunch()
        #expect(try await !relaunch(environment, answer: .cancel, record: record))
        #expect(record.asked == 1 && record.launched == 0 && record.terminated == 0)
        #expect(environment.preferences.languageOverride == nil)
        #expect(environment.session.isDirty)
    }

    @Test("言語を変える再起動で破棄すると下書きを捨ててから起動して終了する")
    func relaunchDiscarding() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.languageOverride = "de"
        environment.session.insertSeparator(in: .topLeft, at: 0)
        let record = Relaunch()
        #expect(try await relaunch(environment, answer: .discard, record: record))
        #expect(record.launched == 1 && record.terminated == 1 && record.dirtyAtLaunch == false)
        #expect(environment.preferences.languageOverride == "de")
        #expect(environment.suite.defaults.object(forKey: "bandArrangementStore") == nil)
    }

    @Test("言語を変える再起動で保存すると使用中の配置か標準の複製に保存してから起動する")
    func relaunchSaving() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        session.insertSeparator(in: .topLeft, at: 0)
        let record = Relaunch()
        #expect(try await relaunch(environment, answer: .save, record: record))
        let copy = try #require(environment.preferences.bandArrangementStore.sets.first)
        #expect(copy.name == String(format: String(localized: "%@ Copy"), String(localized: "Standard")))
        #expect(copy.layouts.split.topLeft.first == .separator && record.dirtyAtLaunch == false)
        session.select(.part(.zoom))
        session.moveSelection(to: .unused)
        #expect(try await relaunch(environment, answer: .save, record: record))
        #expect(environment.preferences.bandArrangementStore.sets.count == 1)
        #expect(
            environment.preferences.bandArrangementStore.activeLayouts.split.unused == BandTestCatalog.standardUnused
                + [.zoom])
        #expect(record.launched == 2 && record.terminated == 2)
    }

    @Test("未保存の配置がなければ聞かずに再起動する")
    func relaunchWhenClean() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let record = Relaunch()
        #expect(try await relaunch(environment, answer: .cancel, record: record))
        #expect(record.asked == 0 && record.launched == 1 && record.terminated == 1)
    }

    @Test("書類のメニューから設定の区分を変えても未保存の配置は先に聞く")
    func sectionChangeFromOutside() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let session = environment.session
        let preferences = environment.preferences
        preferences.settingsSection = .toolbarArrangement
        BandArrangementEditorSession.showSection(.settingSets, preferences: preferences, editor: session)
        #expect(preferences.settingsSection == .settingSets)
        preferences.settingsSection = .toolbarArrangement
        session.insertSeparator(in: .topLeft, at: 0)
        BandArrangementEditorSession.showSection(.settingSets, preferences: preferences, editor: session)
        #expect(preferences.settingsSection == .toolbarArrangement)
        #expect(session.pendingLeave == .section(.settingSets))
        session.discardChanges()
        session.proceed()
        #expect(preferences.settingsSection == .settingSets)
        // Into the editor, from another section, nothing needs asking.
        session.showSection(.toolbarArrangement)
        #expect(preferences.settingsSection == .toolbarArrangement)
    }

    @Test("別に残す元のデータは同じものを二度持たず新しい十件まで")
    func setAsideIsBounded() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let key = AppPreferences.repairedBandArrangementsKey
        let preferences = environment.preferences
        preferences.setAside(Data("same".utf8), under: key)
        preferences.setAside(Data("same".utf8), under: key)
        #expect(environment.suite.defaults.array(forKey: key) as? [Data] == [Data("same".utf8)])
        for number in 1...12 { preferences.setAside(Data("original \(number)".utf8), under: key) }
        let kept = environment.suite.defaults.array(forKey: key) as? [Data] ?? []
        #expect(kept.count == 10)
        #expect(kept.first == Data("original 3".utf8) && kept.last == Data("original 12".utf8))
        preferences.setAside(Data("original 5".utf8), under: key)
        let again = environment.suite.defaults.array(forKey: key) as? [Data] ?? []
        #expect(again.count == 10 && again.last == Data("original 5".utf8))
        #expect(again.filter { $0 == Data("original 5".utf8) }.count == 1)
    }
}

/// Counts the steps of another Settings section that were undone.
@MainActor private final class UndoProbe {
    var undone = 0

    /// One step of its own group, as an event of the other section would leave it.
    func register(on history: UndoManager) {
        history.groupsByEvent = false
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { probe in
            // The undo manager's handler is not main-actor isolated; it runs on the main thread here.
            MainActor.assumeIsolated { probe.undone += 1 }
        }
        history.endUndoGrouping()
    }
}

/// Whether the arrangement editor is the Settings section on screen.
@MainActor private final class EditorShown {
    var shown: Bool
    init(_ shown: Bool) { self.shown = shown }
}
