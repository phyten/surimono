import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    enum PrintCommand: Equatable { case enterPrintMode, printNow }

    /// ⌘P and the Print button: the view mode opens the print tray, and the tray prints right away to the printer
    /// chosen on it. The system dialog stays one step away (⌥⌘P).
    var printCommand: PrintCommand {
        switch mode {
        case .view, .compare: .enterPrintMode
        case .print: .printNow
        }
    }

    var canPerformPrintCommand: Bool {
        !isWindowClosed && manualDuplexSession == nil && (readingPreview == nil || isPreparingWholeDocument)
            && (mode != .print || canStartPrint)
    }

    var canRequestPrintTray: Bool { printCommand == .enterPrintMode && canPerformPrintCommand }

    var isPresentingSomething: Bool {
        window?.attachedSheet != nil || hasDocumentPopover || isComparePlacePickerPresented
            || (mode == .view && (isOutlineDrawerOpen || isDrawerOpen || isReadingPanelOpen || find.isPresented))
            || drop.isActive
            || isReviewingSmartRemoval || manualDuplexSession != nil || duplexTestResult != nil || outputError != nil
            || sourceSharePicker != nil || readingShare?.isPresented == true
    }

    var canFulfillReservedPrint: Bool { canRequestPrintTray && isUpToDate && !isPresentingSomething }

    func cancelReservedPrint() {
        if previewPrintRequest.destination != nil { previewPrintRequest.cancel() }
    }

    func performPrintCommand() {
        guard canPerformPrintCommand else { return }
        switch printCommand {
        case .enterPrintMode: enterPrintMode()
        case .printNow: printDocument(quick: true)
        }
    }

    /// What Esc closes on the print screen. Things open over one another there, and only the topmost takes the key: a
    /// shortcut on what lies underneath would close it in the same press.
    enum PrintEscapeTarget { case popover, settings, fold, screen }

    var printEscapeTarget: PrintEscapeTarget {
        if isThemePalettePresented || isPrintIssuesPresented { return .popover }
        if isPrintFinishPresented { return .settings }
        if showsFold { return .fold }
        return .screen
    }

    /// The tray's "See It Folded" folds the current sheets only: older sheets kept on the tray while newer ones are
    /// composed may be a booklet that the new ones are not, and a fold asked for then would wait unseen and take the
    /// next Esc.
    var canShowFold: Bool { hasCurrentPrintPreview && printTray?.isBooklet == true }

    func showFold() {
        guard mode == .print, canShowFold else { return }
        showsFold = true
    }

    /// The sheets are current again: a fold of sheets that came out as no booklet ends, as it does when the layout is
    /// changed to one that is no booklet.
    func foldAvailabilityDidChange() {
        if hasCurrentPrintPreview, printTray?.isBooklet != true { showsFold = false }
    }

    /// Opens the print settings at one of their sections.
    func presentFinish(_ section: PrintFinishSection) {
        finishSection = section
        isPrintFinishPresented = true
    }

    /// "Print Settings…" in the "…" menu and the Document menu: one panel for both modes, since its settings change
    /// the pages of both. The view mode hangs it off the window's edge in place of the style palette; the tray lays it
    /// beside the sheets. The comparison stage has no such panel.
    func presentPrintSettings() {
        switch mode {
        case .view:
            themePaletteDidClose()
            closeBandPopovers()
            isPrintFinishPresented = true
        case .print:
            isPrintFinishPresented = true
        case .compare:
            break
        }
    }

    /// What the tray's header and footer choice shows: Custom from the moment it is chosen, while the fields are empty.
    var furnitureChoice: PageFurniture.Preset { isWritingFurniture ? .custom : printOptions.furniture.preset }

    func chooseDocumentFurniture() {
        isWritingFurniture = false
        printOptions.latexFurniture = .document
    }

    func chooseFurniture(_ preset: PageFurniture.Preset) {
        printOptions.latexFurniture = nil
        isWritingFurniture = preset == .custom
        if preset == .custom {
            presentFinish(.furniture)
        } else {
            printOptions.furniture.apply(preset)
        }
    }

    /// ⌘1–⌘6 and the layout cards: choose the layout and show it on the tray.
    func chooseLayout(_ id: String) {
        guard PrintLayout.presets.contains(where: { $0.id == id }) else { return }
        enterPrintMode(.layout(id))
    }
}
