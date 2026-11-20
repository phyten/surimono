import AppKit
import Observation
import SurimonoCore

@MainActor
@Observable
final class ShortcutController {
    enum EditError: Error, Equatable {
        case localEditingUnavailable
        case localConflict([ShortcutConflict])
        case externalMenuAssignment
        case savedDataUnavailable
        case acknowledgementRequired
    }

    static let shared = ShortcutController(hotKeys: .shared)
    let hotKeys: GlobalHotKeys
    private(set) var snapshot = ShortcutConfiguration()
    private(set) var environment = ShortcutValidationContext.unavailable
    private(set) var layout = ShortcutKeyboardLayout(projection: [], names: [:], available: false)
    private(set) var unavailableBindings: [ShortcutValidationIssue] = []
    private(set) var loadError = false
    private(set) var migrationError: String?
    var menuAmbiguities: Set<ShortcutOperationID> = []
    private(set) var standardMenuKeys: [ShortcutOperationID: ShortcutCombination] = [:]
    private(set) var externalMenuKeys: [ShortcutOperationID: ShortcutCombination] = [:]
    private var localizedDefaults: [ShortcutOperationID: ShortcutCombination] = [:]
    private var preferences: AppPreferences?
    private let reservations: () -> [ShortcutSystemReservation]?
    private let keyboardLayout: () -> ShortcutKeyboardLayout

    init(
        hotKeys: GlobalHotKeys,
        reservations: @escaping () -> [ShortcutSystemReservation]? = { SystemShortcutReservations.read() },
        keyboardLayout: @escaping () -> ShortcutKeyboardLayout = { .current() }
    ) {
        self.hotKeys = hotKeys
        self.reservations = reservations
        self.keyboardLayout = keyboardLayout
    }

    func start(preferences: AppPreferences) {
        self.preferences = preferences
        refresh()
    }

    func refreshEnvironment() {
        let reserved = reservations()
        let currentLayout = keyboardLayout()
        if layout.projection != currentLayout.projection { localizedDefaults = [:] }
        layout = currentLayout
        environment = .init(
            reservations: (reserved ?? []) + externalMenuKeys.values.map { .init(combination: $0) },
            projection: layout.projection,
            reservationsAvailable: reserved != nil, projectionAvailable: layout.available)
    }

    func refresh() {
        guard let preferences else { return }
        refreshEnvironment()
        preferences.reloadKeyboardShortcuts(environment: environment)
        loadError = preferences.keyboardShortcutsLoadState.isUnreadable
        guard !loadError else {
            snapshot = ShortcutConfiguration()
            hotKeys.synchronize([:])
            return
        }
        let candidate = preferences.keyboardShortcuts
        let validator = ShortcutValidator(environment: environment)
        unavailableBindings = validator.issues(in: candidate)
        if preferences.keyboardShortcutsLoadState == .migrationRequired {
            do {
                guard environment.reservationsAvailable, environment.projectionAvailable else {
                    throw ShortcutPreferencesError.environmentUnavailable
                }
                try hotKeys.apply(registrations(for: candidate)) {
                    try preferences.saveKeyboardShortcutMigration(
                        environment: environment, expectedConfiguration: candidate)
                }
                snapshot = candidate
                migrationError = nil
            } catch {
                // The evaluated legacy values are visible, but no new store is published on registration failure.
                snapshot = candidate
                migrationError = Self.message(error)
            }
        } else {
            snapshot = candidate
            migrationError = nil
            hotKeys.synchronize(registrations(for: candidate))
        }
    }

    private func registrations(for configuration: ShortcutConfiguration) -> [KeyCombo: GlobalHotKeys.Action] {
        let validator = ShortcutValidator(environment: environment)
        var result: [KeyCombo: GlobalHotKeys.Action] = [:]
        for action in GlobalHotKeys.Action.allCases {
            for key in configuration.keys(for: action.operation)
            where !reservedByStandardMenu(key, for: action.operation)
                && validator.issues(for: action.operation, combination: key).isEmpty
                && validator.conflicts(for: action.operation, keys: [key], in: configuration).isEmpty
            {
                if let combo = KeyCombo(key) { result[combo] = action }
            }
        }
        return result
    }

