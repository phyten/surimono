import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct ReadingPDFExportTests {
    @Test("読むPDFは表示から印刷画面へ移らず全論理ページを書き出す", .timeLimit(.minutes(1)))
    func readingCopy() async throws {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("Source.pdf")
        let original = TestFixtures.pdf("Reading", pages: 5)
        try original.write(to: sourceURL)
        let model = DocumentViewModel(
            data: original, fileURL: sourceURL, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        defer { model.stop() }
        model.layoutID = PrintLayout.a4BookletA5.id
        model.setPageRangeText("1-2")
        model.render()
        for _ in 0..<200 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.isUpToDate)
        #expect(model.readingExportName == "Source.pdf")
        let started = await model.beginReadingPDFExport()
        #expect(started)
        #expect(model.mode == .view)
        let destination = directory.appendingPathComponent("Reading.pdf")
        model.completePDFExport(to: destination)
        let pdf = try #require(PDFDocument(url: destination))
        #expect(pdf.pageCount == 5)
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Reading")
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "Surimono")
        #expect(try Data(contentsOf: sourceURL) == original)
        #expect(model.outputError == nil)

        let protected = await model.beginReadingPDFExport()
        #expect(protected)
        model.completePDFExport(to: sourceURL)
        #expect(model.outputError != nil)
        #expect(try Data(contentsOf: sourceURL) == original)
    }

    @Test(
        "表示中の NeurIPS 原稿を読む PDF に保存して開き直すと、最初の引用が 3 ページ目の文献行を指す",
        .timeLimit(.minutes(1)), arguments: ["113-style-neurips", "114-style-neurips-final"])
    func neuripsWindowExport(_ name: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Snapshots/corpus/latex/\(name)/main.tex")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = FileWrapper(regularFileWithContents: try Data(contentsOf: url))
        file.preferredFilename = url.lastPathComponent
        let input = try SurimonoDocument(file: file, contentType: .surimonoLaTeX)
        let model = DocumentViewer.makeModel(
            document: input, fileURL: url, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory), settingsStore: DocumentSettingsStore(directory: directory))
        model.layoutID = PrintLayout.letterSingle.id
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        ViewerWindow.configure(window)
        let presentation = DocumentWindowContent(model: model, in: window, usesSnapshotAppearance: true)
        defer {
            presentation.close()
            window.close()
        }
        window.representedURL = url
        window.orderBack(nil)
        // Use the file window's real hosting and render lifecycle, including PDFKit's view copy.
        while model.error == nil && (!model.isUpToDate || model.paper.view?.visiblePages.isEmpty != false) {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.isUpToDate && model.paper.view?.window === window, "\(model.error ?? name)")
        try #require(model.layoutID == PrintLayout.letterSingle.id)
        let settings = try #require(model.renderSettings(in: .view))
        let source = try #require(model.themedSource)
        let info = model.renderer.latexClassInfo(for: source, composition: settings.latexComposition)
        try #require(model.mode == .view && settings == settings.forReadingLaTeX(info))
        let displayed = try #require(model.paperDocument)
        try #require(displayed === model.result?.viewDocument)
        func destinations(in document: PDFDocument) throws -> [(page: Int, point: CGPoint)] {
            try #require(document.pageCount == 3)
            let links = try #require(document.page(at: 0)?.annotations)
            if name == "113-style-neurips" { try #require(links.count == 10) }
            let targets = try links.compactMap { link -> (page: Int, point: CGPoint)? in
                guard link.type == "Link", !(link.action is PDFActionURL) else { return nil }
                let dest = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
                let page = try #require(dest.page)
                #expect(dest.zoom == kPDFDestinationUnspecifiedValue)
                return (page: document.index(for: page), point: dest.point)
            }
            if name == "113-style-neurips" { try #require(targets.count == 10) }
            let first = try #require(targets.first)
            try #require(first.page == 2)
            let page = try #require(document.page(at: first.page))
            let entry = try #require(document.findString("Model Rail Desk. 2025.").first)
            try #require(entry.pages.first === page)
            let line = entry.bounds(for: page)
            #expect(abs(first.point.x - line.minX) < 6 && abs(first.point.y - line.maxY) < 6)
            if name == "113-style-neurips" {
                #expect(abs(first.point.x - 108) < 1 && abs(first.point.y - 656.15) < 1)
            }
            return targets
        }
        let original = try destinations(in: displayed)
        let started = await model.beginReadingPDFExport()
        try #require(started, "\(model.outputError ?? name)")
        let output = directory.appendingPathComponent("Reading.pdf")
        model.completePDFExport(to: output)
        try #require(model.outputError == nil)
        let reopened = try #require(PDFDocument(url: output))
        let saved = try destinations(in: reopened)
        try #require(original.count == saved.count)
        for (before, after) in zip(original, saved) {
            #expect(before.page == after.page)
            #expect(abs(before.point.x - after.point.x) < 0.001 && abs(before.point.y - after.point.y) < 0.001)
        }
    }

    @Test("読むPDFは印刷画面のページ範囲に依存せずモードを保つ", .timeLimit(.minutes(1)))
    func trayCopy() async throws {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = DocumentViewModel(
            data: TestFixtures.pdf("Reading", pages: 5), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        model.enterPrintMode()
        model.setPageRangeText("1-2")
        model.render()
        for _ in 0..<200 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        let started = await model.beginReadingPDFExport()
        #expect(started)
        #expect(model.mode == .print)
        #expect(model.pageRangeText == "1-2")
        let destination = directory.appendingPathComponent("Reading.pdf")
        model.completePDFExport(to: destination)
        let pdf = try #require(PDFDocument(url: destination))
        #expect(pdf.pageCount == 5)
    }

    @Test("検証した読むPDFのバイト列を保存時に再生成せず、準備中の取り消しと読み直しは出力しない", .timeLimit(.minutes(1)))
    func verifiedBytes() async throws {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = TestFixtures.pdf("First")
        let model = DocumentViewModel(
            data: original, fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        model.render()
        while model.isRendering { await Task.yield() }
        try #require(model.isUpToDate)

        // A legal trailing PDF comment makes a second PDFKit serialization observable.
        let verified = original + Data("% verification marker\n".utf8)
        let prepared = await model.beginReadingPDFExport { _, _ in verified }
        try #require(prepared)
        let url = directory.appendingPathComponent("Reading.pdf")
        model.completePDFExport(to: url)
        #expect(try Data(contentsOf: url) == verified)

        let cancelled = await Task {
            await model.beginReadingPDFExport { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                await Task.yield()
                return verified
            }
        }.value
        #expect(!cancelled && !model.isExporting && model.pendingPDF == nil)
        #expect(model.outputError == nil)

        let stale = await model.beginReadingPDFExport { _, _ in
            await MainActor.run { model.replaceContent(TestFixtures.pdf("Second"), format: .pdf) }
            return verified
        }
        #expect(!stale && !model.isExporting && model.pendingPDF == nil)
        #expect(model.outputError == nil)
    }

    @Test("最新の組版がない文書は読むPDFを開始しない")
    func unrendered() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        let started = await model.beginReadingPDFExport()
        #expect(!started)
        #expect(!model.isExporting)
    }
}
