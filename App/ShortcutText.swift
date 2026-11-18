import Foundation
import SurimonoCore

enum ShortcutText {
    /// The names of the print layouts break into two lines for their cards; a list row shows one line.
    static func name(_ value: ShortcutOperationID) -> String {
        String(localized: nameResource(value)).replacingOccurrences(of: "\n", with: "")
    }

    static func nameResource(_ value: ShortcutOperationID) -> LocalizedStringResource {
        switch value {
        case .readingBack: "Back"
        case .readingForward: "Forward"
        case .bookmarkToggle: "Bookmark This Page"
        case .bookmarkNext: "Next Bookmark"
        case .bookmarkPrevious: "Previous Bookmark"
        case .appOpen: "Open…"
        case .clipboardOpen: "Open from Clipboard"
        case .appSettings: "Settings…"
        case .documentPrint: "Print…"
        case .documentPrintSystem: "Print with System Dialog…"
        case .documentExportPDF: "PDF of the Sheets…"
        case .documentExportReadingPDF: "PDF for Reading…"
        case .documentExportPNG: "Images (PNG)…"
        case .documentExportHTML: "HTML…"
        case .documentCopyHTML: "Copy as HTML"
        case .documentCopyRichText: "Copy as Rich Text"
        case .documentShare: "Share PDF…"
        case .documentFind: "Find…"
        case .documentFindNext: "Find Next"
        case .documentFindPrevious: "Find Previous"
        case .documentGoToPage: "Go to Page…"
        case .documentReload: "Reload"
        case .viewHtmlPresentation: "Web or Paper"
        case .viewSpread: "Spread"
        case .viewSingle: "Single Page"
        case .textIncrease: "Increase Text Size"
        case .textDecrease: "Decrease Text Size"
        case .textReset: "Original Text Size"
        case .viewZoomIn: "Zoom In"
        case .viewZoomOut: "Zoom Out"
        case .viewZoomFit: "Fit to Window"
        case .viewToolbarAlways: "Always Show Toolbar"
        case .viewToolbarToggle: "Show / Hide Toolbar"
        case .viewOptions: "View Options…"
        case .viewSelectText: "Select Text"
        case .readingLeft: "Navigate Left"
        case .readingRight: "Navigate Right"
        case .readingPrevious: "Previous Page"
        case .readingNext: "Next Page"
        case .readingPageUp: "Page Up"
        case .readingPageDown: "Page Down"
        case .readingFirst: "Beginning of Document"
        case .readingLast: "End of Document"
        case .printLayoutSingle: "Single-sided"
        case .printLayoutDuplex: "Double-Sided"
        case .printLayoutBookletLarge: "Booklet on Large Paper"
        case .printLayoutBookletSmall: "Booklet on Small Paper"
        case .printLayoutTwoUpLarge: "Two Pages on Large Paper"
        case .printLayoutHandout: "3 Pages + Notes Column"
        case .listToggle: "Show List"
        case .listMoveUp: "Move Document Up"
        case .listMoveDown: "Move Document Down"
        case .listRemove: "Remove from List"
        case .foldLeft: "Turn Folded Preview Left"
        case .foldRight: "Turn Folded Preview Right"
        case .globalClipboardOpen: "Open from Clipboard"
        case .globalClipboardPrintScreen: "Open Clipboard on the Print Screen"
        case .clipboardOpenPrintScreen: "Open Clipboard on the Print Screen"
        case .appStreamingPreview: "Streaming Preview"
        case .appGettingStarted: "Getting Started with Surimono"
        case .appKeyGuide: "Keys and Gestures"
        case .appCheckUpdates: "Check for Updates…"
        case .documentSaveAsFile: "Save as File…"
        case .documentAdd: "Add Documents…"
        case .documentOpenBinder: "Open as Binder"
        case .documentResetSettings: "Reset Document Settings"
        case .printSettings: "Print Settings…"
        case .styleChoose: "Choose Style…"
        case .printLayoutTwoUpSmall: "Two Pages on Small Paper"
        case .printLayoutFourUp: "4 Pages on One Sheet"
        case .settingSetSave: "Save Current Settings…"
        case .settingSetManage: "Manage Setting Sets…"
        case .viewFloatOnTop: "Float on Top"
        case .viewShowOnAllSpaces: "Show on All Spaces"
        case .viewOutline: "Contents"
        case .viewDocumentInfo: "Document Info…"
        case .viewIgnoreSlides: "Show as Slides"
        case .listSortByName: "Sort by Name"
        case .binderOddPageStarts: "Start Each Document on an Odd Page"
        case .styleCompare: "Compare Styles"
        case .styleFavorite: "Add to Favorites"
        case .compareShuffle: "Shuffle"
        case .printFoldPreview: "See It Folded"
        case .printReviewIssues: "Before Printing"
        case .htmlSmartRemoval: "Smart Removal (Beta)"
        case .htmlReviewRemoval: "Review Removed Parts…"
        case .printManualDuplex: "Print Both Sides Manually…"
        case .printDuplexTest: "Duplex Test Print…"
        }
    }

