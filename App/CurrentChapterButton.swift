import AppKit
import SurimonoCore
import SwiftUI

struct CurrentChapterButton: View {
    @Bindable var model: DocumentViewModel
    var trailing: Bool

    private var widestTitle: String {
        let font = NSFont.systemFont(ofSize: 11)
        return model.chapterEntries.map(\.title).max {
            ($0 as NSString).size(withAttributes: [.font: font]).width
                < ($1 as NSString).size(withAttributes: [.font: font]).width
        } ?? ""
    }

    var body: some View {
        let title = model.currentChapterTitle
        let alignment: Alignment = trailing ? .trailing : .leading
        Button {
            model.toggleOutline()
        } label: {
            Text(verbatim: widestTitle)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 180, alignment: alignment)
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .overlay(alignment: alignment) {
                    Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: alignment)
                }
                .font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((title.isEmpty ? "" : title + "\n") + ShortcutHints.help(String(localized: "Contents"), [.viewOutline]))
        .accessibilityLabel(Text(verbatim: String(localized: "Current Chapter") + ": " + title))
    }
}
