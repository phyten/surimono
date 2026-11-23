import AppKit
import Observation

/// AppKit-hosted windows do not participate in SwiftUI's scene focus propagation.
@Observable
final class DocumentWindows: NSObject {
    static let shared = DocumentWindows()
    private(set) weak var activeModel: DocumentViewModel?
    @ObservationIgnored private let models = NSMapTable<NSWindow, DocumentViewModel>.weakToWeakObjects()
    var currentModel: DocumentViewModel? {
        model(for: NSApp.keyWindow)
    }

    func model(for window: NSWindow?) -> DocumentViewModel? {
        window.flatMap { models.object(forKey: $0) }
    }

    /// An open can finish on either side of SwiftUI registering the viewer. This record belongs to the
    /// actual AppKit window (or to its document until the first window appears), including after it closes.
    @MainActor
    final class Registration {
        private enum State {
            case waiting, registered, closed
            case boundToWindow(Registration)
        }

        private var state = State.waiting
        private weak var model: DocumentViewModel?
        private var waiting: [(DocumentViewModel?) -> Void] = []

        var pendingCount: Int {
            if case .boundToWindow(let window) = state { return window.pendingCount }
            return waiting.count
        }
        var isClosed: Bool {
            if case .closed = state { return true }
            if case .boundToWindow(let window) = state { return window.isClosed }
            return false
        }

        func whenRegistered(_ receive: @escaping (DocumentViewModel?) -> Void) {
            switch state {
            case .waiting: waiting.append(receive)
            case .registered: receive(model)
            case .closed: receive(nil)
            case .boundToWindow(let window): window.whenRegistered(receive)
            }
        }

        /// Link a document's early completions to its first window exactly once. Closing that window remains
        /// terminal even if AppKit detaches its controller before posting the close notification.
        fileprivate func bind(to window: Registration) {
            guard case .waiting = state else { return }
            state = .boundToWindow(window)
            deliverWaiting()
        }

        func register(_ model: DocumentViewModel) {
            guard !isClosed else { return }
            self.model = model
            state = .registered
            deliverWaiting()
        }

        func close() {
            model = nil
            state = .closed
            deliverWaiting()
        }

        private func deliverWaiting() {
            let callbacks = waiting
            waiting.removeAll()
            for receive in callbacks { whenRegistered(receive) }
        }

        isolated deinit {
            // A document can disappear without ever making a window.
            for receive in waiting { receive(nil) }
        }
    }

    private static var registrationKey: UInt8 = 0

    private func registration(of owner: NSObject) -> Registration {
        if let existing = objc_getAssociatedObject(owner, &Self.registrationKey) as? Registration { return existing }
        let registration = Registration()
        objc_setAssociatedObject(owner, &Self.registrationKey, registration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return registration
    }

    func opened(_ document: NSDocument, wasAlreadyOpen: Bool) -> OpenRouter.OpenedFile {
        // A document group may report success before it has attached its first window controller.
        if let window = document.windowForSheet {
            let target = registration(of: window)
            registration(of: document).bind(to: target)
            return OpenRouter.OpenedFile(destination: target, wasAlreadyOpen: wasAlreadyOpen)
        }
        let target = registration(of: document)
        if !NSDocumentController.shared.documents.contains(where: { $0 === document }) { target.close() }
        return OpenRouter.OpenedFile(destination: target, wasAlreadyOpen: wasAlreadyOpen)
    }

    private func primaryDocument(for window: NSWindow) -> NSDocument? {
        guard
            let document = window.windowController?.document as? NSDocument
                ?? NSDocumentController.shared.document(for: window),
            document.windowForSheet == nil || document.windowForSheet === window
        else { return nil }
        return document
    }

    /// A closed window can still be retained by its controller and must no longer receive file requests.
    var openModels: [DocumentViewModel] { models.objectEnumerator()?.allObjects as? [DocumentViewModel] ?? [] }

    override private init() {
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateActive), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        models.removeObject(forKey: window)
        let target = registration(of: window)
        target.close()
        if let document = primaryDocument(for: window) { registration(of: document).bind(to: target) }
        updateActive()
    }

    /// Every kind of window registers its model here, so this reaches documents, bundles, binders and clipboard
    /// windows alike.
    func flushPendingSettings() {
        for model in openModels { model.flushPendingSettings() }
    }

    func register(_ model: DocumentViewModel, for window: NSWindow) {
        let target = registration(of: window)
        guard !target.isClosed else { return }
        models.setObject(model, forKey: window)
        if let document = primaryDocument(for: window) { registration(of: document).bind(to: target) }
        target.register(model)
        updateActive()
    }

    @objc private func updateActive() {
        activeModel = NSApp.keyWindow.flatMap { models.object(forKey: $0) }
    }
}
