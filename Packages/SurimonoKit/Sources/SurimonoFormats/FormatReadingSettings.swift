public struct FormatReadingSettings: Sendable {
    public var document: FormatReadingChoices
    public var defaults: FormatReadingChoices
    /// A saved legacy finish still owns the lead list until its first edit.
    public var manuscriptContents: Bool
    /// A separate contents page can use the native outline even when the manuscript omits its preamble.
    public var separateContentsPage: Bool

    public init(
        document: FormatReadingChoices = .init(), defaults: FormatReadingChoices = .init(),
        manuscriptContents: Bool = false, separateContentsPage: Bool = false
    ) {
        self.document = document
        self.defaults = defaults
        self.manuscriptContents = manuscriptContents
        self.separateContentsPage = separateContentsPage
    }
    struct Options {
        var numbers: ReadingDepth?
        var ownsNumbers = false
        var preservesBreaks = false
        var lead: ReadingDepth?
    }

    func resolve(
        for format: DocumentFormat, numbers: ReadingFileInstructions, contents: ReadingFileInstructions,
        contentsDepth: Int?
    ) -> Options {
        var result = Options()
        switch document.resolve(.sectionNumbers, for: format, file: numbers, defaults: defaults) {
        case .toggle(let present):
            result.numbers = present.value ? .all : nil
        case .outline(let present, let depth):
            result.numbers = present.value ? depth.value : nil
        case nil: break
        }
        result.ownsNumbers = !document.usesStyleForSectionNumbers(for: format, file: numbers, defaults: defaults)
        if case .toggle(let breaks) = document.resolve(.preserveBreaks, for: format, defaults: defaults) {
            result.preservesBreaks = breaks.value
        }
        let choices = manuscriptContents ? FormatReadingChoices() : document
        let app = manuscriptContents ? FormatReadingChoices() : defaults
        if case .outline(let present, let depth) = choices.resolve(
            .tableOfContents, for: format, file: contents, defaults: app), present.value
        {
            result.lead = depth.layer == .app ? contentsDepth.map(ReadingDepth.levels) ?? depth.value : depth.value
        }
        return result
    }

}
