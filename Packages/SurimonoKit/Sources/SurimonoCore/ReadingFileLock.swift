/// The approval belongs to the document and settings that produced it.
public struct ReadingDiscardConfirmation: Equatable, Identifiable, Sendable {
    public var id: Int { generation }
    public let count: Int
    fileprivate let format: DocumentFormat
    fileprivate let generation: Int
    fileprivate let before: FormatReadingChoices
    fileprivate let after: FormatReadingChoices
    fileprivate let oldFinish: PrintFinish?
    fileprivate let newFinish: PrintFinish?
    fileprivate let defaults: FormatReadingChoices
}

public enum ReadingFileLockResult: Equatable, Sendable {
    case finished
    case awaitingInstructions
    case needsConfirmation(ReadingDiscardConfirmation)
}

extension DocumentSettings {
    /// Asking for confirmation leaves both the settings and the legacy finish untouched.
    public mutating func lockReadingFileInstructions(
        for format: DocumentFormat, facts: DocumentFacts?, generation: Int, defaults: FormatReadingChoices,
        confirming approval: ReadingDiscardConfirmation? = nil
    ) -> ReadingFileLockResult {
        guard format.usesFormatReadingSettings, formatReading.allowsFileChanges(for: format) else { return .finished }
        guard let facts else { return .awaitingInstructions }
        let before = formatReading.restricted(to: [format])
        var after = formatReading
        var finish = printFinish
        var count = 0
        after.revert(.sectionNumbers, for: format, fileOnly: facts.numberInstructions)
        let beforeContents = after.restricted(to: [format])
        if beforeContents != before { count += 1 }
        after.revert(.tableOfContents, for: format, fileOnly: facts.contentsInstructions)
        if after.restricted(to: [format]) != beforeContents {
            count += 1
            var migrated = self
            if migrated.migrateContents(format: format, facts: facts, defaults: defaults, editing: .lead) {
                finish = migrated.printFinish
                after.inheritMissingLeadContents(from: migrated.formatReading, for: format)
                after.revert(.tableOfContents, for: format, fileOnly: facts.contentsInstructions)
            }
        }
        after.setAllowsFileChanges(false, for: format)
        let current = ReadingDiscardConfirmation(
            count: count, format: format, generation: generation, before: before,
            after: after.restricted(to: [format]),
            oldFinish: printFinish,
            newFinish: finish, defaults: defaults.restricted(to: [format]))
        if count > 0, current != approval { return .needsConfirmation(current) }
        // Nothing is left to discard, or this exact discard was approved: a stale approval cannot block the lock.
        printFinish = finish
        formatReading = after
        return .finished
    }
}
