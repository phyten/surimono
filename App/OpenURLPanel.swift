import AppKit
import SurimonoCore
import SwiftUI

final class OpenURLPanel: NSWindowController, NSWindowDelegate {
    private static var current: OpenURLPanel?
    private var download: Task<Void, Never>?

    static func present() {
        if let current {
            current.showWindow(nil)
            return
        }
        let address = URLDocument.address(NSPasteboard.general.string(forType: .string))
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = String(localized: "Open from URL…")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        let controller = OpenURLPanel(window: panel)
        let host = NSHostingController(
            rootView: OpenURLView(address: address?.absoluteString ?? "", controller: controller))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        panel.delegate = controller
        current = controller
        panel.center()
        controller.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    static func openDocument(
        at url: URL, beforeOpening: () -> Void = {},
        didOpen: @escaping (MemoryDocumentWindowController) -> Void = { _ in }
    ) async throws {
        let page = try await URLDocument.load(url)
        try Task.checkCancellation()
        beforeOpening()
        let windows = ClipboardWindows.shared
        if page.format == .plainText {
            windows.open(
                text: TextDecoding.decode(page.data).text, hints: .init(), title: page.title,
                source: .url, window: NSApp.mainWindow, printing: false, originalData: page.data,
                baseURL: page.url, didOpen: didOpen)
        } else {
            didOpen(windows.open(page.data, format: page.format, title: page.title, baseURL: page.url))
        }
    }

    func open(_ url: URL, report: @escaping (String) -> Void) {
        guard download == nil else { return }
        download = Task { [weak self] in
            do {
                try await Self.openDocument(at: url, beforeOpening: { self?.close() })
            } catch {
                guard !Task.isCancelled else { return }
                self?.download = nil
                switch error {
                case URLDocument.Failure.requiresHTTPS: report(String(localized: "Only HTTPS pages can be opened."))
                case URLDocument.Failure.tooLarge: report(String(localized: "The document exceeds 20 MB."))
                case URLDocument.Failure.unsupportedFormat:
                    report(String(localized: "This document format cannot be opened."))
                case let error as URLError where error.code == .timedOut:
                    report(String(localized: "The request timed out."))
                default: report(String(localized: "The document could not be downloaded."))
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        download?.cancel()
        download = nil
        window?.contentViewController = nil
        Self.current = nil
    }
}

private struct OpenURLView: View {
    @State var address: String
    let controller: OpenURLPanel
    @State private var message: String?
    @State private var loading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("URL", text: $address)
                .focused($focused)
                .disabled(loading)
                .onChange(of: address) { message = nil }
            if let message {
                Text(verbatim: message).foregroundStyle(PrintPalette.ink2)
            }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { controller.close() }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    guard let url = URLDocument.address(address) else {
                        message = String(localized: "Enter an http or https URL.")
                        return
                    }
                    loading = true
                    message = nil
                    controller.open(url) { error in
                        loading = false
                        message = error
                        focused = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading)
            }
        }
        .padding(18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(PrintPalette.chrome)
        .onAppear { focused = true }
    }
}
