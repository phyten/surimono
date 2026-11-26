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

    @Test("数式組版・RST と MediaWiki の走査・Notebook の出力処理中に期限を迎える", arguments: ["org", "rst", "wiki", "ipynb"])
    func nativeDeadline(suffix: String) throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("paper." + suffix)
            let bytes: Data
            let polls: Int
            switch suffix {
            case "org":
                bytes = Data((String(repeating: "x+", count: 1_000) + "x").utf8)
                // On entry to the math renderer: reserve, start timing, before parsing, after parsing.
                polls = 4
            case "rst":
                bytes = Data(("a" + String(repeating: #"\x"#, count: 32_768)).utf8)
                // The single block has entered the repeated-escape scanner by this point.
                polls = 12
            case "wiki":
                bytes = Data(String(repeating: "{{small|paper}} ", count: 100).utf8)
                // Expire while pairing template delimiters, before rendering the paragraph.
                polls = 12
            default:
                let output = ["output_type": "stream", "name": "stdout", "text": String(repeating: "x", count: 65_536)]
                let cell: [String: Any] = ["cell_type": "code", "source": "", "outputs": [output, output]]
                bytes = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "cells": [cell]])
                // Skip the JSON scan, the cell check and the first output. Expire at the second output.
                polls = (bytes.count + 4095) / 4096 + 3
            }
            try bytes.write(to: file)
            let start = ContinuousClock.now
            let deadline = start + .seconds(5)
            let clock = Mutex((insideConverter: false, checks: 0))
            let preview = FinderPreview.make(
                for: file, deadline: deadline,
                now: {
                    clock.withLock {
                        if $0.insideConverter { $0.checks += 1 }
                        return $0.checks >= polls ? deadline : start
                    }
                },
                convert: { text, format, url in
                    clock.withLock { $0.insideConverter = true }
                    defer { clock.withLock { $0.insideConverter = false } }
                    if format == .org {
                        // Drive the real renderer directly so discovery and file I/O cannot trip its clock.
                        let math = MathRenderer.html(text, display: true)
                        #expect(math == nil)
                        return HTMLFragment(body: math ?? "")
                    }
                    return try FinderPreview.nativeFragment(text, format: format, url: url)
                })
            #expect(clock.withLock { $0.checks } >= polls)
            #expect(preview.html.contains("This document is too complex to preview."))
        }
    }

    @Test("色付けの上限に近いコードにも期限と猶予の範囲で応答する")
    func highlightDeadline() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("code.md")
            let line = "let answer = 42\n"
            let code = String(repeating: line, count: (SyntaxHighlighter.maximumUTF16Count - 1) / line.utf16.count)
            try Data(("```swift\n" + code + "```").utf8).write(to: file)
            let start = ContinuousClock.now
            let html = FinderPreview.make(for: file).html
            #expect(start.duration(to: .now) <= .milliseconds(FinderPreview.timeoutMilliseconds + 500))
            #expect(html.contains("This document is too complex to preview.") || html.contains("body class=\"surimono"))
        }
    }

    @Test("本文とテーマを合わせた HTML が上限を超えたら小さいエラーを返す")
    func completeHTMLBudget() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("paper.md")
            try Data("paper".utf8).write(to: file)
            let start = ContinuousClock.now
            let preview = FinderPreview.make(for: file, deadline: start + .seconds(5), now: { start }) { _, _, _ in
                // The UTF-8 title fits alone. Adding the theme and the body crosses the reply limit.
                HTMLFragment(
                    body: "<p>paper</p>", title: String(repeating: "字", count: FinderPreview.maximumHTMLBytes / 3))
            }
            #expect(preview.html.contains("This document is too complex to preview."))
            #expect(preview.html.utf8.count < 1024 && preview.attachments.isEmpty)
        }
    }

    @Test("返信直前に UTF-8 のバイト数を確かめ、超過時は添付も返さない", arguments: [0, 1])
    func finalReplyBudget(extraByte: Int) {
        let size = FinderPreview.maximumHTMLBytes
        let preview = FinderPreview(
            html: String(repeating: "é", count: size / 2) + String(repeating: "x", count: extraByte),
            attachments: ["test": .init(data: Data([1]), type: .png)])
        var replies = 0
        let data = PreviewWatchdog().watch(
            timeoutMilliseconds: 5_000, grace: .seconds(1), bundle: .main, convert: { _ in preview },
            terminateIfStalled: { Issue.record("期限内の返信で終了処理を呼んだ") },
            encode: { reply in
                replies += 1
                #expect(reply.attachments.isEmpty == (extraByte > 0))
                return Data(reply.html.utf8)
            })
        #expect(replies == 1)
        if extraByte == 0 {
            #expect(data.count == size)
        } else {
            #expect(data.count < 1024 && String(decoding: data, as: UTF8.self).contains("too complex"))
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
        let watchdog = PreviewWatchdog()
        let data = watchdog.watch(
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
        let next = watchdog.watch(
            timeoutMilliseconds: 5_000, grace: .seconds(1), bundle: .main,
            convert: { _ in
                Issue.record("期限後の要求で変換を開始した")
                return FinderPreview.errorPage("unexpected")
            }, terminateIfStalled: { Issue.record("後続の要求で終了処理を予約した") },
            encode: { Data($0.html.utf8) })
        #expect(next == data)
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
        let watchdog = PreviewWatchdog()
        let data = watchdog.watch(
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
