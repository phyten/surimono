public struct ShortcutValidationIssue: Equatable, Sendable {
    public enum Code: String, Codable, CaseIterable, Sendable {
        case invalidKey, invalidModifiers, wrongKeyKind, modifierRequired, globalModifierRequired
        case spotlight, inputSource, applicationSwitching, forceQuit, keyboardNavigation, accessibility
        case screenCapture, sessionControl, workspaceNavigation, cancellation, confirmation, focusNavigation
        case fixedOperation, documentSaving, voiceOver, systemReserved, systemReservationsUnavailable
        case layoutProjectionUnavailable, conflict, malformedLegacy
    }
    public let code: Code
    public let operation: ShortcutOperationID
    public let combination: ShortcutCombination
    public let fixedBehavior: ShortcutFixedKey.Behavior?

    public init(
        code: Code, operation: ShortcutOperationID, combination: ShortcutCombination,
        fixedBehavior: ShortcutFixedKey.Behavior? = nil
    ) {
        self.code = code
        self.operation = operation
        self.combination = combination
        self.fixedBehavior = fixedBehavior
    }
}

// Include both the produced symbol and the base-key spelling for shifted punctuation. This lets the same
// physical screenshot key be protected even when the recorded logical key is "#" rather than Shift-3.
public struct ShortcutProjection: Equatable, Sendable {
    public let logical: ShortcutCombination
    public let physical: ShortcutCombination

    public init(logical: ShortcutCombination, physical: ShortcutCombination) {
        self.logical = logical
        self.physical = physical
    }
}

public struct ShortcutSystemReservation: Equatable, Sendable {
    public let combination: ShortcutCombination
    public let isEnabled: Bool
    public init(combination: ShortcutCombination, isEnabled: Bool = true) {
        self.combination = combination
        self.isEnabled = isEnabled
    }
}

public struct ShortcutValidationContext: Equatable, Sendable {
    public let reservations: [ShortcutSystemReservation]
    public let projection: [ShortcutProjection]
    public let reservationsAvailable: Bool
    public let projectionAvailable: Bool
    private let physicalByLogical: [ShortcutCombination: Set<ShortcutCombination>]
    private let logicalByPhysical: [ShortcutCombination: [IndexedLogical]]
    private let reservedLogical: Set<ShortcutCombination>
    private let reservedPhysical: Set<ShortcutCombination>

    private struct IndexedLogical: Equatable, Sendable {
        let index: Int
        let combination: ShortcutCombination
    }

    public init(
        reservations: [ShortcutSystemReservation] = [], projection: [ShortcutProjection] = [],
        reservationsAvailable: Bool = true, projectionAvailable: Bool = true
    ) {
        self.reservations = reservations
        self.projection = projection
        self.reservationsAvailable = reservationsAvailable
        self.projectionAvailable = projectionAvailable
        var physicalByLogical: [ShortcutCombination: Set<ShortcutCombination>] = [:]
        var logicalByPhysical: [ShortcutCombination: [IndexedLogical]] = [:]
        for (index, item) in projection.enumerated() {
            guard let logical = try? item.logical.normalized() else { continue }
            physicalByLogical[logical, default: []].insert(item.physical)
            logicalByPhysical[item.physical, default: []].append(.init(index: index, combination: logical))
        }
        self.physicalByLogical = physicalByLogical
        self.logicalByPhysical = logicalByPhysical
        var reservedLogical: Set<ShortcutCombination> = []
        var reservedPhysical: Set<ShortcutCombination> = []
        for reservation in reservations where reservation.isEnabled {
            let key = (try? reservation.combination.normalized()) ?? reservation.combination
            // Bare and Option arrows belong to system UI, not an application's global reservations.
            let arrow: Bool
            switch key.key {
            case .macVirtualKey(let code): arrow = (123...126).contains(code)
            case .named(let named): arrow = named.isArrow
            default: arrow = false
            }
            if arrow && key.modifiers.intersection([.command, .control]).isEmpty { continue }
            reservedLogical.insert(key)
            if case .macVirtualKey = key.key {
                reservedPhysical.insert(key)
            } else {
                reservedPhysical.formUnion(physicalByLogical[key] ?? [])
            }
        }
        self.reservedLogical = reservedLogical
        self.reservedPhysical = reservedPhysical
    }

