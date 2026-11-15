import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    enum PrintCommand: Equatable { case enterPrintMode, printNow }

    /// ⌘P and the Print button: the view mode opens the print tray, and the tray prints right away to the printer
    /// chosen on it. The system dialog stays one step away (⌥⌘P).
    var printCommand: PrintCommand { mode == .print ? .printNow : .enterPrintMode }

    var canPerformPrintCommand: Bool {
        manualDuplexSession == nil && (mode != .print || canStartPrint)
    }

    func performPrintCommand() {
        guard manualDuplexSession == nil else { return }
        switch printCommand {
        case .enterPrintMode: enterPrintMode()
        case .printNow: printDocument(quick: true)
        }
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

    func chooseFurniture(_ preset: PageFurniture.Preset) {
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
        layoutID = id
        enterPrintMode()
    }
}
