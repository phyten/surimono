public enum ShortcutOperationID: String, CaseIterable, Codable, Sendable {
    case appOpen = "app.open"
    case clipboardOpen = "clipboard.open"
    case appSettings = "app.settings"
    case documentPrint = "document.print"
    case documentPrintSystem = "document.printSystem"
    case documentExportPDF = "document.exportPDF"
    case documentFind = "document.find"
    case documentFindNext = "document.findNext"
    case documentFindPrevious = "document.findPrevious"
    case documentGoToPage = "document.goToPage"
    case documentReload = "document.reload"
    case viewHtmlPresentation = "view.htmlPresentation"
    case viewSpread = "view.spread"
    case viewSingle = "view.single"
    case textIncrease = "text.increase"
    case textDecrease = "text.decrease"
    case textReset = "text.reset"
    case viewZoomIn = "view.zoomIn"
    case viewZoomOut = "view.zoomOut"
    case viewZoomFit = "view.zoomFit"
    case viewToolbarAlways = "view.toolbarAlways"
    case viewToolbarToggle = "view.toolbarToggle"
    case viewOptions = "view.options"
    case viewSelectText = "view.selectText"
    case readingLeft = "reading.left"
    case readingRight = "reading.right"
    case readingPrevious = "reading.previous"
    case readingNext = "reading.next"
    case readingPageUp = "reading.pageUp"
    case readingPageDown = "reading.pageDown"
    case readingFirst = "reading.first"
    case readingLast = "reading.last"
    case printLayoutSingle = "print.layout.single"
    case printLayoutDuplex = "print.layout.duplex"
    case printLayoutBookletLarge = "print.layout.bookletLarge"
    case printLayoutBookletSmall = "print.layout.bookletSmall"
    case printLayoutTwoUpLarge = "print.layout.twoUpLarge"
    case printLayoutHandout = "print.layout.handout"
    case listToggle = "list.toggle"
    case listMoveUp = "list.moveUp"
    case listMoveDown = "list.moveDown"
    case listRemove = "list.remove"
    case foldLeft = "fold.left"
    case foldRight = "fold.right"
    case globalClipboardOpen = "global.clipboard.open"
    case globalClipboardPrintScreen = "global.clipboard.printScreen"
    case clipboardOpenPrintScreen = "clipboard.openPrintScreen"
    case appStreamingPreview = "app.streamingPreview"
    case appGettingStarted = "app.gettingStarted"
    case appKeyGuide = "app.keyGuide"
    case appCheckUpdates = "app.checkUpdates"
    case documentSaveAsFile = "document.saveAsFile"
    case documentAdd = "document.add"
    case documentOpenBinder = "document.openBinder"
    case documentResetSettings = "document.resetSettings"
    case printSettings = "print.settings"
    case styleChoose = "style.choose"
    case printLayoutTwoUpSmall = "print.layout.twoUpSmall"
    case printLayoutFourUp = "print.layout.fourUp"
    case settingSetSave = "settingSet.save"
    case settingSetManage = "settingSet.manage"
    case viewFloatOnTop = "view.floatOnTop"
    case viewShowOnAllSpaces = "view.showOnAllSpaces"
    case viewOutline = "view.outline"
    case viewDocumentInfo = "view.documentInfo"
    case viewIgnoreSlides = "view.ignoreSlides"
    case listSortByName = "list.sortByName"
    case binderOddPageStarts = "binder.oddPageStarts"
    case styleCompare = "style.compare"
    case styleFavorite = "style.favorite"
    case compareShuffle = "compare.shuffle"
    case printFoldPreview = "print.foldPreview"
    case printReviewIssues = "print.reviewIssues"
    case htmlSmartRemoval = "html.smartRemoval"
    case htmlReviewRemoval = "html.reviewRemoval"
    case printManualDuplex = "print.manualDuplex"
    case printDuplexTest = "print.duplexTest"
    case readingBack = "reading.back"
    case readingForward = "reading.forward"
    case bookmarkToggle = "bookmark.toggle"
    case bookmarkNext = "bookmark.next"
    case bookmarkPrevious = "bookmark.previous"
    case documentExportReadingPDF = "document.exportReadingPDF"
    case documentExportPNG = "document.exportPNG"
    case documentExportHTML = "document.exportHTML"
    case documentCopyHTML = "document.copyHTML"
    case documentShare = "document.share"
    case documentCopyRichText = "document.copyRichText"
    case appOpenURL = "app.openURL"
    case clipboardReopen = "clipboard.reopen"
}

public enum ShortcutRegion: String, CaseIterable, Codable, Sendable {
    case applicationWindow, paperReading, paperSelection, web, printSheet, foldedPreview, comparison
    case focusedList, editableControl, modal, recorder, global