    public static let unavailable = Self(reservationsAvailable: false, projectionAvailable: false)

    public func physicalSignatures(for combination: ShortcutCombination) -> Set<ShortcutCombination> {
        if case .macVirtualKey = combination.key { return [combination] }
        return physicalByLogical[combination] ?? []
    }

    func logicalSpellings(for signatures: Set<ShortcutCombination>) -> [ShortcutCombination] {
        // Preserve projection order so shared physical keys still report the same first refusal.
        signatures.flatMap { logicalByPhysical[$0] ?? [] }.sorted { $0.index < $1.index }.map(\.combination)
    }

    func isReserved(_ normalized: ShortcutCombination) -> Bool {
        reservedLogical.contains(normalized)
            || !reservedPhysical.isDisjoint(with: physicalSignatures(for: normalized))
    }

    public func matches(_ left: ShortcutCombination, _ right: ShortcutCombination) -> Bool {
        let left = (try? left.normalized()) ?? left
        let right = (try? right.normalized()) ?? right
        return left == right || !physicalSignatures(for: left).isDisjoint(with: physicalSignatures(for: right))
    }
}

public struct ShortcutConflict: Equatable, Sendable {
    public struct Owner: Equatable, Sendable {
        public let operation: ShortcutOperationID
        public let binding: ShortcutBinding
    }
    public let operation: ShortcutOperationID
    public let proposed: ShortcutBinding
    public let owners: [Owner]
}

public enum ShortcutConflictResolution: Sendable { case reject, takeConflicts }

public struct ShortcutChangePlan: Equatable, Sendable {
    public let original: ShortcutConfiguration
    public let configuration: ShortcutConfiguration
    public let conflicts: [ShortcutConflict]
    public let requiresPrintingAcknowledgement: Bool
    public let requiresGlobalAcknowledgement: Bool
    public let environment: ShortcutValidationContext
    public let unavailableBindings: [ShortcutValidationIssue]
}

public struct ShortcutValidator: Sendable {
    public let environment: ShortcutValidationContext
    public init(environment: ShortcutValidationContext) { self.environment = environment }

    public func issues(for operation: ShortcutOperationID, combination: ShortcutCombination)
        -> [ShortcutValidationIssue]
    {
        func issue(_ code: ShortcutValidationIssue.Code, _ fixed: ShortcutFixedKey.Behavior? = nil)
            -> [ShortcutValidationIssue]
        {
            [.init(code: code, operation: operation, combination: combination, fixedBehavior: fixed)]
        }
        let normalized: ShortcutCombination
        do { normalized = try combination.normalized() } catch ShortcutModelError.invalidModifiers {
            return issue(.invalidModifiers)
        } catch { return issue(.invalidKey) }
        let metadata = ShortcutOperation.operation(operation)
        let physical: Bool
        if case .macVirtualKey = normalized.key { physical = true } else { physical = false }
        guard physical == metadata.isGlobal else { return issue(.wrongKeyKind) }
        if metadata.isGlobal {
            guard !normalized.modifiers.intersection([.command, .control, .option]).isEmpty else {
                return issue(.globalModifierRequired)
            }
        } else if normalized.modifiers.intersection([.command, .control]).isEmpty {
            let navigationModifiers: ShortcutModifiers
            if case .named(let key) = normalized.key, key.isArrow {
                navigationModifiers = [.shift, .option]
            } else {
                navigationModifiers = .shift
            }
            guard metadata.allowsBareKeys && normalized.modifiers.subtracting(navigationModifiers).isEmpty else {
                return issue(.modifierRequired)
            }
        }
        let signatures = environment.physicalSignatures(for: normalized)
        let projected = environment.logicalSpellings(for: signatures)
        if physical && (!environment.projectionAvailable || projected.isEmpty) {
            return issue(.layoutProjectionUnavailable)
        }
        let logical = physical ? projected : [normalized] + projected
        for key in logical {
            if let refusal = Self.staticRefusal(key) { return issue(refusal.0, refusal.1) }
        }
        // VoiceOver's modifier chord is independent of the keyboard layout.
        if normalized.modifiers.contains([.control, .option]), !normalized.modifiers.contains(.command) {
            return issue(.voiceOver)
        }
        guard environment.reservationsAvailable else { return issue(.systemReservationsUnavailable) }
        guard environment.projectionAvailable else { return issue(.layoutProjectionUnavailable) }
        if environment.isReserved(normalized) {
            return issue(.systemReserved)
        }
        return []
    }

