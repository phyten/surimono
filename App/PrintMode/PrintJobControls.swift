import SurimonoRendering
import SwiftUI

/// How many times the sheets go out and which pages of the document are on them. Both sit with the result on the
/// press bar, since they change what comes out and not how it is laid out. The parts flow onto a second row where
/// the result's column is narrow, so the bar gets no wider for them.
struct PrintJobControls: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        PrintFlowLayout(spacing: 12, lineSpacing: 4) {
            copies
            pages
            if let message {
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.warn)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var copies: some View {
        HStack(spacing: 5) {
            Text("Copies").font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                .accessibilityHidden(true)
            Text(verbatim: "\(model.copies)")
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(minWidth: 16, alignment: .trailing)
                .accessibilityHidden(true)
            Stepper("Copies", value: $model.copies, in: PrintJobFactory.copiesRange)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityValue(Text(verbatim: "\(model.copies)"))
        }
        .fixedSize()
    }

    private var pages: some View {
        HStack(spacing: 5) {
            Text("Page Range").font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                .accessibilityHidden(true)
            TextField(
                "Page Range", text: Binding(get: { model.pageRangeText }, set: { model.setPageRangeText($0) }),
                prompt: Text("All")
            )
            .modifier(PageRangeFieldStyle(isMarked: model.pageRangeProblem != nil))
            .help("Example: 1-5, 8")
        }
        .fixedSize()
    }

    private var message: String? {
        switch model.pageRangeProblem {
        case .unreadable: PrintModeText.string("The pages could not be read", language: model.language)
        case .noSuchPages: PrintModeText.string("No such pages", language: model.language)
        case nil: nil
        }
    }
}

/// The field is drawn like the tray's other controls; its border turns to the warning color for a range that cannot
/// be used.
private struct PageRangeFieldStyle: ViewModifier {
    let isMarked: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .frame(width: 96, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(PrintPalette.raised))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isMarked ? PrintPalette.warn : PrintPalette.line2, lineWidth: isMarked ? 1.5 : 1)
            }
    }
}
