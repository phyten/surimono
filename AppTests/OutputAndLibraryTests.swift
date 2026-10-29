import CoreGraphics
import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct OutputAndLibraryTests {
    @Test("スナップショットとPDF共通の原本保護は同じPNGとシンボリックリンクを拒否する")
    func protectsSnapshotSource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let alias = directory.appendingPathComponent("alias.png")
        try Data("original".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        #expect(!DocumentViewModel.canExport(to: source, sourceURLs: [source]))
        #expect(!DocumentViewModel.canExport(to: alias, sourceURLs: [source]))
        #expect(DocumentViewModel.canExport(to: directory.appendingPathComponent("snapshot.png"), sourceURLs: [source]))
    }

    @Test("プリセットフォルダの初回読み込みと再読み込みに失敗してもPDFとMarkdownの描画設定を生成できる", arguments: [false, true])
    func presetDirectoryFailure(reloading: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = reloading ? UserLibrary(root: directory) : nil
        try Data("not a directory".utf8).write(to: directory.appendingPathComponent("Presets"))
        let library = existing ?? UserLibrary(root: directory)
        if reloading { library.reload() }
        #expect(library.error != nil)
        #expect(library.presets.contains { $0.id == "none" && $0.isBuiltIn })
        let suite = "SurimonoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for format in [DocumentFormat.pdf, .markdown] {
            let model = DocumentViewModel(
                data: Data(), fileURL: nil, format: format,
                preferences: AppPreferences(defaults: defaults), library: library)
            let settings = try #require(model.renderSettings)
            #expect(settings.preset.id == "none")
        }
    }

    @Test("PDF書き出しの失敗後もプレビューを保持し別の保存先へ再出力できる", .timeLimit(.minutes(1)))
    func exportFailureAllowsRetry() async throws {
        try await withRenderedPDF { model, directory in
            let preview = try #require(model.result?.logicalDocument)
            #expect(model.beginPDFExport())
            model.completePDFExport(to: directory.appendingPathComponent("missing/output.pdf"))
            #expect(model.outputError != nil)
            #expect(model.error == nil)
            #expect(!model.isExporting)
            #expect(model.canOutput)
            #expect(model.result?.logicalDocument === preview)
            let destination = directory.appendingPathComponent("retry.pdf")
            #expect(model.beginPDFExport())
            model.completePDFExport(to: destination)
            #expect(model.outputError == nil)
            #expect(model.canOutput)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("保存パネル表示中は出力と重複開始を禁止しキャンセルで解除する", .timeLimit(.minutes(1)))
    func exportDisablesOutputUntilCompletion() async throws {
        try await withRenderedPDF { model, _ in
            #expect(model.canOutput)
            #expect(model.beginPDFExport())
            #expect(model.isExporting)
            #expect(!model.canOutput)
            #expect(!model.beginPDFExport())
            model.completePDFExport(to: nil)
            #expect(!model.isExporting)
            #expect(model.outputError == nil)
            #expect(model.canOutput)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withRenderedPDF(_ body: (DocumentViewModel, URL) throws -> Void) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "SurimonoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        let model = DocumentViewModel(
            data: data as Data, fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        model.render()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isRendering, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.canOutput)
        try body(model, directory)
    }
}