    static func group(_ value: ShortcutGroup) -> String {
        switch value {
        case .application: String(localized: "Application")
        case .documentAndPrinting: String(localized: "Document and Printing")
        case .reading: String(localized: "Reading")
        case .styles: String(localized: "Styles")
        case .lists: String(localized: "Lists")
        case .global: String(localized: "Global")
        }
    }

    static func scope(_ value: ShortcutApplicability) -> String {
        switch value {
        case .application: String(localized: "In any Surimono window")
        case .document: String(localized: "In a document window")
        case .paper: String(localized: "On the paper in view mode")
        case .paperWithPages: String(localized: "On paper with pages")
        case .html: String(localized: "In HTML documents")
        case .themedText: String(localized: "In documents that use styles")
        case .selectableText: String(localized: "On paper with selectable text")
        case .memoryDocument: String(localized: "In documents created from memory")
        case .addDocuments: String(localized: "In documents that accept additions")
        case .includePlan: String(localized: "In documents with included files")
        case .binderOrImages: String(localized: "In binders and image bundles")
        case .binder: String(localized: "In binders")
        case .booklet: String(localized: "In booklet print previews")
        case .updater: String(localized: "When the updater is available")
        case .outline: String(localized: "In view mode with contents")
        case .documentInfo: String(localized: "In view mode with document information")
        }
    }

    static func fixedName(_ value: ShortcutFixedKey.Behavior) -> String { String(localized: fixedResource(value)) }

    static func fixedResource(_ value: ShortcutFixedKey.Behavior) -> LocalizedStringResource {
        switch value {
        case .cancellation: "Cancel"
        case .confirmation: "Confirm"
        case .findSubmission: "Submit Find"
        case .focusTraversal: "Move Keyboard Focus"
        case .paperToolbar: "Show / Hide Toolbar"
        case .controlActivation: "Activate Focused Control"
        case .nativeEditing: "Text Editing and Selection"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .undo: "Undo"
        case .redo: "Redo"
        case .pasteMatchingStyle: "Paste and Match Style"
        case .closeWindow: "Close Window"
        case .quit: "Quit Surimono"
        case .hide: "Hide Surimono"
        case .minimize: "Minimize"
        case .fullScreen: "Full Screen"
        case .cycleWindows: "Cycle Windows"
        case .documentSaving: "Document Saving"
        }
    }

