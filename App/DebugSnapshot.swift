#if DEBUG
    import AppKit
    import CoreText
    import PDFKit
    import OSLog
    import ScreenCaptureKit
    import SurimonoCore

    /// Launch arguments for screenshots in development builds. They never apply to Release builds.
    enum DebugSnapshot {
        static let showMenu = Notification.Name("SurimonoDebugShowMenu")
        private static var captured = false
        private static var loggedMoreMenu = false
        private static weak var firstDocument: DocumentViewModel?
        private static var scheduled = false
        private static var appliedOverrides = false
        private static weak var settingsWindow: NSWindow?
        private static var quitsArrangementEditor = false
        private static let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "Snapshot")

        static func argument(_ name: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        static func flag(_ name: String) -> Bool { argument(name)?.uppercased() == "YES" }

        // Settings photography only: read process arguments into view state, never preferences.
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
        static func configureArrangementEditor() {
            guard let states = argument("SurimonoArrangementEditor"), let editor = BandArrangementEditorSession.app
            else { return }
            for state in states.split(separator: ",") {
                let fields = state.split(separator: ":").map(String.init)
                switch fields[0] {
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
                    logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
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
                    logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        static func configure(_ model: DocumentViewModel) {
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
            if argument("SurimonoCoverAlone")?.uppercased() == "YES" {
                model.updateViewOptions { $0.showsCoverAlone = true }
            }
            if argument("SurimonoRightToLeft")?.uppercased() == "YES" {
                model.updateViewOptions { $0.direction = .rightToLeft }
            }
            if let value = argument("SurimonoTransition"), let transition = ViewOptions.Transition(rawValue: value) {
                model.updateViewOptions { $0.transition = transition }
            }
            if let value = argument("SurimonoZoom"), let zoom = Double(value) { model.zoom = zoom }
            if argument("SurimonoAlwaysOnTop")?.uppercased() == "YES" { model.isAlwaysOnTop = true }
            if argument("SurimonoSelectText")?.uppercased() == "YES" { model.isSelectingText = true }
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
            if firstDocument == nil { firstDocument = model }
            guard firstDocument === model, !captured, !scheduled, model.isUpToDate, model.window != nil,
                let path = argument("SurimonoSnapshotPath"), path.hasPrefix("/")
            else { return }
            scheduled = true
            applyOverrides(to: model)
            Task { @MainActor in
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
                if let value = argument("SurimonoPage"), let page = Int(value) {
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
                if argument("SurimonoSlides") == "off" {
                    model.setIgnoresSlides(true)
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
                // The table of contents is read after the pages are laid out.
                if ["toc", "outline", "stats"].contains(argument("SurimonoPopover")) || flag("SurimonoOutlineDrawer") {
                    NotificationCenter.default.post(name: showMenu, object: model)
                    try? await Task.sleep(for: .milliseconds(600))
                    switch argument("SurimonoPopover") {
                    case "toc", "outline": model.isOutlinePresented = true
                    case "stats": model.isFiguresPresented = true
                    default:
                        model.snapshotOutlineDrawer = true
                        model.isOutlineDrawerOpen = true
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
                    // Wait for the four pages and the row to finish sampling.
                    try? await Task.sleep(for: .milliseconds(2500))
                    if let index = argument("SurimonoComparePlace").flatMap(Int.init) {
                        await model.followComparePlaces()
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
                    try? await Task.sleep(for: .milliseconds(2500))
                }
                if let palette = argument("SurimonoTryCode") {
                    // As if the pointer rested on the palette's row.
                    model.tryCodePalette(palette)
                    try? await Task.sleep(for: .milliseconds(2500))
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
                if let name = argument("SurimonoSettings") {
                    // The Settings window in place of the document's, opened as from the app menu.
                    model.preferences.settingsSection =
                        SettingsSection.allCases.first { String(describing: $0) == name } ?? .general
                    configureArrangementEditor()
                    if let menu = NSApp.mainMenu?.items.first?.submenu,
                        let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," })
                    {
                        menu.performActionForItem(at: index)
                    }
                    try? await Task.sleep(for: .milliseconds(1200))
                    settingsWindow = NSApp.windows.first {
                        $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true
                    }
                    // `-SurimonoSettingsSize 820x540`: the content size, such as the smallest the window allows.
                    if let size = argument("SurimonoSettingsSize")?.split(separator: "x").compactMap({ Double($0) }),
                        size.count == 2
                    {
                        settingsWindow?.setContentSize(NSSize(width: size[0], height: size[1]))
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    // Out of the picture, which takes in the windows next to the one captured.
                    if settingsWindow != nil { model.window?.orderOut(nil) }
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
                    guard let window = settingsWindow ?? model.window else { return }
                    let data = try await capturePNG(around: window)
                    let destination = URL(fileURLWithPath: path)
                    let sources = model.protectedSourceURLs
                    guard DocumentViewModel.canExport(to: destination, sourceURLs: sources) else {
                        logger.error("Snapshot destination matches an open document; nothing was written")
                        return
                    }
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
                    logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        private static func quitAfterCapture() {
            // Review sheets can veto NSApplication's normal termination. This is a DEBUG-only
            // capture process; its saved snapshot is complete and no review should be applied.
            if NSApp.windows.contains(where: { !$0.sheets.isEmpty }) { exit(EXIT_SUCCESS) }
            NSApp.terminate(nil)
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
            var view = content.hitTest(content.convert(local, to: content.superview))
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
            let point = content.convert(local, to: nil)
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

        /// Captures the document window together with the popovers and other small windows of this process next to
        /// it, as composited by the window server. Capturing the app's own windows needs no screen recording permission.
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

        private static func capturePNG(around window: NSWindow) async throws -> Data {
            let content = try await SCShareableContent.currentProcess
            guard let main = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let nearby = main.frame.insetBy(dx: -700, dy: -400)
            // Leave out the menu bar and status layers and anything as large as a screen.
            let windows = content.windows.filter { other in
                other.windowID == main.windowID
                    || (other.isOnScreen && !(24...25).contains(other.windowLayer)
                        && nearby.contains(other.frame) && other.frame.width > 1 && other.frame.height > 1)
            }
            guard
                let display = content.displays.first(where: { $0.frame.intersects(main.frame) })
                    ?? content.displays.first
            else { throw CocoaError(.fileNoSuchFile) }
            let union = windows.filter { other in
                other.windowID == main.windowID
                    || other.frame.width < display.frame.width * 0.9 || other.frame.height < display.frame.height * 0.9
            }
            .map(\.frame).reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull else { throw CocoaError(.fileNoSuchFile) }
            let filter = SCContentFilter(display: display, including: windows)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.sourceRect = union.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.width = Int(union.width * scale)
            configuration.height = Int(union.height * scale)
            configuration.showsCursor = false
            configuration.backgroundColor = .clear
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }
#endif
