import AppKit
import Observation
import SurimonoCore

@MainActor
@Observable
final class ShortcutController {
    enum EditError: Error {
        case localEditingUnavailable
        case localConflict([ShortcutConflict])
        case externalMenuAssignment
        case savedDataUnavailable
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
    private(set) var externalMenuKeys: [ShortcutOperationID: ShortcutCombination] = [:]
    @ObservationIgnored var synchronizeMenus: () -> Void = {}
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
        layout = keyboardLayout()
        environment = .init(
            reservations: (reserved ?? []) + externalMenuKeys.values.map { .init(combination: $0) },
            projection: layout.projection,
            reservationsAvailable: reserved != nil, projectionAvailable: layout.available)
    }

    func refresh() {
        guard let preferences else { return }
        defer { synchronizeMenus() }
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
            where validator.issues(for: action.operation, combination: key).isEmpty
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
        synchronizeMenus()
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
        let conflicts = validator.conflicts(
            for: operation, keys: keys ?? ShortcutDefaults.keys(for: operation), in: snapshot)
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
        ShortcutOperation.operation(operation).isGlobal || ShortcutMenuBridge.operations.contains(operation)
    }

    func setExternalMenuKeys(_ keys: [ShortcutOperationID: ShortcutCombination]) {
        guard externalMenuKeys != keys else { return }
        externalMenuKeys = keys
        refreshEnvironment()
        hotKeys.synchronize(registrations(for: snapshot))
    }

    func localKeys(for operation: ShortcutOperationID) -> [ShortcutCombination] {
        if let key = externalMenuKeys[operation] { return [key] }
        let keys = snapshot.keys(for: operation)
        return keys.filter { key in
            guard !externalMenuKeys.values.contains(where: { environment.matches($0, key) }) else { return false }
            // Built-in equivalents must remain available even when OS reservation discovery fails.
            guard snapshot.overrides[operation] != nil else { return true }
            let validator = ShortcutValidator(environment: environment)
            return validator.issues(for: operation, combination: key).isEmpty
                && validator.conflicts(for: operation, keys: [key], in: snapshot).isEmpty
        }
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
