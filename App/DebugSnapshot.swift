#if DEBUG
    import AppKit
    import OSLog
    import ScreenCaptureKit
    import SurimonoCore

    /// Launch arguments for screenshots in development builds. They never apply to Release builds.
    enum DebugSnapshot {
        static let showMenu = Notification.Name("SurimonoDebugShowMenu")
        private static var captured = false
        private static weak var firstDocument: DocumentViewModel?
        private static var scheduled = false
        private static var appliedOverrides = false
        private static let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "Snapshot")

        static func argument(_ name: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        static func flag(_ name: String) -> Bool { argument(name)?.uppercased() == "YES" }

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

        static func configure(_ model: DocumentViewModel) {
            // The app follows the system appearance; screenshots of both appearances force one for the whole app.
            switch argument("SurimonoAppearance") {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
            if let value = argument("SurimonoLayout"), PrintLayout.presets.contains(where: { $0.id == value }) {
                model.layoutID = value
            }
            // Screenshots that leave the machine should not name the printers set up on it.
            if flag("SurimonoHidePrinters") { model.printerListSource = { .empty } }
            // A made-up printer that takes A4 and smaller on one side only, to see the badges of what it cannot do.
            if flag("SurimonoPrinterLimits") {
                model.printerListSource = { PrinterList(names: ["Printer"], defaultName: "Printer") }
                model.printerCapabilitiesSource = { _ in
                    PrinterCapabilities(paperSizes: [PaperSize.a4.size, PaperSize.b5.size], duplex: false)
                }
            }
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
            if let value = argument("SurimonoPaperSeries"), let series = ViewPaperSeries(rawValue: value) {
                model.paperSeries = series
            }
            if let value = argument("SurimonoPaperHeight"), let height = Double(value), let window = model.window,
                let unit = model.paperUnitSize
            {
                // A small window, to see what the bands fold away.
                ViewerWindow.setPaperSize(
                    CGSize(width: height * unit.width / unit.height, height: height),
                    band: ViewerWindow.bandHeight * CGFloat(model.menuArrangement.bandCount), of: window,
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
                // A screenshot leaves the reader's remembered series alone.
                let remembered = model.preferences.paperSeries
                model.choosePaperSeries(series)
                model.preferences.paperSeries = remembered
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
                if ["toc", "stats"].contains(argument("SurimonoPopover")) || flag("SurimonoOutlineDrawer") {
                    NotificationCenter.default.post(name: showMenu, object: model)
                    try? await Task.sleep(for: .milliseconds(600))
                    switch argument("SurimonoPopover") {
                    case "toc": model.toggleOutline()
                    case "stats": model.isFiguresPresented = true
                    default: model.isOutlineDrawerOpen = true
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
                    let sections: [String: PrintFinishSection] = [
                        "furniture": .furniture, "breaks": .breaks, "contents": .contents, "notes": .notes,
                        "printer": .printer,
                    ]
                    let section = argument("SurimonoFinishSheet").flatMap { sections[$0] }
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
                    // Turn one page with a ten times slower animation and capture it halfway.
                    PaperPDFView.animationScale = 10
                    model.paper.turnPage(forward: turn != "back")
                    try? await Task.sleep(for: .milliseconds(model.viewOptions.transition == .pageCurl ? 2200 : 1300))
                }
                do {
                    guard let window = model.window else { return }
                    let data = try await capturePNG(around: window)
                    let destination = URL(fileURLWithPath: path)
                    let sources = model.protectedSourceURLs
                    guard DocumentViewModel.canExport(to: destination, sourceURLs: sources) else {
                        logger.error("Snapshot destination matches an open document; nothing was written")
                        return
                    }
                    try data.write(to: destination, options: .atomic)
                    captured = true
                    if argument("SurimonoSnapshotQuit")?.uppercased() == "YES" { NSApp.terminate(nil) }
                } catch {
                    logger.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        /// Captures the document window together with the popovers and other small windows of this process next to
        /// it, as composited by the window server. Capturing the app's own windows needs no screen recording permission.
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