    func edit(
        _ operation: ShortcutOperationID, keys: [ShortcutCombination]?, takeConflicts: Bool = false,
        expectedSnapshot: ShortcutConfiguration? = nil
    ) throws {
        guard let preferences else { throw EditError.savedDataUnavailable }
        if let expectedSnapshot, snapshot != expectedSnapshot { throw ShortcutPreferencesError.staleSnapshot }
        let plan = try proposal(operation, keys: keys, takeConflicts: takeConflicts)
        let revision = preferences.keyboardShortcutsRevision
        try hotKeys.apply(registrations(for: plan.configuration)) {
            try preferences.saveKeyboardShortcuts(plan, expectedRevision: revision)
        }
        snapshot = plan.configuration
        unavailableBindings = plan.unavailableBindings
        migrationError = nil
    }

    func proposal(
        _ operation: ShortcutOperationID, keys: [ShortcutCombination]?, takeConflicts: Bool = false
    ) throws -> ShortcutChangePlan {
        guard isConnected(operation) else { throw EditError.localEditingUnavailable }
        guard externalMenuKeys[operation] == nil else { throw EditError.externalMenuAssignment }
        guard !menuAmbiguities.contains(operation) else { throw EditError.localEditingUnavailable }
        guard preferences != nil, !loadError else { throw EditError.savedDataUnavailable }
        // A dialog may have been open while macOS reservations or the input source changed.
        refreshEnvironment()
        let validator = ShortcutValidator(environment: environment)
        let proposed = keys ?? ShortcutDefaults.keys(for: operation)
        if let reserved = proposed.first(where: { reservedByStandardMenu($0, for: operation) }) {
            throw ShortcutModelError.validation([
                .init(code: .systemReserved, operation: operation, combination: reserved)
            ])
        }
        let conflicts = validator.conflicts(for: operation, keys: proposed, in: snapshot)
        // Unconnected handlers still own their defaults and cannot surrender them.
        if conflicts.contains(where: { $0.owners.contains { !isConnected($0.operation) } }) {
            throw EditError.localConflict(conflicts)
        }
        let resolution: ShortcutConflictResolution = takeConflicts ? .takeConflicts : .reject
        let plan: ShortcutChangePlan
        if let keys {
            plan = try validator.plan(replacing: operation, with: keys, in: snapshot, resolution: resolution)
        } else {
            plan = try validator.restore(operation, in: snapshot, resolution: resolution)
        }
        return plan
    }

    func importReview(_ data: Data) throws -> ShortcutImportReview {
        guard !loadError else { throw EditError.savedDataUnavailable }
        refreshEnvironment()
        return ShortcutImportReview(archive: try ShortcutArchive.decode(data), original: snapshot)
    }

    func importBlockedOperations(_ review: ShortcutImportReview) -> [ShortcutOperationID] {
        review.changed.filter { operation in
            externalMenuKeys[operation] != nil || menuAmbiguities.contains(operation) || !isConnected(operation)
                || (operation == .appCheckUpdates && !AppUpdater.shared.isAvailable)
                || review.configuration.keys(for: operation).contains { reservedByStandardMenu($0, for: operation) }
        }
    }

    func applyImport(_ review: ShortcutImportReview, acknowledged: Bool) throws {
        guard review.original == snapshot else { throw ShortcutPreferencesError.staleSnapshot }
        refreshEnvironment()
        guard importBlockedOperations(review).isEmpty else { throw EditError.externalMenuAssignment }
        let plan = try review.plan(using: ShortcutValidator(environment: environment))
        guard acknowledged || (!plan.requiresPrintingAcknowledgement && !plan.requiresGlobalAcknowledgement) else {
            throw EditError.acknowledgementRequired
        }
        try apply(plan)
    }

    var canRestoreAll: Bool { !snapshot.overrides.isEmpty || !snapshot.inactiveMigration.isEmpty }

    func restoreAll(expectedSnapshot: ShortcutConfiguration) throws {
        guard expectedSnapshot == snapshot else { throw ShortcutPreferencesError.staleSnapshot }
        refreshEnvironment()
        try apply(ShortcutValidator(environment: environment).restoreAll(in: snapshot))
    }

    private func apply(_ plan: ShortcutChangePlan) throws {
        guard let preferences, !loadError else { throw EditError.savedDataUnavailable }
        let revision = preferences.keyboardShortcutsRevision
        try hotKeys.apply(registrations(for: plan.configuration)) {
            try preferences.saveKeyboardShortcuts(plan, expectedRevision: revision)
        }
        snapshot = plan.configuration
        unavailableBindings = plan.unavailableBindings
        migrationError = nil
    }

