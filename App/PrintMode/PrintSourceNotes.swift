import SwiftUI

/// What the tray prints of a web page: its current state or the file as it opens, and the details it has closed.
/// The choices last only while the tray is shown.
struct PrintSourceNotes: View {
    let model: DocumentViewModel

    var body: some View {
        if model.offersOriginalPage {
            VStack(alignment: .leading, spacing: 8) {
                if model.printsOriginalPage {
                    row(
                        systemImage: "doc", text: String(localized: "Printing the page as the file opens"),
                        action: "Print as It Is Now", help: "Print the web page as it is now"
                    ) { model.setPrintsOriginalPage(false) }
                } else {
                    row(
                        systemImage: "globe", text: String(localized: "Printing the web page as it is now"),
                        action: "Print the Original Page",
                        help: "Print the page as the file opens, without your changes"
                    ) { model.setPrintsOriginalPage(true) }
                }
                if model.closedDetailsCount > 0 {
                    if model.opensClosedDetails {
                        row(
                            systemImage: "chevron.down.square",
                            text: String(
                                format: String(localized: "Printing %lld closed details opened"),
                                model.closedDetailsCount),
                            action: "Keep Them Closed", help: "Print the details closed, as on the web page"
                        ) { model.setOpensClosedDetails(false) }
                    } else {
                        row(
                            systemImage: "chevron.right.square",
                            text: String(format: String(localized: "%lld closed details"), model.closedDetailsCount),
                            action: "Open and Print",
                            help: "Open all closed details on paper; the web page stays as it is"
                        ) { model.setOpensClosedDetails(true) }
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func row(
        systemImage: String, text: String, action: LocalizedStringKey, help: LocalizedStringKey,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5))
                .foregroundStyle(PrintPalette.ink3)
                .frame(width: 16)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(PrintPalette.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: perform) {
                Text(action).font(.system(size: 12)).padding(.horizontal, 10)
            }
            .buttonStyle(PrintBorderedButtonStyle(height: 24))
            .fixedSize()
            .help(help)
            Spacer(minLength: 0)
        }
    }
}
