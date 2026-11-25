import Foundation
import Testing

@testable import SurimonoCore

struct FinderPreviewTests {
    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try test(url)
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
                ("md", "# paper"), ("org", "* paper"), ("adoc", "= paper\n\npaper"), ("rst", "paper\n====="),
                ("tex", #"\documentclass{article}\begin{document}paper\end{document}"#),
                ("dj", "# paper"), ("textile", "h1. paper"), ("wiki", "== paper =="),
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
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8" onload="bad()">
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

    @Test("Wiki とスクリプト変換器の 5 MB 上限は原文を展開する前に適用する")
    func readerLimits() throws {
        try withDirectory { directory in
            for suffix in ["wiki", "adoc", "dj", "textile"] {
                let url = directory.appendingPathComponent("large." + suffix)
                try Data().write(to: url)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 5_000_001)
                try handle.close()
                let html = FinderPreview.make(for: url).html
                #expect(html.utf8.count < 1024 && html.contains("6 MB"), "\(suffix)")
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
            #expect(preview.html.contains("31 MB"))
            #expect(preview.html.utf8.count < 1024)
            #expect(preview.attachments.isEmpty)
            #expect(FinderPreview.errorPage("<message>").html.contains("&lt;message&gt;"))
        }
    }
}
