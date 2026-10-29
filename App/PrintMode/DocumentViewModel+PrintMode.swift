import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    enum PrintCommand: Equatable { case enterPrintMode, showPrintPanel }

    /// ⌘P and the Print button: the view mode opens the print tray, the tray opens the print panel.
    var printCommand: PrintCommand { mode == .view ? .enterPrintMode : .showPrintPanel }

    var canPerformPrintCommand: Bool { mode == .view || canOutput }

    func performPrintCommand() {
        switch printCommand {
        case .enterPrintMode: enterPrintMode()
        case .showPrintPanel: printDocument()
        }
    }

    /// ⌘1–⌘5 and the layout cards: choose the layout and show it on the tray.
    func chooseLayout(_ id: String) {
        guard PrintLayout.presets.contains(where: { $0.id == id }) else { return }
        layoutID = id
        enterPrintMode()
    }

    /// The sheets of the current output, grouped as they come out of the printer.
    var printTray: PrintTray? {
        guard let result, let renderedSettings else { return nil }
        return PrintTray(
            plan: result.plan, layout: renderedSettings.layout,
            rotatesBackSides: renderedSettings.options.rotatesBackSides)
    }
}
