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
        }

        /// Overrides that must wait until the document's own defaults are known.
        private static func applyOverrides(to model: DocumentViewModel) {
            guard !appliedOverrides else { return }
            appliedOverrides = true
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
            if argument("SurimonoDrawer")?.uppercased() == "YES" { model.isDrawerOpen = true }
            switch argument("SurimonoMenu") {
            case "pinned": model.isMenuPinned = true
            case "compact", "full":
                NotificationCenter.default.post(
                    name: showMenu, object: model, userInfo: ["stage": argument("SurimonoMenu") ?? ""])
            default: break
            }
            if argument("SurimonoPopover") == "view" {
                NotificationCenter.default.post(name: showMenu, object: model, userInfo: ["stage": "full"])
                model.isViewOptionsPresented = true
            }
        }

        static func captureIfReady(_ model: DocumentViewModel) {
            if firstDocument == nil { firstDocument = model }
            guard firstDocument === model, !captured, !scheduled, model.canOutput, model.window != nil,
                let path = argument("SurimonoSnapshotPath"), path.hasPrefix("/")
            else { return }
            scheduled = true
            applyOverrides(to: model)
            Task { @MainActor in
                defer { scheduled = false }
                // Allow SwiftUI, the window resize and PDFKit to settle.
                try? await Task.sleep(for: .milliseconds(1200))
                guard model.canOutput else { return }
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
            let nearby = main.frame.insetBy(dx: -400, dy: -400)
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
