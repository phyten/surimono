import SurimonoCore
import SwiftUI

/// How the arrangement editor names and describes the band's parts. Stored arrangements keep only the stable IDs.
extension BandLayout.Item {
    var editorName: String {
        switch self {
        case .formatBadge: String(localized: "Format")
        case .pageIndicator: String(localized: "Page Indicator")
        case .presentation: String(localized: "Web or Paper")
        case .style: String(localized: "Style")
        case .outline: String(localized: "Contents")
        case .layout: String(localized: "View Type")
        case .transition: String(localized: "Page Turn")
        case .zoom: String(localized: "Zoom Level")
        // It lists the images of a bundle or the documents of a binder, not only thumbnails.
        case .thumbnails: String(localized: "List")
        case .floatOnTop: String(localized: "Float on Top")
        case .pageTurn: String(localized: "Previous / Next Page")
        case .print: String(localized: "Print")
        case .readingDirection: String(localized: "Reading Direction")
        case .scrollDirection: String(localized: "Scroll Direction")
        case .paperOrientation: String(localized: "Paper Orientation")
        case .paperSeries: String(localized: "Paper Series")
        case .cover: String(localized: "Show First Page Alone")
        case .selectText: String(localized: "Select Text")
        case .alwaysShowToolbar: String(localized: "Always Show Toolbar")
        case .margins: String(localized: "Margins")
        case .printSettings: String(localized: "Print Settings")
        case .ignoreSlides: String(localized: "Show as Slides")
        case .beforePrinting: String(localized: "Before Printing")
        case .viewOptions: String(localized: "View Options")
        case .saveAsFile: String(localized: "Save as File")
        case .keysAndGestures: String(localized: "Keys and Gestures")
        }
    }

    var editorDescription: String {
        switch self {
        case .formatBadge: String(localized: "Shows the document’s file type.")
        case .pageIndicator: String(localized: "Shows your page position; on paper, opens Document Info.")
        case .presentation: String(localized: "Switches an HTML document between web and paper views.")
        case .style: String(localized: "Chooses a print style or an HTML cleanup preset.")
        case .outline: String(localized: "Opens the document’s headings or PDF bookmarks.")
        case .layout: String(localized: "Switches between a single page and a spread.")
        case .transition: String(localized: "Chooses scrolling or a page-turn effect.")
        case .zoom: String(localized: "Shows the zoom while zoomed in; click to fit the window.")
        case .thumbnails: String(localized: "Opens the list of images in a bundle or documents in a binder.")
        case .floatOnTop: String(localized: "Keeps this window above other windows.")
        case .pageTurn: String(localized: "Moves to the previous or next page.")
        case .print: String(localized: "Opens the print screen. This part cannot be removed.")
        case .readingDirection: String(localized: "Chooses the reading direction and binding side.")
        case .scrollDirection: String(localized: "Chooses the scrolling direction.")
        case .paperOrientation: String(localized: "Chooses the paper orientation.")
        case .paperSeries: String(localized: "Chooses the paper series.")
        case .cover: String(localized: "Shows the first page alone in a spread.")
        case .selectText: String(localized: "Selects text on the paper.")
        case .alwaysShowToolbar: String(localized: "Keeps the toolbar visible.")
        case .margins: String(localized: "Sets the document margins.")
        case .printSettings: String(localized: "Opens the print settings panel.")
        case .ignoreSlides: String(localized: "Shows a page that looks like slides as a slide deck.")
        case .beforePrinting: String(localized: "Opens the issues to review before printing.")
        case .viewOptions: String(localized: "Opens the view options.")
        case .saveAsFile: String(localized: "Saves the original document to a new file.")
        case .keysAndGestures: String(localized: "Opens the keys and gestures guide.")
        }
    }

    /// When a window shows the part; nil for a part every window has. The editor shows every part regardless.
    var editorAvailability: String? {
        switch self {
        case .formatBadge, .floatOnTop, .print, .alwaysShowToolbar, .printSettings, .viewOptions, .keysAndGestures: nil
        case .pageIndicator: String(localized: "Appears for documents with pages, and for slides on the web.")
        case .presentation: String(localized: "Appears only for HTML documents.")
        case .style: String(localized: "Appears for documents that use a print style or an HTML preset.")
        case .outline: String(localized: "Appears for documents with headings or bookmarks.")
        case .layout, .transition: String(localized: "Appears on paper, not on a live web page.")
        case .zoom: String(localized: "Appears only while zoomed in.")
        case .thumbnails: String(localized: "Appears for image bundles and binders.")
        case .pageTurn: String(localized: "Appears for documents of more than one page, on paper.")
        case .readingDirection: String(localized: "Appears on paper, not on a live web page.")
        case .scrollDirection: String(localized: "Appears on paper; disabled when the page turn does not scroll.")
        case .paperOrientation: String(localized: "Appears on paper; disabled for a fixed paper orientation.")
        case .paperSeries: String(localized: "Appears for text documents and binders containing them.")
        case .cover: String(localized: "Appears when the paper view supports a separate cover.")
        case .selectText: String(localized: "Appears when text can be selected on paper.")
        case .margins: String(localized: "Appears when margins apply to the document.")
        case .ignoreSlides: String(localized: "Appears for HTML documents with detected slides.")
        case .beforePrinting: String(localized: "Appears when there are issues to review before printing.")
        case .saveAsFile: String(localized: "Appears for documents that can be saved to a new file.")
        }
    }
}