    public static let document: Set<Self> = [
        .paperReading, .paperSelection, .web, .printSheet, .foldedPreview, .comparison, .focusedList, .editableControl,
    ]
    public static let application: Set<Self> = document.union([.applicationWindow])
}

public enum ShortcutGroup: String, Codable, Sendable {
    case application, documentAndPrinting, reading, styles, lists, global
}

public enum ShortcutSafety: String, Codable, Sendable {
    case ordinary, changesMode, export, printing, globalPrintScreen
}

public enum ShortcutApplicability: String, Codable, Sendable {
    case application, document, paper, paperWithPages, html, themedText, selectableText, memoryDocument
    case addDocuments, includePlan, binderOrImages, binder, booklet, updater, outline, documentInfo
}

public struct ShortcutBinding: Equatable, Sendable {
    public let combination: ShortcutCombination
    public let regions: Set<ShortcutRegion>

    public init(combination: ShortcutCombination, regions: Set<ShortcutRegion>) {
        self.combination = combination
        self.regions = regions
    }

    public func overlaps(_ other: Self) -> Bool {
        regions.contains(.global) || other.regions.contains(.global) || !regions.isDisjoint(with: other.regions)
    }
}

public struct ShortcutOperation: Equatable, Sendable {
    public let id: ShortcutOperationID
    public let group: ShortcutGroup
    public let applicability: ShortcutApplicability
    public let safety: ShortcutSafety
    public let regions: Set<ShortcutRegion>
    public let allowsBareKeys: Bool
    public var defaults: [ShortcutCombination] { ShortcutDefaults.keys(for: id) }
    public var isGlobal: Bool { regions.contains(.global) }

    public static let catalog: [Self] = ShortcutOperationID.allCases.map { operation($0) }

    public func binding(for combination: ShortcutCombination) -> ShortcutBinding {
        var active = regions
        if allowsBareKeys && combination.modifiers.intersection([.command, .control]).isEmpty {
            active.remove(.editableControl)
        }
        // PDFKit keeps native selection navigation unless a Command binding was explicitly assigned.
        if id.rawValue.hasPrefix("reading."), case .named(let key) = combination.key,
            key.isArrow || [.pageUp, .pageDown, .home, .end].contains(key),
            !combination.modifiers.contains(.command)
        {
            active.remove(.paperSelection)
        }
        return ShortcutBinding(combination: combination, regions: active)
    }

