/// The approval belongs to the document and settings that produced it.
public struct MarkdownDiscardConfirmation: Equatable, Identifiable, Sendable {
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

public enum MarkdownFileLockResult: Equatable, Sendable {
    case finished
    case awaitingInstructions
    case needsConfirmation(MarkdownDiscardConfirmation)
}

extension DocumentSettings {
    /// Asking for confirmation leaves both the settings and the legacy finish untouched.
    public mutating func lockMarkdownFileInstructions(
        for format: DocumentFormat = .markdown, facts: DocumentFacts?, generation: Int, defaults: FormatReadingChoices,
        confirming approval: MarkdownDiscardConfirmation? = nil
    ) -> MarkdownFileLockResult {
        guard format.usesMarkdownReadingSettings, formatReading.allowsFileChanges(for: format) else { return .finished }
        guard let facts else { return .awaitingInstructions }
        var after = formatReading
        var finish = printFinish
        var count = 0
        after.revert(.sectionNumbers, for: format, fileOnly: facts.numberInstructions)
        if after != formatReading { count += 1 }
        let beforeContents = after
        after.revert(.tableOfContents, for: format, fileOnly: facts.contentsInstructions)
        if after != beforeContents {
            count += 1
            var migrated = self
            if migrated.migrateContents(format: format, facts: facts, defaults: defaults, editing: true) {
                finish = migrated.printFinish
                after.inheritMissingLeadContents(from: migrated.formatReading, for: format)
                after.revert(.tableOfContents, for: format, fileOnly: facts.contentsInstructions)
            }
        }
        after.setAllowsFileChanges(false, for: format)
        let current = MarkdownDiscardConfirmation(
            count: count, format: format, generation: generation, before: formatReading, after: after,
            oldFinish: printFinish,
            newFinish: finish, defaults: defaults.restricted(to: [format]))
        if count > 0, current != approval { return .needsConfirmation(current) }
        // Nothing is left to discard, or this exact discard was approved: a stale approval cannot block the lock.
        printFinish = finish
        formatReading = after
        return .finished
    }
}
