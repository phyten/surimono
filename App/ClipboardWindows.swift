import AppKit
import SurimonoCore

/// Where a text to open came from, which the question names.
enum ClipboardTextSource {
    case clipboard, selection
}

final class ClipboardWindows {
    static let shared: ClipboardWindows = ClipboardWindows(
        openFiles: { OpenRouter.shared.open($0, from: $1, printing: $2) },
        warn: { window in
            let alert = NSAlert()
            alert.messageText = String(localized: "There is nothing to open on the clipboard")
            alert.informativeText = String(localized: "Copy Markdown, text, or an image, then try again.")
            alert.addButton(withTitle: String(localized: "OK"))
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }, closeWelcome: { WelcomeController.shared.close() })

    var preferences: AppPreferences?
    var library: UserLibrary?
    var settingsStore: DocumentSettingsStore?
    /// Asks which format unsure text opens as; nil is Cancel. Replaceable so that hosted tests answer it.
    var ask: (ClipboardQuestion, ClipboardTextSource, NSWindow?, @escaping (ClipboardTextKind?) -> Void) -> Void = {
        question, source, window, completion in
        precondition(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            "Hosted tests must inject ClipboardWindows.ask before opening unsure text")
        ClipboardQuestionPanel.present(question, source: source, over: window, completion: completion)
    }
    /// Brings the question that is open forward again, instead of asking a second time.
    var showQuestion: () -> Void = { ClipboardQuestionPanel.bringForward() }
    private var controllers: [ContentHash: MemoryDocumentWindowController] = [:]
    private var cascadePoint = NSPoint.zero
    private let openFiles: ([URL], NSWindow?, Bool) -> Void
    private let warn: (NSWindow?) -> Void
    private let closeWelcome: () -> Void
    private(set) var isAsking = false

    var hasWindows: Bool { !controllers.isEmpty }

    init(
        openFiles: @escaping ([URL], NSWindow?, Bool) -> Void, warn: @escaping (NSWindow?) -> Void,
        closeWelcome: @escaping () -> Void
    ) {
        self.openFiles = openFiles
        self.warn = warn
        self.closeWelcome = closeWelcome
    }

    static func content(from pasteboard: NSPasteboard) -> ClipboardContent {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        // Apps that keep only rich text offer no plain string.
        let richText = pasteboard.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
        let text = pasteboard.string(forType: .string) ?? richText?.string
        return ClipboardContent(
            fileURLs: urls ?? [], text: text, hints: text.map { hints(for: $0, in: pasteboard) } ?? .init(),
            png: pasteboard.data(forType: .png), tiff: pasteboard.data(forType: .tiff))
    }

    /// What the pasteboard's types say about its text. A browser's HTML type is no evidence: what was copied from a
    /// page opens as the words that were seen.
    static func hints(for text: String, in pasteboard: NSPasteboard) -> ClipboardFormatHints {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = pasteboard.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let types = pasteboard.types ?? []
        let tabular = types.contains(.tabularText) || types.contains(.init("public.tab-separated-values-text"))
        return ClipboardFormatHints(hasMatchingURL: !trimmed.isEmpty && url == trimmed, hasTabularData: tabular)
    }

    @discardableResult
    func open(from pasteboard: NSPasteboard = .general, window: NSWindow? = NSApp.keyWindow, printing: Bool = false)
        -> MemoryDocumentWindowController?
    {
        switch Self.content(from: pasteboard) {
        case .files(let urls):
            openFiles(urls, window, printing)
            return nil
        case .empty:
            warn(window)
            return nil
        case .document(let data, let format):
            return open(data, format: format, title: Self.clipboardTitle(), printing: printing)
        case .text(let text, let hints):
            return open(
                text: text, hints: hints, title: Self.clipboardTitle(), source: .clipboard, window: window,
                printing: printing)
        }
    }

    private static func clipboardTitle() -> String {
        String(localized: "Clipboard") + " "
            + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
    }

