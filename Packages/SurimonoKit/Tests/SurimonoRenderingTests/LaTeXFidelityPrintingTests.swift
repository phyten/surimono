import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXFidelityPrintingTests {
    @Test("二段組の表題注と本文注は左段の同じ脚注罫の下に組む", .timeLimit(.minutes(1)), arguments: [false, true])
    func columnNotes(_ composition: Bool) async throws {
        let url = try #require(
            Bundle.module.url(forResource: "column-notes", withExtension: "tex", subdirectory: "Fixtures"))
        var tex = try String(contentsOf: url, encoding: .utf8)
        if composition { tex = tex.replacingOccurrences(of: ",twocolumn", with: "") }
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        settings.latexComposition = composition ? .twoColumn : .document
        let document = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
        let page = try #require(document.page(at: 0))
        let title = try #require(document.findString("Title stock").first).bounds(for: page)
        let body = try #require(document.findString("Body stock").first).bounds(for: page)
        #expect(abs(title.minX - body.minX) < 0.6)
        #expect(abs(title.midY - body.midY - 9.46) < 0.6)
        // The 0.4pt rule spans 40% of the left column. Sample its two sides above the first note.
        let top = 136
        let inside = try (top...top + 4).map { try RenderingFixtures.pixel(page, x: 76, y: $0)[0] }
        let outside = try (top...top + 4).map { try RenderingFixtures.pixel(page, x: 171, y: $0)[0] }
        #expect(inside.min() ?? 255 < 230)
        #expect(outside.allSatisfy { $0 > 245 })
    }

    @Test("A4を選んだままでも読むPDFには原稿の用紙を使う", .timeLimit(.minutes(1)))
    func readingTrim() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "column-notes", withExtension: "tex", subdirectory: "Fixtures"))
        let source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex)
        let renderer = DocumentRenderer()
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let stock = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let reading = stock.forReadingLaTeX(renderer.latexClassInfo(for: source))
        let plain = DocumentSource(
            data: Data(#"\documentclass{article}\usepackage{graphicx}\begin{document}Ink.\end{document}"#.utf8),
            format: .latex)
        let inherited = stock.forReadingLaTeX(renderer.latexClassInfo(for: plain))
        #expect(inherited == stock)
        let custom = DocumentSource(
            data: Data(
                #"\documentclass[a4paper]{article}\pdfpagewidth=700bp\pdfpageheight=500bp\begin{document}Ink.\end{document}"#
                    .utf8),
            format: .latex)
        let customReading = stock.forReadingLaTeX(renderer.latexClassInfo(for: custom))
        var generalStyle = stock
        generalStyle.theme = try #require(PrintThemeLibrary.load().first { $0.formats == nil })
        let generalReading = generalStyle.forReadingLaTeX(renderer.latexClassInfo(for: source))
        #expect(generalReading.logicalPageSize == PaperSize.letter.size)
        for (input, settings, size) in [
            (source, stock, PaperSize.a4.size), (source, reading, PaperSize.letter.size),
            (plain, inherited, PaperSize.a4.size), (custom, customReading, CGSize(width: 700, height: 500)),
        ] {
            let prepared = try await renderer.prepare(input, settings: settings)
            let pdf = try ReadingPDFExporter.document(from: prepared.viewDocument, entries: [], title: "Gauge")
            let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
            #expect(abs(box.width - size.width) < 0.01)
            #expect(abs(box.height - size.height) < 0.01)
        }
        let tray = try await renderer.render(source, settings: stock)
        let sheet = try #require(tray.sheetDocument.page(at: 0)).bounds(for: .mediaBox)
        let job = PrintJobFactory().printInfo(for: tray.layout)
        #expect(abs(sheet.width - PaperSize.a4.size.width) < 0.01)
        #expect(abs(sheet.height - PaperSize.a4.size.height) < 0.01)
        #expect(abs(job.paperSize.width - sheet.width) < 1)
        #expect(abs(job.paperSize.height - sheet.height) < 1)
        #expect(job.scalingFactor == 1)
    }

    @Test(
        "ICLRの小型大文字は見出しの幅を保ちPDFから語のまま取り出せる",
        .timeLimit(.minutes(1)), arguments: ["117-style-iclr", "118-style-iclr-final"])
    func smallCapInk(_ folder: String) async throws {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = root.appendingPathComponent("Snapshots/corpus/latex/\(folder)/main.tex")
        let reference = try #require(
            PDFDocument(url: root.appendingPathComponent("Snapshots/reference/latex/\(folder.prefix(3)).pdf")))
        let source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Gauge", furniture: prepared.viewFurniture)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        try #require(reading.write(to: file))
        let pdf = try #require(PDFDocument(url: file))
        let words = [
            "MEASURING", "FOLDED", "CARD", "SPACERS", "FOR", "MODEL", "RAILS", "ABSTRACT",
            "INTRODUCTION", "METHOD", "THE", "TEST", "SLOT", "LAYER", "RESULTS", "CONCLUSION", "REFERENCES",
        ]
        func checkWords(_ string: String) {
            let tokens = string.split { !$0.isLetter }
            for word in words { #expect(tokens.count { $0 == word } == (word == "MODEL" ? 2 : 1)) }
        }
        checkWords((0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n"))
        for word in words { #expect(pdf.findString(word).count == (word == "MODEL" ? 2 : 1)) }
        // Poppler and PDFKit infer word boundaries independently. Exercise both when Poppler is installed.
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let tool = (paths + ["/opt/homebrew/bin", "/usr/local/bin"]).map({ $0 + "/pdftotext" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            let text = file.appendingPathExtension("txt")
            defer { try? FileManager.default.removeItem(at: text) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-layout", file.path, text.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            checkWords(try String(contentsOf: text, encoding: .utf8))
        }
        for word in ["MEASURING", "ABSTRACT", "INTRODUCTION"] {
            func width(_ document: PDFDocument) throws -> CGFloat {
                let match = try #require(document.findString(word).first)
                return match.bounds(for: try #require(match.pages.first)).width
            }
            #expect(abs(try width(pdf) - width(reference)) < 0.9)
        }
        func ink(_ document: PDFDocument) throws -> (width: Double, height: Double, pixels: Int) {
            let page = try #require(document.page(at: 0))
            let word = try #require(document.findString("measuring", withOptions: .caseInsensitive).first).bounds(
                for: page)
            // Isolate the leading M. The neighbouring small capital begins over 16pt to its right.
            let scale = 8
            let width = 16 * scale
            let height = 20 * scale
            let ctx = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: -word.minX, y: -word.midY + 10)
            ctx.drawPDFPage(try #require(page.pageRef))
            let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            let dark = (0..<width * height).filter { bytes[$0] < 128 }
            let xs = dark.map { $0 % width }
            let ys = dark.map { $0 / width }
            return (
                Double(try #require(xs.max()) - (try #require(xs.min())) + 1) / Double(scale),
                Double(try #require(ys.max()) - (try #require(ys.min())) + 1) / Double(scale), dark.count
            )
        }
        let expected = try ink(reference)
        let actual = try ink(pdf)
        // Scaling the complete run widens the initial M by roughly one PDF point.
        #expect(abs(actual.width - expected.width) < 1.3)
        #expect(abs(actual.height - expected.height) < 0.5)
        #expect(abs(Double(actual.pixels) / Double(expected.pixels) - 1) < 0.06)
    }

    // A destination can change when PDFKit serializes a decorated document. Keep source and target
    // page numbers and coordinates for the same links at each boundary of the export.
    private func destinations(in pdf: PDFDocument) -> String {
        (0..<min(pdf.pageCount, 2)).map { source in
            let links = (pdf.page(at: source)?.annotations ?? []).compactMap { annotation -> String? in
                guard let target = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
                else { return nil }
                let index = target.page.map { pdf.index(for: $0) } ?? NSNotFound
                let point = String(format: "(%.1f,%.1f)", Double(target.point.x), Double(target.point.y))
                return "\(index == NSNotFound ? -1 : index + 1)@\(point)"
            }
            return "p\(source + 1)→" + links.prefix(12).joined(separator: ",")
        }.joined(separator: " ")
    }

    @Test("学会原稿のURLと別ページの節を枠なしでリンクする", .timeLimit(.minutes(1)))
    func conferenceLinks() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "conference-links", withExtension: "tex", subdirectory: "Fixtures"))
        let source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Register", furniture: prepared.viewFurniture)
        let pdf = try #require(PDFDocument(data: reading.dataRepresentation() ?? Data()))
        let first = try #require(pdf.page(at: 0))
        let second = try #require(pdf.page(at: 1))
        #expect(
            first.annotations.contains {
                ($0.action as? PDFActionURL)?.url?.absoluteString == "https://example.org/gauge"
            })
        let targets = first.annotations.compactMap { ($0.action as? PDFActionGoTo)?.destination }
        let target = try #require(targets.first)
        let heading = try #require(
            pdf.findString("Checks", withOptions: .caseInsensitive).first { $0.pages.contains(second) }
        ).bounds(for: second)
        let stages =
            "view[\(destinations(in: prepared.viewDocument))] export[\(destinations(in: reading))] saved[\(destinations(in: pdf))]"
        #expect(target.page === second, "\(stages)")
        #expect(abs(target.point.y - heading.maxY) < 10)
        #expect(first.annotations.allSatisfy { ($0.border?.lineWidth ?? 0) == 0 })
    }

    @Test("CVPRの引用と参考文献の逆参照は保存後も引用したページへ戻れる", .timeLimit(.minutes(1)))
    func citationPages() async throws {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let directory = root.appendingPathComponent("Snapshots/corpus/latex/119-style-cvpr")
        let url = directory.appendingPathComponent("main.tex")
        var source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex)
        source.allowedResourceFolders = [directory]
        let renderer = DocumentRenderer()
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await renderer.prepare(source, settings: settings)
        let decorated = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Links", furniture: prepared.viewFurniture)
        let pdf = try #require(PDFDocument(data: decorated.dataRepresentation() ?? Data()))
        let first = try #require(pdf.page(at: 0))
        let last = try #require(pdf.page(at: 1))
        func destination(_ annotation: PDFAnnotation) -> PDFDestination? {
            (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
        }
        // A tight line must still provide the same searchable space after the minus sign.
        #expect(pdf.findString("c = h2− 2t").count == 1)
        #expect(first.string?.contains("c = h2− 2t") == true)
        let stages =
            "view[\(destinations(in: prepared.viewDocument))] export[\(destinations(in: decorated))] saved[\(destinations(in: pdf))]"
        let refs = try #require(pdf.findString("Spacer Card Register").first).bounds(for: last)
        #expect(
            first.annotations.contains { a in
                guard let target = destination(a), target.page === last else { return false }
                return abs(target.point.y - refs.maxY) < 6
            }, "refsY=\(refs.maxY) \(stages)")
        let splitEntry = try #require(
            pdf.findString("A gauge block of folded").first ?? pdf.findString("A gauge block made of folded").first
        ).bounds(for: last)
        #expect(
            first.annotations.contains { a in
                guard let target = destination(a), target.page === last else { return false }
                return abs(target.point.y - splitEntry.maxY) < 8 && abs(target.point.x - splitEntry.minX) < 150
            }, "split=\(splitEntry) \(stages)")
        let pages = last.annotations.compactMap { a -> Int? in
            guard let target = destination(a), let page = target.page, abs(target.point.y - 720) < 5 else { return nil }
            return pdf.index(for: page) + 1
        }
        #expect(pages == [1, 2, 1, 1, 2], "\(stages)")
        // The figure starts at the top of the left column. The caption package's
        // destination is half a baseline above it in the saved reference PDF.
        #expect(
            first.annotations.contains { a in
                guard let target = destination(a), target.page === last else { return false }
                return abs(target.point.x - 58.5) < 1 && abs(target.point.y - 725.978) < 2
            }, "\(stages)")
    }
}
