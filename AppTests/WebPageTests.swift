import AppKit
import Foundation
import Testing
import WebKit

@testable import Surimono

@MainActor
struct WebPageNavigationTests {
    private let document = URL(fileURLWithPath: "/Documents/page.html")

    private func decide(
        _ url: String, _ type: WKNavigationType, _ target: WebPageController.NavigationTarget = .mainFrame
    ) throws -> WebPageController.NavigationDecision {
        WebPageController.decision(for: try #require(URL(string: url)), type: type, target: target, document: document)
    }

    @Test("文書の枠では、ウェブのリンクとメールはクリックしたときだけ外で開き、ほかの移動は取り消す")
    func mainFrame() throws {
        #expect(try decide("https://example.com/", .linkActivated) == .openExternally)
        #expect(try decide("http://example.com/a", .linkActivated) == .openExternally)
        #expect(try decide("mailto:someone@example.com", .linkActivated) == .openExternally)
        #expect(try decide("https://example.com/", .other) == .cancel)
        #expect(try decide("https://example.com/", .formSubmitted) == .cancel)
        #expect(try decide("file:///Documents/other.html", .linkActivated) == .cancel)
        #expect(try decide("javascript:alert(1)", .linkActivated) == .cancel)
    }

    @Test("文書そのものの読み込み・再読み込み・文書の中の移動は窓の中で行い、文書へのフォームの送信は取り消す")
    func sameDocument() throws {
        #expect(try decide("file:///Documents/page.html", .other) == .allow)
        #expect(try decide("file:///Documents/page.html", .reload) == .allow)
        #expect(try decide("file:///Documents/page.html#q1", .linkActivated) == .allow)
        #expect(try decide("file:///Documents/page.html#top", .backForward) == .allow)
        #expect(try decide("file:///Documents/page.html", .formSubmitted) == .cancel)
    }

    @Test("文書の中の枠は文書が入れた物を読み、枠へのフォームの送信は取り消し、枠のリンクも同じ決まりに従う")
    func subframes() throws {
        #expect(try decide("https://example.com/embed", .other, .subframe) == .allow)
        #expect(try decide("file:///Documents/frame.html", .other, .subframe) == .allow)
        #expect(try decide("https://example.com/post", .formSubmitted, .subframe) == .cancel)
        #expect(try decide("https://example.com/post", .formResubmitted, .subframe) == .cancel)
        #expect(try decide("https://example.com/", .linkActivated, .subframe) == .openExternally)
        #expect(try decide("file:///Documents/other.html", .linkActivated, .subframe) == .cancel)
    }

    @Test("新しい窓は利用者が開いたときだけ、ウェブとメールを外で開く")
    func newWindows() throws {
        #expect(try decide("https://example.com/", .linkActivated, .newWindow(byUser: true)) == .openExternally)
        #expect(try decide("https://example.com/", .other, .newWindow(byUser: false)) == .cancel)
        #expect(try decide("file:///Documents/other.html", .linkActivated, .newWindow(byUser: true)) == .cancel)
        #expect(try decide("javascript:alert(1)", .other, .newWindow(byUser: true)) == .cancel)
    }
}

/// Hosts the real web page controller in a window and sends real key events to it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebPageKeyTests {
    private let page = """
        <!doctype html><meta charset="utf-8"><body style="height: 3000px">
        <p>Key fixture</p>
        <script>
        window.keys = [];
        window.preventsEscape = false;
        document.addEventListener('keydown', event => {
          keys.push(event.key);
          if (event.key === 'Escape' && preventsEscape) event.preventDefault();
        });
        </script></body>
        """

    @MainActor private struct Host {
        let controller: WebPageController
        let window: NSWindow
        let directory: URL
        let menu: OverlayMenuState

        func close() {
            controller.close()
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func host() async throws -> Host {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("keys.html")
        try Data(page.utf8).write(to: file)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = WebPageController()
        let menu = OverlayMenuState()
        controller.container.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        controller.container.onEscape = { menu.hideForEscape(pinned: false) }
        window.contentView = controller.container
        controller.show(file, allowsJavaScript: true)
        window.orderFrontRegardless()
        let host = Host(controller: controller, window: window, directory: directory, menu: menu)
        try await waitUntil { await keys(host) != nil }
        controller.focus()
        menu.showFull()
        return host
    }

    private func keys(_ host: Host) async -> [String]? {
        try? await host.controller.webView?.evaluateJavaScript("window.keys") as? [String]
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        // Up to 20 seconds: a web content process may start slowly on a busy machine.
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The condition was not met in time")
    }

    private func send(_ host: Host, characters: String, keyCode: UInt16) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: host.window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            host.window.sendEvent(event)
        }
    }

    private let arrow = "\u{F703}"

    @Test("ウェブでは矢印・スペース・文字・Tab が文書に届き、帯は動かない")
    func keysReachThePage() async throws {
        let host = try await host()
        defer { host.close() }
        #expect(host.window.firstResponder === host.controller.webView)
        try send(host, characters: arrow, keyCode: 124)
        try send(host, characters: " ", keyCode: 49)
        try send(host, characters: "m", keyCode: 46)
        try send(host, characters: "\t", keyCode: 48)
        try await waitUntil { await keys(host)?.count == 4 }
        #expect(await keys(host) == ["ArrowRight", " ", "m", "Tab"])
        #expect(host.menu.stage == .full)
    }

    @Test("文書が使わなかった Esc は帯を隠す")
    func unhandledEscapeHidesTheBand() async throws {
        let host = try await host()
        defer { host.close() }
        try send(host, characters: "\u{1b}", keyCode: 53)
        try await waitUntil { await keys(host) == ["Escape"] }
        try await waitUntil { host.menu.stage == .hidden }
        #expect(host.menu.stage == .hidden)
    }

    @Test("文書が preventDefault した Esc では帯を隠さない")
    func handledEscapeKeepsTheBand() async throws {
        let host = try await host()
        defer { host.close() }
        _ = try await host.controller.webView?.evaluateJavaScript("window.preventsEscape = true")
        try send(host, characters: "\u{1b}", keyCode: 53)
        try await waitUntil { await keys(host) == ["Escape"] }
        // WebKit answers asynchronously; give an unhandled key time to come back before checking.
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.menu.stage == .full)
    }

    @Test("JavaScript の設定を変えると、ページを新しい設定で開き直す")
    func javaScriptSettingRecreatesThePage() async throws {
        let host = try await host()
        defer { host.close() }
        var restarts = 0
        host.controller.onRestart = { restarts += 1 }
        let file = host.directory.appendingPathComponent("keys.html")
        host.controller.show(file, allowsJavaScript: true)
        #expect(restarts == 0)
        host.controller.show(file, allowsJavaScript: false)
        #expect(restarts == 1)
        #expect(host.controller.allowsJavaScript == false)
        try await waitUntil { host.controller.webView?.isLoading == false && host.controller.webView?.url != nil }
        let ran = try await host.controller.webView?.evaluateJavaScript("typeof window.keys") as? String
        #expect(ran == "undefined")
    }
}
