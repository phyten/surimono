import AppKit
import Observation
import SurimonoCore
import SwiftUI

/// Where an entry stands in the variant being edited: a zone or "Parts to Add", and its index there.
struct BandEntryLocation: Hashable, Sendable {
    var destination: BandDestination
    var index: Int
}

/// The chip the inspector describes. A part is the same part wherever it moves; separators look alike, so one is
/// known by where it stands.
enum BandEditorSelection: Hashable, Sendable {
    case part(BandLayout.Item)
    case separator(BandZoneID, Int)
}

/// Where a drag would land: before the entry at `index` of a zone (the zone's count appends), on "Parts to Add", or
/// anywhere else in the editor.
enum BandEditorDropTarget: Hashable, Sendable {
    case zone(BandZoneID, index: Int)
    case unused
    case outside
}

/// What the editor's drag carries. Only this session's chips are accepted, and only while the draft is still the one
/// the drag started from, so a drop never acts on an entry that has moved since.
struct BandEditorPayload: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case entry(BandEntryLocation, BandEntry)
        /// The palette's separator, which can be added any number of times.
        case newSeparator
    }

    static let prefix = "surimono.band-entry/1"

    var session: UUID
    var revision: Int
    var mode: MenuArrangement
    var source: Source

    var string: String {
        var fields = [Self.prefix, session.uuidString, String(revision), mode.rawValue]
        switch source {
        case .newSeparator: fields.append("new")
        case .entry(let location, let entry):
            fields += [Self.name(of: location.destination), String(location.index), entry.storedValue]
        }
        return fields.joined(separator: ";")
    }

    init(session: UUID, revision: Int, mode: MenuArrangement, source: Source) {
        self.session = session
        self.revision = revision
        self.mode = mode
        self.source = source
    }

    /// Nil for anything that is not exactly one entry of an editor: text from elsewhere, several items, other versions.
    init?(string: String) {
        let fields = string.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, fields[0] == Self.prefix, let session = UUID(uuidString: fields[1]),
            let revision = Int(fields[2]), let mode = MenuArrangement(rawValue: fields[3])
        else { return nil }
        self.session = session
        self.revision = revision
        self.mode = mode
        if fields.count == 5, fields[4] == "new" {
            source = .newSeparator
            return
        }
        guard fields.count == 7, let destination = Self.destination(named: fields[4]), let index = Int(fields[5]),
            index >= 0
        else { return nil }
        let entry: BandEntry
        if fields[6] == BandEntry.separatorToken {
            entry = .separator
        } else if let item = BandLayout.Item(rawValue: fields[6]) {
            entry = .part(item)
        } else {
            return nil
        }
        source = .entry(BandEntryLocation(destination: destination, index: index), entry)
    }

    private static func name(of destination: BandDestination) -> String {
        switch destination {
        case .zone(let zone): zone.rawValue
        case .unused: "unused"
        }
    }

    private static func destination(named name: String) -> BandDestination? {
        name == "unused" ? .unused : BandZoneID(rawValue: name).map { .zone($0) }
    }
}

/// The editor of the toolbar's arrangement in Settings. It edits a draft of both variants of the active set; nothing
/// reaches the windows until the draft is saved, and every command, including the set's own management, is one step
/// of its history.
@MainActor
@Observable
final class BandArrangementEditorSession {
    /// Recorded layout, independent of SwiftUI accessibility nodes and editor history.
    @ObservationIgnored var layoutFrames: [String: CGRect] = [:]

    /// Why leaving the draft needs an answer first.
    enum Leave: Equatable {
        case selectSet(BandArrangementSelection)
        case newSet
        case section(SettingsSection)
        case closeWindow
        /// The app was asked to quit; the answer goes back to AppKit.
        case quit
    }

    /// A dialog the editor shows.
    enum Dialog: Identifiable, Equatable {
        case duplicate, new, rename
        /// Saving a changed Standard makes a named copy.
        case saveCopy
        case delete

        var id: Self { self }
    }

