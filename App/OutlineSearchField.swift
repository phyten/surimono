import AppKit
import SwiftUI

struct OutlineSearchField: NSViewRepresentable {
    @Bindable var model: DocumentViewModel
    var autofocus: Bool

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.autofocus = autofocus
        field.placeholderString = String(localized: "Filter Headings")
        field.setAccessibilityLabel(String(localized: "Filter Headings"))
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        if field.stringValue != model.outlineFilter.query { field.stringValue = model.outlineFilter.query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Field: NSSearchField {
        var autofocus = false
        private var didAutofocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard autofocus, !didAutofocus, window != nil else { return }
            didAutofocus = true
            // SwiftUI may create the field before attaching the popover's window.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: DocumentViewModel
        init(model: DocumentViewModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.outlineFilter.setQuery(field.stringValue, entries: model.outlineEntries)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Composition owns its confirmation and cursor keys before the outline can interpret them.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                model.outlineFilter.move(by: 1)
            case #selector(NSResponder.moveUp(_:)):
                model.outlineFilter.move(by: -1)
            case #selector(NSResponder.insertNewline(_:)):
                if let entry = model.outlineFilter.submit(entries: model.outlineEntries) {
                    model.goToOutlineEntry(entry)
                    model.paper.focus()
                }
            case #selector(NSResponder.cancelOperation(_:)):
                if model.outlineFilter.escape(entries: model.outlineEntries) {
                    model.isOutlinePresented = false
                    model.paper.focus()
                }
            default: return false
            }
            return true
        }
    }
}
