import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThemeSampleCacheTests {
    @Test("固定見本は再起動相当の読み直しで描画せず、破損時は描き直す")
    func reuseAndRepair() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = ThemeSamples()
        samples.diskCache = ThemeSampleCache(directory: directory)
        samples.specimenLanguage = { "en" }
        samples.inputs = { (ThemeSpecimen.source(language: "en"), ThemeSpecimen.settings) }
        defer { samples.invalidate() }
        let theme = PrintTheme(id: "test", name: "Test", css: "body { color: black; }")
        await samples.load(theme)
        #expect(samples.drawCount == 1)
        samples.invalidate()
        await samples.load(theme)
        #expect(samples.drawCount == 0)
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)
        samples.invalidate()
        await samples.load(theme)
        #expect(samples.drawCount == 1)
        #expect(PDFDocument(url: file)?.pageCount == 1)
    }

    @Test("CSSと見本の言語と用紙を変えたら描き直す")
    func changedInputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = ThemeSamples()
        samples.diskCache = ThemeSampleCache(directory: directory)
        var language = "en"
        var settings = ThemeSpecimen.settings
        samples.specimenLanguage = { language }
        samples.inputs = { (ThemeSpecimen.source(language: language), settings) }
        defer { samples.invalidate() }
        let original = PrintTheme(id: "test", name: "Test", css: "body { color: black; }")
        let edited = PrintTheme(id: "test", name: "Test", css: "body { color: blue; }")
        await samples.load(original)
        samples.invalidate()
        await samples.load(edited)
        #expect(samples.drawCount == 1)
        language = "ja"
        samples.invalidate()
        await samples.load(edited)
        #expect(samples.drawCount == 1)
        settings.layout = .b5Single
        samples.invalidate()
        await samples.load(edited)
        #expect(samples.drawCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 4)
    }

    @Test("実文書の見本はディスクへ書かない")
    func privateDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = ThemeSamples()
        samples.diskCache = ThemeSampleCache(directory: directory)
        samples.inputs = { (ThemeSpecimen.source(language: "en"), ThemeSpecimen.settings) }
        defer { samples.invalidate() }
        await samples.load(PrintTheme(id: "test", name: "Test", css: ""))
        #expect(samples.drawCount == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("キャッシュの保存に失敗しても描いた見本は残る")
    func unwritableCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        let samples = ThemeSamples()
        samples.diskCache = ThemeSampleCache(directory: directory)
        samples.specimenLanguage = { "en" }
        samples.inputs = { (ThemeSpecimen.source(language: "en"), ThemeSpecimen.settings) }
        defer { samples.invalidate() }
        let theme = PrintTheme(id: "test", name: "Test", css: "")
        await samples.load(theme)
        #expect(samples.drawCount == 1)
        #expect(samples.page(for: theme) != nil)
        #expect(try Data(contentsOf: directory) == Data("not a directory".utf8))
    }

    @Test("整理は最近使ったファイルを残して個数と容量を両方満たす")
    func eviction() {
        let files = (0..<4).map {
            ThemeSampleCache.Entry(
                url: URL(fileURLWithPath: "/\($0)"), size: 10, used: Date(timeIntervalSince1970: Double($0)))
        }
        #expect(ThemeSampleCache.removing(from: files, countLimit: 3, byteLimit: 20) == [files[0].url, files[1].url])
        #expect(ThemeSampleCache.removing(from: files, countLimit: 4, byteLimit: 40).isEmpty)
    }
}
