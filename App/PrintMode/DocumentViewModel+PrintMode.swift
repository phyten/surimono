import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    enum PrintCommand: Equatable { case enterPrintMode, printNow }

    /// ⌘P and the Print button: the view mode opens the print tray, and the tray prints right away to the printer
    /// chosen on it. The system dialog stays one step away (⌥⌘P).
    var printCommand: PrintCommand { mode == .print ? .printNow : .enterPrintMode }

    var canPerformPrintCommand: Bool { mode != .print || canOutput }

    func performPrintCommand() {
        switch printCommand {
        case .enterPrintMode: enterPrintMode()
        case .printNow: printDocument(quick: true)
        }
    }

    /// ⌘1–⌘6 and the layout cards: choose the layout and show it on the tray.
    func chooseLayout(_ id: String) {
        guard PrintLayout.presets.contains(where: { $0.id == id }) else { return }
        layoutID = id
        enterPrintMode()
    }
}
