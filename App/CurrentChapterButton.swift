import AppKit
import SurimonoCore
import SwiftUI

extension EnvironmentValues {
    /// The title's frame the bottom band's plan gives the chapter part (`BandRowPlan.chapterTitleWidth`). Nil where the
    /// part keeps the room of its widest title, as on the top band and in the measurements.
    @Entry var bandChapterTitleWidth: CGFloat? = nil
}

struct CurrentChapterButton: View {
    @Bindable var model: DocumentViewModel
    var trailing: Bool
    /// A frame of the caller's own, for measuring the part around the title.
    var titleWidth: CGFloat? = nil

    @Environment(\.bandChapterTitleWidth) private var plannedTitleWidth

    private static let maximumTitleWidth: CGFloat = 180
    private static let fontSize: CGFloat = 12

    static func titleText(_ title: String) -> Text { Text(verbatim: title).font(.system(size: fontSize)) }

    /// Whether the whole title shows in its frame: the planned one on the bottom band, the widest otherwise.
    static func titleFits(_ text: String, in frame: CGFloat? = nil) -> Bool {
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return width <= (frame ?? maximumTitleWidth) + 0.5
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
            if let width = titleWidth ?? plannedTitleWidth {
                // One line in the planned frame, the end cut with "…": never smaller type, two lines or a middle cut.
                Text(verbatim: title)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: width, alignment: alignment)
                    .font(.system(size: Self.fontSize))
                    .contentShape(Rectangle())
            } else {
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
        }
        .buttonStyle(BandStatePlate(on: model.isOutlineShown))
    }
}