    public func issues(in configuration: ShortcutConfiguration) -> [ShortcutValidationIssue] {
        ShortcutOperationID.allCases.flatMap { operation in
            configuration.keys(for: operation).flatMap { issues(for: operation, combination: $0) }
        }
    }

    public func conflicts(
        for operation: ShortcutOperationID, keys: [ShortcutCombination],
        in configuration: ShortcutConfiguration
    ) -> [ShortcutConflict] {
        let metadata = ShortcutOperation.operation(operation)
        return keys.compactMap { key in
            let proposed = metadata.binding(for: (try? key.normalized()) ?? key)
            let owners = ShortcutOperationID.allCases.filter { $0 != operation }.flatMap { other in
                configuration.bindings(for: other).compactMap { binding -> ShortcutConflict.Owner? in
                    guard proposed.overlaps(binding), environment.matches(proposed.combination, binding.combination)
                    else { return nil }
                    return .init(operation: other, binding: binding)
                }
            }
            return owners.isEmpty ? nil : .init(operation: operation, proposed: proposed, owners: owners)
        }
    }

    public func conflicts(in configuration: ShortcutConfiguration) -> [ShortcutConflict] {
        // Index both spellings so logical aliases and physical global keys meet in the same bucket.
        // The ordinal preserves catalog and binding order when several signatures find the same owner.
        var owners: [ShortcutConflict.Owner] = []
        var buckets: [ShortcutCombination: [Int]] = [:]
        var signatures: [Set<ShortcutCombination>] = []
        for operation in ShortcutOperation.catalog {
            for binding in configuration.bindings(for: operation.id) {
                let key = (try? binding.combination.normalized()) ?? binding.combination
                let matches = environment.physicalSignatures(for: key).union([key])
                for signature in matches { buckets[signature, default: []].append(owners.count) }
                signatures.append(matches)
                owners.append(.init(operation: operation.id, binding: binding))
            }
        }
        return owners.enumerated().compactMap { index, owner in
            let key = owner.binding.combination
            let proposed = ShortcutOperation.operation(owner.operation).binding(for: (try? key.normalized()) ?? key)
            let candidates = Set(signatures[index].flatMap { buckets[$0] ?? [] }).sorted()
            let others = candidates.map { owners[$0] }.filter {
                $0.operation != owner.operation && proposed.overlaps($0.binding)
            }
            return others.isEmpty ? nil : .init(operation: owner.operation, proposed: proposed, owners: others)
        }
    }

    public func plan(
        replacing operation: ShortcutOperationID, with keys: [ShortcutCombination],
        in original: ShortcutConfiguration, resolution: ShortcutConflictResolution
    ) throws -> ShortcutChangePlan {
        let keys = try ShortcutConfiguration.normalizedKeys(keys)
        let issues = keys.flatMap { self.issues(for: operation, combination: $0) }
        guard issues.isEmpty else { throw ShortcutModelError.validation(issues) }
        let conflicts = conflicts(for: operation, keys: keys, in: original)
        if resolution == .reject, !conflicts.isEmpty { throw ShortcutModelError.conflicts(conflicts) }
        var result = original
        for conflict in conflicts {
            for owner in conflict.owners {
                result = result.replacing(
                    owner.operation,
                    with: result.keys(for: owner.operation).filter {
                        !environment.matches($0, owner.binding.combination)
                    })
            }
        }
        result = result.replacing(operation, with: keys)
        let remaining = self.conflicts(in: result)
        guard remaining.isEmpty else { throw ShortcutModelError.conflicts(remaining) }
        let invalid = self.issues(in: result).filter { $0.code != .systemReserved }
        guard invalid.isEmpty else { throw ShortcutModelError.validation(invalid) }
        return changePlan(original: original, configuration: result, conflicts: conflicts)
    }

    public func restore(
        _ operation: ShortcutOperationID, in original: ShortcutConfiguration,
        resolution: ShortcutConflictResolution
    ) throws -> ShortcutChangePlan {
        let plan = try plan(
            replacing: operation, with: ShortcutDefaults.keys(for: operation), in: original,
            resolution: resolution)
        return changePlan(
            original: original, configuration: plan.configuration.replacing(operation, with: nil),
            conflicts: plan.conflicts)
    }

