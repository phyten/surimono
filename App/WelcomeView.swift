import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        RecentFileHistory.shared?.restoreOnLaunch()
        NSWindow.allowsAutomaticWindowTabbing = false
        // The document controller's launch-time open panel opens a multi-file selection one document at a time and
        // bypasses OpenRouter. The welcome window offers Open… instead.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // DocumentGroup can consume document URLs before the delegate receives openURLs.
        // Intercept the complete Apple event to preserve the user's multi-file selection.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openDocuments(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        // A service can be what launches the app, and its request comes right after launch.
        ServiceProvider.shared.register()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        OpenRouter.shared.open(urls)
    }

    /// File > Open… sends this action along the responder chain. Answering it before the document controller keeps a
    /// multi-file selection together instead of opening every file as its own document.
    @objc func openDocument(_ sender: Any?) {
        OpenRouter.shared.showOpenPanel()
    }

    @objc private func openDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        application(NSApp, open: Self.documentURLs(in: event))
    }

    static func documentURLs(in event: NSAppleEventDescriptor) -> [URL] {
        guard let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)), list.numberOfItems > 0
        else { return [] }
        return (1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue }
    }

    /// A window's settings are saved a moment after a change, and quitting does not close the windows first.
    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeys.shared.stop()
        DocumentWindows.shared.flushPendingSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let preferences = ClipboardWindows.shared.preferences {
            GlobalHotKeys.shared.start(preferences: preferences)
        }
        DocumentEditMenu.startHiding()
        #if DEBUG
            // Screenshots of a clipboard window open a file's text through a private pasteboard, leaving the user's
            // clipboard alone.
            if let path = DebugSnapshot.argument("SurimonoOpenClipboard"),
                let text = try? String(contentsOfFile: path, encoding: .utf8)
            {
                let board = NSPasteboard(name: .init("SurimonoDebugClipboard"))
                board.clearContents()
                board.setString(text, forType: .string)
                ClipboardWindows.shared.open(from: board)
            }
            DebugSnapshot.openFeeds()
        #endif
        // Restored windows appear shortly after launch; do not cover them with the welcome window. A rejected
        // multi-file selection opens nothing, so the welcome window still follows its alert.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            OpenRouter.shared.showWelcomeAfterLaunch()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // What brought the app forward may be a file to open, which arrives right after.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            OpenRouter.shared.showWelcomeOnArrival()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WelcomeController.shared.show() }
        return true
    }
}

final class WelcomeController {
    static let shared = WelcomeController()
    private var window: NSWindow?
    var preferences: AppPreferences?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Surimono"
        // The washi color runs up under the title bar, as it does on the print screen.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(preferences: preferences ?? AppPreferences()))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() { window?.close() }
}

private struct WelcomeView: View {
    let preferences: AppPreferences
    @State private var recent: [URL] =
        RecentFileHistory.shared?.visibleURLs ?? NSDocumentController.shared.recentDocumentURLs
    @State private var window: NSWindow?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            Button {
                ClipboardWindows.shared.open()
            } label: {
                Text("Open from Clipboard").underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(PrintPalette.ink2)
            if !recent.isEmpty { recentFiles }
        }
        .padding(24)
        // The window takes its height from this view, whose minimum width is the window's: at a narrower width the
        // message would wrap letter by letter and the minimum height would grow with it.
        .frame(minWidth: 500, maxWidth: .infinity)
        .background(PrintPalette.chrome)
        // The whole window takes the drop; the dashed zone only shows where files go.
        .dropDestination(for: URL.self) { urls, _ in
            OpenRouter.shared.open(urls, from: window)
        } isTargeted: {
            isTargeted = $0
        }
        .background(WindowReader { window = $0 })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recent = RecentFileHistory.shared?.visibleURLs ?? NSDocumentController.shared.recentDocumentURLs
        }
    }

    /// Where files go, always on show: the print screen's stage color with a dashed edge, which turns to the accent
    /// color while a drag is over the window. Vermilion stays with the Print button.
    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "printer").font(.system(size: 36)).foregroundStyle(PrintPalette.ink3)
            Text("Drop a file to preview and print")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PrintPalette.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open…") { OpenRouter.shared.showOpenPanel() }
                .keyboardShortcut("o")
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(PrintPalette.stage)
                if isTargeted { RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)) }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(PrintPalette.line3),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
    }

    private var recentFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Files").font(.system(size: 13, weight: .bold)).foregroundStyle(PrintPalette.ink)
                .padding(.horizontal, 8)
            // At most six rows, so the window takes their height and nothing scrolls.
            VStack(spacing: 0) {
                ForEach(recent.prefix(6), id: \.self) { url in
                    RecentFileRow(url: url)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecentFileRow: View {
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            let started = url.startAccessingSecurityScopedResource()
            let leases =
                started ? [FolderAccess.Lease(url: url, release: { url.stopAccessingSecurityScopedResource() })] : []
            OpenRouter.shared.open([url], access: leases)
        } label: {
            Text(verbatim: url.lastPathComponent)
                .font(.system(size: 13))
                .foregroundStyle(PrintPalette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background { RoundedRectangle(cornerRadius: 6).fill(isHovered ? PrintPalette.hover : .clear) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.path)
    }
}
