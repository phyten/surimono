import Foundation
import Synchronization
import Testing

@testable import SurimonoCore

struct FinderPreviewTests {
    func withDirectory<T>(_ test: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try test(url)
    }

    @Test("標準スタイルで言語・数式の SVG と書体・コードの色を保ち、紙への改ページを入れない")
    func scrollingDocument() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("note.md")
            try """
            # 日本語の文書

            これは日本語で書いた数式です。 $x^2$

            ```swift
            let x = 42
            ```
            """.write(to: url, atomically: true, encoding: .utf8)
            let html = FinderPreview.make(for: url).html
            for expected in [
                "lang=\"ja\"", "<h1", "<svg ", "viewBox=", "data:font/otf;base64,", "class=\"hl-",
                "font-size: 10.5pt", "max-width: 56rem", "script-src 'none'",
            ] {
                #expect(html.contains(expected), "\(expected)")
            }
            for absent in ["@page", "page-break-after:", "break-before:", "<script", "<base "] {
                #expect(!html.contains(absent), "\(absent)")
            }
        }
    }

    @Test("登録する全形式を本文のあるプレビューに変換する")
    func formats() throws {
        try withDirectory { directory in
            let samples = [
                ("md", "# paper"), ("org", "* paper"), ("rst", "paper\n====="),
                ("tex", #"\documentclass{article}\begin{document}paper\end{document}"#),
                ("qmd", "# paper"), ("Rmd", "# paper"),
                (
                    "ipynb",
                    ##"{"nbformat":4,"nbformat_minor":5,"cells":[{"cell_type":"markdown","metadata":{},"source":["# paper"]}]}"##
                ),
            ]
            for (suffix, source) in samples {
                let url = directory.appendingPathComponent("note." + suffix)
                try source.write(to: url, atomically: true, encoding: .utf8)
                let html = FinderPreview.make(for: url).html
                #expect(html.contains("body class=\"surimono format-"), "\(suffix)")
                #expect(html.components(separatedBy: "<body").last?.contains("paper") == true, "\(suffix)")
            }
        }
    }

    @Test("本文の外部リソース・実行可能な属性・移動先を除き、読み取り可能な相対画像だけを添付する")
    func offlineImages() throws {
        try withDirectory { directory in
            let root = directory.appending(path: "doc", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let png = try #require(
                Data(
                    base64Encoded:
                        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9ioAAAAASUVORK5CYII="))
            try png.write(to: root.appendingPathComponent("a b.png"))
            let outside = directory.appendingPathComponent("outside.png")
            try png.write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked.png"), withDestinationURL: outside)
            let html = """
                <img src="a%20b.png" onload="bad()" srcset="https://remote.invalid/2x">
                <img src="a%20b.png"><img src="//remote.invalid/x"><img src="file:///tmp/x">
                <img src="linked.png"><img src="../outside.png"><img src="missing.png">
                <script>bad()</script><link rel="stylesheet" href="https://remote.invalid/css">
                <style>@import "https://remote.invalid/s";</style><iframe src="https://remote.invalid"></iframe>
                <meta http-equiv="refresh" content="0;url=https://remote.invalid"><base href="https://remote.invalid/">
                <p style="background-image:url(https://remote.invalid/p)">paper</p>
                <svg><use href="https://remote.invalid/s"/><path fill="url(https://remote.invalid/p)"/></svg>
                """
            let url = root.appendingPathComponent("paper.md")
            try html.write(to: url, atomically: true, encoding: .utf8)
            let preview = FinderPreview.make(for: url)
            let image = try #require(preview.attachments["image-1"])
            #expect(image.data == png)
            #expect(image.type == .png)
            #expect(preview.attachments.count == 1)
            #expect(preview.html.components(separatedBy: "src=\"cid:image-1\"").count == 3)
            for removed in [
                "remote.invalid", "<script", "onload=", "bad()", "srcset=", "file:///tmp", "<iframe", "<base ",
            ] {
                #expect(!preview.html.contains(removed), "\(removed)")
            }
        }
    }

    @Test("添付の件数と合計バイト数を制限する")
    func attachmentBudgets() throws {
        try withDirectory { directory in
            let canonical = URL(fileURLWithPath: try ConfinedFile.canonicalPath(directory), isDirectory: true)
            let graphic = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"1\" height=\"1\"/></svg>"
            var count = PreviewImages(directory: canonical)
            for n in 0..<33 {
                let name = "\(n).svg"
                try graphic.write(to: canonical.appendingPathComponent(name), atomically: true, encoding: .utf8)
                let src = count.source(name)
                #expect((src != nil) == (n < 32))
            }
            let png = try #require(
                Data(
                    base64Encoded:
                        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9ioAAAAASUVORK5CYII="))
            var padded = png
            padded.append(Data(count: 4_100_000))
            for name in ["first.png", "second.png"] { try padded.write(to: canonical.appendingPathComponent(name)) }
            var bytes = PreviewImages(directory: canonical)
            #expect(bytes.source("first.png") != nil)
            #expect(bytes.source("second.png") == nil)
            #expect(bytes.source("first.png") == "cid:image-1")
        }
    }

    @Test("埋め込み SVG の本文と画像を保ち、外部参照とスクリプトを除く")
    func notebookImage() throws {
        try withDirectory { directory in
            let image = """
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8000 4000" onload="bad()">
                <image href="https://remote.invalid/p"/><script>bad()</script><circle cx="4" cy="4" r="3"/>
                </svg>
                """
            let notebook: [String: Any] = [
                "nbformat": 4, "nbformat_minor": 5,
                "cells": [
                    [
                        "cell_type": "code", "source": ["42"], "metadata": [:], "execution_count": 1,
                        "outputs": [
                            ["output_type": "display_data", "metadata": [:], "data": ["image/svg+xml": image]]
                        ],
                    ]
                ],
            ]
            let file = directory.appendingPathComponent("saved.ipynb")
            try JSONSerialization.data(withJSONObject: notebook).write(to: file)
            let preview = FinderPreview.make(for: file)
            let attachment = try #require(preview.attachments["image-1"])
            let svg = try #require(String(data: attachment.data, encoding: .utf8))
            #expect(attachment.type == .svg)
            #expect(svg.contains("viewBox="))
            #expect(svg.contains("width=\"1600\"") && svg.contains("height=\"800\""))
            #expect(svg.contains("<circle"))
            #expect(!svg.contains("remote.invalid") && !svg.contains("bad()") && !svg.contains("<script"))
            #expect(preview.html.contains("src=\"cid:image-1\""))
        }
    }

    @Test("reStructuredText の相対画像は添付し、同じフォルダーの別文書は取り込まない")
    func rstFiles() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("paper.rst")
            try ".. image:: shape.svg\n\n.. include:: private.rst\n".write(to: file, atomically: true, encoding: .utf8)
            try "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"4\" height=\"8\"/></svg>".write(
                to: directory.appendingPathComponent("shape.svg"), atomically: true, encoding: .utf8)
            try "private section".write(
                to: directory.appendingPathComponent("private.rst"), atomically: true, encoding: .utf8)
            let preview = FinderPreview.make(for: file)
            #expect(preview.attachments["image-1"]?.type == .svg)
            #expect(!preview.html.contains("private section"))
        }
    }

    @Test("画像のない Org と reStructuredText は説明を表示し、説明のない箇所には枠を残す")
    func missingDescriptions() throws {
        try withDirectory { directory in
            for (suffix, source) in [
                ("org", "[[file:missing.png]]\n\n[[file:missing.png][図の説明]]"),
                ("rst", ".. image:: missing.png\n\n.. image:: missing.png\n   :alt: 図の説明"),
            ] {
                let file = directory.appendingPathComponent("paper." + suffix)
                try Data(source.utf8).write(to: file)
                let preview = FinderPreview.make(for: file)
                #expect(preview.html.contains("<span class=\"preview-missing-image\""))
                #expect(preview.html.contains("図の説明"))
                #expect(!preview.html.contains("missing.png"))
                #expect(preview.attachments.isEmpty)
            }
        }
    }

    @Test("登録を外した形式は変換器に渡さない")
    func removedFormats() throws {
        try withDirectory { directory in
            for suffix in ["wiki", "adoc", "dj", "textile"] {
                let url = directory.appendingPathComponent("paper." + suffix)
                try Data("paper".utf8).write(to: url)
                let preview = FinderPreview.make(for: url, deadline: .now + .seconds(5)) { _, _, _ in
                    Issue.record("対象外の原稿が変換器に届いた")
                    return HTMLFragment(body: "")
                }
                #expect(preview.html.contains("This document format is not supported."))
            }
        }
    }

    @Test("変換スレッドに期限を引き継ぎ、作業が終了してからエラーページを返す")
    func deadline() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("paper.md")
            try Data("paper".utf8).write(to: url)
            let completed = Mutex(false)
            let start = ContinuousClock.now
            let preview = FinderPreview.make(for: url, deadline: start + .milliseconds(150)) { _, _, _ in
                try StackSpace.onLargeStack {
                    defer { completed.withLock { $0 = true } }
                    // A separate safety bound also makes a missing deadline fail without hanging the test.
                    while ContinuousClock.now < start + .seconds(2) {
                        try PreviewConversion.check()
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    Issue.record("変換スレッドが期限を過ぎても中断しなかった")
                    return HTMLFragment(body: "late")
                }
            }
            #expect(completed.withLock { $0 })
            #expect(preview.html.contains("This document is too complex to preview."))
            #expect(preview.html.utf8.count < 1024 && preview.attachments.isEmpty)
        }
    }

    @Test("行数と生成 HTML の上限超過をプレビューのサイズ制限として知らせる")
    func complexityLimits() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("paper.md")
            try Data(repeating: 10, count: 100_000).write(to: url)
            #expect(FinderPreview.make(for: url).html.contains("This document exceeds the preview size limits."))
            try Data("paper".utf8).write(to: url)
            let preview = FinderPreview.make(for: url, deadline: .now + .seconds(10)) { _, _, _ in
                HTMLFragment(body: String(repeating: "x", count: DocumentSizeLimits.htmlBytes + 1))
            }
            #expect(preview.html.contains("This document exceeds the preview size limits."))
            #expect(preview.html.utf8.count < 1024 && preview.attachments.isEmpty)
        }
    }

    @Test("BOM 付き UTF-16 と UTF-32 の両バイト順で本文を読める")
    func byteOrderMarks() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("paper.md")
            let encodings: [(String.Encoding, [UInt8])] = [
                (.utf16LittleEndian, [0xff, 0xfe]), (.utf16BigEndian, [0xfe, 0xff]),
                (.utf32LittleEndian, [0xff, 0xfe, 0, 0]), (.utf32BigEndian, [0, 0, 0xfe, 0xff]),
            ]
            for (encoding, bom) in encodings {
                let text = try #require("# 本文".data(using: encoding))
                try (Data(bom) + text).write(to: url)
                #expect(FinderPreview.make(for: url).html.contains("本文"))
            }
            for invalid: [UInt8] in [[0xfe, 0xff, 0xd8, 0], [0, 0, 0xfe, 0xff, 0, 0x11, 0, 0]] {
                try Data(invalid).write(to: url)
                #expect(
                    FinderPreview.make(for: url).html.contains("The text encoding could not be read without data loss.")
                )
            }
        }
    }

    @Test("読めないノートと上限を超える原稿は小さなエラーページにする")
    func errors() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("broken.ipynb")
            try Data("invalid".utf8).write(to: url)
            #expect(FinderPreview.make(for: url).html.contains("The document could not be loaded."))
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.truncate(atOffset: 30_000_001)
            let preview = FinderPreview.make(for: url)
            #expect(preview.html.contains("This file is too large to preview."))
            #expect(preview.html.utf8.count < 1024)
            #expect(preview.attachments.isEmpty)
            #expect(FinderPreview.errorPage("<message>").html.contains("&lt;message&gt;"))
        }
    }
}
