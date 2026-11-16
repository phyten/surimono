import AppKit
import Observation
import SurimonoCore
import SwiftUI

/// The question for text whose format the detector is unsure of: a sheet on the document window in front, or a small
/// window of its own when there is none. Only one is open at a time.
enum ClipboardQuestionPanel {
    private static var current: QuestionWindow?

    static func present(
        _ question: ClipboardQuestion, source: ClipboardTextSource, over parent: NSWindow?,
        completion: @escaping (ClipboardTextKind?) -> Void
    ) {
        let window = QuestionWindow()
        let state = ClipboardQuestionState(question: question, source: source) { [weak window] kind in
            window?.finish(kind)
        }
        window.completion = { kind in
            current = nil
            completion(kind)
        }
        let host = NSHostingController(rootView: ClipboardQuestionView(state: state))
        // The window takes the question's own height, which depends on its rows and the language.
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        current = window
        if let parent, DocumentWindows.shared.model(for: parent) != nil, parent.isVisible, parent.attachedSheet == nil {
            parent.beginSheet(window)
        } else {
            window.title = "Surimono"
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    static func bringForward() {
        guard let window = current else { return }
        if let parent = window.sheetParent {
            parent.makeKeyAndOrderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// The window currently asking, for screenshots.
    static var window: NSWindow? { current }
}

private final class QuestionWindow: NSWindow, NSWindowDelegate {
    var completion: ((ClipboardTextKind?) -> Void)?
    private var finished = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        // The washi color runs up under the title bar, as in the welcome window.
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        delegate = self
    }

    func finish(_ kind: ClipboardTextKind?) {
        guard !finished else { return }
        finished = true
        if let parent = sheetParent { parent.endSheet(self) } else { close() }
        let completion = completion
        self.completion = nil
        completion?(kind)
    }

    // The close button of the window on its own is Cancel.
    func windowWillClose(_ notification: Notification) { finish(nil) }
}

@Observable
final class ClipboardQuestionState {
    let question: ClipboardQuestion
    let source: ClipboardTextSource
    var selection: ClipboardTextKind
    private let answer: (ClipboardTextKind?) -> Void

    init(question: ClipboardQuestion, source: ClipboardTextSource, answer: @escaping (ClipboardTextKind?) -> Void) {
        self.question = question
        self.source = source
        selection = question.preferred
        self.answer = answer
    }

    var title: String {
        switch source {
        case .clipboard: String(localized: "How should the clipboard’s contents open?")
        case .selection: String(localized: "How should the selected text open?")
        }
    }

    /// Up and down move through the rows and stop at their ends.
    func move(by step: Int) {
        let kinds = question.options.map(\.kind)
        guard let index = kinds.firstIndex(of: selection) else { return }
        selection = kinds[min(max(index + step, 0), kinds.count - 1)]
    }

    func open(_ kind: ClipboardTextKind? = nil) { answer(kind ?? selection) }
    func cancel() { answer(nil) }
}

struct ClipboardQuestionView: View {
    @Bindable var state: ClipboardQuestionState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            preview
            rows
            buttons
            Text("↑↓ to choose · Return to open · Esc to cancel")
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .overlay(alignment: .top) { PrintPalette.line.frame(height: 1).offset(y: -6) }
        }
        .padding(18)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(PrintPalette.chrome)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) {
            state.move(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.move(by: 1)
            return .handled
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: state.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(PrintPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: ClipboardFormatText.reason(state.question))
                    .font(.system(size: 12))
                    .foregroundStyle(PrintPalette.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.question.preview.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.isEmpty ? " " : line).lineLimit(1).truncationMode(.tail)
            }
            if state.question.isPreviewCut { Text(verbatim: "…") }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(PrintPalette.ink2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(PrintPalette.press))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Beginning of the text"))
    }

    private var rows: some View {
        VStack(spacing: 6) {
            ForEach(state.question.options, id: \.kind) { option in
                ClipboardQuestionRow(option: option, isSelected: state.selection == option.kind) {
                    state.selection = option.kind
                } open: {
                    state.open(option.kind)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            if !state.question.others.isEmpty {
                Menu("Other Formats") {
                    ForEach(state.question.others, id: \.kind) { option in
                        Button {
                            state.open(option.kind)
                        } label: {
                            Text(
                                verbatim: ClipboardFormatText.name(option.kind) + " — "
                                    + ClipboardFormatText.result(option.kind))
                        }
                    }
                }
                .fixedSize()
                .help("Opens the text in a format that is not listed")
            }
            Spacer(minLength: 12)
            Button("Cancel") { state.cancel() }
                .keyboardShortcut(.cancelAction)
            // "Open" alone is already the key of an open state, worded differently in other languages.
            Button("Open Chosen Format") { state.open() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ClipboardQuestionRow: View {
    let option: ClipboardQuestion.Option
    let isSelected: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        let name = ClipboardFormatText.name(option.kind)
        let result = ClipboardFormatText.result(option.kind)
        let evidence = ClipboardFormatText.evidence(of: option)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (Text(verbatim: name).bold() + Text(verbatim: " — " + result))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if isSelected {
                        // The key that opens the selected row, as the menus draw it.
                        Text(verbatim: "↩").font(.system(size: 11)).opacity(0.85).accessibilityHidden(true)
                    }
                }
                Text(verbatim: evidence)
                    .font(.system(size: 11.5))
                    .opacity(0.88)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? PrintPalette.raised : PrintPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? PrintPalette.ai : PrintPalette.raised))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? PrintPalette.ai : PrintPalette.line2))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(open))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name + " — " + result))
        .accessibilityValue(Text(verbatim: evidence))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Open Chosen Format")) { open() }
    }
}
