import AppKit
import SurimonoCore
import SwiftUI

struct CurrentChapterButton: View {
    @Bindable var model: DocumentViewModel
    var trailing: Bool

    private static let maximumTitleWidth: CGFloat = 180
    private static let fontSize: CGFloat = 12

    static func titleFits(_ text: String) -> Bool {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width <= maximumTitleWidth
    }

    private var widestTitle: String {
        let font = NSFont.systemFont(ofSize: Self.fontSize)
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
                .frame(maxWidth: Self.maximumTitleWidth, alignment: alignment)
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .overlay(alignment: alignment) {
                    Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: alignment)
                }
                .font(.system(size: Self.fontSize))
                .contentShape(Rectangle())
        }
        .buttonStyle(BandStatePlate(on: model.isOutlineShown))
    }
}
