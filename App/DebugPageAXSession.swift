#if DEBUG
    import AppKit
    import PDFKit
    import SurimonoCore

    /// A private document gives the external reader unambiguous text without writing to a reader's open file.
    enum DebugPageAXSession {
        static private(set) var current: Session?

        struct Session {
            let directory: URL
            let fixture: URL
            let token = UUID().uuidString
            let operation: String
            let count: Int
        }

        struct ReaderStopped: LocalizedError {
            let reason: String
            var errorDescription: String? { reason }
        }

        private struct StageDiagnosticError: LocalizedError {
            let failure: AppFailure
            let writeError: Error
            var errorDescription: String? {
                "\(failure.localizedDescription); could not write error.json: \(writeError.localizedDescription)"
            }
        }

        static func start() throws {
            guard let path = DebugSnapshot.argument("SurimonoAXProbeDirectory") else { return }
            guard path.hasPrefix("/"), let operation = DebugSnapshot.argument("SurimonoAXOperation"),
                ["reload", "layout", "tray"].contains(operation),
                let count = Int(DebugSnapshot.argument("SurimonoRerenderCount") ?? "50"), count > 0
            else { throw CocoaError(.fileWriteInvalidFileName) }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            // A run can neither consume stale acknowledgements nor overwrite a previous run.
            guard mkdir(path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            let session = Session(
                directory: directory, fixture: scratch.appending(path: "Paper.md"), operation: operation, count: count)
            do {
                try writeFixture(session, generation: 0)
                current = session
                guard OpenRouter.shared.open([session.fixture]) else { throw CocoaError(.fileReadUnknown) }
            } catch {
                current = nil
                try? FileManager.default.removeItem(at: scratch)
                throw error
            }
        }

        @discardableResult private static func writeFixture(_ session: Session, generation: Int) throws -> Data {
            let marker = "世代 \(generation)。 R01-\(session.token.prefix(8))"
            let source = "# 紙面の検査\n\n" + Array(repeating: "\(marker) 紙面の本文です。\n\n", count: 90).joined()
            let data = Data(source.utf8)
            try data.write(to: session.fixture, options: .atomic)
            return data
        }

        static func run(_ model: DocumentViewModel, session: Session) async throws {
            defer {
                current = nil
                try? FileManager.default.removeItem(at: session.fixture.deletingLastPathComponent())
            }
            var sequence = 0
            var phase = "initial"
            func wait(_ stage: String, forReader: Bool = false, for ready: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(90)
                while !ready() {
                    if (try? String(contentsOf: session.directory.appending(path: "abort"), encoding: .utf8))
                        == session.token
                    {
                        throw ReaderStopped(reason: "Reader aborted while waiting for " + stage)
                    }
                    if forReader && ContinuousClock.now >= deadline {
                        throw ReaderStopped(reason: "Reader did not acknowledge " + stage)
                    }
                    guard model.window != nil, model.error == nil, ContinuousClock.now < deadline else {
                        throw SnapshotDeadline(stage: stage)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }

            func references() throws -> ([PageReference], HitTarget) {
                guard let view = model.paper.attachedProbeView, let window = view.window,
                    let content = window.contentView, let primary = NSScreen.screens.first, let document = view.document
                else { throw StageIssue(kind: .geometryNotReady, field: "paper", value: "no attached paper") }
                var pages: [PageReference] = []
                var target: HitTarget?
                let elements = view.accessibilityChildren() as? [PageTextElement] ?? []
                for page in view.visiblePages {
                    let id = session.token + ".page." + String(document.index(for: page))
                    guard let text = page.string as NSString? else { continue }
                    let index = text.range(of: "世").location
                    guard index != NSNotFound else { continue }
                    let range = NSRange(location: index, length: 1)
                    func axRect(_ rect: CGRect) -> CGRect {
                        let ns = window.convertToScreen(view.convert(rect, to: nil))
                        return CGRect(x: ns.minX, y: primary.frame.maxY - ns.maxY, width: ns.width, height: ns.height)
                    }
                    let field = "pages[\(pages.count)].characterBounds"
                    guard let element = elements.first(where: { $0.accessibilityIdentifier() == id }) else {
                        throw StageIssue(kind: .geometryNotReady, field: field, value: "missing AX page " + id)
                    }
                    let screenBox = element.accessibilityFrame(for: range)
                    let elementBox = CGRect(
                        x: screenBox.minX, y: primary.frame.maxY - screenBox.maxY,
                        width: screenBox.width, height: screenBox.height)
                    // Obtain the reference from PDFKit independently of the AX cache. A copied page is queried in
                    // its own document, then its page-space rectangle is converted through the displayed page.
                    func markerBounds(_ candidate: PDFPage) -> CGRect {
                        candidate.selection(for: range)?.bounds(for: candidate) ?? .null
                    }
                    var selectionBounds = markerBounds(page)
                    var referenceSource = "displayedPage"
                    if !PageTextGeometry.usable(selectionBounds) {
                        PageTextGeometry.withCopy(of: page, matching: text) { copy in
                            selectionBounds = markerBounds(copy)
                            referenceSource = "copiedPage"
                        }
                    }
                    do {
                        try StageIssue.check(selectionBounds, field: field + ".pdf")
                    } catch let issue as StageIssue {
                        throw StageIssue(
                            kind: issue.kind, field: issue.field,
                            value: "\(issue.value); PDFKit: \(referenceSource); AX frame: \(screenBox)")
                    }
                    let glyph = view.convert(selectionBounds, from: page)
                    try StageIssue.check(glyph, field: field + ".view")
                    let bounds = axRect(glyph)
                    try StageIssue.check(bounds, field: field)
                    guard PageTextGeometry.usable(screenBox),
                        [
                            elementBox.minX - bounds.minX, elementBox.minY - bounds.minY,
                            elementBox.maxX - bounds.maxX, elementBox.maxY - bounds.maxY,
                        ].allSatisfy({ abs($0) <= 1 })
                    else {
                        throw StageIssue(
                            kind: .geometryNotReady, field: "pages[\(pages.count)].elementCharacterBounds",
                            value: "AX: \(elementBox); PDFKit (\(referenceSource)): \(bounds)")
                    }
                    pages.append(
                        .init(
                            identifier: id, characterIndex: index, characterBounds: bounds,
                            referenceSource: referenceSource, elementCharacterBounds: elementBox))
                    let pageFrame = view.convert(page.bounds(for: view.displayBox), from: page)
                    try StageIssue.check(pageFrame, field: "visiblePages[\(id)].frame")
                    try StageIssue.check(view.visibleRect, field: "paper.visibleRect")
                    let visible = view.visibleRect.intersection(pageFrame)
                    for box in [glyph.intersection(visible), visible] where !box.isEmpty {
                        let local = CGPoint(x: box.midX, y: box.midY)
                        let base = view.convert(local, to: nil)
                        try StageIssue.check(base, field: "hit.windowPoint")
                        let screen = window.convertPoint(toScreen: base)
                        let point = CGPoint(x: screen.x, y: primary.frame.maxY - screen.y)
                        try StageIssue.check(point, field: "hit.point")
                        let mouse = content.hitTest(content.superview?.convert(base, from: nil) ?? base)
                        let leaf = view.accessibilityHitTest(screen) as? PageTextElement
                        let windowHit = window.accessibilityHitTest(screen) as? NSAccessibilityProtocol
                        var ancestor = view.accessibilityParent() as? NSAccessibilityProtocol
                        var isAncestor = false
                        for _ in 0..<32 {
                            guard let node = ancestor else { break }
                            if node === windowHit {
                                isAncestor = true
                                break
                            }
                            ancestor = node.accessibilityParent() as? NSAccessibilityProtocol
                        }
                        let candidate = HitTarget(
                            point: point, page: id,
                            mouseHitsPaper: mouse === view || mouse?.isDescendant(of: view) == true,
                            paperHitIdentifier: leaf?.accessibilityIdentifier(), windowIsPaperAncestor: isAncestor,
                            windowRole: windowHit?.accessibilityRole()?.rawValue,
                            windowIdentifier: windowHit?.accessibilityIdentifier())
                        if target == nil
                            || (candidate.reachesPage
                                && (target?.reachesPage != true || candidate.windowIdentifier == id))
                        {
                            target = candidate
                        }
                    }
                }
                guard let target, target.reachesPage else {
                    throw StageIssue(kind: .geometryNotReady, field: "hit", value: "no reachable fixture page")
                }
                return (pages, target)
            }

            func publish(generation: Int) async throws {
                let needsPaper = phase != "inTray" && phase != "finished"
                var focused = false
                let data = try await Stage.encodeWhenReady {
                    var pages: [PageReference] = []
                    var hit: HitTarget?
                    if needsPaper {
                        model.paper.attachedProbeView?.identifyProbePaper(session.token)
                        if !focused {
                            _ = try references()
                            try focusPaper(inner: phase != "initial")
                            focused = true
                        }
                        // Changing responder can lay out the paper again. Validate the sample we will publish.
                        (pages, hit) = try references()
                    }
                    return Stage(
                        pid: getpid(), token: session.token, operation: session.operation, count: session.count,
                        sequence: sequence, phase: phase, generation: generation,
                        hit: hit, pages: pages, axElements: ShownDocumentsProbe.elementMetrics)
                }
                let file = session.directory.appending(path: "stage-\(sequence).json")
                try data.write(to: file, options: .atomic)
                // No UI action is sent by the AX client. It only confirms that this precise stage was read.
                let ack = session.directory.appending(path: "ack-\(sequence)")
                try await wait("AX reader at " + phase, forReader: true) {
                    (try? String(contentsOf: ack, encoding: .utf8)) == session.token
                }
                sequence += 1
                try await Task.sleep(for: .milliseconds(300))
            }

            func paperReady() -> Bool {
                model.window?.isVisible == true && model.mode == .view && model.isUpToDate
                    && model.paper.probeShows(model.paperDocument)
            }
            func focusPaper(inner: Bool) throws {
                guard let view = model.paper.attachedProbeView, let window = view.window else {
                    throw SnapshotDeadline(stage: "missing paper window")
                }
                // A real click leaves PDFKit's public documentView as the responder.
                guard let responder = inner ? view.documentView : view,
                    window.makeFirstResponder(responder), window.firstResponder === responder
                else { throw SnapshotDeadline(stage: inner ? "inner paper focus" : "outer paper focus") }
            }
            do {
                try await wait("first paper", for: paperReady)
                model.zoom = 1
                model.setLayout(.single)
                try await wait("single page") { paperReady() && model.paper.attachedProbeView?.probeLayout == .single }
                try await publish(generation: 0)
                phase = "innerFocus"
                try await publish(generation: 0)
                for iteration in 1...session.count {
                    if session.operation == "layout" {
                        phase = "layout"
                        let next: ViewOptions.Layout = iteration.isMultiple(of: 2) ? .single : .spread
                        model.setLayout(next)
                        try await wait("layout") { paperReady() && model.paper.attachedProbeView?.probeLayout == next }
                        try await publish(generation: iteration - 1)
                    } else if session.operation == "tray" {
                        phase = "inTray"
                        let oldID = model.paper.attachedProbeView?.probeID
                        model.enterPrintMode()
                        try await wait("tray") {
                            model.mode == .print && model.hasCurrentPrintPreview && model.paper.attachedProbeView == nil
                        }
                        try await publish(generation: iteration - 1)
                        phase = "afterTray"
                        model.exitPrintMode()
                        try await wait("returned paper") {
                            paperReady() && model.paper.attachedProbeView?.probeID != oldID
                        }
                        try await publish(generation: iteration - 1)
                    }
                    phase = "reload"
                    let previous = model.result?.id
                    let expected = try writeFixture(session, generation: iteration)
                    model.reload()
                    try await wait("new generation") {
                        paperReady() && model.data == expected && model.result?.id != previous
                    }
                    try await publish(generation: iteration)
                }
                phase = "finished"
                try await publish(generation: session.count)
                phase = "complete"
                try Data(session.token.utf8).write(
                    to: session.directory.appending(path: "complete"), options: .atomic)
            } catch let stopped as ReaderStopped {
                throw stopped
            } catch {
                let failure = AppFailure(session: session, sequence: sequence, phase: phase, error: error)
                do {
                    try JSONEncoder().encode(failure).write(
                        to: session.directory.appending(path: "error.json"), options: .atomic)
                } catch {
                    // The stage and its diagnostic can both fail if the directory is no longer writable.
                    throw StageDiagnosticError(failure: failure, writeError: error)
                }
                throw failure
            }
        }
    }
#endif
