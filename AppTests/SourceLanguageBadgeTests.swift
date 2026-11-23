import Foundation
import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct SourceLanguageBadgeTests {
    private func badge(_ name: String?, _ text: String = "", format: DocumentFormat = .plainText) -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = BandTestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data(text.utf8), fileURL: name.map { directory.appendingPathComponent($0) }, format: format,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        model.isolateBandTestOutput()
        return model.shortFormatBadge
    }

    /// A window's model over a file, laid out with stand-in pages so that the text is really converted.
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        let url: URL
        let model: DocumentViewModel

        @MainActor
        init(_ name: String, _ data: Data, paginate: DocumentRenderer.Paginate? = nil) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent(name)
            try data.write(to: url)
            let renderer = DocumentRenderer(
                paginate: paginate ?? { _ in PDFDocument(data: TestFixtures.pdf("Source", pages: 1))! })
            model = DocumentViewModel(
                data: data, fileURL: url, format: .plainText, preferences: AppPreferences(defaults: suite.defaults),
                library: UserLibrary(root: directory.appendingPathComponent("Library")), renderer: renderer,
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
            model.start()
        }

        @MainActor
        func close() {
            model.stop()
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func wait(_ reason: Comment, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), reason)
    }

    @Test("ソースコードの形式バッジは言語の名前になる")
    func sourceCode() {
        #expect(badge("main.swift") == "Swift")
        #expect(badge("main.ts") == "TypeScript")
        #expect(badge("tool.py") == "Python")
        #expect(badge("model.rb") == "Ruby")
        #expect(badge("config.yaml") == "YAML")
        #expect(badge("Makefile") == "Makefile")
    }

    @Test("固定名から派生した名前でも、文章の拡張子なら形式バッジは TXT のまま")
    func derivedNames() {
        #expect(badge("Dockerfile.txt") == "TXT")
        #expect(badge("Dockerfile.dev") == "Dockerfile")
    }

    @Test("文章と名前のないテキストの形式バッジは TXT のまま")
    func plainText() {
        #expect(badge("notes.txt", "#!/bin/sh\n") == "TXT")
        #expect(badge("server.log") == "TXT")
        #expect(badge(nil, "#!/bin/sh\n") == "TXT")
    }

    @Test("テキスト以外の形式のバッジは変わらない")
    func otherFormats() {
        #expect(badge("notes.md", format: .markdown) == "MD")
        #expect(badge("table.csv", format: .csv) == "CSV")
    }

    @Test("本文を読まないと分からない言語は、組版が本文を読むまで名前だけで決めた表示にする")
    func beforeLayout() {
        // No layout has run for these models, and the badge does not decode the text to find out.
        #expect(badge("tool", "#!/usr/bin/env python3\nprint(1)\n") == "TXT")
        #expect(badge("solve.m", "% Solves.\nx = 1;\n") == "Objective-C")
    }

    @Test("拡張子のないスクリプトの形式バッジは、組版のあと shebang の言語になる", .timeLimit(.minutes(1)))
    func shebang() async throws {
        let fixture = try Fixture("tool", Data("#!/usr/bin/env python3\nprint(1)\n".utf8))
        defer { fixture.close() }
        try await wait("組版が終わる") { fixture.model.result != nil && !fixture.model.isRendering }
        #expect(fixture.model.shortFormatBadge == "Python")
        #expect(fixture.model.result?.facts?.sourceLanguage?.id == "python")
    }

    @Test("UTF-16 の .m が % で始まるとき、形式バッジは紙と同じ MATLAB になる", .timeLimit(.minutes(1)))
    func utf16() async throws {
        let text = try #require("% 解く\nx = 1;\n".data(using: .utf16LittleEndian))
        let fixture = try Fixture("solve.m", Data([0xFF, 0xFE]) + text)
        defer { fixture.close() }
        #expect(fixture.model.shortFormatBadge == "Objective-C")
        try await wait("組版が終わる") { fixture.model.result != nil && !fixture.model.isRendering }
        #expect(fixture.model.shortFormatBadge == "MATLAB")
    }

    @Test("同じウインドウで先頭行を Python から Ruby に変えると、形式バッジの読み手に変更が通知され Ruby になる", .timeLimit(.minutes(1)))
    func reloadChangesLanguage() async throws {
        let fixture = try Fixture("tool", Data("#!/usr/bin/env python3\nprint(1)\n".utf8))
        defer { fixture.close() }
        let model = fixture.model
        try await wait("組版が終わる") { model.result != nil && !model.isRendering }
        #expect(model.shortFormatBadge == "Python")
        final class Flag: @unchecked Sendable {
            // Only read and written on the main actor: Observation calls back where the change is made.
            var changed = false
        }
        let flag = Flag()
        withObservationTracking {
            _ = model.shortFormatBadge
        } onChange: {
            flag.changed = true
        }
        try Data("#!/usr/bin/env ruby\nputs 1\n".utf8).write(to: fixture.url, options: .atomic)
        model.reload()
        try await wait("読み直した本文の言語になる") { model.shortFormatBadge == "Ruby" }
        #expect(flag.changed)
        #expect(model.sourceLanguage?.id == "ruby")
    }

    /// Holds the first layout until the test lets it go, so that a later layout can finish before it.
    @MainActor
    private final class HeldLayout {
        var calls = 0
        private var held: CheckedContinuation<Void, Never>?

        func paginate(_ request: PaginationRequest) async -> PDFDocument {
            calls += 1
            if calls == 1 { await withCheckedContinuation { held = $0 } }
            return PDFDocument(data: TestFixtures.pdf("Source", pages: 1))!
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    @Test("古い内容の組版が新しい内容の組版より後に終わっても、形式バッジは新しい内容の言語のまま", .timeLimit(.minutes(1)))
    func lateLayoutOfOldContents() async throws {
        let layout = HeldLayout()
        let fixture = try Fixture(
            "tool", Data("#!/usr/bin/env python3\nprint(1)\n".utf8), paginate: { await layout.paginate($0) })
        defer { fixture.close() }
        let model = fixture.model
        try await wait("最初の組版が始まる") { layout.calls == 1 }
        // The first layout is held: nothing has read the text for this window yet.
        #expect(model.result == nil)
        #expect(model.shortFormatBadge == "TXT")
        try Data("#!/usr/bin/env ruby\nputs 1\n".utf8).write(to: fixture.url, options: .atomic)
        model.reload()
        try await wait("新しい内容の組版が先に終わる") { model.shortFormatBadge == "Ruby" && !model.isRendering }
        #expect(layout.calls >= 2)
        // Now the layout of the old contents finishes, with Python in its facts.
        layout.release()
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.shortFormatBadge == "Ruby")
        #expect(model.result?.facts?.sourceLanguage?.id == "ruby")
        #expect(model.data == Data("#!/usr/bin/env ruby\nputs 1\n".utf8))
    }

    @Test("先頭行から shebang が消えると、形式バッジは TXT に戻る", .timeLimit(.minutes(1)))
    func reloadRemovesLanguage() async throws {
        let fixture = try Fixture("tool", Data("#!/bin/sh\necho 1\n".utf8))
        defer { fixture.close() }
        let model = fixture.model
        try await wait("組版が終わる") { model.result != nil && !model.isRendering }
        #expect(model.shortFormatBadge == "Shell")
        try Data("echo 1\n".utf8).write(to: fixture.url, options: .atomic)
        model.reload()
        try await wait("読み直した本文に合わせる") { model.shortFormatBadge == "TXT" }
    }
}
