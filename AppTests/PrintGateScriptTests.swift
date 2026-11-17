import JavaScriptCore
import Testing

@testable import Surimono

/// The script that passes a page's print request on runs here on its own, with the reader's events given in order and
/// a clock the test moves. The checks then depend neither on a web content process nor on timing.
@MainActor
struct PrintGateScriptTests {
    @MainActor private final class Gate {
        private let context: JSContext

        init() throws {
            context = try #require(JSContext())
            context.evaluateScript(
                """
                var listeners = { window: {}, document: {} };
                var posted = 0;
                var now = 0;
                var performance = { now: function () { return now; } };
                function listen(target) {
                  return function (type, handler) {
                    (listeners[target][type] = listeners[target][type] || []).push(handler);
                  };
                }
                var handlers = {};
                handlers['\(WebPageController.printMessageName)'] = { postMessage: function () { posted += 1; } };
                var window = { addEventListener: listen('window'), webkit: { messageHandlers: handlers } };
                var document = { addEventListener: listen('document') };
                function fire(type, trusted, repeat) {
                  (listeners.window[type] || []).forEach(function (handler) {
                    handler({ type: type, isTrusted: trusted, repeat: repeat });
                  });
                }
                function request() {
                  (listeners.document['\(WebPageController.printEventName)'] || []).forEach(function (handler) {
                    handler({});
                  });
                }
                """)
            context.evaluateScript(WebPageController.printGateScript)
            try #require(context.exception == nil)
        }

        /// The reader's events, in order; each is trusted unless the page made it.
        func fire(_ types: String..., trusted: Bool = true, isRepeat: Bool = false) {
            for type in types { context.evaluateScript("fire('\(type)', \(trusted), \(isRepeat))") }
        }

        /// The page asks to print, as `window.print()` does; returns how many requests have reached the app so far.
        @discardableResult
        func request() -> Int {
            context.evaluateScript("request()")
            return Int(context.evaluateScript("posted").toInt32())
        }

        func wait(milliseconds: Int) { context.evaluateScript("now += \(milliseconds)") }
    }

    @Test("利用者の操作がなければ、ページが作ったイベントがあっても依頼は届かない")
    func nothingWithoutThePress() throws {
        let gate = try Gate()
        #expect(gate.request() == 0)
        gate.fire("keydown", "mousedown", "pointerdown", "click", trusted: false)
        #expect(gate.request() == 0)
    }

    @Test("キーを押して離すあいだに、届く依頼は 1 つだけ")
    func oneKeyPress() throws {
        let gate = try Gate()
        gate.fire("keydown")
        #expect(gate.request() == 1)
        #expect(gate.request() == 1)
        // The release of a press that has been used allows nothing more.
        gate.wait(milliseconds: 120)
        gate.fire("keyup")
        #expect(gate.request() == 1)
    }

    @Test("押したままのキーのリピートは、新しい依頼を許さない")
    func keyRepeat() throws {
        let gate = try Gate()
        gate.fire("keydown")
        #expect(gate.request() == 1)
        for _ in 0..<3 {
            gate.wait(milliseconds: 80)
            gate.fire("keydown", isRepeat: true)
            #expect(gate.request() == 1)
        }
    }

    @Test("ふつうのクリックでは、ボタンの click で頼んだ依頼が 1 つ届く")
    func ordinaryClick() throws {
        let gate = try Gate()
        gate.fire("pointerdown", "mousedown")
        gate.wait(milliseconds: 90)
        gate.fire("pointerup", "mouseup", "click")
        #expect(gate.request() == 1)
        #expect(gate.request() == 1)
    }

    @Test("pointerdown を止めてマウスのイベントが出ないボタンでも、click で頼んだ依頼が届く")
    func cancelledPointerPress() throws {
        let gate = try Gate()
        gate.fire("pointerdown")
        gate.wait(milliseconds: 90)
        gate.fire("pointerup", "click")
        #expect(gate.request() == 1)
    }

    @Test("pointerdown で頼んだあと、同じ押下のマウスのイベントは新しい依頼を許さない")
    func pointerAndMouseAreOnePress() throws {
        let gate = try Gate()
        gate.fire("pointerdown")
        #expect(gate.request() == 1)
        gate.fire("mousedown")
        #expect(gate.request() == 1)
        gate.wait(milliseconds: 90)
        gate.fire("pointerup", "mouseup", "click")
        #expect(gate.request() == 1)
    }

    @Test("長く押してから離したボタンでも、離したあとの click で頼んだ依頼が届く")
    func longPress() throws {
        let gate = try Gate()
        gate.fire("pointerdown", "mousedown")
        gate.wait(milliseconds: 3000)
        // The press is too old by now for a request made before the release.
        #expect(gate.request() == 0)
        gate.fire("pointerup", "mouseup", "click")
        #expect(gate.request() == 1)
    }

    @Test("押下のない click（支援機能が出すもの）は、それだけで 1 つの依頼を許す")
    func clickWithoutPress() throws {
        let gate = try Gate()
        gate.fire("click")
        #expect(gate.request() == 1)
        #expect(gate.request() == 1)
    }

    @Test("押してから決めた時間が過ぎると、依頼は届かない")
    func pressExpires() throws {
        let gate = try Gate()
        gate.fire("keydown")
        gate.wait(milliseconds: WebPageController.printGestureWindowMilliseconds + 1)
        #expect(gate.request() == 0)
    }
}
