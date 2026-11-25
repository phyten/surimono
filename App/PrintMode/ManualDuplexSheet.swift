import SurimonoCore
import SwiftUI

struct ManualDuplexSheet: View {
    let model: DocumentViewModel
    @Bindable var session: ManualDuplexSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reload the Paper and Print the Backs").font(.headline)
            Text(
                verbatim: PrintModeText.format(
                    "Fronts sent: %lld sheets. (Printer: %@)", language: session.language,
                    session.sheetCount, session.printerName)
            )
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Wait until all the sheets have come out.")
                step(2, "Put the stack back into the tray without changing the order.")
                step(3, "Load the paper so the blank sides will be printed. Turn the whole stack if needed.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("If It Did Not Work").font(.subheadline.weight(.semibold))
                Toggle(isOn: $session.correction.reversesBackOrder) {
                    correctionLabel("Reverse the Back Order", when: "If the backs printed on the wrong sheets")
                }
                Toggle(isOn: $session.correction.rotatesBackSides) {
                    correctionLabel("Rotate the Backs 180°", when: "If the backs printed upside down")
                }
                Text("These adjustments are remembered for this printer and binding.")
                    .font(.caption).foregroundStyle(PrintPalette.ink2)
            }
            .disabled(session.phase != .awaitingReload)
            if let error = session.error {
                Text(verbatim: error).foregroundStyle(PrintPalette.warn).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("manualDuplexError")
            }
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Cancel") { model.cancelManualDuplex() }.keyboardShortcut(.cancelAction)
                    Text("Cancelling does not cancel print jobs already sent.")
                        .font(.caption).foregroundStyle(PrintPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Print the Backs") { model.printManualDuplexBacks() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.phase != .awaitingReload)
                    .accessibilityIdentifier("printManualDuplexBacks")
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled()
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number).").monospacedDigit()
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func correctionLabel(_ title: LocalizedStringKey, when hint: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(hint).font(.caption).foregroundStyle(PrintPalette.ink2)
        }
    }
}

struct ManualDuplexPresentation: ViewModifier {
    let model: DocumentViewModel

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: model.controlBinding(
                get: { $0.manualDuplexSession?.showsReload == true },
                // Only a dismissal from outside ends the session; the sheet closing for the backs must not.
                set: { if !$1, $0.manualDuplexSession?.showsReload == true { $0.cancelManualDuplex() } }
            )
        ) { [weak model] in
            if let model, let session = model.manualDuplexSession {
                ManualDuplexSheet(model: model, session: session)
            }
        }
    }
}