    func logicalKey(_ physical: ShortcutCombination) throws -> ShortcutCombination {
        guard
            let logical = layout.projection.last(where: {
                $0.physical
                    == ShortcutCombination(key: physical.key, modifiers: physical.modifiers.subtracting(.option))
            })?.logical
        else {
            throw ShortcutModelError.invalidKey
        }
        return try ShortcutCombination(key: logical.key, modifiers: physical.modifiers).normalized()
    }

    func isConnected(_ operation: ShortcutOperationID) -> Bool {
        ShortcutOperation.operation(operation).isGlobal || ShortcutDispatcher.operations.contains(operation)
            || ShortcutSurfaceKeys.operations.contains(operation)
    }

    private func reservedByStandardMenu(_ key: ShortcutCombination, for operation: ShortcutOperationID) -> Bool {
        standardMenuKeys.contains { $0.key != operation && environment.matches($0.value, key) }
    }

    func setExternalMenuKeys(
        _ keys: [ShortcutOperationID: ShortcutCombination], standard: [ShortcutOperationID: ShortcutCombination] = [:]
    ) {
        guard externalMenuKeys != keys || standardMenuKeys != standard else { return }
        standardMenuKeys = standard
        externalMenuKeys = keys
        refreshEnvironment()
        hotKeys.synchronize(registrations(for: snapshot))
    }

    func observeLocalizedDefaults(_ keys: [ShortcutOperationID: ShortcutCombination]) {
        // Keep a translation while its row is absent or temporarily has no equivalent because of a conflict.
        for (operation, key) in keys {
            let translation = key == ShortcutDefaults.keys(for: operation).first ? nil : key
            if localizedDefaults[operation] != translation { localizedDefaults[operation] = translation }
        }
    }

    private func translatedDefault(_ key: ShortcutCombination, for operation: ShortcutOperationID)
        -> ShortcutCombination
    {
        if let actual = localizedDefaults[operation] { return actual }
        // AppKit mirrors these equivalents in an RTL main menu. A conditional row may not exist to read yet.
        guard NSApp?.userInterfaceLayoutDirection == .rightToLeft else { return key }
        let pairs: [ShortcutKey: ShortcutKey] = [
            .character("["): .character("]"), .character("{"): .character("}"),
            .character("("): .character(")"), .character("<"): .character(">"), .named(.leftArrow): .named(.rightArrow),
        ]
        let mirrored = pairs[key.key] ?? pairs.first { $0.value == key.key }?.key
        return mirrored.map { ShortcutCombination(key: $0, modifiers: key.modifiers) } ?? key
    }

    func automaticMenuKey(for operation: ShortcutOperationID, effective: ShortcutCombination?) -> ShortcutCombination? {
        guard snapshot.overrides[operation] == nil, externalMenuKeys[operation] == nil,
            standardMenuKeys[operation] == nil,
            let base = ShortcutDefaults.keys(for: operation).first,
            !base.modifiers.intersection([.command, .control]).isEmpty,
            translatedDefault(base, for: operation) == effective
        else { return nil }
        // SwiftUI localizes the base key. Feeding it the already translated key would mirror it twice.
        return base
    }

    func localKeys(for operation: ShortcutOperationID, textInput: Bool = false) -> [ShortcutCombination] {
        let keys = resolvedKeys(for: operation)
        // A menu equivalent with only Control can swallow an editor command before the text view sees it.
        return textInput ? keys.filter { $0.modifiers.contains(.command) } : keys
    }

    private func resolvedKeys(for operation: ShortcutOperationID) -> [ShortcutCombination] {
        guard !menuAmbiguities.contains(operation) else { return [] }
        if let key = externalMenuKeys[operation] {
            if reservedByStandardMenu(key, for: operation) { return [] }
            let conflict = externalMenuKeys.contains { owner, other in
                owner != operation && environment.matches(key, other)
                    && ShortcutOperation.operation(owner).binding(for: other).overlaps(
                        ShortcutOperation.operation(operation).binding(for: key))
            }
            return conflict ? [] : [key]
        }
        var keys = snapshot.keys(for: operation)
        if snapshot.overrides[operation] == nil, let first = keys.first,
            !first.modifiers.intersection([.command, .control]).isEmpty
        {
            keys[0] = translatedDefault(first, for: operation)
        }
        let aliases = keys.filter { key in
            guard !reservedByStandardMenu(key, for: operation),
                !externalMenuKeys.values.contains(where: { environment.matches($0, key) })
            else { return false }
            // Built-in equivalents must remain available even when OS reservation discovery fails.
            guard snapshot.overrides[operation] != nil else {
                // A translated default can collide with an explicit binding that was valid in the previous layout.
                guard localizedDefaults[operation] == key else { return true }
                return !snapshot.overrides.keys.contains { owner in
                    resolvedKeys(for: owner).contains { other in
                        environment.matches(other, key)
                            && ShortcutOperation.operation(owner).binding(for: other).overlaps(
                                ShortcutOperation.operation(operation).binding(for: key))
                    }
                }
            }
            let validator = ShortcutValidator(environment: environment)
            return validator.issues(for: operation, combination: key).isEmpty
                && validator.conflicts(for: operation, keys: [key], in: snapshot).isEmpty
        }
        // Open and Settings are native commands. Their displayed equivalents still work after an in-app rebind.
        if let native = standardMenuKeys[operation] {
            return [native] + aliases.filter { $0 != native }
        }
        return aliases
    }

