import SurimonoCore

/// Commands without a main-menu item. Their controls and keys share the model's existing actions.
enum ShortcutCommands {
    static let operations: Set<ShortcutOperationID> = [
        .viewOutline, .viewDocumentInfo, .styleCompare, .styleFavorite, .compareShuffle,
        .printFoldPreview, .printReviewIssues, .htmlSmartRemoval, .htmlReviewRemoval,
        .printManualDuplex, .printDuplexTest,
    ]
}

/// The six established card roles followed by the two compact alternatives. Never persist a layout array index.
enum ShortcutPrintLayouts {
    static let operations: [ShortcutOperationID] = [
        .printLayoutSingle, .printLayoutDuplex, .printLayoutBookletLarge, .printLayoutBookletSmall,
        .printLayoutTwoUpLarge, .printLayoutHandout, .printLayoutTwoUpSmall, .printLayoutFourUp,
    ]

    static func layout(for operation: ShortcutOperationID, series: PaperSeries) -> PrintLayout? {
        switch operation {
        case .printLayoutTwoUpSmall:
            switch series {
            case .a: .a4TwoUp
            case .b: .b5TwoUp
            case .letter: .letterTwoUp
            }
        case .printLayoutFourUp:
            switch series {
            case .a: .a4FourUp
            case .b: .b5FourUp
            case .letter: .letterFourUp
            }
        case .printLayoutHandout where series == .b: .a4Handout3
        default:
            operations.firstIndex(of: operation).flatMap { index in
                let cards = PrintLayout.presets(in: series)
                return cards.indices.contains(index) ? cards[index] : nil
            }
        }
    }
}

extension DocumentViewModel {
    /// The comparison's selected group also supplies candidates when Shuffle is invoked from a key.
    func shuffleComparison() {
        guard mode == .compare, usesPrintTheme else { return }
        let group = themeMenu.sections.first { $0.id == compareFilterID }?.themes.map(\.id) ?? []
        let pool = group.count > 3 ? group : library.themes.filter(\.isBuiltIn).map(\.id)
        var generator = SystemRandomNumberGenerator()
        themeComparison?.shuffle(from: pool, using: &generator)
    }

    func performAdditionalShortcut(_ operation: ShortcutOperationID) {
        switch operation {
        case .viewOutline:
            if mode == .view, hasOutline { toggleOutline() }
        case .viewDocumentInfo:
            if mode == .view, !showsWeb { isFiguresPresented.toggle() }
        case .styleCompare: enterCompareMode()
        case .styleFavorite:
            if usesPrintTheme { toggleFavoriteTheme() }
        case .compareShuffle: shuffleComparison()
        case .printFoldPreview:
            if mode == .print, layout.kind == .booklet { showsFold = true }
        case .printReviewIssues: reviewPrintIssues()
        case .htmlSmartRemoval:
            if format == .html { setSmartRemoval(enabled: !isSmartRemovalEnabled) }
        case .htmlReviewRemoval: reviewSmartRemoval()
        case .printManualDuplex:
            if mode == .print, canPrintManualDuplex {
                printDocument(intent: .manualDuplex)
            }
        case .printDuplexTest:
            if mode == .print { printDuplexTest() }
        default: break
        }
    }
}
