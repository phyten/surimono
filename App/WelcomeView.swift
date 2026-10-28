import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Let Finder's initial open-document event reach DocumentGroup first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if NSDocumentController.shared.documents.isEmpty { WelcomeController.shared.show() }
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
    @State private var error: String?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "printer").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Drop a file to preview and print")
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    for url in files { open(url) }
                    return !files.isEmpty
                } isTargeted: {
                    isTargeted = $0
                }
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut("o")
            if !recent.isEmpty {
                Text("Recent Files").font(.headline)
                List(recent.prefix(6), id: \.self) { url in
                    Button {
                        open(url)
                    } label: {
                        Text(verbatim: url.lastPathComponent)
                    }
                    .buttonStyle(.plain).help(url.path)
                }
            }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
        }
        .padding(24)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recent = NSDocumentController.shared.recentDocumentURLs
        }
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { self.error = error.localizedDescription }
        }
    }
}