    func settingsKeys(for operation: ShortcutOperationID) -> [ShortcutCombination] {
        if standardMenuKeys[operation] != nil { return localKeys(for: operation) }
        // Keep a rejected stored binding visible in Settings alongside its explanation.
        return externalMenuKeys[operation].map { [$0] } ?? snapshot.keys(for: operation)
    }

    func status(for operation: ShortcutOperationID) -> String {
        if menuAmbiguities.contains(operation) {
            return String(localized: "This menu command could not be identified uniquely.")
        }
        if externalMenuKeys[operation] != nil { return String(localized: "Managed in macOS") }
        if loadError { return Self.message(EditError.savedDataUnavailable) }
        if let record = snapshot.inactiveMigration.first(where: { $0.operation == operation }) {
            return record.reasons.map { ShortcutText.reason($0) }.joined(separator: "\n")
        }
        if let issue = unavailableBindings.first(where: { $0.operation == operation }) {
            return ShortcutText.reason(issue.code)
        }
        if snapshot.keys(for: operation).contains(where: { reservedByStandardMenu($0, for: operation) }) {
            return ShortcutText.reason(.systemReserved)
        }
        if standardMenuKeys[operation] != nil && snapshot.keys(for: operation).isEmpty {
            return String(localized: "Managed in macOS")
        }
        guard !snapshot.keys(for: operation).isEmpty else { return String(localized: "Unassigned") }
        let validator = ShortcutValidator(environment: environment)
        if let issue = snapshot.keys(for: operation).flatMap({ validator.issues(for: operation, combination: $0) })
            .first
        {
            return ShortcutText.reason(issue.code)
        }
        if !validator.conflicts(
            for: operation, keys: snapshot.keys(for: operation), in: snapshot
        ).isEmpty {
            return ShortcutText.reason(.conflict)
        }
        if !ShortcutOperation.operation(operation).isGlobal { return "" }
        guard let action = GlobalHotKeys.Action.allCases.first(where: { $0.operation == operation }),
            hotKeys.isRegistered(action), !hotKeys.failed.contains(action)
        else { return String(localized: "Could not register this shortcut. Try another combination.") }
        return String(localized: "Registered")
    }

    static func message(_ error: any Error) -> String {
        if case ShortcutModelError.validation(let issues) = error, let issue = issues.first {
            return ShortcutText.reason(issue.code)
        }
        if case EditError.acknowledgementRequired = error {
            return String(localized: "Acknowledge the global and printing shortcut changes before applying.")
        }
        if case EditError.externalMenuAssignment = error { return String(localized: "Managed in macOS") }
        if case EditError.localConflict(let conflicts) = error {
            let names = Set(conflicts.flatMap { $0.owners.map { ShortcutText.name($0.operation) } }).sorted()
            return String.localizedStringWithFormat(
                String(localized: "Already used by %@. This operation is not connected to customizable shortcuts yet."),
                names.joined(separator: ", "))
        }
        if let error = error as? ShortcutModelError, error == .invalidKey || error == .invalidModifiers {
            return ShortcutText.reason(.invalidKey)
        }
        if error is GlobalHotKeys.RegistrationError {
            return String(localized: "Could not register this shortcut. Try another combination.")
        }
        if case ShortcutPreferencesError.environmentUnavailable = error {
            return String(localized: "System shortcuts or the keyboard layout could not be read. Try again.")
        }
        return String(
            localized:
                "Shortcut settings could not be saved. Reopen this page and try again; existing data is preserved.")
    }
}