extension BandZoneID {
    var editorName: String {
        switch self {
        case .topLeft: String(localized: "Top Left")
        case .topRight: String(localized: "Top Right")
        case .bottomLeft: String(localized: "Bottom Left")
        case .bottomRight: String(localized: "Bottom Right")
        }
    }
}

extension BandDestination {
    var editorName: String {
        switch self {
        case .zone(let zone): zone.editorName
        case .unused: String(localized: "Not in Use")
        }
    }
}

/// A part drawn as the band draws it, small and inert: the same symbols and the same vermilion Print, with sample
/// values. Nothing here acts on a document.
struct BandPartGlyph: View {
    let item: BandLayout.Item
    /// Beside the part's name, where the List's own label would only repeat it.
    var besideName = false

    var sampleIssueCount: Int? { item == .beforePrinting && !besideName ? 2 : nil }

    var body: some View {
        switch item {
        case .formatBadge: FormatBadge(text: "MD")
        case .pageIndicator:
            Text(verbatim: "3 / 12").font(.system(size: 11)).monospacedDigit().foregroundStyle(PrintPalette.ink)
        case .presentation: Segments(symbols: ["globe", "doc.text"], selected: 1)
        case .style: WithChevron(symbol: "paintpalette")
        case .outline: symbol("list.bullet")
        case .layout:
            Segments(
                symbols: ViewOptions.Layout.displayOrder.map(\.symbol),
                selected: ViewOptions.Layout.displayOrder.firstIndex(of: .spread) ?? 0)
        case .transition: WithChevron(symbol: ViewOptions.Transition.scroll.symbol)
        case .zoom: Text(verbatim: "125%").font(.system(size: 11)).monospacedDigit().foregroundStyle(PrintPalette.ink)
        case .thumbnails:
            if besideName {
                symbol("square.grid.2x2")
            } else {
                Text("Images \(12)").font(.system(size: 11)).foregroundStyle(PrintPalette.ink).lineLimit(1)
            }
        case .floatOnTop: PinGlyph(isPinned: false).foregroundStyle(PrintPalette.ink).frame(width: 18, height: 18)
        case .pageTurn:
            HStack(spacing: 6) {
                symbol("chevron.left")
                symbol("chevron.right")
            }
        case .print: PrintGlyph()
        case .readingDirection, .scrollDirection, .paperOrientation, .paperSeries, .margins:
            WithChevron(symbol: item.additionalSymbol ?? "questionmark")
        case .beforePrinting:
            HStack(spacing: 3) {
                symbol("exclamationmark.triangle")
                if let sampleIssueCount { Text(verbatim: String(sampleIssueCount)).monospacedDigit() }
            }
        case .cover, .selectText, .alwaysShowToolbar, .printSettings, .ignoreSlides, .viewOptions,
            .saveAsFile, .keysAndGestures:
            symbol(item.additionalSymbol ?? "questionmark")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 12)).foregroundStyle(PrintPalette.ink)
    }

    private struct WithChevron: View {
        let symbol: String
        var body: some View {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 12))
                BandMenuChevron()
            }
            .foregroundStyle(PrintPalette.ink)
        }
    }

    /// A segmented control's look: the chosen segment filled in the accent color.
    private struct Segments: View {
        let symbols: [String]
        let selected: Int

        var body: some View {
            HStack(spacing: 1) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .frame(width: 20, height: 15)
                        .foregroundStyle(index == selected ? AnyShapeStyle(.white) : AnyShapeStyle(PrintPalette.ink))
                        .background {
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(index == selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                        }
                }
            }
            .padding(1)
            .background(RoundedRectangle(cornerRadius: 4.5).fill(.quaternary))
        }
    }
}

/// The band's Print button as a picture: vermilion is the color of printing, and it never prints from here.
struct PrintGlyph: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "printer").font(.system(size: 10, weight: .medium))
            Text("Print").font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 5).fill(PrintPalette.shu))
    }
}

extension BandRepairNotice {
    /// Whether loading changed or left out something that was saved, rather than only adding a newer version's part
    /// to "Not in Use" or keeping an unknown one aside.
    var losesData: Bool {
        switch self {
        case .addedToUnused, .unknownID: false
        default: true
        }
    }

    /// What the editor tells about the repair; nil for what needs no word or what the recovery notice covers.
    var editorText: String? {
        switch self {
        case .invalidRecord, .duplicateIdentity, .duplicateName:
            String(localized: "A saved arrangement could not be read and was left out.")
        case .recoveredVariant:
            String(localized: "A layout of a saved arrangement could not be read and is back to Standard.")
        case .missingActiveSet:
            String(localized: "The arrangement in use could not be found, so Standard is used.")
        case .duplicate, .restoredPrint, .movedBottomZones, .removedUnusedSeparator:
            String(localized: "Some parts of a saved arrangement were out of place and were put back.")
        case .addedToUnused, .unknownID, .malformedStore, .unsupportedSchema:
            nil
        }
    }
}
