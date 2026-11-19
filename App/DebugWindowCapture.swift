#if DEBUG
    import AppKit
    import QuartzCore
    import CoreVideo
    import ScreenCaptureKit
    import SwiftUI

    enum SnapshotSurface { case window, paper, tray }

    @MainActor
    enum DebugWindowCapture {
        private static let muted = NSHashTable<NSWindow>.weakObjects()
        private static var monitor: Any?
        private static var observers: [NSObjectProtocol] = []
        private static let popoverOwners = NSMapTable<NSWindow, NSWindow>.weakToWeakObjects()
        private static var insertionColors: [NSTextView: NSColor] = [:]
        static let requested = DebugSnapshot.argument("SurimonoSnapshotPath")?.hasPrefix("/") == true
        static var ignoresRealPointer: Bool { monitor != nil }

        /// Start before the first window is shown: a SwiftUI tile can latch its hover before the first screenshot.
        static func begin() {
            guard monitor == nil else { return }
            DebugSnapshotProgress.start()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseEntered, .mouseMoved, .cursorUpdate]) { _ in nil
            }
            for name in [
                NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didUpdateNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                        // Delivered on the main queue, so the notification never leaves the main actor.
                        nonisolated(unsafe) let note = note
                        MainActor.assumeIsolated { if let window = note.object as? NSWindow { mute(window) } }
                    })
            }
            // Some AppKit popovers are separate panels, without a public childWindows entry.
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSPopover.didShowNotification, object: nil, queue: .main
                ) { note in
                    nonisolated(unsafe) let note = note
                    MainActor.assumeIsolated {
                        if let popover = note.object as? NSPopover,
                            let panel = popover.contentViewController?.view.window,
                            let owner = panel.parent ?? NSApp.mainWindow, owner !== panel
                        {
                            popoverOwners.setObject(owner, forKey: panel)
                            mute(panel)
                        }
                    }
                })
            NSApp.windows.forEach(mute)
        }

        private static func mute(_ window: NSWindow) {
            guard !window.ignoresMouseEvents else { return }
            muted.add(window)
            window.ignoresMouseEvents = true
        }

        private static func finish() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for window in muted.allObjects { window.ignoresMouseEvents = false }
            muted.removeAllObjects()
            popoverOwners.removeAllObjects()
            for (editor, color) in insertionColors { editor.insertionPointColor = color }
            insertionColors.removeAll()
        }

        private static func family(_ root: NSWindow, children: Bool) -> [NSWindow] {
            var result = [root]
            guard children else { return result }
            var index = 0
            while index < result.count {
                let parent = result[index]
                let panels = popoverOwners.keyEnumerator().allObjects.compactMap { $0 as? NSWindow }
                    .filter { popoverOwners.object(forKey: $0) === parent }
                for child in (parent.childWindows ?? []) + [parent.attachedSheet].compactMap({ $0 }) + panels
                where child.isVisible && !result.contains(child) { result.append(child) }
                index += 1
            }
            return result
        }

        // snapshot-capability: opaque-ui
        // Native title bars and popover arrows live outside the SwiftUI hosting view.
        private static func prepareSurfaces(_ window: NSWindow) {
            let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if window.styleMask.contains(.titled) {
                let background = NSColor(
                    srgbRed: dark ? 0.15 : 0.96, green: dark ? 0.15 : 0.96,
                    blue: dark ? 0.15 : 0.96, alpha: 1)
                if window.backgroundColor != background { window.backgroundColor = background }
            }
            if window.colorSpace != .sRGB { window.colorSpace = .sRGB }
            for view in descendants(window.contentView?.superview) {
                if let effect = view as? NSVisualEffectView {
                    if effect.blendingMode != .withinWindow { effect.blendingMode = .withinWindow }
                    if effect.state != .active { effect.state = .active }
                    // contentBackground is AppKit's opaque content material. The popover's own mask keeps its arrow.
                    switch effect.material {
                    case .titlebar, .popover, .sidebar, .sheet, .windowBackground, .underWindowBackground:
                        effect.material = .contentBackground
                    default: break
                    }
                }
            }
        }

        private static func descendants(_ view: NSView?) -> [NSView] {
            guard let view, !view.isHidden else { return [] }
            return [view] + view.subviews.flatMap { descendants($0) }
        }

        private static func animating(_ layer: CALayer) -> Bool {
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key), animation.speed > 0,
                    animation.duration > 0
                else { continue }
                if animation.isRemovedOnCompletion { return true }
            }
            return (layer.sublayers ?? []).contains(where: animating)
        }

        private static func clearFocus(_ windows: [NSWindow]) throws {
            for window in windows {
                mute(window)
                // A search field can reuse its field editor during a focus transition between samples.
                if let editor = (window.firstResponder as? NSTextView)
                    ?? (window.fieldEditor(false, for: nil) as? NSTextView),
                    insertionColors[editor] == nil
                {
                    insertionColors[editor] = editor.insertionPointColor
                    editor.insertionPointColor = .clear
                }
                if window.firstResponder !== window {
                    window.endEditing(for: nil)
                    guard window.makeFirstResponder(nil) else { throw CocoaError(.userCancelled) }
                }
                window.displayIfNeeded()
            }
            CATransaction.flush()
        }

        static func png(
            around root: NSWindow, children: Bool = true, requiresChild: Bool = false, trackingMenu: Bool = false,
            surface: SnapshotSurface = .window, ready: () -> String? = { nil }
        ) async throws -> Data {
            defer { finish() }
            DebugSnapshotProgress.recordAppearance(root.effectiveAppearance)
            let windows = family(root, children: children)
            DebugSnapshotProgress.report("Clearing the field editor and laying out windows")
            try clearFocus(windows)
            var aligned = Set<ObjectIdentifier>()
            func pending() -> String? {
                let current = family(root, children: children)
                for window in current {
                    prepareSurfaces(window)
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                CATransaction.flush()
                if let reason = ready() { return reason }
                if requiresChild && current.count == 1 { return "Expected popover is missing" }
                let views = current.flatMap { descendants($0.contentView) }.filter { !$0.visibleRect.isEmpty }
                let sheets = views.compactMap { $0 as? SheetPageNSView }
                if surface == .tray && (sheets.isEmpty || sheets.contains(where: { !$0.snapshotDrawn })) {
                    return "Waiting for visible imposed sheets to draw"
                }
                let pdfs = views.compactMap { $0 as? PageTextPDFView }
                if surface == .paper && pdfs.isEmpty { return "Waiting for the PDF view" }
                for pdf in pdfs {
                    if let paper = pdf as? PaperPDFView, paper.document != nil,
                        aligned.insert(ObjectIdentifier(paper)).inserted
                    {
                        paper.alignSnapshotPaper()
                        // Request a display at final size even if another app covers the document.
                        paper.window?.display()
                    }
                    // PDFKit renders tiles off the main actor. Only visibility can be checked on the view.
                    if pdf.visiblePages.isEmpty { return "PDFKit has no visible page yet" }
                }
                if current.compactMap({ $0.contentView?.superview?.layer }).contains(where: animating) {
                    return "Waiting for window animations"
                }
                return nil
            }
            let deadline = ContinuousClock.now + .seconds(35)
            var issue = pending()
            while let reason = issue, ContinuousClock.now < deadline {
                DebugSnapshotProgress.report(reason)
                try await Task.sleep(for: .milliseconds(50))
                issue = pending()
            }
            let result = try await CaptureSequence.settle {
                try await frame(root, children: children, requiresChild: requiresChild, trackingMenu: trackingMenu)
            } matches: {
                $0.matches($1)
            } pause: {
                try await Task.sleep(for: .milliseconds(300))
            }
            let last = result.frame
            let observation = CaptureObservation(
                isKeyWindow: last.key, appActive: last.active,
                attempts: result.attempts, stable: result.stable,
                readinessIssue: !last.complete ? "Incomplete window family" : issue ?? pending())
            // snapshot-capability: capture-dpi
            // snapshot-capability: capture-stability
            return try observation.png(image: last.image, scale: last.scale)
        }

        private static func frame(_ root: NSWindow, children: Bool, requiresChild: Bool, trackingMenu: Bool)
            async throws
            -> CaptureFrame
        {
            let listStage = "ScreenCaptureKit window list"
            DebugSnapshotProgress.report(listStage)
            let content = try await CaptureSequence.bounded(listStage, limit: .seconds(8)) {
                try await SCShareableContent.currentProcess
            }
            DebugSnapshotProgress.report("Clearing focus and preparing window layers")
            let windows = family(root, children: children)
            windows.forEach(prepareSurfaces)
            try clearFocus(windows)
            let ids = Set(windows.map { CGWindowID($0.windowNumber) })
            guard let main = content.windows.first(where: { $0.windowID == CGWindowID(root.windowNumber) })
            else { throw CocoaError(.fileNoSuchFile) }
            let scale = CGFloat(SCContentFilter(desktopIndependentWindow: main).pointPixelScale)
            let order = NSWindow.windowNumbers(options: []) ?? []
            let layers = content.windows.filter {
                ids.contains($0.windowID)
                    || (trackingMenu && $0.isOnScreen && $0.windowLayer == NSWindow.Level.popUpMenu.rawValue)
            }.sorted { a, b in
                if a.windowID == main.windowID || b.windowID == main.windowID {
                    return a.windowID != b.windowID && a.windowID == main.windowID
                }
                if a.windowLayer != b.windowLayer { return a.windowLayer < b.windowLayer }
                let aRank = order.firstIndex(of: NSNumber(value: a.windowID)) ?? -1
                let bRank = order.firstIndex(of: NSNumber(value: b.windowID)) ?? -1
                return aRank == bRank ? a.windowID < b.windowID : aRank > bRank
            }
            guard let layout = CaptureGeometry(root: main.frame, layers: layers.map(\.frame), scale: scale)
            else { throw CocoaError(.fileReadCorruptFile) }
            let canvas = try layout.makeCanvas()
            for (layer, rect) in zip(layers, layout.destinations) {
                let config = SCStreamConfiguration()
                config.width = Int(rect.width)
                config.height = Int(rect.height)
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
                config.includeChildWindows = false
                config.shouldBeOpaque = false
                config.backgroundColor = .clear
                let imageStage = "ScreenCaptureKit window image"
                DebugSnapshotProgress.report(imageStage)
                let image = try await CaptureSequence.bounded(imageStage, limit: .seconds(8)) {
                    try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: layer), configuration: config)
                }
                canvas.draw(image, in: rect)
            }
            // Discard a frame if editing resumed while ScreenCaptureKit was sampling the windows.
            guard !windows.contains(where: { $0.firstResponder is NSText }),
                let image = canvas.makeImage(), let pixels = image.dataProvider?.data
            else { throw CocoaError(.fileReadCorruptFile) }
            let finalFamily = family(root, children: children)
            let visibleIDs = Set(finalFamily.map { CGWindowID($0.windowNumber) })
            let complete =
                visibleIDs == ids && ids.isSubset(of: layers.map(\.windowID))
                && (!requiresChild || windows.count > 1)
            return CaptureFrame(
                image: image, pixels: pixels, scale: scale, key: root.isKeyWindow, active: NSApp.isActive,
                complete: complete)
        }
    }

    struct SnapshotSettingsSurface: ViewModifier {
        let sidebar: Bool
        @Environment(\.colorScheme) private var scheme

        func body(content: Content) -> some View {
            if DebugWindowCapture.requested {
                // System sidebar and form materials can tint even an already opaque dark window.
                let white = scheme == .dark ? (sidebar ? 0.17 : 0.14) : (sidebar ? 0.96 : 1.0)
                content.scrollContentBackground(.hidden)
                    .background(Color(.sRGB, white: white).ignoresSafeArea())
            } else {
                content
            }
        }
    }

    extension View {
        @ViewBuilder func snapshotControlAppearance() -> some View {
            if DebugWindowCapture.requested {
                self.environment(\.appearsActive, true)
                    .allowsHitTesting(false)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            } else {
                self
            }
        }
    }
#endif
