import Foundation
import SurimonoCore

enum ShortcutText {
    /// The names of the print layouts break into two lines for their cards; a list row shows one line.
    static func name(_ value: ShortcutOperationID) -> String {
        cardName(value).replacingOccurrences(of: "\n", with: "")
    }

    private static func cardName(_ value: ShortcutOperationID) -> String {
        switch value {
        case .readingBack: String(localized: "Back")
        case .readingForward: String(localized: "Forward")
        case .bookmarkToggle: String(localized: "Bookmark This Page")
        case .bookmarkNext: String(localized: "Next Bookmark")
        case .bookmarkPrevious: String(localized: "Previous Bookmark")
        case .appOpen: String(localized: "Open…")
        case .clipboardOpen: String(localized: "Open from Clipboard")
        case .appSettings: String(localized: "Settings…")
        case .documentPrint: String(localized: "Print…")
        case .documentPrintSystem: String(localized: "Print with System Dialog…")
        case .documentExportPDF: String(localized: "PDF of the Sheets…")
        case .documentExportReadingPDF: String(localized: "PDF for Reading…")
        case .documentExportPNG: String(localized: "Images (PNG)…")
        case .documentExportHTML: String(localized: "HTML…")
        case .documentCopyRichText: String(localized: "Copy as Rich Text")
        case .documentCopyHTML: String(localized: "Copy as HTML")
        case .documentShare: String(localized: "Share…")
        case .documentFind: String(localized: "Find…")
        case .documentFindNext: String(localized: "Find Next")
        case .documentFindPrevious: String(localized: "Find Previous")
        case .documentGoToPage: String(localized: "Go to Page…")
        case .documentReload: String(localized: "Reload")
        case .viewHtmlPresentation: String(localized: "Web or Paper")
        case .viewSpread: String(localized: "Spread")
        case .viewSingle: String(localized: "Single Page")
        case .textIncrease: String(localized: "Increase Text Size")
        case .textDecrease: String(localized: "Decrease Text Size")
        case .textReset: String(localized: "Original Text Size")
        case .viewZoomIn: String(localized: "Zoom In")
        case .viewZoomOut: String(localized: "Zoom Out")
        case .viewZoomFit: String(localized: "Fit to Window")
        case .viewToolbarAlways: String(localized: "Always Show Toolbar")
        case .viewToolbarToggle: String(localized: "Show / Hide Toolbar")
        case .viewOptions: String(localized: "View Options…")
        case .viewSelectText: String(localized: "Select Text")
        case .readingLeft: String(localized: "Navigate Left")
        case .readingRight: String(localized: "Navigate Right")
        case .readingPrevious: String(localized: "Previous Page")
        case .readingNext: String(localized: "Next Page")
        case .readingPageUp: String(localized: "Page Up")
        case .readingPageDown: String(localized: "Page Down")
        case .readingFirst: String(localized: "Beginning of Document")
        case .readingLast: String(localized: "End of Document")
        case .printLayoutSingle: String(localized: "Single-sided")
        case .printLayoutDuplex: String(localized: "Double-Sided")
        case .printLayoutBookletLarge: String(localized: "Booklet on Large Paper")
        case .printLayoutBookletSmall: String(localized: "Booklet on Small Paper")
        case .printLayoutTwoUpLarge: String(localized: "Two Pages on Large Paper")
        case .printLayoutHandout: String(localized: "3 Pages + Notes Column")
        case .listToggle: String(localized: "Show List")
        case .listMoveUp: String(localized: "Move Document Up")
        case .listMoveDown: String(localized: "Move Document Down")
        case .listRemove: String(localized: "Remove from List")
        case .foldLeft: String(localized: "Turn Folded Preview Left")
        case .foldRight: String(localized: "Turn Folded Preview Right")
        case .globalClipboardOpen: String(localized: "Open from Clipboard")
        case .globalClipboardPrintScreen: String(localized: "Open Clipboard on the Print Screen")
        case .clipboardOpenPrintScreen: String(localized: "Open Clipboard on the Print Screen")
        case .appStreamingPreview: String(localized: "Streaming Preview")
        case .appGettingStarted: String(localized: "Getting Started with Surimono")
        case .appKeyGuide: String(localized: "Keys and Gestures")
        case .appCheckUpdates: String(localized: "Check for Updates…")
        case .documentSaveAsFile: String(localized: "Save as File…")
        case .documentAdd: String(localized: "Add Documents…")
        case .documentOpenBinder: String(localized: "Open as Binder")
        case .documentResetSettings: String(localized: "Reset Document Settings")
        case .printSettings: String(localized: "Print Settings…")
        case .styleChoose: String(localized: "Choose Style…")
        case .printLayoutTwoUpSmall: String(localized: "Two Pages on Small Paper")
        case .printLayoutFourUp: String(localized: "4 Pages on One Sheet")
        case .settingSetSave: String(localized: "Save Current Settings…")
        case .settingSetManage: String(localized: "Manage Setting Sets…")
        case .viewFloatOnTop: String(localized: "Float on Top")
        case .viewOutline: String(localized: "Contents")
        case .viewDocumentInfo: String(localized: "Document Info…")
        case .viewIgnoreSlides: String(localized: "Show as Slides")
        case .listSortByName: String(localized: "Sort by Name")
        case .binderOddPageStarts: String(localized: "Start Each Document on an Odd Page")
        case .styleCompare: String(localized: "Compare Styles")
        case .styleFavorite: String(localized: "Add to Favorites")
        case .compareShuffle: String(localized: "Shuffle")
        case .printFoldPreview: String(localized: "See It Folded")
        case .printReviewIssues: String(localized: "Before Printing")
        case .htmlSmartRemoval: String(localized: "Smart Removal (Beta)")
        case .htmlReviewRemoval: String(localized: "Review Removed Parts…")
        case .printManualDuplex: String(localized: "Print Both Sides Manually…")
        case .printDuplexTest: String(localized: "Duplex Test Print…")
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

    static func fixedName(_ value: ShortcutFixedKey.Behavior) -> String {
        switch value {
        case .cancellation: String(localized: "Cancel")
        case .confirmation: String(localized: "Confirm")
        case .findSubmission: String(localized: "Submit Find")
        case .focusTraversal: String(localized: "Move Keyboard Focus")
        case .paperToolbar: String(localized: "Show / Hide Toolbar")
        case .controlActivation: String(localized: "Activate Focused Control")
        case .nativeEditing: String(localized: "Text Editing and Selection")
        case .copy: String(localized: "Copy")
        case .cut: String(localized: "Cut")
        case .paste: String(localized: "Paste")
        case .selectAll: String(localized: "Select All")
        case .undo: String(localized: "Undo")
        case .redo: String(localized: "Redo")
        case .pasteMatchingStyle: String(localized: "Paste and Match Style")
        case .closeWindow: String(localized: "Close Window")
        case .quit: String(localized: "Quit Surimono")
        case .hide: String(localized: "Hide Surimono")
        case .minimize: String(localized: "Minimize")
        case .fullScreen: String(localized: "Full Screen")
        case .cycleWindows: String(localized: "Cycle Windows")
        case .documentSaving: String(localized: "Document Saving")
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
        case .documentExportPNG, .documentExportHTML, .documentCopyRichText, .documentCopyHTML, .documentShare:
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
