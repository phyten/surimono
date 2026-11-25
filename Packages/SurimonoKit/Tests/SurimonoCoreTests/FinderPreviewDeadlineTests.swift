import Foundation
import Synchronization
import Testing

@testable import SurimonoCore

extension FinderPreviewTests {
    @Test("タグ境界が検査間隔を飛び越えても期限を検知する")
    func jumpingHTMLPositions() {
        // After the one-byte prefix, every tag ends at an odd offset.
        let html = "a" + String(repeating: "<br>", count: 8_000)
        let start = ContinuousClock.now
        let deadline = start + .seconds(1)
        let time = Mutex(start)
        var tags = 0
        PreviewConversion.$current.withValue(PreviewConversion(deadline: deadline, now: { time.withLock { $0 } })) {
            HTMLScanner.forEachToken(html) { token in
                if case .tag = token {
                    tags += 1
                    if tags == 1 { time.withLock { $0 = deadline } }
                }
            }
        }
        #expect(tags > 0 && tags <= 1_025)
    }

    @Test("実際の変換器が大きな入力にも期限と猶予の範囲で応答する", arguments: ["org", "rst", "ipynb", "md"])
    func nativeDeadline(suffix: String) throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("paper." + suffix)
            let bytes: Data
            switch suffix {
            case "org":
                bytes = Data(("$$" + String(repeating: "x+", count: 40_000) + "x$$").utf8)
            case "rst":
                bytes = Data(("a" + String(repeating: #"\x"#, count: 150_000)).utf8)
            case "ipynb":
                let output = [
                    "output_type": "stream", "name": "stdout", "text": String(repeating: "value ", count: 180_000),
                ]
                let cell: [String: Any] = ["cell_type": "code", "source": ["1"], "metadata": [:], "outputs": [output]]
                bytes = try JSONSerialization.data(withJSONObject: [
                    "nbformat": 4, "nbformat_minor": 5, "cells": [cell],
                ])
            default:
                let line = "let answer = 42\n"
                let code = String(repeating: line, count: (SyntaxHighlighter.maximumUTF16Count - 1) / line.utf16.count)
                bytes = Data(("```swift\n" + code + "```").utf8)
            }
            try bytes.write(to: file)
            let done = DispatchGroup()
            let result = Mutex<(html: String, elapsed: Duration)?>(nil)
            done.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { done.leave() }
                let start = ContinuousClock.now
                let html = FinderPreview.make(for: file).html
                result.withLock { $0 = (html, start.duration(to: .now)) }
            }
            try #require(done.wait(timeout: .now() + .seconds(9)) == .success)
            let reply = try #require(result.withLock { $0 })
            #expect(reply.elapsed <= .milliseconds(FinderPreview.timeoutMilliseconds + 500))
            let tooComplex = reply.html.contains("This document is too complex to preview.")
            if suffix == "org" {
                #expect(reply.html.contains("<pre class=\"math-error\">$$x+"))
            } else {
                #expect(tooComplex || reply.html.contains("body class=\"surimono format-"))
            }
        }
    }

    @Test("停止しない変換にはエラーを一度返し、猶予の後でのみ終了処理を呼ぶ")
    func stalledWatchdog() {
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let terminated = DispatchSemaphore(value: 0)
        let events = Mutex<[(String, ContinuousClock.Instant)]>([])
        defer {
            release.signal()
            #expect(stopped.wait(timeout: .now() + .seconds(2)) == .success)
        }
        let data = FinderPreview.watch(
            timeoutMilliseconds: 200, grace: .milliseconds(150), bundle: .main,
            convert: { _ in
                defer { stopped.signal() }
                _ = release.wait(timeout: .now() + .seconds(3))
                return FinderPreview.errorPage("late")
            },
            terminateIfStalled: {
                events.withLock { $0.append(("terminate", .now)) }
                terminated.signal()
            },
            encode: { preview in
                events.withLock { $0.append(("reply", .now)) }
                return Data(preview.html.utf8)
            })
        #expect(String(decoding: data, as: UTF8.self).contains("This document is too complex to preview."))
        #expect(terminated.wait(timeout: .now() + .seconds(2)) == .success)
        let observed = events.withLock { $0 }
        #expect(observed.map(\.0) == ["reply", "terminate"])
        if let first = observed.first, let last = observed.last {
            #expect(first.1.duration(to: last.1) >= .milliseconds(150))
        }
    }

    @Test("期限内の成功と猶予中の協調停止では拡張を終了しない", arguments: [false, true])
    func cooperativeWatchdog(waitsForCancellation: Bool) {
        let terminated = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let data = FinderPreview.watch(
            timeoutMilliseconds: 250, grace: .milliseconds(200), bundle: .main,
            convert: { _ in
                defer { stopped.signal() }
                let end = ContinuousClock.now + .seconds(3)
                while waitsForCancellation && !Task.isCancelled && ContinuousClock.now < end {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                return FinderPreview.errorPage("test result")
            }, terminateIfStalled: { terminated.signal() }, encode: { Data($0.html.utf8) })
        let expected = waitsForCancellation ? "This document is too complex to preview." : "test result"
        #expect(String(decoding: data, as: UTF8.self).contains(expected))
        #expect(stopped.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(terminated.wait(timeout: .now() + .milliseconds(350)) == .timedOut)
    }
}
