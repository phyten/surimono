import AppKit
import SwiftUI

/// The find bar laid over the top right of the paper: the words, how many places hold them, and the way to the next
/// and the previous one.
struct FindBar: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            FindField(
                text: Bindable(model.find).text, focusRequests: model.find.focusRequests,
                onSubmit: { forward in model.findStep(forward: forward) },
                onCancel: { model.closeFind() }
            )
            .frame(width: 150)
            Text(verbatim: model.find.state.countText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("Matches")
                .accessibilityValue(Text(verbatim: model.find.state.countText))
            PanelIconButton("chevron.up", label: "Find Previous") { model.findStep(forward: false) }
            PanelIconButton("chevron.down", label: "Find Next") { model.findStep(forward: true) }
            PanelIconButton("xmark", label: "Close") { model.closeFind() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .paperOverlayBackground(cornerRadius: 10)
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// The bar's text field. An AppKit field, because it must take the keys as soon as the bar opens and tell Return from
/// Shift-Return and Esc, which the field editor reports as commands.
private struct FindField: NSViewRepresentable {
    @Binding var text: String
    let focusRequests: Int
    let onSubmit: (_ forward: Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.placeholderString = String(localized: "Find")
        field.setAccessibilityLabel(String(localized: "Find"))
        field.delegate = context.coordinator
        context.coordinator.focusRequests = focusRequests
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequests != focusRequests {
            context.coordinator.focusRequests = focusRequests
            field.takeFocus()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindField
        var focusRequests = 0

        init(_ parent: FindField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// A field that takes the keys when it comes on screen, with what it holds selected, so that typing replaces the
/// words of the last search.
final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocus()
    }

    func takeFocus() {
        // The window may still be laying the bar out; the field can only take the keys once it is in place.
        Task { @MainActor [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
            selectText(nil)
        }
    }
}

/// View › Go to Page…: asks for a page by the number the page indicator shows.
struct GoToPageSheet: View {
    @Bindable var model: DocumentViewModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page").font(.headline)
            HStack(spacing: 8) {
                TextField(String(model.currentPageIndex + 1), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($isFocused)
                    .accessibilityLabel("Page number")
                Text(verbatim: "1 – \(model.pageCount)").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.isGoToPagePresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { model.goToPage(entered: text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 260)
        .onAppear { isFocused = true }
    }
}