    public func restoreAll(in original: ShortcutConfiguration = .init()) throws -> ShortcutChangePlan {
        let defaults = ShortcutConfiguration()
        let conflicts = conflicts(in: defaults)
        guard conflicts.isEmpty else { throw ShortcutModelError.conflicts(conflicts) }
        let invalid = issues(in: defaults).filter { $0.code != .systemReserved }
        guard invalid.isEmpty else { throw ShortcutModelError.validation(invalid) }
        return changePlan(original: original, configuration: defaults, conflicts: [])
    }

    func changePlan(
        original: ShortcutConfiguration, configuration: ShortcutConfiguration,
        conflicts: [ShortcutConflict]
    ) -> ShortcutChangePlan {
        let changed = ShortcutOperation.catalog.filter { original.keys(for: $0.id) != configuration.keys(for: $0.id) }
        return .init(
            original: original, configuration: configuration, conflicts: conflicts,
            requiresPrintingAcknowledgement: changed.contains { [.printing, .export].contains($0.safety) },
            requiresGlobalAcknowledgement: changed.contains { $0.isGlobal && !configuration.keys(for: $0.id).isEmpty },
            environment: environment, unavailableBindings: issues(in: configuration))
    }

    public static func staticRefusal(_ combination: ShortcutCombination)
        -> (ShortcutValidationIssue.Code, ShortcutFixedKey.Behavior?)?
    {
        let key = combination.key
        let flags = combination.modifiers
        if key == .named(.space), flags.contains(.command) { return (.spotlight, nil) }
        if key == .named(.space), flags == .control || flags == [.control, .option] { return (.inputSource, nil) }
        if key == .named(.tab), flags == .command || flags == [.shift, .command] {
            return (.applicationSwitching, nil)
        }
        if key == .named(.escape), flags == [.option, .command] { return (.forceQuit, nil) }
        let navigation: [ShortcutKey] = [
            .named(.f1), .named(.f2), .named(.f3), .named(.f4),
            .named(.f5), .named(.f6), .named(.f7), .named(.f8),
        ]
        if navigation.contains(key), flags == .control { return (.keyboardNavigation, nil) }
        if [ShortcutKey.named(.f4), .named(.f6)].contains(key), flags == [.control, .shift] {
            return (.keyboardNavigation, nil)
        }
        if key == .named(.f5), flags == .command || flags == [.option, .command] { return (.accessibility, nil) }
        if [ShortcutKey.character("3"), .character("4"), .character("5"), .character("6")].contains(key),
            flags == [.shift, .command] || flags == [.control, .shift, .command]
        {
            return (.screenCapture, nil)
        }
        if key == .character("q"),
            flags == [.control, .command] || flags == [.shift, .command] || flags == [.option, .shift, .command]
        {
            return (.sessionControl, nil)
        }
        if case .named(let named) = key, named.isArrow, flags == .control { return (.workspaceNavigation, nil) }
        if key == .character("d"), flags == [.option, .command] { return (.workspaceNavigation, nil) }
        if key == .named(.escape) { return (.cancellation, .cancellation) }
        if key == .named(.return) || key == .named(.enter) || (key == .character(".") && flags == .command) {
            return (.confirmation, .confirmation)
        }
        if key == .named(.tab) { return (.focusNavigation, .focusTraversal) }
        for (behavior, keys) in ShortcutFixedKey.protectedCharacters where keys.contains(combination) {
            return (behavior == .documentSaving ? .documentSaving : .fixedOperation, behavior)
        }
        if flags.contains([.control, .option]), !flags.contains(.command) { return (.voiceOver, nil) }
        return nil
    }
}

extension ShortcutModifiers {
    /// Carbon's public modifier bits; the intrinsic function-key flag is not a shortcut modifier.
    public static func carbon(_ value: UInt32) -> Self {
        var flags: Self = []
        for (mask, flag): (UInt32, Self) in [
            (0x1000, .control), (0x0800, .option), (0x0200, .shift), (0x0100, .command),
        ] where value & mask != 0 { flags.insert(flag) }
        return flags
    }
}
