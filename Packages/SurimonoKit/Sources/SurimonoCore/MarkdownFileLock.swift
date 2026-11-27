/// The approval belongs to the document and settings that produced it.
public struct MarkdownDiscardConfirmation: Equatable, Identifiable, Sendable {
    public var id: Int { generation }
    public let count: Int
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
        facts: DocumentFacts?, generation: Int, defaults: FormatReadingChoices,
        confirming approval: MarkdownDiscardConfirmation? = nil
    ) -> MarkdownFileLockResult {
        guard formatReading.allowsFileChanges(for: .markdown) else { return .finished }
        guard let facts else { return .awaitingInstructions }
        var after = formatReading
        var finish = printFinish
        var count = 0
        after.revert(.sectionNumbers, for: .markdown, fileOnly: facts.numberInstructions)
        if after != formatReading { count += 1 }
        let beforeContents = after
        after.revert(.tableOfContents, for: .markdown, fileOnly: facts.contentsInstructions)
        if after != beforeContents {
            count += 1
            var migrated = self
            if migrated.migrateContents(format: .markdown, facts: facts, defaults: defaults, editing: true) {
                finish = migrated.printFinish
                after.inheritMissingLeadContents(from: migrated.formatReading, for: .markdown)
                after.revert(.tableOfContents, for: .markdown, fileOnly: facts.contentsInstructions)
            }
        }
        after.setAllowsFileChanges(false, for: .markdown)
        let current = MarkdownDiscardConfirmation(
            count: count, generation: generation, before: formatReading, after: after, oldFinish: printFinish,
            newFinish: finish, defaults: defaults.restricted(to: [.markdown]))
        if count > 0, current != approval { return .needsConfirmation(current) }
        // Nothing is left to discard, or this exact discard was approved: a stale approval cannot block the lock.
        printFinish = finish
        formatReading = after
        return .finished
    }
}
