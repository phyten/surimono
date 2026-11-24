import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var appearanceKeeper: AppearanceKeeper?

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
            if DebugWindowCapture.requested { DebugWindowCapture.begin() }
        #endif
        // Before any window exists, so that none shows in the system's appearance first.
        if let preferences = WelcomeController.shared.preferences {
            appearanceKeeper = AppearanceKeeper(preferences: preferences)
            appearanceKeeper?.start()
        }
        let controller = type(of: NSDocumentController.shared)
        if controller != NSDocumentController.self { DocumentShareMenu.useExplicitPlacement(on: controller) }
        // Observe assembly before SwiftUI installs the document group's File submenu.
        ShortcutDispatcher.shared.menus.start()
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

    /// Route external senders of the AppKit action through the same multi-selection panel as the File menu.
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

    /// Quitting does not close the Settings window, whose close asks about an unsaved toolbar arrangement; the editor
    /// asks here instead and holds the quit until the reader answers.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        BandArrangementEditorSession.app?.shouldTerminate() ?? .terminateNow
    }

    /// A window's settings are saved a moment after a change, and quitting does not close the windows first.
    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.remove()
        menuBarController = nil
        DistributedNotificationCenter.default().removeObserver(self)
        ShortcutDispatcher.shared.stop()
        GlobalHotKeys.shared.stop()
        DocumentWindows.shared.flushPendingSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let preferences = ClipboardWindows.shared.preferences {
            menuBarController = MenuBarController(preferences: preferences)
            GlobalHotKeys.shared.start()
            ShortcutController.shared.start(preferences: preferences)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(keyboardInputSourceChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        ShortcutDispatcher.shared.start()
        #if DEBUG
            DebugMenuDump.observeTestLaunch()
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
            DebugSnapshot.openURL()
            DebugSnapshot.openFeeds()
            DebugSnapshot.askClipboardQuestion()
            DebugSnapshot.openGettingStarted()
        #endif
        // Restored windows appear shortly after launch; do not cover them with the welcome window. A rejected
        // multi-file selection opens nothing, so the welcome window still follows its alert.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            OpenRouter.shared.showWelcomeAfterLaunch()
        }
    }

    @objc private func keyboardInputSourceChanged() {
        ShortcutController.shared.refresh()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ShortcutController.shared.refresh()
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
        let welcome = WelcomeView(preferences: preferences ?? AppPreferences())
        #if DEBUG
            window.contentView = NSHostingView(rootView: welcome.snapshotControlAppearance())
        #else
            window.contentView = NSHostingView(rootView: welcome)
        #endif
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        #if DEBUG
            DebugSnapshot.captureWelcome(window)
        #endif
    }

    func close() { window?.close() }
}

private struct WelcomeView: View {
    let preferences: AppPreferences
    @State private var recent: [URL] =
        RecentFileHistory.welcomeURLs
    @State private var window: NSWindow?
    @State private var isTargeted = false
    @State private var isGuideHovered = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            if !recent.isEmpty { recentFiles }
            Button("Open Sample Document") { OpenRouter.shared.openSampleDocument() }
                .buttonStyle(.link)
                .foregroundStyle(PrintPalette.ai)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
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
            recent = RecentFileHistory.welcomeURLs
        }
    }

    /// Where files go, always on show: the print screen's stage color with a dashed edge, which turns to the accent
    /// color while a drag is over the window. Vermilion stays with the Print button.
    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "printer").font(.system(size: 36)).foregroundStyle(PrintPalette.ink3)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Drop files to view and print")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                WelcomeFormatsLine()
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ForEach(WelcomeAction.allCases, id: \.self) { action in
                    if action.isPrimary {
                        Button {
                            action.perform()
                        } label: {
                            Text(action.title).frame(minWidth: 68)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PrintPalette.aiControl)
                    } else {
                        Button {
                            action.perform()
                        } label: {
                            Text(action.title)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.large)
            .buttonBorderShape(
                preferences.corners.usesSystemControls
                    ? .automatic
                    : .roundedRectangle(radius: preferences.corners.radius(for: .control, shortestSide: 32)))
            // A third way in for someone who has nothing to open yet. A line of its own keeps the two buttons from
            // crowding at the window's fixed width, and indigo is the color of the print screen's text buttons.
            Button {
                OpenRouter.shared.openGettingStarted()
            } label: {
                Label("Getting Started with Surimono", systemImage: "book")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PrintPalette.ai)
                    .emphasisForDisplayContrast(isGuideHovered)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background {
                        CornerRole.control.shape.fill(isGuideHovered ? PrintPalette.aiTint : .clear)
                    }
                    .contentShape(CornerRole.control.shape)
            }
            .buttonStyle(.plain)
            .onHover { isGuideHovered = $0 }
            .help("A short guide to view, print and fold into a booklet")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                CornerRole.panel.shape.fill(PrintPalette.stage)
                if isTargeted {
                    CornerRole.panel.shape.fill(
                        DisplayAccessibility.shared.options.fill(
                            PrintPalette.ai, opacity: 0.12, over: PrintPalette.stage))
                }
            }
        }
        .overlay {
            CornerRole.panel.shape
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(PrintPalette.ai) : AnyShapeStyle(PrintPalette.line3),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: isTargeted && DisplayAccessibility.shared.options.increasedContrast ? [] : [6, 4]))
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

enum WelcomeAction: CaseIterable {
    case open, clipboard

    var isPrimary: Bool { self == .open }

    var title: LocalizedStringResource {
        switch self {
        case .open: "Open…"
        case .clipboard: "Open from Clipboard"
        }
    }

    func perform() {
        switch self {
        case .open: OpenRouter.shared.showOpenPanel()
        case .clipboard: ClipboardWindows.shared.open()
        }
    }
}

struct WelcomeFormatsLine: View {
    var body: some View {
        Text("Markdown, PDF, Word, LaTeX, Org, images, and more")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.disabled)
    }
}

struct RecentFileRow: View {
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            OpenRouter.shared.openRecent(url)
        } label: {
            // The folder tells apart files of the same name and says where a file is before it opens.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: url.lastPathComponent)
                    .emphasisForDisplayContrast(isHovered)
                    .font(.system(size: 13))
                    .foregroundStyle(PrintPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(verbatim: Self.folder(of: url))
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.ink2)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background { CornerRole.control.shape.fill(isHovered ? PrintPalette.hover : .clear) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.path)
    }

    /// The file's folder, the home folder written as ~. In the sandbox the home directory APIs name the container, so
    /// the reader's own home comes from the account.
    static func folder(of url: URL, home: String = RecentFileRow.userHome) -> String {
        let folder = url.deletingLastPathComponent().path
        guard !home.isEmpty else { return folder }
        if folder == home { return "~" }
        return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }

    static var userHome: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }
}
