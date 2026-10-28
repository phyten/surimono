import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // The document controller's launch-time open panel opens a multi-file selection one document at a time and
        // bypasses OpenRouter. The welcome window offers Open… instead.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // DocumentGroup can consume document URLs before the delegate receives openURLs.
        // Intercept the complete Apple event to preserve the user's multi-file selection.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openDocuments(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restored windows appear shortly after launch; do not cover them with the welcome window. A rejected
        // multi-file selection opens nothing, so the welcome window still follows its alert.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            OpenRouter.shared.showWelcomeIfIdle()
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Surimono"
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
    @State private var recent: [URL] = NSDocumentController.shared.recentDocumentURLs
    @State private var window: NSWindow?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "printer").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Drop a file to preview and print")
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            Button("Open…") { OpenRouter.shared.showOpenPanel() }
                .keyboardShortcut("o")
            if !recent.isEmpty {
                Text("Recent Files").font(.headline)
                List(recent.prefix(6), id: \.self) { url in
                    Button {
                        OpenRouter.shared.open([url])
                    } label: {
                        Text(verbatim: url.lastPathComponent)
                    }
                    .buttonStyle(.plain).help(url.path)
                }
            }
        }
        .padding(24)
        .dropDestination(for: URL.self) { urls, _ in
            OpenRouter.shared.open(urls, from: window)
        } isTargeted: {
            isTargeted = $0
        }
        .background(WindowReader { window = $0 })
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recent = NSDocumentController.shared.recentDocumentURLs
        }
    }
}
