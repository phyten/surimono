import AppKit
import Observation
import SurimonoCore

@MainActor
@Observable
final class ShortcutController {
    enum EditError: Error {
        case localEditingUnavailable
        case localConflict([ShortcutConflict])
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
            reservations: reserved ?? [], projection: layout.projection,
            reservationsAvailable: reserved != nil, projectionAvailable: layout.available)
    }

    func refresh() {
        guard let preferences else { return }
        refreshEnvironment()
        preferences.reloadKeyboardShortcuts(environment: environment)
        loadError = preferences.keyboardShortcutsLoadState.isUnreadable
        guard !loadError else {
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
    }

    func proposal(
        _ operation: ShortcutOperationID, keys: [ShortcutCombination]?, takeConflicts: Bool = false
    ) throws -> ShortcutChangePlan {
        guard ShortcutOperation.operation(operation).isGlobal else { throw EditError.localEditingUnavailable }
        guard preferences != nil, !loadError else { throw EditError.savedDataUnavailable }
        // A dialog may have been open while macOS reservations or the input source changed.
        refreshEnvironment()
        let validator = ShortcutValidator(environment: environment)
        let conflicts = validator.conflicts(
            for: operation, keys: keys ?? ShortcutDefaults.keys(for: operation), in: snapshot)
        // Local handlers still use defaults in step 3, so taking a local key would create two active owners.
        if conflicts.contains(where: { $0.owners.contains { !ShortcutOperation.operation($0.operation).isGlobal } }) {
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

    func status(for operation: ShortcutOperationID) -> String {
        if loadError { return Self.message(EditError.savedDataUnavailable) }
        if let record = snapshot.inactiveMigration.first(where: { $0.operation == operation }) {
            return record.reasons.map { ShortcutText.reason($0) }.joined(separator: "\n")
        }
        if let issue = unavailableBindings.first(where: { $0.operation == operation }) {
            return ShortcutText.reason(issue.code)
        }
        guard !snapshot.keys(for: operation).isEmpty else { return String(localized: "Unassigned") }
        if !ShortcutValidator(environment: environment).conflicts(
            for: operation, keys: snapshot.keys(for: operation), in: snapshot
        ).isEmpty {
            return ShortcutText.reason(.conflict)
        }
        guard let action = GlobalHotKeys.Action.allCases.first(where: { $0.operation == operation }),
            hotKeys.isRegistered(action), !hotKeys.failed.contains(action)
        else { return String(localized: "Could not register this shortcut. Try another combination.") }
        return String(localized: "Registered")
    }

    static func message(_ error: any Error) -> String {
        if case ShortcutModelError.validation(let issues) = error, let issue = issues.first {
            return ShortcutText.reason(issue.code)
        }
        if case EditError.localConflict(let conflicts) = error {
            let names = Set(conflicts.flatMap { $0.owners.map { ShortcutText.name($0.operation) } }).sorted()
            return String.localizedStringWithFormat(
                String(localized: "Already used by %@. Local shortcuts cannot be changed yet."),
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
