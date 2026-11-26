import SurimonoCore
import SwiftUI

struct BandHintContent: Equatable {
    var name: String
    var state: String?
    var active = false
    var shortcut = ""
    var detail: String
    var reason: String?

    var accessibilityDetail: String?
    var usesNativeSwitchValue = false

    var accessibilityValue: String? {
        guard !usesNativeSwitchValue else { return nil }
        let values = [state, accessibilityDetail].compactMap { $0 }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    var accessibilityHint: String { reason ?? detail }

    static var more: Self {
        Self(name: String(localized: "More"), detail: String(localized: "All operations are also available in “…”."))
    }

    static func editor(_ item: BandLayout.Item) -> Self {
        Self(name: item.editorName, detail: item.editorDescription)
    }

    static func turn(forward: Bool, model: DocumentViewModel) -> Self {
        let menu = BandMenuContent(model: model)
        let id: BandMenuContent.ID = forward ? .nextPage : .previousPage
        var hint = Self(
            name: menu.entry(id).title, shortcut: ShortcutHints.keys(menu.operations(for: id)),
            detail: BandLayout.Item.pageTurn.editorDescription)
        if !model.canTurnPaperPage(forward: forward) {
            hint.reason =
                model.isPreparingWholeDocument
                ? PageIndicatorText.preparingHelp
                : (forward ? String(localized: "End of Document") : String(localized: "Beginning of Document"))
        }
        return hint
    }

    static func band(_ item: BandLayout.Item, model: DocumentViewModel) -> Self {
        let menu = BandMenuContent(model: model)
        let id = BandMenuContent.ID(rawValue: item.rawValue)
        let entry = id.map(menu.entry)
        var result = Self(name: item.editorName, detail: item.editorDescription)
        var operations = id.map { menu.operations(for: $0) } ?? []
        func open(_ value: Bool) {
            result.active = value
            result.state = value ? String(localized: "Open") : String(localized: "Closed")
        }
        switch item {
        case .formatBadge:
            result.state = model.textKind == nil ? model.formatBadge : menu.entry(.textFormat).value
            if let badge = model.latexBadge {
                open(model.isLaTeXRecognitionPresented)
                result.accessibilityDetail = badge.explanation
            }
        case .chapter:
            operations = menu.operations(for: .outline)
            open(model.isOutlineShown)
            if !model.currentChapterTitle.isEmpty {
                result.name = model.currentChapterTitle
                result.accessibilityDetail = model.currentChapterTitle
            }
        case .pageIndicator:
            operations = [.documentGoToPage]
            result.state = model.pageIndicator
            result.accessibilityDetail = BandAccessibility.pageIndicator(
                nil, bookmarked: model.isVisiblePageBookmarked, preparing: model.isPreparingWholeDocument)
            if model.isPreparingWholeDocument { result.reason = PageIndicatorText.preparingHelp }
        case .readingSettings:
            open(model.isReadingPanelOpen)
            if model.orgDocumentReading.changedCount > 0 {
                result.accessibilityDetail = String(
                    localized: BandAccessibility.readingChanges(model.orgDocumentReading.changedCount))
            }
        case .outline:
            open(model.isOutlineShown)
            if !model.hasContents {
                result.reason =
                    model.isPreparingWholeDocument ? PageIndicatorText.preparingHelp : item.editorAvailability
            }
        case .thumbnails:
            open(model.showsSideList)
            if let binder = model.binder {
                result.accessibilityDetail = String(localized: BandAccessibility.documents(binder.items.count))
            }
        case .viewOptions: open(model.isViewOptionsPresented)
        case .printSettings: open(model.isPrintFinishPresented)
        case .style:
            result = Self(name: String(localized: model.bandStyleAccessibility.name), detail: item.editorDescription)
            if model.usesPrintTheme && model.binder == nil {
                open(model.isThemePalettePresented)
                result.accessibilityDetail = model.bandStyleAccessibility.value
            } else if model.usesHTMLPreset && model.binder == nil {
                result.active = model.isSmartRemovalEnabled
                result.state = choice(
                    String(localized: "Smart Removal"), item.bandAccessibilityValue(checked: result.active))
                result.accessibilityDetail = model.styleName
            } else {
                result.state = model.styleName
            }
        case .zoom: result.state = model.zoomPercentage
        case .pageTurn:
            operations = menu.operations(for: .previousPage) + menu.operations(for: .nextPage)
            if model.isPreparingWholeDocument { result.reason = PageIndicatorText.preparingHelp }
        case .cover, .selectText, .alwaysShowToolbar, .ignoreSlides, .floatOnTop, .showOnAllSpaces:
            result.usesNativeSwitchValue = true
            result.active = entry?.isChecked == true
            result.state = item.bandAccessibilityValue(checked: result.active)
            if item == .cover && result.active && !model.viewOptions.usesCoverOption {
                result.detail = String(
                    localized: "This setting applies in spread view. You are viewing one page at a time.")
            }
        case .beforePrinting: result.state = model.printIssueCount.formatted()
        case .presentation, .layout, .transition, .readingDirection, .scrollDirection, .paperOrientation, .paperSeries,
            .margins:
            result.state = entry?.value
            if entry?.isEnabled == false {
                result.reason =
                    item == .paperOrientation
                    ? String(localized: "This layout uses a fixed paper orientation.")
                    : String(localized: "Not used by the current page turn.")
            }
        case .print:
            if model.previewPrintRequest.destination != nil {
                result = Self(
                    name: String(localized: "Print When Ready"), state: String(localized: "Cancel"),
                    detail: item.editorDescription)
            }
            if entry?.isEnabled == false {
                result.reason =
                    model.error
                    ?? (model.manualDuplexSession != nil
                        ? String(localized: "Finish the manual duplex job first.")
                        : String(localized: "Preparing pages…"))
            }
        case .saveAsFile, .keysAndGestures: break
        }
        result.shortcut = ShortcutHints.keys(operations)
        return result
    }
}
