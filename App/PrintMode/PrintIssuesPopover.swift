import SurimonoCore
import SwiftUI

struct PrintIssuesPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before Printing").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.printIssues) { issue in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: PrintIssueText.title(issue, language: model.language))
                                .font(.system(size: 13, weight: .semibold))
                                .textSelection(.enabled)
                            if let page = issue.pageNumber {
                                Text("Page \(page)").font(.caption).foregroundStyle(PrintPalette.ink2)
                            }
                            Text(verbatim: PrintIssueText.advice(issue, language: model.language))
                                .font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                            ViewThatFits(in: .horizontal) {
                                HStack { actions(issue) }
                                VStack(alignment: .leading) { actions(issue) }
                            }
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if issue.id != model.printIssues.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 440)
        .foregroundStyle(PrintPalette.ink)
        .tint(PrintPalette.ai)
    }

    @ViewBuilder
    private func actions(_ issue: PrintIssue) -> some View {
        if issue.pageNumber != nil {
            Button("Go to Page") { model.showPrintIssue(issue) }
        }
        switch issue.kind {
        case .image:
            if issue.imageFailure == .missing, model.fileURL != nil {
                Button("Show in Finder") { model.revealPrintIssueFolder() }
            } else if issue.imageFailure == .folderAccess, model.fileURL != nil {
                Button("Allow Access to Folder…") { model.allowFolderAccess() }
            }
        case .overflow:
            Button("Use Landscape") { model.useLandscapeForPrintIssue() }
                .disabled(PaperOrientationControl(model: model).isFixed)
                .help(
                    PaperOrientationControl(model: model).isFixed
                        ? Text("This layout uses a fixed paper orientation.") : Text("Paper Orientation"))
            if model.format.usesPrintTheme {
                Button("Make Text Smaller") { model.decreaseTextSize() }
                    .disabled(TextScale.smaller(than: model.textScale) == model.textScale)
            }
        case .math, .latex, .mermaid: EmptyView()
        }
    }
}

enum PrintIssueText {
    static func title(_ issue: PrintIssue, language: String) -> String {
        let key: String
        switch issue.kind {
        case .image: key = "Could Not Load Image: %@"
        case .math: key = "Could Not Render Formula: %@"
        case .mermaid: key = "Could Not Render Diagram: %@"
        case .latex: key = "Unsupported LaTeX: %@"
        case .overflow:
            switch issue.element {
            case .table: key = "Table Exceeds the Text Width"
            case .image: key = "Image Exceeds the Text Width"
            case .code: key = "Code Exceeds the Text Width"
            case .math: key = "Formula Exceeds the Text Width"
            case .figure, nil: key = "Figure Exceeds the Text Width"
            }
            return PrintModeText.string(key, language: language)
        }
        return PrintModeText.format(key, language: language, issue.detail)
    }

    static func advice(_ issue: PrintIssue, language: String) -> String {
        let key: String
        switch issue.kind {
        case .image:
            switch issue.imageFailure {
            case .missing: key = "Image file not found: check its name and location in the source document."
            case .folderAccess:
                key = "Folder access is not allowed: allow access to the folder containing the document and its images."
            case .other, nil: key = "Check that the image is readable and in a supported format."
            }
        case .overflow: key = "Try landscape paper or smaller text, or adjust this element in the source document."
        case .math: key = "Check the formula's syntax and use supported commands in the source document."
        case .mermaid: key = "Check the Mermaid syntax and simplify the diagram in the source document."
        case .latex: key = "Replace this part with an image or supported LaTeX in the source document."
        }
        return PrintModeText.string(key, language: language)
    }
}
