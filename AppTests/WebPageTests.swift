import AppKit
import Foundation
import SurimonoCore
import SurimonoRendering
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
        controller.container.onEscape = { menu.hideForEscape(alwaysVisible: false) }
        window.contentView = controller.container
        controller.show(file, allowsJavaScript: true)
        window.orderFrontRegardless()
        let host = Host(controller: controller, window: window, directory: directory, menu: menu)
        do {
            try await waitUntil { await keys(host) != nil }
        } catch {
            host.close()
            throw error
        }
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
            try send(host, type, characters: characters, keyCode: keyCode)
        }
    }

    private func send(_ host: Host, _ type: NSEvent.EventType, characters: String, keyCode: UInt16) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        host.window.sendEvent(event)
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

    @Test("利用者のキーの後の window.print() はアプリに 1 回だけ印刷を頼み、文書からはアプリへの通り道が見えない")
    func windowPrintAsksTheApp() async throws {
        let host = try await host()
        defer { host.close() }
        var requests = 0
        host.controller.onPrintRequest = { requests += 1 }
        try send(host, characters: "p", keyCode: 35)
        try await waitUntil { await keys(host) == ["p"] }
        let visible =
            try await host.controller.webView?.evaluateJavaScript(
                "window.print(); window.print(); typeof (window.webkit && window.webkit.messageHandlers.surimonoPrint)")
            as? String
        try await waitUntil { requests == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(requests == 1)
        #expect(visible == "undefined")
    }

    @Test("タイマーで繰り返す window.print() と、文書が自分で出した依頼のイベントは、利用者の操作がなければ届かない")
    func printWithoutGestureIsIgnored() async throws {
        let host = try await host()
        defer { host.close() }
        var requests = 0
        host.controller.onPrintRequest = { requests += 1 }
        _ = try await host.controller.webView?.evaluateJavaScript(
            """
            window.print();
            document.dispatchEvent(new Event('surimono-print-request'));
            window.printTimer = setInterval(() => window.print(), 50);
            """)
        try await Task.sleep(for: .milliseconds(500))
        #expect(requests == 0)

        // One key lets one request through; the timer cannot use it again.
        try send(host, characters: "p", keyCode: 35)
        try await waitUntil { requests == 1 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(requests == 1)
        _ = try await host.controller.webView?.evaluateJavaScript("clearInterval(window.printTimer)")
    }

    @Test("キーを押したときと離したときの両方でページが印刷を頼んでも、1 回の押下で届く依頼は 1 つだけ")
    func oneKeyPressLetsOneRequestThrough() async throws {
        let host = try await host()
        defer { host.close() }
        var requests = 0
        host.controller.onPrintRequest = { requests += 1 }
        _ = try await host.controller.webView?.evaluateJavaScript(
            """
            window.ups = 0;
            window.addEventListener('keydown', () => window.print());
            window.addEventListener('keyup', () => { window.print(); window.ups += 1; });
            """)
        try send(host, .keyDown, characters: "p", keyCode: 35)
        try await waitUntil { requests == 1 }
        // The release belongs to the same press, so the request the page makes on it does not get through.
        try send(host, .keyUp, characters: "p", keyCode: 35)
        try await waitUntil { await ups(host) == 1 }
        // The page has handled the release; one more round trip lets a request posted from it arrive first.
        _ = await ups(host)
        #expect(requests == 1)
    }

    private func ups(_ host: Host) async -> Int? {
        try? await host.controller.webView?.evaluateJavaScript("window.ups") as? Int
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

/// The copy of the live page must end even when WebKit never answers, and a page whose process ended is loaded
/// again only when the reader asks.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebPageSnapshotDeadlineTests {
    /// Stands in for WebKit: takes the request for a copy and never answers it, as a stopped process does.
    @MainActor private final class HeldReplies {
        private(set) var replies: [WebPaginator.Reply] = []
        var count: Int { replies.count }

        func hold(in controller: WebPageController) {
            controller.startSnapshot = { [self] _, reply in replies.append(reply) }
        }
    }

    /// Stands in for WebKit: takes each load without starting it, so that the test decides how it ends.
    @MainActor private final class HeldNavigations {
        private(set) var navigations: [NSObject] = []
        var last: NSObject { navigations[navigations.count - 1] }

        func hold(in controller: WebPageController) {
            controller.startNavigation = { [self] _, _, _ in
                let navigation = NSObject()
                navigations.append(navigation)
                return navigation
            }
        }
    }

    /// Holds WebKit's real completion so a test can deliver it after a copy is already waiting.
    @MainActor private final class HeldFinish: NSObject, WKNavigationDelegate {
        var finished: WKNavigation?

        func hold(in controller: WebPageController) {
            let start = controller.startNavigation
            controller.startNavigation = { [self] view, url, sandboxed in
                view.navigationDelegate = self
                return start(view, url, sandboxed)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = navigation
        }
    }

    /// Only the test advances load time. Cancelling the controller's timer removes the outstanding alarm.
    @MainActor private final class ManualLoadClock {
        private(set) var now = ContinuousClock.now
        private var alarm: (deadline: ContinuousClock.Instant, fire: @MainActor () -> Void)?

        func install(in controller: WebPageController) {
            controller.loadNow = { self.now }
            controller.scheduleLoadAlarm = { deadline, fire in
                self.alarm = (deadline, fire)
                return { self.alarm = nil }
            }
        }

        func advance(by duration: Duration, firingAlarm: Bool = true) {
            now += duration
            guard firingAlarm, let alarm, now >= alarm.deadline else { return }
            self.alarm = nil
            alarm.fire()
        }
    }

    /// The outcome of a copy running beside the test; nil while it is still waiting.
    @MainActor private final class Copy {
        private(set) var outcome: WebPageController.Snapshot?
        private var task: Task<Void, Never>?

        init(of controller: WebPageController) {
            task = Task { self.outcome = await controller.snapshot() }
        }

        func cancel() { task?.cancel() }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        // Up to 20 seconds: a web content process may start slowly on a busy machine.
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The condition was not met in time")
        throw CancellationError()
    }

    /// Runs `body` with a page that has loaded and been copied once, and with its file.
    private func withPage(sandboxed: Bool = false, _ body: (WebPageController, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("page.html")
        try Data("<!doctype html><meta charset=\"utf-8\"><p>Snapshot fixture</p>".utf8).write(to: file)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = WebPageController()
        controller.isSandboxed = { sandboxed }
        controller.container.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = controller.container
        defer {
            controller.close()
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        // A page never shown has nothing to load again and nothing to copy.
        controller.reload()
        controller.reloadEndedPage()
        controller.applyJavaScriptSetting(false)
        #expect(controller.state == .notShown && controller.loadCount == 0)
        #expect(await controller.snapshot() == .notLoaded)
        controller.show(file, allowsJavaScript: true)
        try await waitUntil { controller.webView?.isLoading == false && controller.webView?.url != nil }
        guard case .captured(let copy) = await controller.snapshot() else {
            Issue.record("The loaded page could not be copied")
            return
        }
        try #require(copy.html.contains("Snapshot fixture"))
        // A live page is not loaded again by Try Again.
        controller.reloadEndedPage()
        try #require(controller.loadCount == 1 && controller.state == .live)
        try await body(controller, file)
    }

    /// Ends the page's process as WebKit reports it (the process of the test's page keeps running), has the reader
    /// ask for the page again, and starts a copy that waits for that load.
    private func copyWaitingForReload(_ controller: WebPageController) async throws -> Copy {
        controller.webViewWebContentProcessDidTerminate(try #require(controller.webView))
        controller.reloadEndedPage()
        #expect(controller.state == .reloading && controller.loadCount == 2)
        let copy = Copy(of: controller)
        try await waitUntil { controller.reloadWaiterCount == 1 }
        #expect(copy.outcome == nil)
        return copy
    }

    @Test("応答のない写しは、締切までは待ち、締切で失敗になる")
    func deadline() async throws {
        try await withPage { controller, _ in
            let held = HeldReplies()
            held.hold(in: controller)
            controller.snapshotTimeout = .seconds(2)
            let started = ContinuousClock.now
            let copy = Copy(of: controller)
            try await waitUntil { held.count == 1 }
            try await Task.sleep(for: .milliseconds(300))
            // Well before the deadline the copy is still waiting.
            try #require(ContinuousClock.now - started < .seconds(1.5))
            #expect(copy.outcome == nil)
            try await waitUntil { copy.outcome != nil }
            #expect(copy.outcome == .failed)
            #expect(ContinuousClock.now - started >= .seconds(2))
            #expect(controller.state == .live)
        }
    }

    @Test("写している途中でプロセスが終わったら長い締切より先に失敗になり、ページを勝手に読み込み直さない")
    func endedProcess() async throws {
        try await withPage { controller, file in
            let webView = try #require(controller.webView)
            let held = HeldReplies()
            held.hold(in: controller)
            // Far beyond the test's limit: only the ended process can end these waits.
            controller.snapshotTimeout = .seconds(300)
            let copy = Copy(of: controller)
            try await waitUntil { held.count == 1 }
            #expect(copy.outcome == nil)
            controller.webViewWebContentProcessDidTerminate(webView)
            try await waitUntil { copy.outcome != nil }
            #expect(copy.outcome == .failed)
            #expect(controller.state == .ended)
            // A later request fails too, without asking the page (it would answer from an empty page) and without
            // reading the file as if no page had been shown. Showing the page again and a second report of the
            // ended process load nothing either.
            #expect(await controller.snapshot() == .failed)
            controller.show(file, allowsJavaScript: true)
            controller.webViewWebContentProcessDidTerminate(webView)
            #expect(await controller.snapshot() == .failed)
            #expect(held.count == 1)
            #expect(controller.state == .ended && controller.loadCount == 1)
        }
    }

    @Test("プロセスが終わったページは、もう一度試すと一度だけ読み込み直し、読み込みを終えてから写す")
    func reloadOnRetry() async throws {
        try await withPage { controller, _ in
            let webView = try #require(controller.webView)
            controller.webViewWebContentProcessDidTerminate(webView)
            // A live process would still answer here; the page changes so that only a reloaded page has the text.
            _ = try await webView.evaluateJavaScript("document.body.innerHTML = '<p>Stale</p>'; 0")
            #expect(await controller.snapshot() == .failed)
            controller.reloadEndedPage()
            controller.reloadEndedPage()
            #expect(controller.loadCount == 2)
            #expect(controller.state == .reloading)
            guard case .captured(let copy) = await controller.snapshot() else {
                Issue.record("The reloaded page was not copied")
                return
            }
            #expect(copy.html.contains("Snapshot fixture") && !copy.html.contains("Stale"))
            #expect(controller.state == .live)
            #expect(controller.loadCount == 2)
        }
    }

    @Test("読み込み直しを待つ写しは、ほかの読み込みの完了では進まず、その読み込みの完了で写す")
    func reloadFinishes() async throws {
        try await withPage { controller, _ in
            let finish = HeldFinish()
            finish.hold(in: controller)
            controller.snapshotTimeout = .seconds(300)
            let copy = try await copyWaitingForReload(controller)
            let webView = try #require(controller.webView)
            // A late report of an earlier load must not pass for this one.
            controller.navigationDidFinish(webView, NSObject())
            try await waitUntil { finish.finished != nil }
            #expect(copy.outcome == nil && controller.state == .reloading)
            controller.navigationDidFinish(webView, finish.finished)
            try await waitUntil { copy.outcome != nil }
            guard case .captured = copy.outcome else {
                Issue.record("The reloaded page was not copied")
                return
            }
            #expect(controller.state == .live && controller.loadCount == 2)
        }
    }

    @Test("読み込み直している途中でまたプロセスが終わったら、待っていた写しは長い締切より先に失敗になる")
    func endedWhileReloading() async throws {
        try await withPage { controller, _ in
            HeldNavigations().hold(in: controller)
            // Far beyond the test's limit: only the ended process can end the wait for the reload.
            controller.snapshotTimeout = .seconds(300)
            let copy = try await copyWaitingForReload(controller)
            let webView = try #require(controller.webView)
            controller.webViewWebContentProcessDidTerminate(webView)
            try await waitUntil { copy.outcome != nil }
            #expect(copy.outcome == .failed)
            #expect(controller.state == .ended && controller.loadCount == 2)
        }
    }

    @Test("読み込み直しが失敗したら待っていた写しは失敗になり、もう一度試すと読み込みがちょうど一つ増える")
    func reloadFails() async throws {
        try await withPage { controller, _ in
            let navigations = HeldNavigations()
            navigations.hold(in: controller)
            controller.snapshotTimeout = .seconds(300)
            let copy = try await copyWaitingForReload(controller)
            let webView = try #require(controller.webView)
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile)
            // The failure of another load is not this one's.
            controller.navigationDidFail(webView, NSObject(), error)
            #expect(controller.state == .reloading)
            controller.navigationDidFail(webView, navigations.last, error)
            try await waitUntil { copy.outcome != nil }
            #expect(copy.outcome == .failed)
            #expect(controller.state == .ended && controller.loadCount == 2)
            #expect(await controller.snapshot() == .failed)
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.loadCount == 3)
            controller.navigationDidFail(try #require(controller.webView), navigations.last, error)
            #expect(controller.state == .ended)
        }
    }

    @Test("読み込み直しが締切まで終わらなければ写しは失敗になり、もう一度試すと新しい読み込みがちょうど一つ始まる")
    func reloadDeadline() async throws {
        try await withPage { controller, _ in
            let navigations = HeldNavigations()
            navigations.hold(in: controller)
            controller.snapshotTimeout = .seconds(2)
            let clock = ManualLoadClock()
            clock.install(in: controller)
            let copy = try await copyWaitingForReload(controller)
            clock.advance(by: .seconds(1))
            #expect(copy.outcome == nil)
            clock.advance(by: .seconds(1))
            try await waitUntil { copy.outcome != nil }
            #expect(copy.outcome == .failed)
            // The unanswered load is given up: the page waits for the reader again instead of for that load.
            #expect(controller.state == .ended && controller.loadCount == 2)
            let abandoned = navigations.last
            controller.reloadEndedPage()
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.loadCount == 3)
            // The load given up cannot finish the new one.
            controller.navigationDidFinish(try #require(controller.webView), abandoned)
            #expect(controller.state == .reloading)
        }
    }

    @Test("初回表示と通常の再読み込みでは、完了を待ち、失敗したら元ファイルや古い本文を使わない", arguments: [false, true])
    func copyDuringOrdinaryLoad(sandboxed: Bool) async throws {
        try await withPage(sandboxed: sandboxed) { controller, file in
            let oldView = try #require(controller.webView)
            _ = try await oldView.evaluateJavaScript("document.body.textContent = 'Old DOM'; 0")
            try Data("<p>New file</p>".utf8).write(to: file)
            let navigations = HeldNavigations()
            navigations.hold(in: controller)
            let replies = HeldReplies()
            replies.hold(in: controller)
            controller.reload()
            let pending = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 1 || replies.count > 0 || pending.outcome != nil }
            try #require(controller.reloadWaiterCount == 1 && replies.count == 0 && pending.outcome == nil)
            let view = try #require(controller.webView)
            #expect(view !== oldView)
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile)
            controller.navigationDidFail(view, navigations.last, error)
            try await waitUntil { pending.outcome != nil }
            #expect(pending.outcome == .failed && replies.count == 0)

            controller.close()
            controller.show(file, allowsJavaScript: true)
            let first = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 1 || first.outcome != nil }
            try #require(controller.reloadWaiterCount == 1 && first.outcome == nil)
            controller.reload()
            try await waitUntil { first.outcome != nil }
            #expect(first.outcome == .failed && replies.count == 0)
        }
    }

    @Test("新しい読み込みを頼んだあとで古いページの開始と完了が届いても、新しい本文の完了まで写さない", arguments: [false, true], [false, true])
    func copyOfUpdatedFile(sandboxed: Bool, recovering: Bool) async throws {
        try await withPage(sandboxed: sandboxed) { controller, file in
            let view = try #require(controller.webView)
            _ = try await view.evaluateJavaScript("document.body.textContent = 'Old DOM'; 0")
            try Data("<p>New file</p>".utf8).write(to: file)
            let finish = HeldFinish()
            finish.hold(in: controller)
            let capture = controller.startSnapshot
            let replies = HeldReplies()
            replies.hold(in: controller)
            if recovering { controller.webViewWebContentProcessDidTerminate(view) }
            controller.reload()
            let current = try #require(controller.webView)
            // P was never registered. Its first notification arrives after the app requested B.
            let p = NSObject()
            controller.navigationDidStart(view, p)
            controller.navigationDidFinish(view, p)
            try await waitUntil { finish.finished != nil }
            let b = try #require(finish.finished)
            controller.navigationDidStart(current, b)
            #expect(controller.state == (recovering ? .reloading : .loading))
            #expect(controller.loadCount == 2)
            let pending = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 1 || replies.count > 0 || pending.outcome != nil }
            try #require(controller.reloadWaiterCount == 1 && replies.count == 0 && pending.outcome == nil)
            current.navigationDelegate = controller
            controller.navigationDidFinish(current, b)
            #expect(controller.state == .live)
            try await waitUntil { replies.count == 1 }
            capture(current, replies.replies[0])
            try await waitUntil { pending.outcome != nil }
            guard case .captured(let copy) = pending.outcome else {
                Issue.record("新しい本文の写しが届かなかった")
                return
            }
            #expect(copy.html.contains("New file") && !copy.html.contains("Old DOM"))
        }
    }

    @Test("ページ自身が再読み込みを始めたら古い写しを捨て、置き換えた読み込みの遅い通知も使わない")
    func pageInitiatedReload() async throws {
        try await withPage { controller, _ in
            let view = try #require(controller.webView)
            let replies = HeldReplies()
            replies.hold(in: controller)
            let old = Copy(of: controller)
            try await waitUntil { replies.count == 1 }
            // The reload can discard the script's reply; observe its navigation on the controller.
            _ = try? await view.evaluateJavaScript("location.reload(); 0")
            try await waitUntil { controller.loadCount == 2 && controller.state == .live }
            replies.replies[0](.success(#"{"html":"Old DOM","closedDetails":0}"#))
            try await waitUntil { old.outcome != nil }
            #expect(old.outcome == .failed)

            // Hold the next provisional navigation to deliver its start and finish out of order.
            let pageLoad = NSObject()
            controller.navigationDidStart(view, pageLoad)
            let waiting = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 1 }
            controller.navigationDidStart(view, pageLoad)
            let newer = NSObject()
            controller.navigationDidStart(view, newer)
            controller.navigationDidStart(view, pageLoad)
            controller.navigationDidFinish(view, pageLoad)
            try await waitUntil { waiting.outcome != nil }
            #expect(waiting.outcome == .failed && replies.count == 1)
            let latest = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 1 }
            controller.navigationDidFinish(view, newer)
            try await waitUntil { replies.count == 2 }
            replies.replies[1](.success(#"{"html":"New DOM","closedDetails":0}"#))
            try await waitUntil { latest.outcome != nil }
            #expect(latest.outcome == .captured(HTMLSnapshot(html: "New DOM")))
        }
    }

    @Test("識別できない開始のあと古い写しが届いても失敗し、対応不明の完了では写せる状態に戻らない")
    func unidentifiedStartInvalidatesCopy() async throws {
        try await withPage { controller, _ in
            let view = try #require(controller.webView)
            let replies = HeldReplies()
            let capture = controller.startSnapshot
            replies.hold(in: controller)
            controller.snapshotTimeout = .seconds(300)
            let old = Copy(of: controller)
            try await waitUntil { replies.count == 1 }
            let unanswered = Copy(of: controller)
            try await waitUntil { replies.count == 2 }
            controller.webView(view, didStartProvisionalNavigation: nil)
            replies.replies[0](.success(#"{"html":"Old DOM","closedDetails":0}"#))
            try await waitUntil { old.outcome != nil && unanswered.outcome != nil }
            #expect(old.outcome == .failed && unanswered.outcome == .failed)
            controller.webView(view, didFinish: nil)
            controller.navigationDidFinish(view, NSObject())
            try #require(controller.state == .ended)
            #expect(await controller.snapshot() == .failed && replies.count == 2)
            controller.startSnapshot = capture
            controller.reloadEndedPage()
            guard case .captured(let copy) = await controller.snapshot() else {
                Issue.record("明示的に読み直したページを写せなかった")
                return
            }
            #expect(copy.html.contains("Snapshot fixture"))
        }
    }

    @Test("最初の表示で読み込みを始められない・読み込みに失敗したページの写しは、ファイルに進まず失敗になる")
    func firstLoadFails() async throws {
        let file = URL(fileURLWithPath: "/Documents/page.html")
        let notStarted = WebPageController()
        defer { notStarted.close() }
        notStarted.startNavigation = { _, _, _ in nil }
        notStarted.show(file, allowsJavaScript: false)
        #expect(notStarted.state == .ended && notStarted.loadCount == 1)
        #expect(await notStarted.snapshot() == .failed)

        let failing = WebPageController()
        defer { failing.close() }
        let navigations = HeldNavigations()
        navigations.hold(in: failing)
        failing.show(file, allowsJavaScript: false)
        let webView = try #require(failing.webView)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile)
        // The failure of another load is not this one's.
        failing.navigationDidFail(webView, NSObject(), error)
        #expect(failing.state == .loading)
        failing.navigationDidFail(webView, navigations.last, error)
        #expect(failing.state == .ended)
        #expect(await failing.snapshot() == .failed)
    }

    @Test("本文を見せていたページの再読み込みを始められなければ、前の本文を写さず失敗になる", arguments: [false, true])
    func reloadOfLivePageNotStarted(sandboxed: Bool) async throws {
        try await withPage { controller, _ in
            let replies = HeldReplies()
            replies.hold(in: controller)
            controller.isSandboxed = { sandboxed }
            controller.startNavigation = { _, _, _ in nil }
            controller.reload()
            #expect(controller.state == .ended && controller.loadCount == 2)
            #expect(await controller.snapshot() == .failed)
            // The page that showed the text before was not asked for a copy.
            #expect(replies.count == 0)
        }
    }

    @Test("待っていた写しの締切を過ぎてから届いた読み込みの完了ではページを生かさず、もう一度試すと新しく読み込む")
    func finishAfterDeadline() async throws {
        try await withPage { controller, _ in
            let navigations = HeldNavigations()
            navigations.hold(in: controller)
            let replies = HeldReplies()
            replies.hold(in: controller)
            let clock = ManualLoadClock()
            clock.install(in: controller)
            controller.snapshotTimeout = .milliseconds(200)
            let copy = try await copyWaitingForReload(controller)
            // Deliver the late finish before the alarm has had its turn on the main actor.
            clock.advance(by: .milliseconds(200), firingAlarm: false)
            controller.navigationDidFinish(try #require(controller.webView), navigations.last)
            #expect(controller.state == .ended)
            try await waitUntil { copy.outcome != nil }
            #expect(copy.outcome == .failed && replies.count == 0)
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.loadCount == 3)
        }
    }

    @Test("二つの写しが同じ読み込み直しを待つとき、一方の取り消しや短い締切では読み込みを止めない")
    func cancelledWaiterLeavesTheReload() async throws {
        try await withPage { controller, _ in
            let finish = HeldFinish()
            finish.hold(in: controller)
            let clock = ManualLoadClock()
            clock.install(in: controller)
            controller.snapshotTimeout = .seconds(300)
            let long = try await copyWaitingForReload(controller)
            let cancelled = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 2 }
            controller.snapshotTimeout = .seconds(1)
            let short = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 3 }
            cancelled.cancel()
            try await waitUntil { cancelled.outcome != nil }
            #expect(controller.reloadWaiterCount == 2)
            clock.advance(by: .seconds(1))
            try await waitUntil { short.outcome != nil }
            #expect(cancelled.outcome == .failed && short.outcome == .failed)
            // The load is still the one the last copy waits for.
            #expect(controller.state == .reloading && long.outcome == nil && controller.loadCount == 2)
            try await waitUntil { finish.finished != nil }
            controller.navigationDidFinish(try #require(controller.webView), finish.finished)
            try await waitUntil { long.outcome != nil }
            guard case .captured = long.outcome else {
                Issue.record("The reloaded page was not copied")
                return
            }
            #expect(controller.state == .live)
        }
    }

    @Test("ファイルを読み直した復旧は、写しを頼まなくても最後の写しを取り消しても締切で終わり、もう一度試せる", arguments: [false, true])
    func unattendedRecovery(cancelOnlyCopy: Bool) async throws {
        try await withPage { controller, _ in
            let view = try #require(controller.webView)
            controller.webViewWebContentProcessDidTerminate(view)
            let navigations = HeldNavigations()
            navigations.hold(in: controller)
            let clock = ManualLoadClock()
            clock.install(in: controller)
            var stops = 0
            controller.stopNavigation = { stopped in
                #expect(stopped !== view)
                stops += 1
                stopped.stopLoading()
            }
            controller.snapshotTimeout = .seconds(1)
            controller.reload()
            let abandoned = navigations.last
            if cancelOnlyCopy {
                controller.snapshotTimeout = .seconds(300)
                let copy = Copy(of: controller)
                try await waitUntil { controller.reloadWaiterCount == 1 }
                copy.cancel()
                try await waitUntil { copy.outcome != nil }
                #expect(copy.outcome == .failed && controller.reloadWaiterCount == 0)
            }
            clock.advance(by: .milliseconds(999))
            #expect(controller.state == .reloading && stops == 0)
            clock.advance(by: .milliseconds(1))
            #expect(controller.state == .ended)
            #expect(controller.loadCount == 2 && stops == 1)
            controller.snapshotTimeout = .seconds(300)
            controller.reloadEndedPage()
            controller.navigationDidFinish(view, abandoned)
            #expect(controller.state == .reloading && controller.loadCount == 3)
            controller.navigationDidFinish(try #require(controller.webView), navigations.last)
            #expect(controller.state == .live && stops == 1)
        }
    }

    @Test("いちばん遅い締切の写しを取り消すと、残った写しの締切で復旧が終わってもう一度試せる")
    func cancellingLatestDeadline() async throws {
        try await withPage { controller, _ in
            let navigations = HeldNavigations()
            navigations.hold(in: controller)
            controller.webViewWebContentProcessDidTerminate(try #require(controller.webView))
            let clock = ManualLoadClock()
            clock.install(in: controller)
            var stops = 0
            controller.stopNavigation = { _ in stops += 1 }
            controller.snapshotTimeout = .seconds(300)
            controller.reload()
            controller.snapshotTimeout = .seconds(1)
            let short = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 1 }
            controller.snapshotTimeout = .seconds(300)
            let long = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 2 }
            long.cancel()
            try await waitUntil { long.outcome != nil }
            #expect(long.outcome == .failed && controller.reloadWaiterCount == 1)
            clock.advance(by: .milliseconds(999))
            #expect(short.outcome == nil && controller.state == .reloading && stops == 0)
            clock.advance(by: .milliseconds(1))
            #expect(controller.state == .ended && stops == 1)
            try await waitUntil { short.outcome != nil }
            #expect(short.outcome == .failed && controller.reloadWaiterCount == 0)
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.loadCount == 3)
        }
    }

    @Test("応答のない復旧の締切を過ぎたらタイマーが動く前でも、もう一度試すと新しい読み込みを始める")
    func retryBeforeTimerRuns() async throws {
        try await withPage { controller, _ in
            HeldNavigations().hold(in: controller)
            controller.webViewWebContentProcessDidTerminate(try #require(controller.webView))
            controller.snapshotTimeout = .zero
            controller.reload()
            // The main actor has not yielded to the timer yet.
            controller.snapshotTimeout = .seconds(300)
            controller.reloadEndedPage()
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.loadCount == 3)
        }
    }

    @Test("読み込みを始められなければ読み込み直しを待たず、次にもう一度試すと読み込み直して写せる")
    func navigationNotStarted() async throws {
        try await withPage { controller, _ in
            let start = controller.startNavigation
            controller.startNavigation = { _, _, _ in nil }
            controller.snapshotTimeout = .seconds(300)
            controller.webViewWebContentProcessDidTerminate(try #require(controller.webView))
            controller.reloadEndedPage()
            #expect(controller.state == .ended && controller.loadCount == 2)
            #expect(await controller.snapshot() == .failed)
            controller.startNavigation = start
            controller.snapshotTimeout = .seconds(20)
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.loadCount == 3)
            guard case .captured(let copy) = await controller.snapshot() else {
                Issue.record("The reloaded page was not copied")
                return
            }
            #expect(copy.html.contains("Snapshot fixture"))
        }
    }

    @Test(
        "読み込み直しの途中でファイルを読み込み直すと、前の写しは失敗になり、新しい写しは二度目の読み込みの完了まで始まらない",
        arguments: [false, true])
    func reloadReplaced(sandboxed: Bool) async throws {
        try await withPage { controller, _ in
            let navigations = HeldNavigations()
            navigations.hold(in: controller)
            let replies = HeldReplies()
            replies.hold(in: controller)
            controller.isSandboxed = { sandboxed }
            controller.snapshotTimeout = .seconds(300)
            let earlier = try await copyWaitingForReload(controller)
            let first = navigations.last
            controller.reload()
            #expect(controller.state == .reloading && controller.loadCount == 3)
            try await waitUntil { earlier.outcome != nil }
            #expect(earlier.outcome == .failed)
            let later = Copy(of: controller)
            try await waitUntil { controller.reloadWaiterCount == 1 }
            let webView = try #require(controller.webView)
            // The first load's late report must not let the new request through.
            controller.navigationDidFinish(webView, first)
            #expect(later.outcome == nil && replies.count == 0 && controller.state == .reloading)
            controller.navigationDidFinish(webView, navigations.last)
            #expect(controller.state == .live)
            // The held load never gave the new view a URL. Neither path may fall back to the file.
            try await waitUntil { later.outcome != nil }
            #expect(later.outcome == .failed && replies.count == 0)
        }
    }

    @Test("プロセスが終わったページは JavaScript の設定を変えても読み込まず、もう一度試すと新しい設定で読み込み直す")
    func settingChangesWhileEnded() async throws {
        try await withPage { controller, file in
            var restarts = 0
            controller.onRestart = { restarts += 1 }
            controller.webViewWebContentProcessDidTerminate(try #require(controller.webView))
            controller.applyJavaScriptSetting(false)
            controller.show(file, allowsJavaScript: false)
            #expect(controller.state == .ended && controller.loadCount == 1)
            // The web view of the old setting is gone, and still the page is not one that was never shown.
            #expect(controller.webView == nil)
            #expect(await controller.snapshot() == .failed)
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.loadCount == 2)
            #expect(controller.allowsJavaScript == false)
            guard case .captured(let copy) = await controller.snapshot() else {
                Issue.record("The reloaded page was not copied")
                return
            }
            #expect(copy.html.contains("Snapshot fixture"))
            #expect(restarts == 0)
        }
    }

    @Test("読み込み直しの途中で JavaScript の設定が変わったら、待っていた写しは失敗になり、次の操作を待つ")
    func settingChangesWhileReloading() async throws {
        try await withPage { controller, file in
            HeldNavigations().hold(in: controller)
            controller.snapshotTimeout = .seconds(300)
            let copy = try await copyWaitingForReload(controller)
            // The same setting leaves the load alone.
            controller.show(file, allowsJavaScript: true)
            controller.applyJavaScriptSetting(true)
            #expect(copy.outcome == nil && controller.state == .reloading)
            controller.applyJavaScriptSetting(false)
            try await waitUntil { copy.outcome != nil }
            #expect(copy.outcome == .failed)
            #expect(controller.state == .ended && controller.loadCount == 2)
            controller.reloadEndedPage()
            #expect(controller.state == .reloading && controller.allowsJavaScript == false)
            controller.close()
            #expect(controller.state == .notShown)
            #expect(await controller.snapshot() == .notLoaded)
        }
    }
}
