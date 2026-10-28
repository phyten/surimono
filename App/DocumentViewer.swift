import AppKit
import PDFKit
import SurimonoCore
import SwiftUI

struct DocumentViewer: View {
    let document: SurimonoDocument
    let fileURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let fileURL {
                    Text(verbatim: fileURL.lastPathComponent)
                } else {
                    Text("Document")
                }
                Spacer()
                if let format = document.format {
                    Text(LocalizedStringKey(format.displayName))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown Format")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch document.format {
        case .pdf:
            if let pdf = PDFDocument(data: document.data) {
                PDFDocumentView(document: pdf)
            } else {
                Text("This PDF could not be opened.")
            }
        case .image:
            if let image = NSImage(data: document.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
            } else {
                Text("This image could not be opened.")
            }
        default:
            if let text = String(data: document.data, encoding: .utf8) {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                }
            } else {
                Text("This document is not UTF-8 text.")
            }
        }
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