    public static func operation(_ id: ShortcutOperationID) -> Self {
        switch id {
        case .appOpen:
            return Self(
                id: id, group: .application, applicability: .application, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .clipboardOpen, .clipboardReopen, .appOpenURL:
            return Self(
                id: id, group: .application, applicability: .application, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .appSettings:
            return Self(
                id: id, group: .application, applicability: .application, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .documentPrint:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .printing,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .documentPrintSystem:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .printing,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .documentExportPDF, .documentExportReadingPDF, .documentExportPNG, .documentShare:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .export,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .documentExportHTML, .documentCopyHTML, .documentCopyRichText:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .themedText, safety: .export,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .documentFind:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .editableControl], allowsBareKeys: false)
        case .documentFindNext:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .editableControl], allowsBareKeys: false)
        case .documentFindPrevious:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .editableControl], allowsBareKeys: false)
        case .documentGoToPage:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .paperWithPages, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .editableControl], allowsBareKeys: false)
        case .documentReload:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .viewHtmlPresentation:
            return Self(
                id: id, group: .reading, applicability: .html, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .viewSpread:
            return Self(
                id: id, group: .reading, applicability: .document, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .viewSingle:
            return Self(
                id: id, group: .reading, applicability: .document, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .textIncrease:
            return Self(
                id: id, group: .styles, applicability: .themedText, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .textDecrease:
            return Self(
                id: id, group: .styles, applicability: .themedText, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .textReset:
            return Self(
                id: id, group: .styles, applicability: .themedText, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .viewZoomIn:
            return Self(
                id: id, group: .reading, applicability: .document, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .web, .printSheet, .foldedPreview, .editableControl],
                allowsBareKeys: false)
        case .viewZoomOut:
            return Self(
                id: id, group: .reading, applicability: .document, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .web, .printSheet, .foldedPreview, .editableControl],
                allowsBareKeys: false)
        case .viewZoomFit:
            return Self(
                id: id, group: .reading, applicability: .document, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .web, .printSheet, .foldedPreview, .editableControl],
                allowsBareKeys: false)
        case .viewToolbarAlways:
            return Self(
                id: id, group: .reading, applicability: .document, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .viewToolbarToggle:
            return Self(
                id: id, group: .reading, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .viewOptions:
            return Self(
                id: id, group: .reading, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .viewSelectText:
            return Self(
                id: id, group: .reading, applicability: .selectableText, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .readingBack, .readingForward, .bookmarkToggle, .bookmarkNext, .bookmarkPrevious:
            return Self(
                id: id, group: .reading, applicability: .paperWithPages, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .readingLeft:
            return Self(
                id: id, group: .reading, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .readingRight:
            return Self(
                id: id, group: .reading, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .readingPrevious:
            return Self(
                id: id, group: .reading, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .readingNext, .readingPageUp, .readingPageDown, .readingFirst, .readingLast:
            return Self(
                id: id, group: .reading, applicability: .paper, safety: .ordinary,
                regions: [.paperReading, .paperSelection], allowsBareKeys: true)
        case .printLayoutSingle:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printLayoutDuplex:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printLayoutBookletLarge:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printLayoutBookletSmall:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printLayoutTwoUpLarge:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printLayoutHandout:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .listToggle:
            return Self(
                id: id, group: .lists, applicability: .binderOrImages, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .listMoveUp:
            return Self(
                id: id, group: .lists, applicability: .binderOrImages, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .listMoveDown:
            return Self(
                id: id, group: .lists, applicability: .binderOrImages, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .listRemove:
            return Self(
                id: id, group: .lists, applicability: .binder, safety: .ordinary,
                regions: [.focusedList], allowsBareKeys: true)
        case .foldLeft:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .booklet, safety: .ordinary,
                regions: [.foldedPreview], allowsBareKeys: true)
        case .foldRight:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .booklet, safety: .ordinary,
                regions: [.foldedPreview], allowsBareKeys: true)
        case .globalClipboardOpen:
            return Self(
                id: id, group: .global, applicability: .application, safety: .ordinary,
                regions: [.global], allowsBareKeys: false)
        case .globalClipboardPrintScreen:
            return Self(
                id: id, group: .global, applicability: .application, safety: .globalPrintScreen,
                regions: [.global], allowsBareKeys: false)
        case .clipboardOpenPrintScreen:
            return Self(
                id: id, group: .application, applicability: .application, safety: .changesMode,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .appStreamingPreview:
            return Self(
                id: id, group: .application, applicability: .application, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .appGettingStarted:
            return Self(
                id: id, group: .application, applicability: .application, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .appKeyGuide:
            return Self(
                id: id, group: .application, applicability: .application, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .appCheckUpdates:
            return Self(
                id: id, group: .application, applicability: .updater, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .documentSaveAsFile:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .memoryDocument, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .documentAdd:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .addDocuments, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .documentOpenBinder:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .includePlan, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .documentResetSettings:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printSettings:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .web, .printSheet, .foldedPreview], allowsBareKeys: false)
        case .styleChoose:
            return Self(
                id: id, group: .styles, applicability: .themedText, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .printSheet, .foldedPreview], allowsBareKeys: false)
        case .printLayoutTwoUpSmall:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printLayoutFourUp:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .settingSetSave:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .settingSetManage:
            return Self(
                id: id, group: .application, applicability: .application, safety: .ordinary,
                regions: ShortcutRegion.application, allowsBareKeys: false)
        case .viewFloatOnTop, .viewShowOnAllSpaces:
            return Self(
                id: id, group: .reading, applicability: .document, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .viewOutline:
            return Self(
                id: id, group: .reading, applicability: .outline, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .web], allowsBareKeys: false)
        case .viewDocumentInfo:
            return Self(
                id: id, group: .reading, applicability: .documentInfo, safety: .ordinary,
                regions: [.paperReading, .paperSelection, .web], allowsBareKeys: false)
        case .viewIgnoreSlides:
            return Self(
                id: id, group: .reading, applicability: .html, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .listSortByName:
            return Self(
                id: id, group: .lists, applicability: .binderOrImages, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .binderOddPageStarts:
            return Self(
                id: id, group: .lists, applicability: .binder, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .styleCompare:
            return Self(
                id: id, group: .styles, applicability: .themedText, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .styleFavorite:
            return Self(
                id: id, group: .styles, applicability: .themedText, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .compareShuffle:
            return Self(
                id: id, group: .styles, applicability: .themedText, safety: .ordinary,
                regions: [.comparison], allowsBareKeys: false)
        case .printFoldPreview:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .booklet, safety: .changesMode,
                regions: [.printSheet], allowsBareKeys: false)
        case .printReviewIssues:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .htmlSmartRemoval:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .html, safety: .ordinary,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .htmlReviewRemoval:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .html, safety: .changesMode,
                regions: ShortcutRegion.document, allowsBareKeys: false)
        case .printManualDuplex:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .printing,
                regions: [.printSheet, .foldedPreview], allowsBareKeys: false)
        case .printDuplexTest:
            return Self(
                id: id, group: .documentAndPrinting, applicability: .document, safety: .printing,
                regions: [.printSheet, .foldedPreview], allowsBareKeys: false)
        }
    }
}
