#if DEBUG
    import AppKit
    import OSLog
    import ScreenCaptureKit
    import SurimonoCore

    enum DebugSnapshot {
        private static var captured = false
        private static weak var firstDocument: DocumentViewModel?
        private static var scheduled = false
        private static let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "Snapshot")

        private static func argument(_ name: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        static func configure(_ model: DocumentViewModel) {
            if let value = argument("SurimonoAppearance"), let appearance = AppAppearance(rawValue: value) {
                model.appearanceOverride = appearance
            }
            if let value = argument("SurimonoLayout"), PrintLayout.presets.contains(where: { $0.id == value }) {
                model.layoutID = value
            }
            if let value = argument("SurimonoPreviewMode"), let mode = PreviewMode(rawValue: value) {
                model.previewMode = mode
            }
        }

        static func captureIfReady(_ model: DocumentViewModel) {
            if firstDocument == nil { firstDocument = model }
            guard firstDocument === model, !captured, !scheduled, model.canOutput, let window = model.window,
                let path = argument("SurimonoSnapshotPath"), path.hasPrefix("/")
            else { return }
            scheduled = true
            Task { @MainActor in
                defer { scheduled = false }
                // Allow SwiftUI and PDFKit to install and lay out the completed preview.
                try? await Task.sleep(for: .milliseconds(500))
                guard model.canOutput else { return }
                do {
                    let data = try await capturePNG(of: window)
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

        /// Captures the window as composited by the window server. `cacheDisplay` misses layer-backed content such
        /// as PDFView's page tiles, and capturing the app's own windows needs no screen recording permission.
        private static func capturePNG(of window: NSWindow) async throws -> Data {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }
#endif