    static func fixedReason(_ value: ShortcutFixedKey.Behavior) -> String {
        switch value {
        case .cancellation: String(localized: "Keeps cancellation available in every window.")
        case .confirmation: String(localized: "Keeps default buttons and text submission available.")
        case .findSubmission: String(localized: "Return and Shift-Return move through results in the Find field.")
        case .focusTraversal: String(localized: "Keeps keyboard and accessibility navigation available.")
        case .paperToolbar: String(localized: "Tab belongs to focus navigation and the paper toolbar.")
        case .controlActivation: String(localized: "Space activates the focused control.")
        case .nativeEditing: String(localized: "Keeps native text editing, selection and input methods available.")
        case .copy: String(localized: "Keeps native text editing, selection and input methods available.")
        case .cut: String(localized: "Keeps native text editing, selection and input methods available.")
        case .paste: String(localized: "Keeps native text editing, selection and input methods available.")
        case .selectAll: String(localized: "Keeps native text editing, selection and input methods available.")
        case .undo: String(localized: "Keeps native text editing, selection and input methods available.")
        case .redo: String(localized: "Keeps native text editing, selection and input methods available.")
        case .pasteMatchingStyle: String(localized: "Keeps native text editing, selection and input methods available.")
        case .closeWindow: String(localized: "Managed by macOS window and application controls.")
        case .quit: String(localized: "Managed by macOS window and application controls.")
        case .hide: String(localized: "Managed by macOS window and application controls.")
        case .minimize: String(localized: "Managed by macOS window and application controls.")
        case .fullScreen: String(localized: "Managed by macOS window and application controls.")
        case .cycleWindows: String(localized: "Managed by macOS window and application controls.")
        case .documentSaving:
            String(localized: "Surimono never changes the original document; these keys stay disabled.")
        }
    }

    static func reason(_ value: ShortcutValidationIssue.Code) -> String {
        switch value {
        case .invalidKey, .invalidModifiers, .wrongKeyKind: String(localized: "This key combination is not supported.")
        case .modifierRequired, .globalModifierRequired:
            String(localized: "Include Command, Option or Control in a global shortcut.")
        case .spotlight: String(localized: "Reserved for Spotlight.")
        case .inputSource: String(localized: "Reserved for switching input sources.")
        case .applicationSwitching, .forceQuit, .sessionControl, .workspaceNavigation:
            String(localized: "Reserved for macOS application and workspace controls.")
        case .keyboardNavigation, .accessibility, .voiceOver, .focusNavigation:
            String(localized: "Reserved for keyboard navigation and accessibility.")
        case .screenCapture: String(localized: "Reserved for screen capture.")
        case .cancellation: String(localized: "Escape is reserved for cancellation.")
        case .confirmation: String(localized: "Return and Enter are reserved for confirmation.")
        case .fixedOperation: String(localized: "Reserved for a fixed editing or window operation.")
        case .documentSaving:
            String(localized: "Surimono never changes the original document; these keys stay disabled.")
        case .systemReserved: String(localized: "This key is enabled in macOS Keyboard Shortcuts.")
        case .systemReservationsUnavailable, .layoutProjectionUnavailable:
            String(localized: "System shortcuts or the keyboard layout could not be read. Try again.")
        case .conflict: String(localized: "Another operation uses this key.")
        case .malformedLegacy: String(localized: "The previous shortcut could not be read. Record a new shortcut.")
        }
    }

}

extension ShortcutText {
    /// Shown before accepting every output-capable assignment, including restoring or transferring a key.
    static func outputWarning(_ operation: ShortcutOperationID) -> String? {
        switch operation {
        case .documentPrint:
            String(localized: "Opens the print screen; a new press there prints to the selected printer.")
        case .documentPrintSystem:
            String(localized: "This key opens the system print dialog after preparing the print screen.")
        case .documentExportPNG, .documentExportHTML, .documentCopyHTML, .documentCopyRichText, .documentShare:
            String(localized: "This key exports or shares the document in reading order.")
        case .documentExportReadingPDF:
            String(localized: "This key opens the save dialog for a PDF in reading order.")
        case .documentExportPDF:
            String(localized: "This key prepares the print screen and opens the PDF save dialog.")
        case .printManualDuplex:
            String(
                localized:
                    "On the print screen, this key sends the fronts to the selected printer and starts manual duplex printing."
            )
        case .printDuplexTest:
            String(localized: "On the print screen, this key sends a duplex test sheet to the selected printer.")
        default: nil
        }
    }
}
