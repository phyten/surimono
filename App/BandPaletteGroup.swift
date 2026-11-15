import SurimonoCore
import SwiftUI

/// Display-only categories. Neither their order nor their local indices enter the saved arrangement.
enum BandPaletteGroup: CaseIterable {
    case movement, display, reading, bodyAndPaper, window, printingAndSaving, help

    var title: String {
        switch self {
        case .movement: String(localized: "Movement and Document Info")
        case .display: String(localized: "Display")
        case .reading: String(localized: "Reading")
        case .bodyAndPaper: String(localized: "Body and Paper")
        case .window: String(localized: "Window")
        case .printingAndSaving: String(localized: "Printing and Saving")
        case .help: String(localized: "Help")
        }
    }

    static func group(for item: BandLayout.Item) -> Self {
        switch item {
        case .formatBadge, .pageIndicator, .outline, .thumbnails, .pageTurn: .movement
        case .presentation, .layout, .transition, .zoom: .display
        case .readingDirection, .scrollDirection, .cover, .selectText: .reading
        case .style, .paperOrientation, .paperSeries, .margins, .ignoreSlides: .bodyAndPaper
        case .floatOnTop, .alwaysShowToolbar, .viewOptions: .window
        case .printSettings, .beforePrinting, .print, .saveAsFile: .printingAndSaving
        case .keysAndGestures: .help
        }
    }

    struct Part: Identifiable, Equatable {
        let id: BandLayout.Item
        let location: BandEntryLocation
    }

    struct Section: Identifiable, Equatable {
        let id: BandPaletteGroup
        let parts: [Part]
    }

    /// Enumerate before filtering so every drag and accessibility position refers to the original unused array.
    static func project(_ unused: [BandLayout.Item]) -> [Section] {
        allCases.compactMap { group in
            let parts = unused.enumerated().compactMap { index, item in
                Self.group(for: item) == group
                    ? Part(id: item, location: BandEntryLocation(destination: .unused, index: index)) : nil
            }
            return parts.isEmpty ? nil : Section(id: group, parts: parts)
        }
    }
}