    /// Opens text in the format the detector is sure of, or the one the reader picks when it is not. The same text
    /// already open is brought forward as it is, without asking again. Nil when nothing opened yet: the question is
    /// still open, or was cancelled. `alwaysAsks` is for screenshots of the question.
    @discardableResult
    func open(
        text: String, hints: ClipboardFormatHints, title: String, source: ClipboardTextSource, window: NSWindow?,
        printing: Bool, alwaysAsks: Bool = false
    ) -> MemoryDocumentWindowController? {
        let data = Data(text.utf8)
        if let existing = controllers[ContentHash.of(data)] {
            show(existing, printing: printing)
            return existing
        }
        guard !isAsking else {
            showQuestion()
            return nil
        }
        let settings = preferences?.clipboardFormat ?? .standard
        let detection = ClipboardFormatDetector.detect(text, hints: hints, settings: settings)
        if case .open(let kind) = detection.action, !alwaysAsks {
            let origin: TextFormatOrigin = detection.reason == .fixed ? .settings : .automatic
            return open(data, format: kind.documentFormat, title: title, printing: printing, textOrigin: origin)
        }
        isAsking = true
        var opened: MemoryDocumentWindowController?
        let question = ClipboardQuestion(text: text, detection: detection, settings: settings)
        ask(question, source, window) { [weak self] kind in
            guard let self else { return }
            isAsking = false
            guard let kind else { return }
            opened = open(data, format: kind.documentFormat, title: title, printing: printing, textOrigin: .chosen)
        }
        return opened
    }

    /// Opens bytes that have no file. The same content has one window, whichever way it came in. A text whose format
    /// was a guess (`textOrigin`) can open again as another from the format menu.
    @discardableResult
    func open(
        _ data: Data, format: DocumentFormat, title: String, printing: Bool = false,
        textOrigin: TextFormatOrigin? = nil
    ) -> MemoryDocumentWindowController {
        let hash = ContentHash.of(data)
        let controller =
            controllers[hash]
            ?? makeController(data, format: format, title: title, hash: hash, textOrigin: textOrigin)
        show(controller, printing: printing)
        return controller
    }

    /// The same original text as another kind, in a new window at the place of the old one, which closes.
    func reopen(_ model: DocumentViewModel, as kind: ClipboardTextKind) {
        guard let data = model.memoryContent, kind.documentFormat != model.format,
            let (hash, old) = controllers.first(where: { $0.value.model === model })
        else { return }
        let frame = old.window?.frame
        let printing = model.mode == .print
        let controller = makeController(
            data, format: kind.documentFormat, title: model.displayName, hash: hash, textOrigin: .chosen,
            cascades: false)
        // The window fits its new paper from the top left, as every window of the view mode does.
        if let frame { controller.window?.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY)) }
        show(controller, printing: printing)
        old.close()
    }

    private func show(_ controller: MemoryDocumentWindowController, printing: Bool) {
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        closeWelcome()
        if printing { controller.model.requestPrintMode() }
    }

    private func makeController(
        _ data: Data, format: DocumentFormat, title: String, hash: ContentHash, textOrigin: TextFormatOrigin?,
        cascades: Bool = true
    ) -> MemoryDocumentWindowController {
        let model = DocumentViewModel(
            data: data, fileURL: nil, format: format,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            settingsStore: settingsStore, title: title)
        if let textOrigin, ClipboardTextKind(format) != nil {
            model.textFormatOrigin = textOrigin
            model.textReopener = { [weak self, weak model] kind in
                if let self, let model { reopen(model, as: kind) }
            }
        }
        let controller = MemoryDocumentWindowController(model: model) { [weak self, weak model] in
            // A window opened again as another kind has already taken this one's place.
            guard let self, controllers[hash]?.model === model else { return }
            controllers.removeValue(forKey: hash)
        }
        controllers[hash] = controller
        if cascades, let window = controller.window { cascadePoint = window.cascadeTopLeft(from: cascadePoint) }
        return controller
    }
}
