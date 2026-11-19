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
            // A sheet can also end because its parent goes away or someone else ends it; the question still finishes.
            window.watchClosing(of: parent)
            parent.beginSheet(window) { [weak window] _ in window?.finish(nil, endsSheet: false) }
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

    private var parentObserver: (any NSObjectProtocol)?

    /// Finishes the question, unanswered, when the window it is a sheet on closes.
    func watchClosing(of parent: NSWindow) {
        parentObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: parent, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    /// Delivers the answer exactly once, whichever way the question ends. `endsSheet` is false when the sheet has
    /// already ended, from its own completion handler.
    func finish(_ kind: ClipboardTextKind?, endsSheet: Bool = true) {
        guard !finished else { return }
        finished = true
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        if let parent = sheetParent {
            if endsSheet { parent.endSheet(self) }
        } else if endsSheet {
            close()
        }
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
        case .clipboard: String(localized: "Which format should the clipboard’s text open in?")
        case .url: String(localized: "Which format should the downloaded text open in?")
        case .selection: String(localized: "Which format should the selected text open in?")
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
        .background(CornerRole.control.shape.fill(PrintPalette.raised))
        .overlay(CornerRole.control.shape.strokeBorder(PrintPalette.line2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Beginning of the text"))
    }

    /// One list in one box, marked the way a single-selection list marks its row.
    private var rows: some View {
        let options = state.question.options
        return VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.kind) { index, option in
                if index > 0 {
                    // As in a list, no line runs beside the selected row.
                    let besideSelection = state.selection == option.kind || state.selection == options[index - 1].kind
                    PrintPalette.line.frame(height: 1).padding(.horizontal, 8).opacity(besideSelection ? 0 : 1)
                }
                ClipboardQuestionRow(option: option, isSelected: state.selection == option.kind) {
                    state.selection = option.kind
                } open: {
                    state.open(option.kind)
                }
            }
        }
        .padding(ListMetrics.inset)
        .background(CornerRole.tile.shape.fill(PrintPalette.raised))
        .overlay(CornerRole.tile.shape.strokeBorder(PrintPalette.line2))
    }

    private var buttons: some View {
        HStack {
            if !state.question.others.isEmpty {
                Menu("Other Formats") {
                    ForEach(state.question.others, id: \.kind) { option in
                        Button {
                            state.open(option.kind)
                        } label: {
                            Text(verbatim: ClipboardFormatText.name(option.kind))
                        }
                    }
                }
                .fixedSize()
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

/// The inset keeps the selection inside the box of choices.
private enum ListMetrics {
    static let inset: CGFloat = 4
}

private struct ClipboardQuestionRow: View {
    let option: ClipboardQuestion.Option
    @Environment(\.self) private var environment
    let isSelected: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        let name = ClipboardFormatText.name(option.kind)
        let ground = Color(nsColor: .selectedContentBackgroundColor)
        let selectedInk = DisplayAccessibility.selectionInk(on: ground.resolve(in: environment))
        let evidence = ClipboardFormatText.evidence(of: option)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .emphasisForDisplayContrast(isSelected)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? selectedInk : PrintPalette.ink)
                Text(verbatim: evidence)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isSelected
                            ? selectedInk : PrintPalette.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    CornerRole.badge.shape
                        .fill(ground)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(open))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: evidence))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // The element above replaces the button's own, and with it the press: without this, VoiceOver's press and
        // other accessibility clients reach a row that does nothing.
        .accessibilityAction { select() }
        .accessibilityAction(named: Text("Open Chosen Format")) { open() }
    }
}
