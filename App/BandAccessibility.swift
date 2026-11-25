import SurimonoCore
import SwiftUI

extension BandLayout.Item {
    /// The narrow band names the action even when its visible label is a symbol or the current value.
    var bandAccessibilityName: LocalizedStringKey {
        switch self {
        case .formatBadge: "LaTeX Layout"
        case .pageIndicator: "Go to Page"
        case .zoom: "Fit to Window"
        case .thumbnails: "Pages Tab"
        default: LocalizedStringKey(editorNameResource.key)
        }
    }

    func bandAccessibilityValue(
        choice: String? = nil, checked: Bool? = nil, isOpen: Bool = false, issueCount: @autoclosure () -> Int = 0
    ) -> String {
        if self == .beforePrinting { return issueCount().formatted() }
        if let choice { return choice }
        if let checked { return checked ? String(localized: "On") : String(localized: "Off") }
        if self == .viewOptions || self == .printSettings {
            return isOpen ? String(localized: "Open") : String(localized: "Closed")
        }
        return ""
    }
}

enum BandAccessibility {
    static let more: LocalizedStringKey = "More"

    static func documents(_ count: Int) -> LocalizedStringResource { "Documents \(count)" }

    static func readingChanges(_ count: Int) -> LocalizedStringResource {
        "Changed in This Document: \(count)"
    }

    static func zoomPercentage(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }

    static func zoomValue(_ zoom: Double, locale: Locale) -> String {
        zoom.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    static func pageIndicator(_ indicator: String?, bookmarked: Bool) -> String {
        [indicator, bookmarked ? String(localized: "Bookmarked") : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

enum BandStyleAccessibility {
    case theme(String?)
    case preset(String?, smartRemoval: Bool)

    var name: LocalizedStringResource {
        switch self {
        case .theme: BandLayout.Item.style.editorNameResource
        case .preset: "HTML Preset"
        }
    }

    var value: String {
        switch self {
        case .theme(let name): return name ?? String(localized: "Not Found")
        case .preset(let name, let smartRemoval):
            let preset = name ?? String(localized: "Not Found")
            return smartRemoval ? choice(preset, String(localized: "Smart Removal")) : preset
        }
    }
}