    enum Message: Equatable {
        case moved(String, String, Int, Int)
        case unused(String)
        case printIsRequired
        case separatorAdded(String)
        case separatorDeleted
        case backToStandard
        case saved(String)
        case cannotSave
        /// The saved set changed elsewhere since the draft started from it.
        case conflict
        /// Undoing would erase what was saved elsewhere since.
        case historyConflict

        var text: String {
            switch self {
            case .moved(let name, let zone, let position, let count):
                String(
                    format: String(localized: "%1$@ moved to %2$@, position %3$lld of %4$lld."), name, zone, position,
                    count)
            case .unused(let name):
                String(format: String(localized: "%@ is not in use. It stays available in “…”."), name)
            case .printIsRequired: String(localized: "Print can be moved, but cannot be removed.")
            case .separatorAdded(let zone): String(format: String(localized: "Separator added to %@."), zone)
            case .separatorDeleted: String(localized: "Separator deleted.")
            case .backToStandard:
                String(localized: "Back to Standard, not saved yet. Undo brings your arrangement back.")
            case .saved(let name): String(format: String(localized: "Saved “%@”. All view windows use it now."), name)
            case .cannotSave: String(localized: "Arrangements cannot be saved right now.")
            case .conflict: String(localized: "Not saved: this arrangement was changed elsewhere.")
            case .historyConflict:
                String(localized: "This step cannot be undone: the saved arrangements were changed elsewhere.")
            }
        }

        var isWarning: Bool {
            [.printIsRequired, .cannotSave, .conflict, .historyConflict].contains(self)
        }
    }

    private struct Snapshot {
        var draft: BandArrangementVariants
        var selection: BandEditorSelection?
        var base: BandArrangementSelection
        var baseLayouts: BandArrangementVariants
        /// Only for commands that changed the saved sets: the store to put back, and the store that must still be
        /// there for that to undo only this command. Restoring a draft never writes.
        var store: BandArrangementStore?
        var expected: BandArrangementStore?
    }

    /// Identifies this editor's drags.
    let id = UUID()
    let preferences: AppPreferences
    /// The variant shown. Choosing the other one keeps both drafts and is not a step of the history.
    var mode: MenuArrangement {
        didSet {
            guard mode != oldValue else { return }
            selection = nil
            dropTarget = nil
            revision += 1
        }
    }
    private(set) var draft: BandArrangementVariants
    /// The saved set the draft edits, and its layouts as they were when the draft started from them. Saving checks
    /// both against the store, so a draft never lands on another set or over a change made elsewhere.
    private(set) var base: BandArrangementSelection
    private(set) var baseLayouts: BandArrangementVariants
    private(set) var selection: BandEditorSelection?
    private(set) var message: Message?
    /// The insertion marker while something is dragged over the miniature. Hovering is never history.
    var dropTarget: BandEditorDropTarget?
    /// The drag this editor started last, for the marker and the refusal while it hovers.
    private(set) var dragging: BandEditorPayload?
    /// Counts the draft's changes; a drag that began before one is stale.
    private(set) var revision = 0
    /// Explicit moves reveal the selected chip without scrolling during a drag.
    private(set) var selectionRevealRevision = 0
    var pendingLeave: Leave?
    var dialog: Dialog?
    /// The editor's own history. Settings' Edit menu and ⌘Z reach it while the editor shows (`SettingsUndoRouter`);
    /// the other sections keep the window's.
    let history = UndoManager()
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var historyObservers: [NSObjectProtocol] = []

    /// The app's editor, which Settings shows and which quitting asks about.
    static weak var app: BandArrangementEditorSession?
    /// Answers AppKit's question whether the app may quit; tests stand in for it.
    @ObservationIgnored var replyToTermination: @MainActor (Bool) -> Void = {
        NSApp.reply(toApplicationShouldTerminate: $0)
    }
    /// Opens Settings for the question when its window is not on screen; tests stand in for it.
    @ObservationIgnored var showSettings: @MainActor () -> Void = {
        AppKitShell.current?.showSettings(nil)
    }

