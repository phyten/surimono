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
