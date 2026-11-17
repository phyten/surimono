import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    var canPrintManualDuplex: Bool { canStartPrint && printerLayout.sentDuplex != .none }

    func startManualDuplex(
        prepared: PreparedRender, request: PrintRequest, pageOrder: PrintPageOrder
    ) {
        guard manualDuplexSession == nil, let name = request.printerName else { return }
        let session = ManualDuplexSession(
            printerName: name, layout: prepared.layout, imposition: prepared.plan, copies: request.copies,
            pageOrder: pageOrder, jobTitle: printJobTitle, language: language,
            correction: preferences.printerProfile(for: name).manualCorrection(for: prepared.layout.sentDuplex))
        session.saveCorrection = manualDuplexSaveCorrection
        manualDuplexSession = session
        outputError = nil
        manualDuplexTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Compose from the captured preparation, with no automatic-printer calibration baked into the backs.
                let neutral = try await renderer.composeSheet(for: prepared, rotatesBackSides: false)
                try await session.prepare(from: neutral.sheetDocument)
                try Task.checkCancellation()
                guard manualDuplexSession?.id == session.id else { return }
                let current = printerListSource().request(
                    quick: true, shown: name, remembered: preferences.printerName)
                let route = PrintRoute.resolve(
                    intent: .manualDuplex, request: current, layout: session.layout,
                    issue: issue(sending: session.layout, to: current.printerName))
                guard case .manualDuplex = route else {
                    fallbackFromManual(session, prepared: prepared, request: route.request)
                    return
                }
                guard session.transition(from: .preparing, to: .sendingFronts) else { return }
                let submission = try session.submission(for: .fronts)
                let submissionID = session.beginSubmission()
                sendManualDuplex(submission) { [weak self] outcome in
                    guard let self, manualDuplexSession?.id == session.id, session.phase == .sendingFronts,
                        session.submissionID == submissionID
                    else {
                        return
                    }
                    switch outcome {
                    case .handedOff(let printer) where printer == session.printerName:
                        _ = session.transition(from: .sendingFronts, to: .awaitingReload)
                    case .notStarted:
                        fallbackFromManual(session, prepared: prepared, request: current)
                    default:
                        failManualDuplex(session)
                    }
                }
            } catch {
                guard manualDuplexSession?.id == session.id else { return }
                cancelManualDuplex()
                if !(error is CancellationError) {
                    outputError = String(localized: "The print job could not be created.")
                }
            }
        }
    }

    private func fallbackFromManual(_ session: ManualDuplexSession, prepared: PreparedRender, request: PrintRequest) {
        guard manualDuplexSession?.id == session.id else { return }
        if session.phase == .sendingFronts { _ = session.transition(from: .sendingFronts, to: .preparing) }
        manualDuplexTask = Task { [weak self] in
            guard let self else { return }
            var request = printerListSource().request(
                quick: false, shown: request.printerName, remembered: preferences.printerName)
            request.copies = session.copies
            let rotates = preferences.printerProfile(for: request.printerName).rotation(
                for: prepared.layout.sentDuplex, default: preferences.rotateBack)
            do {
                // The full-document dialog must use its destination's automatic calibration, not the old printer's.
                let result = try await renderer.composeSheet(for: prepared, rotatesBackSides: rotates)
                try Task.checkCancellation()
                guard manualDuplexSession?.id == session.id else { return }
                cancelManualDuplex()
                submitDocument(result, request: request, pageOrder: session.frontPageOrder, jobTitle: session.jobTitle)
            } catch {
                guard manualDuplexSession?.id == session.id else { return }
                cancelManualDuplex()
                if !(error is CancellationError) {
                    outputError = String(localized: "The print job could not be created.")
                }
            }
        }
    }

    func cancelManualDuplex() {
        manualDuplexSession = nil
        manualDuplexTask?.cancel()
        manualDuplexTask = nil
    }

    func printManualDuplexBacks() {
        guard let session = manualDuplexSession, session.phase == .awaitingReload else { return }
        guard manualDestinationAvailable(session) else { return }
        guard session.transition(from: .awaitingReload, to: .preparingBacks) else { return }
        session.error = nil
        let correction = session.correction
        manualDuplexTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.prepareBacks(correction: correction)
                try Task.checkCancellation()
                guard manualDuplexSession?.id == session.id else { return }
                // Recheck after preparation too; a disconnected printer must not redirect a partly printed stack.
                guard manualDestinationAvailable(session) else {
                    _ = session.transition(from: .preparingBacks, to: .awaitingReload)
                    return
                }
                let submission = try session.submission(for: .backs)
                // Asking the sheet to go only changes what the presentation reads; it is still attached until it has
                // closed, so the backs start once it has left the window.
                guard session.transition(from: .preparingBacks, to: .closingSheet) else { return }
                let detached = await manualDuplexSheetDetached()
                try Task.checkCancellation()
                guard manualDuplexSession?.id == session.id, session.phase == .closingSheet else { return }
                guard detached else {
                    session.error = PrintModeText.string(
                        "The backs could not be prepared. Nothing was sent.", language: session.language)
                    _ = session.transition(from: .closingSheet, to: .awaitingReload)
                    return
                }
                guard manualDestinationAvailable(session) else {
                    _ = session.transition(from: .closingSheet, to: .awaitingReload)
                    return
                }
                if let save = session.saveCorrection {
                    save(correction)
                } else {
                    preferences.setManualDuplexCorrection(correction, for: session.printerName, duplex: session.binding)
                }
                guard session.transition(from: .closingSheet, to: .sendingBacks) else { return }
                let submissionID = session.beginSubmission()
                sendManualDuplex(submission) { [weak self] outcome in
                    guard let self, manualDuplexSession?.id == session.id, session.phase == .sendingBacks,
                        session.submissionID == submissionID
                    else {
                        return
                    }
                    switch outcome {
                    case .handedOff(let printer) where printer == session.printerName:
                        cancelManualDuplex()
                        showToast(
                            Toast(
                                systemImage: "printer",
                                title: PrintModeText.format(
                                    "Backs sent to %@", language: session.language, printer)))
                    case .notStarted:
                        session.error = missingManualPrinter(session)
                        _ = session.transition(from: .sendingBacks, to: .awaitingReload)
                    default:
                        failManualDuplex(session)
                    }
                }
            } catch {
                guard manualDuplexSession?.id == session.id else { return }
                if error is CancellationError { return }
                session.error = PrintModeText.string(
                    "The backs could not be prepared. Nothing was sent.", language: session.language)
                _ = session.transition(from: .preparingBacks, to: .awaitingReload)
            }
        }
    }

    /// How long the backs wait for the reload sheet to leave the window before giving up without printing.
    static let manualDuplexSheetDetachLimit = Duration.seconds(2)

    /// Whether the window is free of sheets, waiting up to the limit. SwiftUI's `.sheet` gives no completion for its
    /// dismissal and detaches the sheet only after the closing animation, so the window itself is watched.
    func manualDuplexSheetDetached() async -> Bool {
        let deadline = ContinuousClock.now + Self.manualDuplexSheetDetachLimit
        while window?.attachedSheet != nil {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func manualDestinationAvailable(_ session: ManualDuplexSession) -> Bool {
        let request = printerListSource().request(
            quick: true, shown: session.printerName, remembered: session.printerName)
        guard !request.showsPanel, request.printerName == session.printerName else {
            session.error = missingManualPrinter(session)
            return false
        }
        return true
    }

    private func missingManualPrinter(_ session: ManualDuplexSession) -> String {
        PrintModeText.format(
            "%@ is unavailable. Connect the printer, then press Print the Backs.",
            language: session.language, session.printerName)
    }

    private func failManualDuplex(_ session: ManualDuplexSession) {
        cancelManualDuplex()
        outputError = PrintModeText.string(
            "The print job could not be sent or was cancelled. Check the print queue and paper before trying again.",
            language: session.language)
    }

    private func sendManualDuplex(
        _ submission: ManualDuplexSubmission, complete: @escaping (ManualDuplexSubmissionResult) -> Void
    ) {
        // A snapshot owns its fake submitter, even if the model's normal injection is subsequently replaced.
        if let submit = manualDuplexSession?.submitOverride ?? manualDuplexSubmit {
            submit(submission, complete)
            return
        }
        guard let name = submission.request.printerName, let printer = NSPrinter(name: name) else {
            complete(.notStarted)
            return
        }
        guard let window, let operation = makeManualDuplexOperation(submission, printer: printer) else {
            complete(.cancelledOrFailed)
            return
        }
        ManualDuplexCompletion.run(operation, document: submission.document, window: window, complete: complete)
    }

    /// Construction is separate from submission so tests can inspect the transport without sending anything.
    func makeManualDuplexOperation(_ submission: ManualDuplexSubmission, printer: NSPrinter? = nil) -> NSPrintOperation?
    {
        let operation = PrintJobFactory().printOperation(
            for: submission.document, layout: submission.layout, showsPrintPanel: false, printer: printer,
            pageOrder: submission.pageOrder, copies: 1, jobTitle: submission.jobTitle)
        operation?.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        operation?.printInfo.jobDisposition = .spool
        return operation
    }
}

private final class ManualDuplexCompletion: NSObject {
    let operation: NSPrintOperation
    let document: PDFDocument
    let complete: (ManualDuplexSubmissionResult) -> Void
    // AppKit's delegate is not an ownership boundary. Retain the job until its callback even if the window closes.
    private var lifetime: ManualDuplexCompletion?

    init(
        _ operation: NSPrintOperation, document: PDFDocument, complete: @escaping (ManualDuplexSubmissionResult) -> Void
    ) {
        self.operation = operation
        self.document = document
        self.complete = complete
    }

    static func run(
        _ operation: NSPrintOperation, document: PDFDocument, window: NSWindow,
        complete: @escaping (ManualDuplexSubmissionResult) -> Void
    ) {
        let delegate = ManualDuplexCompletion(operation, document: document, complete: complete)
        delegate.lifetime = delegate
        operation.runModal(
            for: window, delegate: delegate,
            didRun: #selector(didRun(_:success:context:)), contextInfo: nil)
    }

    @objc private func didRun(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        defer { lifetime = nil }
        let info = operation.printInfo
        complete(
            success && info.jobDisposition == .spool ? .handedOff(printerName: info.printer.name) : .cancelledOrFailed)
    }
}