    init(preferences: AppPreferences) {
        self.preferences = preferences
        mode = preferences.menuArrangement
        base = preferences.bandArrangementStore.active
        baseLayouts = preferences.bandArrangementStore.activeLayouts
        draft = preferences.bandArrangementStore.activeLayouts
        // Each command is grouped explicitly, so two commands in one event stay two steps.
        history.groupsByEvent = false
        let center = NotificationCenter.default
        historyObservers = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
            center.addObserver(forName: name, object: history, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHistory() }
            }
        }
    }

    isolated deinit {
        for observer in historyObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - State

    var store: BandArrangementStore { preferences.bandArrangementStore }
    var active: BandArrangementSelection { store.active }
    var savedLayouts: BandArrangementVariants { store.activeLayouts }
    var isDirty: Bool { draft != baseLayouts }
    /// The draft edits Standard, which is never written.
    var isStandardActive: Bool { base == .standard }
    /// The saved arrangements moved on under unsaved changes: another set is in use, or the edited set changed.
    var hasConflict: Bool { isDirty && (store.active != base || store.activeLayouts != baseLayouts) }
    /// Unreadable stored data waits for the reader's decision; nothing is written until then.
    var needsRecovery: Bool { preferences.retainedBandArrangementData != nil }
    var arrangement: BandArrangement { draft.arrangement(for: mode) }
    var zones: [BandZoneID] { mode == .split ? BandZoneID.allCases : [.topLeft, .topRight] }
    var destinations: [BandDestination] { zones.map { .zone($0) } + [.unused] }

    /// The name of the set the draft edits.
    var activeName: String { name(of: base) }

    func name(of selection: BandArrangementSelection) -> String {
        switch selection {
        case .standard: String(localized: "Standard")
        case .user(let id): store.sets.first { $0.id == id }?.name ?? String(localized: "Standard")
        }
    }

    var selectedLocation: BandEntryLocation? {
        switch selection {
        case .part(let item):
            guard let destination = arrangement.location(of: item),
                let index = arrangement[destination].firstIndex(of: .part(item))
            else { return nil }
            return BandEntryLocation(destination: destination, index: index)
        case .separator(let zone, let index):
            guard zones.contains(zone), arrangement[zone].indices.contains(index),
                arrangement[zone][index] == .separator
            else { return nil }
            return BandEntryLocation(destination: .zone(zone), index: index)
        case nil:
            return nil
        }
    }

    var selectedEntry: BandEntry? {
        selectedLocation.map { arrangement[$0.destination][$0.index] }
    }

    func select(_ selection: BandEditorSelection?) {
        self.selection = selection
    }

    func entry(at location: BandEntryLocation) -> BandEntry? {
        let entries = arrangement[location.destination]
        return entries.indices.contains(location.index) ? entries[location.index] : nil
    }

    /// A separator the app does not draw: first or last in its zone, or next to another separator.
    func separatorIsIdle(at index: Int, in zone: BandZoneID) -> Bool {
        let entries = arrangement[zone]
        guard entries.indices.contains(index), entries[index] == .separator else { return false }
        let before = entries[..<index].last
        let after = entries[(index + 1)...].first
        return before == nil || after == nil || before == .separator || after == .separator
    }

    var hasIdleSeparators: Bool {
        zones.contains { zone in arrangement[zone].indices.contains { separatorIsIdle(at: $0, in: zone) } }
    }

    func canMove(_ location: BandEntryLocation, by offset: Int) -> Bool {
        guard case .zone = location.destination else { return false }
        let target = location.index + offset
        return arrangement[location.destination].indices.contains(target)
    }

    /// Follows the saved arrangements while there is nothing unsaved; with unsaved changes the draft stays, and
    /// `hasConflict` tells.
    func refresh() {
        guard !isDirty, store.active != base || store.activeLayouts != baseLayouts else { return }
        adoptSaved()
    }

    private func adoptSaved() {
        base = store.active
        baseLayouts = store.activeLayouts
        draft = baseLayouts
        selection = nil
        revision += 1
    }

    // MARK: - Editing the draft

    /// Moves an entry so that it stands before the entry now at `index` of the destination (its count appends).
    @discardableResult
    func move(_ location: BandEntryLocation, to destination: BandDestination, at index: Int) -> Bool {
        guard let entry = entry(at: location) else { return false }
        if entry == .part(.print), destination == .unused {
            say(.printIsRequired)
            return false
        }
        let before = snapshot()
        let next: BandArrangement
        do {
            next = try arrangement.movingEntry(
                at: location.index, from: location.destination, to: destination, at: index, for: mode)
        } catch {
            if error as? BandArrangementMoveError == .printIsRequired { say(.printIsRequired) }
            return false
        }
        guard next != arrangement else { return true }
        // Where the entry ends up: after removal, an entry moved later in its own zone stands one place earlier.
        var landed = index
        if location.destination == destination, location.index < index { landed -= 1 }
        let name: String
        switch entry {
        case .part(let item):
            selection = .part(item)
            name = item.editorName
        case .separator:
            name = String(localized: "Separator")
            if case .zone(let zone) = destination { selection = .separator(zone, landed) } else { selection = nil }
        }
        apply(next)
        commit(before, action: String(localized: "Move"))
        switch destination {
        case .zone(let zone):
            say(.moved(name, zone.editorName, landed + 1, arrangement[zone].count))
        case .unused:
            say(entry == .separator ? .separatorDeleted : .unused(name))
        }
        return true
    }

    @discardableResult
    func insertSeparator(in zone: BandZoneID, at index: Int) -> Bool {
        let before = snapshot()
        guard let next = try? arrangement.insertingSeparator(at: index, in: zone, for: mode) else { return false }
        selection = .separator(zone, index)
        apply(next)
        commit(before, action: String(localized: "Add Separator"))
        say(.separatorAdded(zone.editorName))
        return true
    }

    /// The inspector's destination buttons: the end of a zone, or "Parts to Add" (a separator there is deleted).
    func moveSelection(to destination: BandDestination) {
        guard let location = selectedLocation else { return }
        if move(location, to: destination, at: arrangement[destination].count) { selectionRevealRevision += 1 }
    }

    /// Move Earlier and Move Later: one place within the zone.
    func moveSelection(by offset: Int) {
        guard let location = selectedLocation, canMove(location, by: offset) else { return }
        if move(location, to: location.destination, at: location.index + (offset > 0 ? offset + 1 : offset)) {
            selectionRevealRevision += 1
        }
    }

    /// Delete for a separator, Remove for a part: the part goes to "Parts to Add".
    func removeSelection() {
        moveSelection(to: .unused)
    }

    /// The inspector's Add Separator: right after the selected entry, or at the end of the selected part's zone.
    func insertSeparatorAfterSelection() {
        guard let location = selectedLocation, case .zone(let zone) = location.destination else { return }
        insertSeparator(in: zone, at: location.index + 1)
    }

    func backToStandard() {
        let standard = BandArrangementVariants()
        guard draft != standard else { return }
        let before = snapshot()
        selection = nil
        draft = standard
        revision += 1
        commit(before, action: String(localized: "Back to Standard"))
        say(.backToStandard)
    }

    /// Leaves the saved sets as they are and takes the saved one in use, also after a change made elsewhere. It is
    /// a step of the history, so Undo brings the draft back.
    func discardChanges() {
        guard isDirty else { return }
        let before = snapshot()
        adoptSaved()
        commit(before, action: String(localized: "Discard Changes"))
        message = nil
    }

    private func apply(_ next: BandArrangement) {
        if mode == .split { draft.split = next } else { draft.top = next }
        revision += 1
    }

    // MARK: - Drag and drop

    func beginDrag(_ source: BandEditorPayload.Source) -> BandEditorPayload {
        let payload = BandEditorPayload(session: id, revision: revision, mode: mode, source: source)
        dragging = payload
        dropTarget = nil
        return payload
    }

    /// Whether a drop of the drag in progress may land there; Print over "Parts to Add" says why it may not.
    func proposal(for target: BandEditorDropTarget) -> DropOperation {
        guard let dragging, validate(dragging) else { return .forbidden }
        switch (dragging.source, target) {
        case (.newSeparator, .zone): return .copy
        case (.newSeparator, _): return .forbidden
        case (.entry(_, .part(.print)), .unused):
            // Said once while it hovers, not at every movement of the pointer.
            if message != .printIsRequired { say(.printIsRequired) }
            return .forbidden
        case (.entry(_, .part), .outside): return .forbidden
        case (.entry(let location, _), .unused) where location.destination == .unused: return .forbidden
        default: return .move
        }
    }

    /// One drop is one step of the history. Dropping changes nothing unless the payload is this editor's current drag.
    @discardableResult
    func drop(_ payload: BandEditorPayload, on target: BandEditorDropTarget) -> Bool {
        defer {
            dropTarget = nil
            dragging = nil
        }
        guard validate(payload) else { return false }
        switch (payload.source, target) {
        case (.newSeparator, .zone(let zone, let index)):
            return insertSeparator(in: zone, at: index)
        case (.newSeparator, _):
            return false
        case (.entry(let location, _), .zone(let zone, let index)):
            return move(location, to: .zone(zone), at: index)
        case (.entry(let location, let entry), .unused):
            guard location.destination != .unused else { return false }
            if entry == .part(.print) {
                say(.printIsRequired)
                return false
            }
            return move(location, to: .unused, at: arrangement.unused.count)
        case (.entry(let location, .separator), .outside):
            // A separator dragged off the toolbar is taken away, as onto "Parts to Add".
            return move(location, to: .unused, at: arrangement.unused.count)
        case (.entry, .outside):
            return false
        }
    }

    func validate(_ payload: BandEditorPayload) -> Bool {
        guard payload.session == id, payload.revision == revision, payload.mode == mode else { return false }
        if case .entry(let location, let entry) = payload.source {
            guard location.destination == .unused || zones.contains(where: { .zone($0) == location.destination }),
                self.entry(at: location) == entry
            else { return false }
        }
        return true
    }

    // MARK: - Saved sets

    var canOverwrite: Bool { !isStandardActive && isDirty && !needsRecovery && !hasConflict }

    /// Selecting a saved set uses it in every view window; the draft becomes that set.
    func selectSet(_ selection: BandArrangementSelection) {
        guard selection != active else { return }
        storeCommand(String(localized: "Choose Arrangement")) { store in try store.select(selection) }
    }

    /// Nil while the set the draft edits is still the saved one in use, as it was; otherwise says why not and writes
    /// nothing.
    private func conflictProblem() -> String? {
        guard store.active == base, store.activeLayouts == baseLayouts else {
            say(.conflict)
            return Message.conflict.text
        }
        return nil
    }

    /// The draft, edits included, under a new name; the copy becomes the set in use.
    @discardableResult
    func duplicate(named name: String) -> String? {
        let set = BandArrangementSet(name: name, layouts: draft)
        return storeCommand(String(localized: "Duplicate Arrangement")) { try $0.insert(set) }
    }

    @discardableResult
    func overwrite() -> String? {
        guard !isStandardActive, isDirty, !needsRecovery else { return nil }
        if let problem = conflictProblem() { return problem }
        let layouts = draft
        let base = base
        let result = storeCommand(String(localized: "Overwrite Arrangement")) {
            try $0.overwrite(base, layouts: layouts)
        }
        if result == nil { say(.saved(activeName)) }
        return result
    }

    /// A new set starts from Standard's two variants.
    @discardableResult
    func createSet(named name: String) -> String? {
        let set = BandArrangementSet(name: name)
        return storeCommand(String(localized: "New Arrangement")) { try $0.insert(set) }
    }

    @discardableResult
    func rename(to name: String) -> String? {
        if let problem = conflictProblem() { return problem }
        let base = base
        return storeCommand(String(localized: "Rename Arrangement"), keepsDraft: true) {
            try $0.rename(base, to: name)
        }
    }

    /// Deletes the set in use; the windows move to `replacement` at the same time.
    @discardableResult
    func deleteActive(replacement: BandArrangementSelection) -> String? {
        if let problem = conflictProblem() { return problem }
        let base = base
        return storeCommand(String(localized: "Delete Arrangement")) {
            try $0.delete(base, replacement: replacement)
        }
    }

    /// Save from the unsaved-changes question: the set in use takes the draft. A changed Standard, or a draft whose
    /// set changed elsewhere, is saved as a named copy instead, so nothing saved is written over.
    func saveForLeaving() -> Bool {
        if isStandardActive || hasConflict {
            dialog = .saveCopy
            return false
        }
        return overwrite() == nil
    }

    /// The Settings window's guard, which closes the window once the reader has answered.
    @ObservationIgnored weak var settingsController: SettingsWindowController?
    /// Routes the Settings window's Undo and Redo here while the editor shows.
    @ObservationIgnored weak var undoRouter: SettingsUndoRouter?

    /// The editor came into view: follow the saved arrangements, and make sure the window still routes Undo here and
    /// still asks before closing.
    func didAppear() {
        refresh()
        undoRouter?.insertIntoChain()
    }

    /// Every change of the Settings section goes here: leaving the editor with unsaved changes asks first.
    func showSection(_ section: SettingsSection) {
        guard section != preferences.settingsSection else { return }
        if preferences.settingsSection == .toolbarArrangement {
            request(.section(section))
        } else {
            preferences.settingsSection = section
        }
    }

    /// For places outside Settings, such as a document's menu, that know only the preferences.
    static func showSection(
        _ section: SettingsSection, preferences: AppPreferences, editor: BandArrangementEditorSession? = app
    ) {
        preferences.settingsNavigationRevision += 1
        if let editor, editor.preferences === preferences {
            editor.showSection(section)
        } else {
            preferences.settingsSection = section
        }
    }

    enum RelaunchAnswer { case save, discard, cancel }

    /// Before the app relaunches itself (for another language): true when it may go ahead. A relaunch starts the new
    /// instance before this one quits, so the draft is settled first; asking at quit time would come too late.
    /// Standard, or a set changed elsewhere, is saved as a copy under the proposed name.
    func resolveBeforeRelaunch(ask: () -> RelaunchAnswer) -> Bool {
        refresh()
        guard isDirty, !needsRecovery else { return true }
        switch ask() {
        case .cancel: return false
        case .discard:
            discardChanges()
            return true
        case .save:
            if isStandardActive || hasConflict { return duplicate(named: proposedCopyName()) == nil }
            return overwrite() == nil
        }
    }

    /// Leaves the draft at once when it has no unsaved changes; otherwise asks first (Save, Discard, Cancel).
    func request(_ leave: Leave) {
        refresh()
        guard isDirty else {
            if leave == .newSet {
                dialog = .new
            } else {
                pendingLeave = leave
                proceed()
            }
            return
        }
        pendingLeave = leave
    }

    /// Carries out what waited for the unsaved changes to be saved or discarded.
    func proceed() {
        guard let leave = pendingLeave else { return }
        pendingLeave = nil
        switch leave {
        case .selectSet(let selection): selectSet(selection)
        case .newSet:
            // After the question has gone: one sheet at a time.
            Task { @MainActor in self.dialog = .new }
        case .section(let section): preferences.settingsSection = section
        case .closeWindow: settingsController?.window?.close()
        case .quit: replyToTermination(true)
        }
    }

    /// Cancel in the question or in naming the copy: nothing happens, and a quit that waited is called off.
    func cancelLeave() {
        if pendingLeave == .quit { replyToTermination(false) }
        pendingLeave = nil
    }

    /// The app's delegate asks before quitting. Unsaved changes hold the quit until the reader answers in the editor.
    func shouldTerminate() -> NSApplication.TerminateReply {
        refresh()
        guard isDirty, !needsRecovery else { return .terminateNow }
        dialog = nil
        preferences.settingsSection = .toolbarArrangement
        pendingLeave = .quit
        if let window = settingsController?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The question is asked in Settings.
            showSettings()
        }
        return .terminateLater
    }

    /// The sets a deletion can fall back to: Standard and every other saved set.
    var replacements: [BandArrangementSelection] {
        [.standard] + store.sets.map { .user($0.id) }.filter { $0 != base }
    }

    func proposedCopyName() -> String {
        uniqueName(String(format: String(localized: "%@ Copy"), activeName))
    }

    func proposedNewName() -> String { uniqueName(String(localized: "New Arrangement")) }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(store.sets.map { BandArrangementStore.normalizedName($0.name) })
        var name = base
        var number = 2
        while taken.contains(BandArrangementStore.normalizedName(name)) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// Nil when the name can be used for the set being named (`excluding` for a rename).
    func nameProblem(_ name: String, excluding: BandArrangementSelection? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "Enter a name.") }
        let normalized = BandArrangementStore.normalizedName(trimmed)
        let clash = store.sets.contains { set in
            excluding != .user(set.id) && BandArrangementStore.normalizedName(set.name) == normalized
        }
        return clash ? String(localized: "An arrangement with this name already exists.") : nil
    }

    /// Writes the change and makes it one step of the history; the draft follows the new set in use unless the
    /// command only renames. Returns what went wrong, in words, or nil.
    @discardableResult
    private func storeCommand(
        _ action: String, keepsDraft: Bool = false, _ change: (inout BandArrangementStore) throws -> Void
    ) -> String? {
        refresh()
        var before = snapshot()
        before.store = store
        do {
            try preferences.updateBandArrangements(change)
        } catch BandArrangementStoreError.emptyName {
            return String(localized: "Enter a name.")
        } catch BandArrangementStoreError.duplicateName {
            return String(localized: "An arrangement with this name already exists.")
        } catch {
            say(.cannotSave)
            return Message.cannotSave.text
        }
        before.expected = store
        if !keepsDraft { adoptSaved() }
        commit(before, action: action)
        return nil
    }

    // MARK: - Recovery

    /// Keeps the unreadable data aside and starts again from Standard. Not undoable: the data stays retained.
    func startOver() {
        preferences.startBandArrangementsOver()
        adoptSaved()
        history.removeAllActions()
        refreshHistory()
    }

    // MARK: - History

    func undo() {
        guard history.canUndo else { return }
        history.undo()
        refreshHistory()
    }

    func redo() {
        guard history.canRedo else { return }
        history.redo()
        refreshHistory()
    }

    private func snapshot() -> Snapshot {
        Snapshot(draft: draft, selection: selection, base: base, baseLayouts: baseLayouts)
    }

    private func commit(_ before: Snapshot, action: String) {
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(before, action: action) }
        }
        history.setActionName(action)
        history.endUndoGrouping()
        refreshHistory()
    }

    private func restore(_ snapshot: Snapshot, action: String) {
        var current = self.snapshot()
        if let saved = snapshot.store, let expected = snapshot.expected {
            // Putting the whole store back would also take back whatever was saved elsewhere since this command.
            guard store == expected else {
                say(.historyConflict)
                // Later steps assume this one; the history cannot be kept consistent and is cleared once the undo
                // manager has finished this call.
                Task { @MainActor in
                    self.history.removeAllActions()
                    self.refreshHistory()
                }
                return
            }
            do {
                try preferences.updateBandArrangements { $0 = saved }
            } catch {
                say(.cannotSave)
                return
            }
            current.store = expected
            current.expected = saved
        }
        draft = snapshot.draft
        selection = snapshot.selection
        base = snapshot.base
        baseLayouts = snapshot.baseLayouts
        dropTarget = nil
        revision += 1
        message = nil
        // Registered while undoing, this is the redo step (and the other way round).
        history.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(current, action: action) }
        }
        history.setActionName(action)
    }

    private func refreshHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    private func say(_ message: Message) {
        self.message = message
        AccessibilityNotification.Announcement(message.text).post()
    }

    #if DEBUG
        /// Development snapshots: a hovering drag's marker without a drag, of the selected entry if there is one.
        func showDropMarker(_ target: BandEditorDropTarget) {
            let source = selectedLocation.flatMap { location in
                entry(at: location).map { BandEditorPayload.Source.entry(location, $0) }
            }
            dragging = BandEditorPayload(session: id, revision: revision, mode: mode, source: source ?? .newSeparator)
            dropTarget = target
        }

        /// Development snapshots: the saved set as if it had changed elsewhere since the draft started.
        func simulateChangeElsewhere() {
            baseLayouts.split.topLeft.append(.separator)
        }
    #endif
}
