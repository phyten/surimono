#if DEBUG
    import AppKit
    import CoreText
    import PDFKit
    import OSLog
    import SurimonoCore
    import SwiftUI

    /// Launch arguments for screenshots in development builds. They never apply to Release builds.
    enum DebugSnapshot {
        static let showMenu = Notification.Name("SurimonoDebugShowMenu")
        private static var captured = false
        private static var loggedMoreMenu = false
        private static let openURLArgument = argument("SurimonoOpenURL")
        private static weak var firstDocument: DocumentViewModel?
        private static var scheduled = false
        private static var appliedOverrides = false
        private static weak var settingsWindow: NSWindow?
        private static var quitsArrangementEditor = false
        private static let logger = Logger(subsystem: "app.surimono.Surimono", category: "Snapshot")

        static func argument(_ name: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        static func flag(_ name: String) -> Bool { argument(name)?.uppercased() == "YES" }

        // Settings photography only: read process arguments into view state, never preferences.
        struct OrgDefaultsFixture {
            let current: OrgReadingDefaults
            let target: OrgReadingDefaults?
            let changedOnly: Bool

            init?(state: String?, alert: String?, changedOnly: Bool) {
                let requested: OrgReadingDefaults? =
                    switch alert {
                    case "emacs": .emacs
                    case "reset": .surimono
                    default: nil
                    }
                switch state {
                case "emacs": current = .emacs
                case "custom":
                    var values = OrgReadingDefaults.emacs
                    values.tableOfContents = .off
                    values.planning = true
                    current = values
                default:
                    guard requested != nil || changedOnly else { return nil }
                    current = requested == .surimono ? .emacs : .surimono
                }
                self.changedOnly = changedOnly
                // A matching target is disabled in the actual footer and has no alert to capture.
                target = current == requested ? nil : requested
            }
        }

        static var orgDefaultsFixture: OrgDefaultsFixture? {
            guard argument("SurimonoSettings") == "org" else { return nil }
            return OrgDefaultsFixture(
                state: argument("SurimonoOrgDefaultsState"), alert: argument("SurimonoOrgDefaultsAlert"),
                changedOnly: flag("SurimonoOrgChangedOnly"))
        }

        static var shortcutReview: String? { argument("SurimonoShortcutReview") }
        static var shortcutSearch: String? { argument("SurimonoShortcutSearch") }
        static var shortcutShowGlobal: Bool { flag("SurimonoShortcutGlobal") }

        /// A transient Split arrangement for photographing selected parts, in the supplied order.
        static func bandPartsFixture(_ names: String) -> BandArrangementStore? {
            let parts = names.split(separator: ",").compactMap { BandLayout.Item(rawValue: String($0)) }
            guard !parts.isEmpty else { return nil }
            var layouts = BandArrangementVariants()
            do {
                for part in parts {
                    layouts.split = try layouts.split.moving(part, to: .zone(.topRight), before: .print, for: .split)
                }
                var store = BandArrangementStore()
                try store.insert(BandArrangementSet(name: "Band Parts", layouts: layouts))
                return store
            } catch {
                logger.error("Band parts fixture is invalid: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        /// Arrangements to look at: `-SurimonoBandArrangement printBottom|reordered|sparse|editor|editorReading`
        /// (`unreadable` stands for data a newer version wrote). They are held in memory only; the preferences refuse
        /// to save over the reader's sets while one is shown.
        static func bandArrangementFixture(named name: String) -> BandArrangementStore? {
            if name == "editor" || name == "editorReading" {
                return editorFixture(activatesReading: name == "editorReading")
            }
            var layouts: BandArrangementVariants
            switch name {
            case "printBottom":
                // Print at the bottom right of Split, and at the start of the left zone in Top Only.
                layouts = BandArrangementVariants(
                    split: BandArrangement(
                        topLeft: [.formatBadge], topRight: [.floatOnTop],
                        bottomLeft: [.presentation, .style, .outline, .layout, .transition, .zoom, .thumbnails],
                        bottomRight: [.pageIndicator, .pageTurn, .print]),
                    top: BandArrangement(
                        topLeft: [.print, .formatBadge, .pageIndicator],
                        topRight: [
                            .presentation, .style, .outline, .layout, .transition, .zoom, .thumbnails, .floatOnTop,
                        ],
                        unused: [.pageTurn]))
            case "reordered":
                // Tools across zones and against the catalog order; Print is not last, so "…" docks at the edge.
                layouts = BandArrangementVariants(
                    split: BandArrangement(
                        topLeft: [.formatBadge, .outline], topRight: [.layout, .print, .floatOnTop],
                        bottomLeft: [.pageTurn, .pageIndicator],
                        bottomRight: [.transition, .style, .presentation, .zoom, .thumbnails]),
                    top: BandArrangement(
                        topLeft: [.formatBadge, .pageIndicator, .outline, .style],
                        topRight: [.transition, .layout, .zoom, .presentation, .thumbnails, .print, .floatOnTop],
                        unused: [.pageTurn]))
            case "sparse":
                // Most parts not in use; they stay within reach in "…".
                layouts = BandArrangementVariants(
                    split: BandArrangement(
                        topRight: [.print], bottomLeft: [.outline, .layout], bottomRight: [.pageIndicator, .pageTurn],
                        unused: [.formatBadge, .presentation, .style, .transition, .zoom, .thumbnails, .floatOnTop]),
                    top: BandArrangement(
                        topLeft: [.pageIndicator], topRight: [.outline, .layout, .print],
                        unused: [
                            .formatBadge, .presentation, .style, .transition, .zoom, .thumbnails, .floatOnTop,
                            .pageTurn,
                        ]))
            default:
                return nil
            }
            if name == "reordered" {
                layouts.split.topLeft = [
                    .separator, .part(.formatBadge), .separator, .separator, .part(.outline), .separator,
                ]
                layouts.top.topLeft = [
                    .part(.formatBadge), .part(.pageIndicator), .part(.outline), .separator, .part(.style),
                ]
                layouts.split.bottomRight.insert(.separator, at: 2)
            }
            var store = BandArrangementStore()
            do {
                try store.insert(BandArrangementSet(name: name, layouts: layouts))
            } catch {
                logger.error("Band arrangement fixture is invalid: \(String(describing: error), privacy: .public)")
                return nil
            }
            return store
        }

        /// Saved arrangements as an older or damaged store could have them: one record without a name, and a set
        /// whose Top Only layout is not a layout. Loading leaves out the first and puts Standard in the second.
        static let repairedArrangementData = Data(
            #"""
            {"schemaVersion":1,"active":{"kind":"user","id":"5C6B1D2E-0F4A-4E8B-9C7D-2A1B3C4D5E6F"},
            "sets":[{"id":"5C6B1D2E-0F4A-4E8B-9C7D-2A1B3C4D5E6F","name":"Reading",
            "layouts":{"split":{"topLeft":["formatBadge"],"topRight":["floatOnTop","print"],
            "bottomLeft":["outline","@separator","layout","transition"],"bottomRight":["pageIndicator","pageTurn"],
            "unused":["presentation","style","zoom","thumbnails"]},"top":7}},
            {"id":"6D7C2E3F-1A5B-4F9C-8D6E-3B2C4D5E6F70","name":""}]}
            """#.utf8)

        /// Two saved sets for the arrangement editor's snapshots, named in the snapshot's language.
        private static func editorFixture(activatesReading: Bool) -> BandArrangementStore? {
            let japanese = Bundle.main.preferredLocalizations.first == "ja"
            var reading = BandArrangementSet(name: japanese ? "読むとき" : "Reading")
            reading.layouts.split = BandArrangement(
                entries: [
                    .topLeft: [.part(.formatBadge)], .topRight: [.part(.floatOnTop), .part(.print)],
                    .bottomLeft: [.part(.outline), .separator, .part(.layout), .part(.transition)],
                    .bottomRight: [.part(.pageIndicator), .part(.pageTurn)],
                ], unused: [.presentation, .style, .zoom, .thumbnails])
            reading.layouts.top = BandArrangement(
                entries: [
                    .topLeft: [.part(.pageIndicator)],
                    .topRight: [
                        .part(.outline), .separator, .part(.layout), .part(.transition), .separator,
                        .part(.floatOnTop), .part(.print),
                    ],
                ], unused: [.formatBadge, .presentation, .style, .zoom, .thumbnails, .pageTurn])
            var printing = BandArrangementSet(name: japanese ? "刷るとき" : "Printing")
            printing.layouts.split = BandArrangement(
                entries: [
                    .topLeft: [.part(.formatBadge)], .topRight: [.part(.print)],
                    .bottomLeft: [.part(.style), .separator, .part(.layout)], .bottomRight: [.part(.pageIndicator)],
                ],
                unused: [.presentation, .outline, .transition, .zoom, .thumbnails, .floatOnTop, .pageTurn])
            var store = BandArrangementStore()
            do {
                try store.insert(reading, activate: activatesReading)
                try store.insert(printing, activate: false)
            } catch {
                logger.error("Band arrangement fixture is invalid: \(String(describing: error), privacy: .public)")
                return nil
            }
            return store
        }

        /// `-SurimonoArrangementProbe <path>` writes whether the Settings window routes Undo to the editor: the router
        /// in the responder chain, an editor step undone through the chain, the window's own history untouched.
        static func probeArrangementUndo(in window: NSWindow) {
            guard let path = argument("SurimonoArrangementProbe"), let editor = BandArrangementEditorSession.app,
                let content = window.contentView
            else { return }
            var chain: [String] = []
            var responder: NSResponder? = content
            while let current = responder, chain.count < 32 {
                chain.append(String(describing: type(of: current)))
                responder = current.nextResponder
            }
            let windowHistory = window.undoManager
            windowHistory?.registerUndo(withTarget: window) { _ in }
            let before = editor.draft
            editor.insertSeparator(in: .topLeft, at: 0)
            let sent = content.tryToPerform(#selector(SettingsUndoRouter.undo(_:)), with: nil)
            let lines = [
                "chain: \(chain.joined(separator: " > "))",
                "sent: \(sent)",
                "editorUndone: \(editor.draft == before)",
                "windowHistoryKept: \(windowHistory?.canUndo == true)",
            ]
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            windowHistory?.removeAllActions(withTarget: window)
        }

        /// `-SurimonoArrangementEditor <state,…>` puts the arrangement editor in a state to photograph, in memory only:
        /// `top`, `draft` (edits with separators the toolbar does not draw), `select:<part>`, `drop:<zone>:<index>`
        /// (the insertion marker of a hovering drag), `refused` (Print taken off), `unsaved` (the question before
        /// switching to Standard), `delete` and `new` (their sheets).
        /// A coordinate drop is `drop:new@topLeft:x,y` or `drop:bottomLeft:1@topRight:x,y`. Source indices are
        /// zero-based; offsets are points from the named zone's top-left, including negative offsets and overflow.
        static func configureArrangementEditor(_ states: String, editor: BandArrangementEditorSession) async throws {
            var commands = states.split(separator: ",").makeIterator()
            while let state = commands.next() {
                if state.hasPrefix("drop:"), state.contains("@") {
                    guard let y = commands.next() else { throw CocoaError(.coderInvalidValue) }
                    try await performEditorDrop(state.dropFirst(5), y: y, editor: editor)
                    continue
                }
                let fields = state.components(separatedBy: ":")
                switch fields[0] {
                case "hint": break  // The hint host reads the target without changing the selection.
                case "top": editor.mode = .top
                case "split": editor.mode = .split
                case "draft": draftEdits(editor)
                case "select":
                    if fields.count > 1, let item = BandLayout.Item(rawValue: fields[1]) { editor.select(.part(item)) }
                case "drop":
                    if fields.count > 2, let zone = BandZoneID(rawValue: fields[1]), let index = Int(fields[2]) {
                        editor.showDropMarker(.zone(zone, index: index))
                    }
                case "refused":
                    editor.select(.part(.print))
                    editor.removeSelection()
                case "unsaved": editor.pendingLeave = .selectSet(.standard)
                case "conflict":
                    editor.simulateChangeElsewhere()
                    editor.overwrite()
                case "quit":
                    // Asked once Settings is on screen, through the quit command's own path.
                    quitsArrangementEditor = true
                case "delete": editor.dialog = .delete
                case "new": editor.dialog = .new
                default: logger.error("Unknown editor state \(state, privacy: .public)")
                }
            }
        }

        private static func performEditorDrop(
            _ command: Substring, y: Substring, editor: BandArrangementEditorSession
        ) async throws {
            let pair = command.split(separator: "@", omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw CocoaError(.coderInvalidValue) }
            let destination = pair[1].split(separator: ":")
            guard destination.count == 2, let zone = BandZoneID(rawValue: String(destination[0])),
                editor.zones.contains(zone), let x = Double(destination[1]), x.isFinite, let y = Double(y), y.isFinite
            else { throw CocoaError(.coderInvalidValue) }

            // Earlier commands and window resizing can change wrapping. Let SwiftUI publish each zone's geometry.
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                try await Task.sleep(for: .milliseconds(30))
                if editor.zones.allSatisfy({ zone in
                    editor.layoutFrames[zone.rawValue]?.isEmpty == false
                        && editor.chipFrames[zone, default: []].count == editor.arrangement[zone].count
                }), editor.layoutFrames["topBand"] != nil,
                    editor.mode == .top || editor.layoutFrames["bottomBand"] != nil,
                    editor.arrangement.topRight.last(where: { $0.item != nil }) != .part(.print)
                        || editor.dockedMoreFrame != nil
                {
                    break
                }
                guard ContinuousClock.now < deadline else { throw SnapshotDeadline(stage: "Toolbar drop geometry") }
            } while true
            guard let frame = editor.layoutFrames[zone.rawValue] else { throw CocoaError(.coderInvalidValue) }
            let source: BandEditorPayload.Source
            if pair[0] == "new" {
                source = .newSeparator
            } else {
                let fields = pair[0].split(separator: ":")
                guard fields.count == 2, let from = BandZoneID(rawValue: String(fields[0])),
                    editor.zones.contains(from), let index = Int(fields[1])
                else { throw CocoaError(.coderInvalidValue) }
                let location = BandEntryLocation(destination: .zone(from), index: index)
                guard editor.entry(at: location) == .separator else { throw CocoaError(.coderInvalidValue) }
                source = .entry(location, .separator)
            }
            let point = CGPoint(x: frame.minX + x, y: frame.minY + y)
            let provider = BandEditorDrop.provider(editor.beginDrag(source))
            let placed = await withCheckedContinuation { continuation in
                if !BandEditorDrop.perform(
                    [provider], at: point, in: editor,
                    completion: { result in
                        continuation.resume(returning: result)
                    })
                {
                    continuation.resume(returning: false)
                }
            }
            guard placed else {
                throw CocoaError(
                    .coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "Toolbar drop refused: \(command),\(y)"])
            }
        }

        private static func draftEdits(_ editor: BandArrangementEditorSession) {
            let arrangement = editor.arrangement
            if let index = arrangement.unused.firstIndex(of: .zoom) {
                let zone: BandZoneID = editor.mode == .split ? .bottomLeft : .topRight
                editor.move(
                    BandEntryLocation(destination: .unused, index: index), to: .zone(zone),
                    at: editor.arrangement[zone].count)
            }
            let first: BandZoneID = editor.mode == .split ? .bottomLeft : .topRight
            // A separator at the start of a zone and two in a row: kept in the editor, not drawn.
            editor.insertSeparator(in: first, at: 0)
            if let index = editor.arrangement[first].lastIndex(of: .separator), index > 0 {
                editor.insertSeparator(in: first, at: index)
            }
            editor.select(nil)
        }

        static func openURL() {
            guard let openURLArgument else { return }
            guard let url = URLDocument.address(openURLArgument), url.scheme?.lowercased() == "https" else {
                logger.error("Snapshot URL must be HTTPS")
                return
            }
            Task {
                do {
                    try await OpenURLPanel.openDocument(
                        at: url,
                        didOpen: { controller in
                            guard let model = controller.model else { return }
                            firstDocument = model
                            captureIfReady(model)
                        })
                } catch {
                    logger.error("Snapshot URL could not be opened")
                }
            }
        }

        /// Stands in for another app: a service's selection and a streaming feed come through private pasteboards, leaving
        /// the shared ones alone.
        static func openFeeds() {
            if let path = argument("SurimonoServiceText"), let text = try? String(contentsOfFile: path, encoding: .utf8)
            {
                let board = NSPasteboard(name: .init("SurimonoDebugService"))
                board.clearContents()
                board.setString(text, forType: .string)
                var message: NSString?
                if argument("SurimonoService") == "print" {
                    ServiceProvider.shared.printSelection(board, userData: nil, error: &message)
                } else {
                    ServiceProvider.shared.openSelection(board, userData: nil, error: &message)
                }
            }
            if argument("SurimonoStreaming") == "live" {
                StreamingPreviewWindows.shared.open()
            } else if let path = argument("SurimonoStreaming") {
                let board = NSPasteboard(name: .init("SurimonoDebugStreaming"))
                board.clearContents()
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    board.setString(text, forType: .string)
                }
                StreamingPreviewWindows.shared.open(from: board)
            }
        }

        /// `-SurimonoClipboardQuestion <path>` shows the question about that file's text as if it came from the clipboard,
        /// whatever the detector decides, without touching the clipboard. With a document open it is the sheet on the
        /// document's window; without one it is the window of its own, captured here.
        static func askClipboardQuestion() {
            guard let path = argument("SurimonoClipboardQuestion") else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                guard NSDocumentController.shared.documents.isEmpty, !ClipboardWindows.shared.hasWindows,
                    firstDocument == nil
                else { return }
                askClipboardQuestion(path, over: nil)
                try? await Task.sleep(for: .milliseconds(1000))
                guard let window = ClipboardQuestionPanel.window, let target = argument("SurimonoSnapshotPath"),
                    target.hasPrefix("/")
                else { return }
                do {
                    try await capturePNG(around: window).write(to: URL(fileURLWithPath: target), options: .atomic)
                    captured = true
                    if flag("SurimonoSnapshotQuit") { quitAfterCapture() }
                } catch {
                    DebugSnapshotProgress.failed(error)
                }
            }
        }

        private static func askClipboardQuestion(_ path: String, over window: NSWindow?) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            ClipboardWindows.shared.open(
                text: text, hints: .init(), title: String(localized: "Clipboard") + " " + time, source: .clipboard,
                window: window, printing: false, alwaysAsks: true)
        }

        /// `-SurimonoOpenGettingStarted YES` opens the bundled guide the way the welcome window and the Help menu do,
        /// so that its window is the one captured. `-SurimonoSnapshotWelcome YES` shows the welcome window to capture.
        static func openGettingStarted() {
            if flag("SurimonoOpenGettingStarted") { OpenRouter.shared.openGettingStarted() }
            // An app that `open` launches may not come forward, and then the welcome window waits for the reader.
            if flag("SurimonoSnapshotWelcome") { WelcomeController.shared.show() }
        }

        /// `-SurimonoSnapshotWelcome YES` captures the welcome window, which no document's rendering would trigger.
        static func captureWelcome(_ window: NSWindow) {
            guard flag("SurimonoSnapshotWelcome"), !captured, !scheduled, let path = argument("SurimonoSnapshotPath"),
                path.hasPrefix("/")
            else { return }
            scheduled = true
            Task { @MainActor in
                defer { scheduled = false }
                try? await Task.sleep(for: .milliseconds(800))
                do {
                    let data = try await capturePNG(around: window)
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    captured = true
                    if flag("SurimonoSnapshotQuit") { quitAfterCapture() }
                } catch {
                    DebugSnapshotProgress.failed(error)
                }
            }
        }

        static func configure(_ model: DocumentViewModel) {
            if flag("SurimonoReadingPanel"), model.offersOrgReading { model.isReadingPanelOpen = true }
            if flag("SurimonoFolderNotice") { model.showToast(.folderAccess) }
            if let choice = argument("SurimonoComposition").flatMap(LaTeXComposition.init(rawValue:)) {
                model.snapshotComposition = choice
            }
            // snapshot-capability: reading-typeface. Export finishes before the post-layout window overrides.
            if argument("SurimonoExport") == "reading",
                let face = argument("SurimonoTypeface").flatMap(Typeface.init(rawValue:))
            {
                model.setTypeface(face)
            }
            if let value = argument("SurimonoLayout"), PrintLayout.presets.contains(where: { $0.id == value }) {
                model.layoutID = value
            }
            // Screenshots that leave the machine should not name the printers set up on it.
            if flag("SurimonoHidePrinters") { model.printerListSource = { .empty } }
            if let name = argument("SurimonoPrinterName") { showPrinterName(name, in: model) }
            // A made-up printer that takes A4 and smaller on one side only, to see the badges of what it cannot do.
            if flag("SurimonoPrinterLimits") {
                model.printerListSource = { PrinterList(names: ["Printer"], defaultName: "Printer") }
                model.printerCapabilitiesSource = { _ in
                    PrinterCapabilities(paperSizes: [PaperSize.a4.size, PaperSize.b5.size], duplex: false)
                }
            }
            if flag("SurimonoManualDuplexSheet") {
                isolateManualDuplex(model)
                model.manualDuplexTask = Task { [weak model] in
                    guard let model else { return }
                    do {
                        try await installManualDuplexFixture(
                            model, sheets: argument("SurimonoManualDuplexSheets").flatMap(Int.init) ?? 3,
                            correction: ManualDuplexCorrection(
                                reversesBackOrder: flag("SurimonoManualDuplexReverseBacks"),
                                rotatesBackSides: flag("SurimonoManualDuplexRotateBacks")))
                    } catch {
                        if !(error is CancellationError) {
                            model.outputError = String(localized: "The print job could not be created.")
                        }
                    }
                }
            }
        }

        /// Puts a printer of the given name on the tray, to see how the press bar fits a long name. The name may be
        /// that of a printer set up on this Mac, so every way out to a printer is replaced: Print, the duplex test
        /// print and manual duplex reach `sent` and nothing else, and no correction is saved. Its abilities are left
        /// unknown.
        static func showPrinterName(
            _ name: String, in model: DocumentViewModel, sent: @escaping (String) -> Void = { _ in }
        ) {
            model.printerListSource = { PrinterList(names: [name], defaultName: name) }
            model.printerCapabilitiesSource = { _ in nil }
            model.printSubmit = { _, request, _ in sent("print \(request.printerName ?? "")") }
            model.duplexTestSubmit = { _, _, request, complete in
                sent("duplexTest \(request.printerName ?? "")")
                complete(nil)
            }
            model.manualDuplexSubmit = { submission, complete in
                sent("manualDuplex \(submission.request.printerName ?? "")")
                complete(.notStarted)
            }
            model.manualDuplexSaveCorrection = { _ in }
        }

        private static func isolateManualDuplex(_ model: DocumentViewModel) {
            model.printerListSource = { PrinterList(names: ["Snapshot Printer"], defaultName: "Snapshot Printer") }
            model.printerCapabilitiesSource = { _ in PrinterCapabilities(duplex: false) }
            model.printSubmit = { _, _, _ in }
            model.duplexTestSubmit = { _, _, _, complete in complete(nil) }
            model.manualDuplexSubmit = { submission, complete in
                complete(.handedOff(printerName: submission.request.printerName ?? "Snapshot Printer"))
            }
            // Every session the window starts saves its corrections here, not into the real preferences.
            let preferences = ManualDuplexFixturePreferences()
            model.manualDuplexSaveCorrection = { preferences.correction = $0 }
        }

        /// The fixture has its own preferences and submitter so even its default button cannot reach a printer.
        static func installManualDuplexFixture(
            _ model: DocumentViewModel, sheets: Int = 3, correction: ManualDuplexCorrection = .init()
        ) async throws {
            isolateManualDuplex(model)
            let layout = model.layout.sentDuplex == .none ? PrintLayout.a4Duplex : model.layout
            let count = min(max(sheets, 1), 99)
            let imposition = Imposition.plan(pageCount: count * (layout.kind == .booklet ? 4 : 2), layout: layout)
            let session = ManualDuplexSession(
                printerName: "Snapshot Printer", layout: layout, imposition: imposition, copies: 1,
                pageOrder: .lastSheetFirst, jobTitle: "Manual Duplex Snapshot", language: model.language,
                correction: correction)
            session.saveCorrection = model.manualDuplexSaveCorrection
            session.submitOverride = { _, complete in complete(.handedOff(printerName: "Snapshot Printer")) }
            let data = NSMutableData()
            var box = CGRect(origin: .zero, size: layout.sheetSize)
            guard let consumer = CGDataConsumer(data: data),
                let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else { throw ManualFixtureError.invalidPDF }
            for index in 0..<imposition.sides.count {
                context.beginPDFPage(nil)
                let label = NSAttributedString(
                    string: "Sheet \(index / 2 + 1) \(index % 2 == 0 ? "Front" : "Back")",
                    attributes: [.font: NSFont.systemFont(ofSize: 24)])
                context.textPosition = CGPoint(x: 40, y: box.height - 60)
                CTLineDraw(CTLineCreateWithAttributedString(label), context)
                context.endPDFPage()
            }
            context.closePDF()
            guard let document = PDFDocument(data: data as Data) else { throw ManualFixtureError.invalidPDF }
            try await session.prepare(from: document)
            try Task.checkCancellation()
            _ = session.transition(from: .preparing, to: .sendingFronts)
            _ = session.transition(from: .sendingFronts, to: .awaitingReload)
            model.manualDuplexSession = session
        }

        private enum ManualFixtureError: Error { case invalidPDF }
        private final class ManualDuplexFixturePreferences {
            var correction = ManualDuplexCorrection()
        }

        /// Overrides that must wait until the document's own defaults are known.
        private static func applyOverrides(to model: DocumentViewModel) {
            guard !appliedOverrides else { return }
            appliedOverrides = true
            applyFinishOverrides(to: model)
            if let value = argument("SurimonoViewLayout"), let layout = ViewOptions.Layout(rawValue: value) {
                model.setLayout(layout)
            }
            if argument("SurimonoCoverAlone") != nil {
                model.updateViewOptions { $0.showsCoverAlone = flag("SurimonoCoverAlone") }
            }
            if argument("SurimonoRightToLeft")?.uppercased() == "YES" {
                model.updateViewOptions { $0.direction = .rightToLeft }
            }
            if let value = argument("SurimonoTransition"), let transition = ViewOptions.Transition(rawValue: value) {
                model.updateViewOptions { $0.transition = transition }
            }
            if let value = argument("SurimonoZoom"), let zoom = Double(value) { model.zoom = zoom }
            if argument("SurimonoAlwaysOnTop") != nil { model.isAlwaysOnTop = flag("SurimonoAlwaysOnTop") }
            if argument("SurimonoShowsOnAllSpaces") != nil { model.showsOnAllSpaces = flag("SurimonoShowsOnAllSpaces") }
            if argument("SurimonoSelectText") != nil { model.isSelectingText = flag("SurimonoSelectText") }
            if argument("SurimonoAlwaysShowToolbar") != nil {
                model.isBandAlwaysVisible = flag("SurimonoAlwaysShowToolbar")
            }
            if argument("SurimonoDrawer")?.uppercased() == "YES" { model.isDrawerOpen = true }
            switch argument("SurimonoMenu") {
            case "pinned", "always": model.bandVisibility = .always
            case "compact", "full":
                // Keep older snapshot commands usable with the single visible state.
                NotificationCenter.default.post(name: showMenu, object: model)
            default: break
            }
            switch argument("SurimonoSmartRemoval") {
            case "on": model.setSmartRemoval(enabled: true)
            case "review":
                model.setSmartRemoval(enabled: true)
                model.reviewSmartRemoval()
            default: break
            }
            if let value = argument("SurimonoTypeface").flatMap(Typeface.init(rawValue:)) { model.setTypeface(value) }
            if let value = argument("SurimonoCodePalette") { model.selectCodePalette(value) }
            if let value = argument("SurimonoCodeFrame"), let frame = CodeBlockOptions.Frame(rawValue: value) {
                model.codeBlock.frame = frame
            }
            if let value = argument("SurimonoCodeNumbers"), let numbers = CodeBlockOptions.LineNumbers(rawValue: value)
            {
                model.codeBlock.lineNumbers = numbers
            }
            if let value = argument("SurimonoCodeLong"), let lines = CodeBlockOptions.LongLines(rawValue: value) {
                model.codeBlock.longLines = lines
            }
            if let value = argument("SurimonoCodeLabel"), let label = CodeBlockOptions.LanguageLabel(rawValue: value) {
                model.codeBlock.languageLabel = label
            }
            if argument("SurimonoPopover") == "view" {
                NotificationCenter.default.post(name: showMenu, object: model, userInfo: ["stage": "full"])
                model.isViewOptionsPresented = true
            }
            if argument("SurimonoPopover") == "style", argument("SurimonoMode") != "print" {
                NotificationCenter.default.post(name: showMenu, object: model, userInfo: ["stage": "full"])
                model.openThemePalette()
            }
            if let value = argument("SurimonoPaperSeries"), let series = PaperSeries(rawValue: value) {
                model.choosePaperSeries(series, remembers: false)
            }
            if let value = argument("SurimonoPaperHeight"), let height = Double(value), let window = model.window,
                let unit = model.paperUnitSize
            {
                // A small window, to see what the bands fold away.
                ViewerWindow.setPaperSize(
                    CGSize(width: height * unit.width / unit.height, height: height),
                    band: model.bandInset, of: window,
                    animate: false)
            }
        }

        /// The tray's finish, as if chosen on its strip.
        private static func applyFinishOverrides(to model: DocumentViewModel) {
            if let index = argument("SurimonoSet").flatMap(Int.init) {
                let sets = PrintSettingSet.builtIns(language: model.language)
                if sets.indices.contains(index) { model.applyPrintSettingSet(sets[index]) }
            }
            if let value = argument("SurimonoSeries"), let series = PaperSeries(rawValue: value) {
                // A screenshot leaves the reader's remembered series and default layout alone.
                model.choosePaperSeries(series, remembers: false)
            }
            if let value = argument("SurimonoHeader"), let preset = PageFurniture.Preset(rawValue: value) {
                model.chooseFurniture(preset)
            }
            switch argument("SurimonoBreak") {
            case "h1": model.printFinish.breaks.h1 = .page
            case "right": model.printFinish.breaks.h1 = .rightPage
            default: break
            }
            switch argument("SurimonoTOC") {
            case "head": model.printFinish.toc.mode = .front
            case "hidden": model.printFinish.toc.mode = .hidden
            default: break
            }
            if let value = argument("SurimonoNote"), let preset = NotePaperPreset.preset(id: value) {
                model.chooseNotePreset(id: preset.id, style: preset.style)
                model.notes.isEnabled = true
            }
            switch argument("SurimonoNoteSide") {
            case "left": model.notes.placement = .spreadLeft
            case "right": model.notes.placement = .spreadRight
            case "back": model.notes.placement = .duplexBack
            case "chapter": model.notes.placement = .chapterEnd
            default: break
            }
            if let value = argument("SurimonoMargins") {
                let sides = value.split(separator: ",").compactMap { Double($0) }
                if sides.count == 4 {
                    model.printOptions.linksMargins = false
                    model.printOptions.margins = PageMargins(
                        top: sides[0], left: sides[1], bottom: sides[2], right: sides[3])
                }
            }
            if let value = argument("SurimonoPages") { model.setPageRangeText(value) }
            if let value = argument("SurimonoCopies").flatMap({ Int($0) }) { model.copies = value }
            if flag("SurimonoMirror") { model.printOptions.mirrorsMargins = true }
        }

        static func captureIfReady(_ model: DocumentViewModel) {
            if let session = DebugPageAXSession.current {
                guard !scheduled, !captured, model.window != nil,
                    model.fileURL?.resolvingSymlinksInPath() == session.fixture.resolvingSymlinksInPath()
                else { return }
                scheduled = true
                Task {
                    do {
                        try await DebugPageAXSession.run(model, session: session)
                        captured = true
                        quitAfterCapture()
                    } catch let stopped as DebugPageAXSession.ReaderStopped {
                        logger.error("\(stopped.reason, privacy: .public)")
                        exit(4)
                    } catch {
                        DebugSnapshotProgress.failed(error)
                        exit(EXIT_FAILURE)
                    }
                }
                return
            }
            // A restored window can finish rendering before the requested download.
            if openURLArgument != nil, firstDocument !== model { return }
            if firstDocument == nil { firstDocument = model }
            if flag("SurimonoMenuTiming") {
                guard firstDocument === model, !scheduled, !captured, model.window != nil, model.isUpToDate else {
                    return
                }
                scheduled = true
                Task { @MainActor in
                    do {
                        guard let path = argument("SurimonoMenuTimingPath"), path.hasPrefix("/") else {
                            throw CocoaError(.fileWriteInvalidFileName)
                        }
                        model.window?.makeKeyAndOrderFront(nil)
                        guard DocumentWindows.shared.currentModel === model, let main = NSApp.mainMenu else {
                            throw CocoaError(.coderValueNotFound)
                        }
                        let destination = URL(fileURLWithPath: path)
                        let sources = DocumentWindows.shared.openModels.flatMap(\.protectedSourceURLs)
                        guard DocumentViewModel.canExport(to: destination, sourceURLs: sources) else {
                            throw CocoaError(.fileWriteNoPermission)
                        }
                        try writeMenuTiming(main, to: destination)
                        captured = true
                        if flag("SurimonoSnapshotQuit") { quitAfterCapture() }
                    } catch {
                        DebugSnapshotProgress.failed(error)
                    }
                }
                return
            }
            if let path = ShownDocumentsProbe.path {
                guard firstDocument === model, !scheduled, !captured, model.window != nil else { return }
                scheduled = true
                Task { @MainActor in
                    do {
                        try await ShownDocumentsProbe.run(model, path: path)
                        captured = true
                        quitAfterCapture()
                    } catch {
                        DebugSnapshotProgress.failed(error)
                        exit(EXIT_FAILURE)
                    }
                }
                return
            }
            if firstDocument === model, !captured, !scheduled, model.isUpToDate,
                let kind = argument("SurimonoExport"), let path = argument("SurimonoExportPath"), path.hasPrefix("/")
            {
                scheduled = true
                model.additionalExportTask = Task { @MainActor in
                    defer { model.additionalExportTask = nil }
                    let success = await export(model, kind: kind, path: path)
                    captured = true
                    scheduled = false
                    if success, flag("SurimonoSnapshotQuit") { quitAfterCapture() }
                }
                return
            }
            guard firstDocument === model, !captured, !scheduled, model.isUpToDate, model.window != nil,
                let path = argument("SurimonoSnapshotPath"), path.hasPrefix("/")
            else { return }
            scheduled = true
            applyOverrides(to: model)
            Task { @MainActor [model] in
                defer { scheduled = false }
                // Allow SwiftUI, the window resize and PDFKit to settle.
                try? await Task.sleep(for: .milliseconds(1200))
                guard model.isUpToDate else { return }
                if flag("SurimonoOpenIncludes"), model.includePlan != nil {
                    // The binder's window replaces this one and is the one to capture.
                    firstDocument = nil
                    appliedOverrides = false
                    model.openIncludesAsBinder()
                    return
                }
                // Another display, to see the window at that display's scale (for example a Retina one beside a 1x one).
                if let value = argument("SurimonoScreen"), let index = Int(value),
                    NSScreen.screens.indices.contains(index), let window = model.window
                {
                    let visible = NSScreen.screens[index].visibleFrame
                    window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 20))
                    try? await Task.sleep(for: .milliseconds(800))
                }
                if let value = argument("SurimonoBookmarks") {
                    for page in Set(value.split(separator: ",").compactMap { Int($0) }).sorted() {
                        if !model.bookmarkPages.contains(page - 1) {
                            model.toggleBookmark(page: page - 1, visiblePages: [page - 1])
                        }
                    }
                    model.flushPendingSettings()
                }
                let requestedPage = argument("SurimonoPage").flatMap(Int.init)
                let trialID = argument("SurimonoTryCode").map(DocumentViewModel.codeTrialID) ?? argument("SurimonoTry")
                let previewsPaper =
                    model.mode == .view && argument("SurimonoMode") != "print"
                    && argument("SurimonoMode") != "compare" && argument("SurimonoPopover") != "issues"
                let pageTrialID =
                    requestedPage != nil && previewsPaper && trialID != model.themeID
                        && trialID != DocumentViewModel.codeTrialID(model.codePaletteID) ? trialID : nil
                if let page = requestedPage, pageTrialID == nil {
                    model.paper.goToPage(index: page - 1)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if let words = argument("SurimonoFind") {
                    // As if the reader pressed ⌘F and typed the words.
                    model.performFind()
                    model.find.text = words
                    try? await Task.sleep(for: .milliseconds(900))
                }
                if argument("SurimonoPopover") == "goToPage" {
                    model.presentGoToPage()
                    try? await Task.sleep(for: .milliseconds(800))
                }
                if let value = argument("SurimonoThenLayout"), let layout = ViewOptions.Layout(rawValue: value) {
                    // Change the layout with everything shown, as a reader does with the view options open; the window
                    // then resizes to the new shape.
                    model.setLayout(layout)
                    try? await Task.sleep(for: .milliseconds(1200))
                }
                if let value = argument("SurimonoThenMenu"), let visibility = BandVisibility(rawValue: value) {
                    // Turn the toolbar on or off once the window fits the paper, as ⌥⌘T does.
                    model.bandVisibility = visibility
                    try? await Task.sleep(for: .milliseconds(900))
                }
                if let script = argument("SurimonoPointer"), let window = model.window {
                    await runPointerScript(script, in: window, log: argument("SurimonoPointerLog"))
                }
                // A slide deck is measured once the page has loaded, and the window then takes its shape.
                if model.showsWeb { try? await Task.sleep(for: .milliseconds(1200)) }
                if let slides = argument("SurimonoSlides"), ["on", "off"].contains(slides) {
                    model.setIgnoresSlides(slides == "off")
                    try? await Task.sleep(for: .milliseconds(800))
                }
                if let script = argument("SurimonoWebScript") {
                    // Stands in for a reader using the live page before it is shown as paper.
                    _ = try? await model.web.webView?.evaluateJavaScript(script)
                    try? await Task.sleep(for: .milliseconds(300))
                    // A page's print button opens the tray, which takes its time to show the sheets.
                    if model.mode == .print { try? await Task.sleep(for: .milliseconds(1500)) }
                }
                switch argument("SurimonoPresentation") {
                case "paper":
                    model.setHTMLPresentation(.paper)
                    try? await Task.sleep(for: .milliseconds(1500))
                case "roundtrip":
                    // To paper and back, to check that the live page continues where it was.
                    model.setHTMLPresentation(.paper)
                    try? await Task.sleep(for: .milliseconds(1500))
                    model.setHTMLPresentation(.web)
                    try? await Task.sleep(for: .milliseconds(600))
                default: break
                }
                if let number = argument("SurimonoScrub").flatMap(Int.init) {
                    let room = argument("SurimonoScrubRoom").flatMap(Double.init)
                    NotificationCenter.default.post(
                        name: showMenu, object: model, userInfo: room.map { ["scrubRoom": CGFloat($0)] })
                    if number > 0 {
                        for _ in 0..<100 where model.scrubber.frame.width == 0 {
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        model.scrubThumbnailReady = { [weak model] generation, page in
                            model?.snapshotScrubImage = (generation, page)
                        }
                        model.scrubber.point(model.pageTrack.fraction(for: number - 1), immediately: true)
                    }
                }
                // The table of contents is read after the pages are laid out.
                if ["toc", "outline", "stats"].contains(argument("SurimonoPopover")) || flag("SurimonoOutlineDrawer")
                    || argument("SurimonoContentsTab") == "prose"
                {
                    NotificationCenter.default.post(name: showMenu, object: model)
                    try? await Task.sleep(for: .milliseconds(600))
                    if let tab = argument("SurimonoContentsTab").flatMap(
                        DocumentSettings.ContentsPanel.Tab.init(rawValue:))
                    {
                        model.snapshotContentsTab = tab
                    }
                    switch argument("SurimonoPopover") {
                    case "toc", "outline": model.isOutlinePresented = true
                    case "stats": model.isFiguresPresented = true
                    default:
                        model.snapshotOutlineDrawer = true
                        if model.imageBundle != nil {
                            model.isDrawerOpen = true
                        } else {
                            model.isOutlineDrawerOpen = true
                        }
                    }
                    if let query = argument("SurimonoOutlineFilter") {
                        model.outlineFilter.setQuery(query, entries: model.outlineEntries)
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                }
                if flag("SurimonoWaitForChange") {
                    // The caller saves the file while this waits, as a reader does in an editor.
                    for _ in 0..<150 where model.paperChangeMarks.isEmpty {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(1200))
                }
                if argument("SurimonoMode") == "print" || argument("SurimonoPopover") == "issues" {
                    // After the page script, so that the tray shows the page as it was left.
                    model.enterPrintMode()
                    try? await Task.sleep(for: .milliseconds(1500))
                }
                if model.mode == .print {
                    if let size = argument("SurimonoTraySize")?.split(separator: "x").compactMap({ Double($0) }),
                        size.count == 2
                    {
                        model.window?.setContentSize(NSSize(width: size[0], height: size[1]))
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                    // The tray's choices of what to print a web page as.
                    switch argument("SurimonoTray") {
                    case "original": model.setPrintsOriginalPage(true)
                    case "openDetails": model.setOpensClosedDetails(true)
                    case "currentSlide": model.setPrintsCurrentSlideOnly(true)
                    default: break
                    }
                    if argument("SurimonoTray") != nil { try? await Task.sleep(for: .milliseconds(1500)) }
                    // The press bar exists only in print mode, so its popover opens after entering it.
                    if argument("SurimonoPopover") == "issues" {
                        model.reviewPrintIssues()
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                    if argument("SurimonoPopover") == "printOptions" {
                        model.isPrintFinishPresented = true
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                    let section = finishSectionArgument()
                    if flag("SurimonoFinishSheet") || section != nil {
                        model.finishSection = section
                        model.showsNoteAdjustments = flag("SurimonoNoteAdjust")
                        model.isPrintFinishPresented = true
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                }
                if let index = argument("SurimonoIssueFrame").flatMap(Int.init), model.mode == .print,
                    model.printIssues.indices.contains(index)
                {
                    // As if 「該当箇所を確認」 were pressed for that problem: the paper shows its page, framed for a moment.
                    model.showPrintIssue(model.printIssues[index])
                    try? await Task.sleep(for: .milliseconds(1700))
                }
                if argument("SurimonoMode") == "compare" {
                    model.enterCompareMode()
                    if let size = argument("SurimonoTraySize")?.split(separator: "x").compactMap({ Double($0) }),
                        size.count == 2
                    {
                        // After the window has taken the stage's size, which would undo this one.
                        try? await Task.sleep(for: .milliseconds(900))
                        model.window?.setContentSize(NSSize(width: size[0], height: size[1]))
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                    await model.followComparePlaces()
                    if let index = argument("SurimonoComparePlace").flatMap(Int.init) {
                        let places = model.themeSamples.places
                        if places.indices.contains(index) { model.comparePlace = places[index] }
                        try? await Task.sleep(for: .milliseconds(1500))
                    }
                    if argument("SurimonoPopover") == "comparePlace" {
                        model.isComparePlacePickerPresented = true
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                if argument("SurimonoPopover") == "style" {
                    if let value = argument("SurimonoSampleSource"), let source = ThemeSampleSource(rawValue: value) {
                        model.preferences.themeSampleSource = source
                    }
                    model.openThemePalette()
                    // The palette samples the themes it shows.
                    try? await Task.sleep(for: .milliseconds(2500))
                }
                if argument("SurimonoPopover") == "print", model.mode == .view {
                    // The view mode's print settings, off the window's edge; -SurimonoFinishSheet scrolls them.
                    model.finishSection = finishSectionArgument()
                    model.presentPrintSettings()
                    try? await Task.sleep(for: .milliseconds(900))
                }
                if let theme = argument("SurimonoTry") {
                    // As if the pointer rested on the theme in the palette.
                    model.hoverPaletteTheme(theme)
                    if pageTrialID == nil { try? await Task.sleep(for: .milliseconds(2500)) }
                }
                if let palette = argument("SurimonoTryCode") {
                    // As if the pointer rested on the palette's row.
                    model.tryCodePalette(palette)
                    if pageTrialID == nil { try? await Task.sleep(for: .milliseconds(2500)) }
                }
                if let pageTrialID, let page = requestedPage {
                    do {
                        try await showTrialPage(page, of: pageTrialID, in: model)
                    } catch {
                        DebugSnapshotProgress.failed(error)
                        return
                    }
                }
                if argument("SurimonoMode") == "roundtrip" {
                    // Into the print mode and back, to check that the view mode returns as it was.
                    model.enterPrintMode()
                    try? await Task.sleep(for: .milliseconds(900))
                    model.exitPrintMode()
                    try? await Task.sleep(for: .milliseconds(900))
                }
                if let turn = argument("SurimonoTurn") {
                    if let progress = argument("SurimonoTurnAt").flatMap(Double.init), (0...1).contains(progress) {
                        // Hold the turn still at that share of its length, to look at it frame by frame.
                        PaperPDFView.frozenTurnProgress = progress
                        model.paper.turnPage(forward: turn != "back")
                        try? await Task.sleep(for: .milliseconds(800))
                    } else {
                        // Turn one page with a ten times slower animation and capture it halfway.
                        PaperPDFView.animationScale = 10
                        model.paper.turnPage(forward: turn != "back")
                        try? await Task.sleep(
                            for: .milliseconds(model.viewOptions.transition == .pageCurl ? 2200 : 1300))
                    }
                }
                if flag("SurimonoPaletteJump"), let marker = paletteJumpMarker, let window = marker.window {
                    openMenu(
                        in: window, at: marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil))
                    try? await Task.sleep(for: .milliseconds(1200))
                }
                if flag("SurimonoMoreMenu"), let window = model.window {
                    // As if "…" were clicked, to see what it holds; the menu closes again after the capture.
                    openMoreMenu(of: model, in: window)
                    try? await Task.sleep(for: .milliseconds(1200))
                }
                if flag("SurimonoFormatMenu"), let window = model.window {
                    // The format on the band of a text from the clipboard, clicked open.
                    openMoreMenu(of: model, in: window, at: .item(.formatBadge))
                    try? await Task.sleep(for: .milliseconds(1200))
                }
                if let path = argument("SurimonoClipboardQuestion"), let window = model.window {
                    // The question as a sheet on this document's window.
                    askClipboardQuestion(path, over: window)
                    try? await Task.sleep(for: .milliseconds(1200))
                }
                if model.isUpToDate, !loggedMoreMenu, flag("SurimonoMoreMenuLog") {
                    loggedMoreMenu = true
                    // Only operation IDs are public; never log the document header or user-selected style names.
                    let entries = BandMenuContent(model: model).groups.map {
                        $0.entries.map { $0.id.rawValue }.joined(separator: ",")
                    }.joined(separator: " | ")
                    logger.info("More menu: \(entries, privacy: .public)")
                }
                if let path = argument("SurimonoHitMap"), let window = model.window {
                    try? hitMap(of: window).write(toFile: path, atomically: true, encoding: .utf8)
                }
                if let width = argument("SurimonoBandCaptureWidth").flatMap(Double.init), width >= 320,
                    let window = model.window, let content = window.contentView
                {
                    window.setContentSize(NSSize(width: width, height: content.bounds.height))
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if let name = argument("SurimonoSettings") {
                    // The Settings window in place of the document's, opened as from the app menu.
                    model.preferences.settingsSection =
                        SettingsSection.allCases.first { String(describing: $0) == name } ?? .general
                    DebugSnapshotProgress.report("Opening Settings: " + name)
                    AppKitShell.current?.showSettings(nil)
                    let deadline = ContinuousClock.now + .seconds(8)
                    DebugSnapshotProgress.report("Waiting for visible Settings window: " + name)
                    repeat {
                        settingsWindow = NSApp.windows.first {
                            $0.isVisible && $0.identifier == SettingsWindowController.windowID
                        }
                        if settingsWindow != nil { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    } while ContinuousClock.now < deadline
                    guard settingsWindow != nil else {
                        DebugSnapshotProgress.failed(SnapshotDeadline(stage: "Settings window: " + name))
                        return
                    }
                    // `-SurimonoSettingsSize 820x540`: the content size, such as the smallest the window allows.
                    if let size = argument("SurimonoSettingsSize")?.split(separator: "x").compactMap({ Double($0) }),
                        size.count == 2
                    {
                        settingsWindow?.setContentSize(NSSize(width: size[0], height: size[1]))
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if let states = argument("SurimonoArrangementEditor"), let editor = BandArrangementEditorSession.app
                    {
                        do {
                            try await configureArrangementEditor(states, editor: editor)
                        } catch {
                            DebugSnapshotProgress.failed(error)
                            return
                        }
                    }
                    if let settingsWindow { probeArrangementUndo(in: settingsWindow) }
                    if quitsArrangementEditor {
                        // From a run loop timer, as ⌘Q would: AppKit waits for the editor's answer in a nested run
                        // loop, which drains the main queue only when it was not entered from a main-queue block.
                        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                            MainActor.assumeIsolated { NSApp.terminate(nil) }
                        }
                        RunLoop.main.add(timer, forMode: .common)
                        try? await Task.sleep(for: .milliseconds(1200))
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                do {
                    let target = argument("SurimonoSettings") == nil ? model.window : settingsWindow
                    guard let window = target else { throw CocoaError(.fileNoSuchFile) }
                    let doc = window === model.window
                    let folded = flag("SurimonoFold")
                    let requestedMode = argument("SurimonoMode")
                    let surface: SnapshotSurface
                    if !doc || requestedMode == "compare" {
                        surface = .window
                    } else if folded {
                        surface = .paper
                    } else if requestedMode == "print" {
                        surface = .tray
                    } else {
                        surface = model.mode == .view && !model.showsWeb ? .paper : .window
                    }
                    let data = try await capturePNG(
                        around: window, includeChildren: openURLArgument == nil, surface: surface
                    ) {
                        if !doc, orgDefaultsFixture?.target != nil, window.attachedSheet?.isVisible != true {
                            return "Waiting for the Org defaults alert"
                        }
                        guard doc else { return nil }
                        if requestedMode == "print" && model.mode != .print { return "Waiting for the print tray" }
                        if requestedMode == "compare" && model.mode != .compare {
                            return "Waiting for the compare stage"
                        }
                        if folded && !model.showsFold { return "Waiting for the folded book" }
                        if !model.isUpToDate { return "Waiting for the current document render" }
                        if let number = argument("SurimonoScrub").flatMap(Int.init) {
                            if argument("SurimonoScrubRoom") != nil {
                                guard let width = model.snapshotScrubWidth, let content = window.contentView,
                                    abs(content.bounds.width - width) <= 1, model.bandAnchors.plan?.bottom != nil
                                else { return "Waiting for the measured bottom band" }
                            }
                            if number == 0, model.scrubber.frame.width > 0 { return "Waiting for the scrubber to fold" }
                            if number > 0,
                                model.snapshotScrubImage?.page != number - 1
                                    || model.snapshotScrubImage?.generation != model.thumbnailGeneration
                            {
                                return "Waiting for the scrubber thumbnail"
                            }
                        }
                        if model.snapshotContentsTab == .prose {
                            if !model.snapshotProseReady { return "Waiting for the writing check" }
                            if argument("SurimonoProseFinding") != nil && !model.paper.showsProseMark {
                                return "Waiting for the marked finding"
                            }
                        }
                        if model.snapshotContentsTab == .pages,
                            model.snapshotThumbnailRequests.isEmpty
                                || model.snapshotThumbnailRequests.values.contains(false)
                        {
                            return "Waiting for the visible page thumbnails"
                        }
                        if ViewerWindow.isResizingProgrammatically(window) { return "Waiting for window resize" }
                        if model.mode == .print
                            && (!model.hasCurrentPrintPreview || (!model.showsFold && model.trayZoomer?.context == nil))
                        {
                            return "Waiting for imposed sheets and tray layout"
                        }
                        if model.mode == .print, let sheet = argument("SurimonoTraySheet").flatMap(Int.init) {
                            guard
                                let row = model.printTray?.rows.firstIndex(where: { row in
                                    row.sheets.contains { $0.number == sheet }
                                }), let zoomer = model.trayZoomer, let context = zoomer.context
                            else {
                                return "Waiting for sheet \(sheet)"
                            }
                            let geometry = TrayGeometry(context: context, zoom: zoomer.zoom)
                            let target = geometry.offset(showingRow: row, topInset: zoomer.scroll.topInset, x: 0)
                            if abs(zoomer.scroll.offset.y - target.y) > 1 {
                                zoomer.show(row: row, animated: false)
                                return "Scrolling to sheet \(sheet)"
                            }
                        }
                        if model.mode == .compare {
                            guard let comparison = model.themeComparison else { return "Waiting for comparison" }
                            let cards = comparison.candidates.compactMap { model.theme($0) }
                            let tray = model.themeMenu.sections.first { $0.id == model.compareFilterID }?.themes ?? []
                            if let missing = cards.first(where: {
                                model.themeSamples.page(for: $0, at: model.comparePlace) == nil
                            })
                                ?? tray.first(where: { model.themeSamples.page(for: $0) == nil })
                            {
                                return "Waiting for theme sample " + missing.id
                            }
                        }
                        return nil
                    }
                    let destination = URL(fileURLWithPath: path)
                    let sources = model.protectedSourceURLs
                    guard DocumentViewModel.canExport(to: destination, sourceURLs: sources) else {
                        logger.error("Snapshot destination matches an open document; nothing was written")
                        return
                    }
                    DebugSnapshotProgress.report("Writing capture")
                    try data.write(to: destination, options: .atomic)
                    captured = true
                    trackedMenu?.cancelTrackingWithoutAnimation()
                    if argument("SurimonoSnapshotQuit")?.uppercased() == "YES" {
                        // A document window with a sheet attached will not close, which cancels the quit.
                        if model.manualDuplexSession != nil {
                            model.cancelManualDuplex()
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                        // Nor will the Settings window while the arrangement editor's question or sheet is open, and
                        // the quit itself would ask about the draft, which lives only in this run.
                        if let editor = BandArrangementEditorSession.app,
                            editor.pendingLeave != nil || editor.dialog != nil || editor.isDirty
                        {
                            editor.cancelLeave()
                            editor.dialog = nil
                            editor.discardChanges()
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                        quitAfterCapture()
                    }
                } catch {
                    DebugSnapshotProgress.failed(error)
                }
            }
        }

        // -SurimonoExport reading|png|html|richtext -SurimonoExportPath <path>
        // richtext writes the RTFD package, RTF and HTML into an existing folder without using a pasteboard.
        // -SurimonoSnapshotQuit YES terminates after a successful export.
        private static func export(_ model: DocumentViewModel, kind: String, path: String) async -> Bool {
            let destination = URL(fileURLWithPath: path)
            guard DocumentViewModel.canExport(to: destination, sourceURLs: model.protectedSourceURLs) else {
                logger.error("Export destination matches an open document")
                return false
            }
            DebugSnapshotProgress.report("Exporting document")
            DebugSnapshotProgress.recordAppearance(model.window?.effectiveAppearance ?? NSApp.effectiveAppearance)
            switch kind {
            case "reading":
                guard await model.beginReadingPDFExport() else { return false }
                model.completePDFExport(to: destination)
                return model.outputError == nil
            case "png":
                return await model.performReadingExport(
                    .png, destination: destination,
                    dpi: argument("SurimonoExportDPI").flatMap(Double.init))
            case "richtext":
                return await model.performReadingExport(.richText, destination: destination)
            case "html":
                return await model.performReadingExport(.html, destination: destination)
            default:
                logger.error("Unknown export kind")
                return false
            }
        }

        private static func writeMenuTiming(_ main: NSMenu, to destination: URL) throws {
            struct Timing: Encodable {
                let medianMS: Double
                let maximumMS: Double
            }
            struct Measurement: Encodable {
                let menu: String
                let menuNeedsUpdate: Timing?
                let appKitUpdate: Timing
            }
            struct Report: Encodable {
                let iterations: Int
                let menus: [Measurement]
            }
            let iterations = 20
            func measure(_ update: () -> Void) -> Timing {
                let samples = (0..<iterations).map { _ in
                    let start = DispatchTime.now().uptimeNanoseconds
                    update()
                    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                }.sorted()
                let middle = samples.count / 2
                return Timing(medianMS: (samples[middle - 1] + samples[middle]) / 2, maximumMS: samples[iterations - 1])
            }
            let menus = main.items.compactMap(\.submenu)
            guard !menus.isEmpty else { throw CocoaError(.coderValueNotFound) }
            let measurements = menus.map { menu in
                // Keep the application delegate cost distinguishable from AppKit's native validation.
                let delegate = menu.delegate?.menuNeedsUpdate.map { update in measure { update(menu) } }
                return Measurement(menu: menu.title, menuNeedsUpdate: delegate, appKitUpdate: measure { menu.update() })
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let report = Report(iterations: iterations, menus: measurements)
            try encoder.encode(report).write(to: destination, options: .atomic)
        }

        private static func quitAfterCapture() {
            DebugSnapshotProgress.report("Output written; terminating app")
            // Review sheets can veto NSApplication's normal termination. This is a DEBUG-only
            // capture process; its saved snapshot is complete and no review should be applied.
            if NSApp.windows.contains(where: { !$0.sheets.isEmpty }) { exit(EXIT_SUCCESS) }
            NSApp.terminate(nil)
        }

        private static weak var paletteJumpMarker: NSView?

        /// The palette lives in its own popover window, outside the document's band anchors.
        struct PaletteJumpMarker: NSViewRepresentable {
            func makeNSView(context: Context) -> NSView {
                let view = NSView()
                paletteJumpMarker = view
                return view
            }

            func updateNSView(_ view: NSView, context: Context) {}
        }

        private static weak var trackedMenu: NSMenu?
        private static var menuObserver: NSObjectProtocol?

        /// Clicks the control under "…" from a run loop timer rather than from this task: the menu tracks in a nested
        /// run loop, which drains the main queue only when it was not entered from a main-queue block.
        private static func openMoreMenu(
            of model: DocumentViewModel, in window: NSWindow, at anchor: BandAnchors.Anchor = .more
        ) {
            guard let frame = model.bandAnchors.frames[anchor], let content = window.contentView else { return }
            let local = NSPoint(x: frame.midX, y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY)
            openMenu(in: window, at: content.convert(local, to: nil))
        }

        private static func openMenu(in window: NSWindow, at point: NSPoint) {
            guard let content = window.contentView else { return }
            var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            while let candidate = view, !(candidate is NSControl) { view = candidate.superview }
            menuObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { note in
                // Safe: the observer is called on the main queue, where the menu lives.
                nonisolated(unsafe) let menu = note.object as? NSMenu
                MainActor.assumeIsolated { trackedMenu = menu }
            }
            let control = view as? NSControl
            // A menu drawn as a plain button is no AppKit control; a click in the window opens it as a pointer would.
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let control { return control.performClick(nil) }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                        {
                            window.sendEvent(event)
                        }
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        /// The section of the print settings that `-SurimonoFinishSheet` names.
        private static func finishSectionArgument() -> PrintFinishSection? {
            let sections: [String: PrintFinishSection] = [
                "furniture": .furniture, "breaks": .breaks, "contents": .contents, "notes": .notes,
                "printer": .printer,
            ]
            return argument("SurimonoFinishSheet").flatMap { sections[$0] }
        }

        /// Stands in for the reader's pointer: each step of `x,y,ms;…` puts the pointer at that offset from the paper's
        /// top-left corner as it was on the screen when the script started, and holds it there. The window's frame is
        /// written every 50 ms, to see whether the bands come and go under a still pointer.
        private static func runPointerScript(_ script: String, in window: NSWindow, log path: String?) async {
            let content = window.contentRect(forFrameRect: window.frame)
            let origin = NSPoint(x: content.minX, y: content.maxY)
            var lines: [String] = []
            let start = Date()
            for (index, step) in script.split(separator: ";").enumerated() {
                let parts = step.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 3 else { continue }
                PointerTracker.TrackerView.debugMouseLocation = NSPoint(x: origin.x + parts[0], y: origin.y - parts[1])
                for _ in 0..<max(Int(parts[2] / 50), 1) {
                    try? await Task.sleep(for: .milliseconds(50))
                    let frame = window.frame
                    let lights = window.standardWindowButton(.closeButton).map { !$0.isHidden && $0.alphaValue > 0 }
                    lines.append(
                        "\(Int(Date().timeIntervalSince(start) * 1000)) step=\(index) y=\(Int(frame.minY)) "
                            + "top=\(Int(frame.maxY)) height=\(Int(frame.height)) lights=\(lights ?? false)")
                }
            }
            PointerTracker.TrackerView.debugMouseLocation = nil
            if let path { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        }

        /// Which view takes a click across the window's top 52pt, every 4pt: `L` a traffic light, `T` the title bar
        /// (a toolbar item viewer over the content), `.` the content. Toolbar item viewers' frames come first.
        private static func hitMap(of window: NSWindow) -> String {
            // The window's root view, which holds the title bar in front of the content.
            var root = window.contentView
            while let parent = root?.superview { root = parent }
            guard let frame = root else { return "" }
            func viewers(_ view: NSView) -> [NSView] {
                (String(describing: type(of: view)).contains("ToolbarItemViewer") ? [view] : [])
                    + view.subviews.flatMap(viewers)
            }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            var lines = viewers(frame).map { "viewer \($0.convert($0.bounds, to: nil))" }
            for y in stride(from: 2.0, through: 50, by: 4) {
                var row = String(format: "y%02.0f ", y)
                for x in stride(from: 0.0, to: frame.bounds.width, by: 4) {
                    var view = frame.hitTest(NSPoint(x: x, y: frame.bounds.height - y))
                    var mark: Character = "."
                    while let current = view {
                        if buttons.contains(where: { $0 === current }) {
                            mark = "L"
                            break
                        }
                        if String(describing: type(of: current)).contains("Titlebar") { mark = "T" }
                        view = current.superview
                    }
                    row.append(mark)
                }
                lines.append(row)
            }
            return lines.joined(separator: "\n") + "\n"
        }

        static func showTrialPage(_ number: Int, of trialID: String, in model: DocumentViewModel) async throws {
            let deadline = ContinuousClock.now + .seconds(35)
            let stage = "Waiting for trial PDF page " + String(number)
            DebugSnapshotProgress.report(stage)
            // SwiftUI may still have the original PDF installed after the trial renderer publishes its result.
            repeat {
                if model.themeTrial.themeID == trialID, let source = model.themeTrial.document {
                    guard number > 0, number <= source.pageCount else { break }
                    if model.paper.showSnapshotPage(number - 1, in: source) { return }
                }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            throw SnapshotDeadline(stage: stage)
        }

        private static func capturePNG(
            around window: NSWindow, includeChildren: Bool = true,
            surface: SnapshotSurface = .window, ready: () -> String? = { nil }
        ) async throws -> Data {
            try await DebugWindowCapture.png(
                around: window, children: includeChildren, requiresChild: argument("SurimonoPopover") == "view",
                trackingMenu: trackedMenu != nil, surface: surface, ready: ready)
        }
    }
#endif
