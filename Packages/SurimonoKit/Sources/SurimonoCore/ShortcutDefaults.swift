public enum ShortcutDefaults: Sendable {
    public static func keys(for operation: ShortcutOperationID) -> [ShortcutCombination] {
        switch operation {
        case .readingBack: [character("[", .command)]
        case .readingForward: [character("]", .command)]
        case .bookmarkToggle: [character("b", [])]
        case .bookmarkNext: [character("]", [])]
        case .bookmarkPrevious: [character("[", [])]
        case .appOpen: [character("o", .command)]
        case .clipboardOpen: [character("n", .command)]
        case .appSettings: [character(",", .command)]
        case .documentPrint: [character("p", .command)]
        case .documentPrintSystem: [character("p", [.option, .command])]
        case .documentExportReadingPDF: []
        case .documentExportPDF: [character("e", [.shift, .command])]
        case .documentFind: [character("f", .command)]
        case .documentFindNext: [character("g", .command)]
        case .documentFindPrevious: [character("g", [.shift, .command])]
        case .documentGoToPage: [character("g", [.option, .command])]
        case .documentReload: [character("r", .command)]
        case .viewHtmlPresentation: [character("p", [.control, .command])]
        case .viewSpread: [character("2", [.option, .command])]
        case .viewSingle: [character("1", [.option, .command])]
        case .textIncrease: [character("+", [.option, .command]), character("=", [.option, .command])]
        case .textDecrease: [character("-", [.option, .command])]
        case .textReset: [character("0", [.option, .command])]
        case .viewZoomIn: [character("+", .command), character("=", .command)]
        case .viewZoomOut: [character("-", .command)]
        case .viewZoomFit: [character("0", .command)]
        case .viewToolbarAlways: [character("t", [.option, .command])]
        case .viewToolbarToggle: [character("m", []), character("m", .shift)]
        case .viewOptions: [character("v", []), character("v", .shift)]
        case .viewSelectText: [character("t", []), character("t", .shift)]
        case .readingLeft, .foldLeft: [.init(key: .named(.leftArrow))]
        case .readingRight, .foldRight: [.init(key: .named(.rightArrow))]
        case .readingPrevious: [.init(key: .named(.upArrow)), .init(key: .named(.space), modifiers: .shift)]
        case .readingNext: [.init(key: .named(.downArrow)), .init(key: .named(.space))]
        case .readingPageUp: [.init(key: .named(.pageUp))]
        case .readingPageDown: [.init(key: .named(.pageDown))]
        case .readingFirst: [.init(key: .named(.home))]
        case .readingLast: [.init(key: .named(.end))]
        case .printLayoutSingle: [character("1", .command)]
        case .printLayoutDuplex: [character("2", .command)]
        case .printLayoutBookletLarge: [character("3", .command)]
        case .printLayoutBookletSmall: [character("4", .command)]
        case .printLayoutTwoUpLarge: [character("5", .command)]
        case .printLayoutHandout: [character("6", .command)]
        case .listToggle: [character("s", [.control, .command])]
        case .listMoveUp: [.init(key: .named(.upArrow), modifiers: [.option, .command])]
        case .listMoveDown: [.init(key: .named(.downArrow), modifiers: [.option, .command])]
        case .listRemove: [.init(key: .named(.deleteBackward))]
        case .globalClipboardOpen, .globalClipboardPrintScreen, .clipboardOpenPrintScreen, .appStreamingPreview,
            .appGettingStarted, .appKeyGuide, .appCheckUpdates, .documentSaveAsFile, .documentAdd, .documentOpenBinder,
            .documentResetSettings, .printSettings, .styleChoose, .printLayoutTwoUpSmall, .printLayoutFourUp,
            .settingSetSave, .settingSetManage, .viewFloatOnTop, .viewOutline, .viewDocumentInfo, .viewIgnoreSlides,
            .listSortByName, .binderOddPageStarts, .styleCompare, .styleFavorite, .compareShuffle,
            .printFoldPreview, .printReviewIssues, .htmlSmartRemoval, .htmlReviewRemoval,
            .printManualDuplex, .printDuplexTest:
            []
        }
    }

    private static func character(_ value: String, _ modifiers: ShortcutModifiers) -> ShortcutCombination {
        .init(key: .character(value), modifiers: modifiers)
    }
}

public struct ShortcutFixedKey: Equatable, Sendable {
    public enum Behavior: String, CaseIterable, Sendable {
        case cancellation, confirmation, findSubmission, focusTraversal, paperToolbar, controlActivation
        case nativeEditing, copy, cut, paste, selectAll, undo, redo, pasteMatchingStyle
        case closeWindow, quit, hide, minimize, fullScreen, cycleWindows, documentSaving
    }
    public let behavior: Behavior
    public let combinations: [ShortcutCombination]
    public let regions: Set<ShortcutRegion>

    public static let catalog: [Self] =
        [
            .init(
                behavior: .cancellation, combinations: [.init(key: .named(.escape))],
                regions: ShortcutRegion.application.union([.modal, .recorder])),
            .init(
                behavior: .confirmation, combinations: [.init(key: .named(.return)), .init(key: .named(.enter))],
                regions: ShortcutRegion.application.union([.modal])),
            .init(
                behavior: .findSubmission,
                combinations: [
                    .init(key: .named(.return)), .init(key: .named(.return), modifiers: .shift),
                ], regions: [.editableControl]),
            .init(
                behavior: .focusTraversal,
                combinations: [
                    .init(key: .named(.tab)), .init(key: .named(.tab), modifiers: .shift),
                ], regions: ShortcutRegion.application.union([.modal, .recorder])),
            .init(
                behavior: .paperToolbar,
                combinations: [
                    .init(key: .named(.tab)), .init(key: .named(.tab), modifiers: .shift),
                ], regions: [.paperReading, .paperSelection]),
            .init(
                behavior: .controlActivation, combinations: [.init(key: .named(.space))],
                regions: [.editableControl, .modal, .recorder]),
            .init(behavior: .nativeEditing, combinations: [], regions: [.editableControl, .paperSelection, .web]),
        ]
        + protectedCharacters.map { behavior, keys in
            Self(behavior: behavior, combinations: keys, regions: ShortcutRegion.application)
        }

    static let protectedCharacters: [(Behavior, [ShortcutCombination])] = [
        (.copy, [key("c")]), (.cut, [key("x")]), (.paste, [key("v")]), (.selectAll, [key("a")]),
        (.undo, [key("z")]), (.redo, [key("z", [.shift, .command])]),
        (.pasteMatchingStyle, [key("v", [.option, .shift, .command])]),
        (.closeWindow, [key("w"), key("w", [.option, .command])]), (.quit, [key("q")]),
        (.hide, [key("h"), key("h", [.option, .command])]),
        (.minimize, [key("m"), key("m", [.option, .command])]),
        (.fullScreen, [key("f", [.control, .command])]),
        (.cycleWindows, [key("`"), key("`", [.shift, .command]), key("~")]),
        (.documentSaving, [key("s"), key("s", [.shift, .command]), key("s", [.option, .shift, .command])]),
    ]

    private static func key(_ value: String, _ modifiers: ShortcutModifiers = .command) -> ShortcutCombination {
        .init(key: .character(value), modifiers: modifiers)
    }
}
