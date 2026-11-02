import SurimonoCore
import SwiftUI

struct DuplexTestSheet: View {
    @Bindable var model: DocumentViewModel
    let test: DocumentViewModel.DuplexTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which way did the back arrow point?").font(.headline)
            Text(verbatim: test.printerName).font(.subheadline)
            Text(instruction)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Later") { model.answerDuplexTest(rotatesBackSides: nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Up (same as front)") { model.answerDuplexTest(rotatesBackSides: false) }
                Button("Down (upside down)") { model.answerDuplexTest(rotatesBackSides: true) }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var instruction: LocalizedStringKey {
        test.duplex == .longEdge
            ? "Turn the sheet along its long edge. The back arrow should point up."
            : "Turn the sheet along its short edge. The back arrow should point up."
    }

}
