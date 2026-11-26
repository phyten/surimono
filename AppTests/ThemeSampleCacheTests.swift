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

    @Test("容量を超えた見本を整理で削除しても、読み込み済みのページは元の色で描ける")
    func scheduledEviction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ThemeSampleCache(directory: directory)
        let red = try #require(NSImage(data: TestFixtures.png(red: 1, green: 0, blue: 0)))
        cache.store(try #require(PDFPage(image: red)), for: "red")
        let page = try #require(cache.page(for: "red"))
        try await evict(directory.appendingPathComponent("red.pdf"), from: cache)

        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        let bounds = page.bounds(for: .mediaBox)
        context.scaleBy(x: 4 / bounds.width, y: 3 / bounds.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        page.draw(with: .mediaBox, to: context)
        let center = try #require(bitmap.colorAt(x: 2, y: 1)?.usingColorSpace(.sRGB))
        #expect(center.redComponent > 0.9 && center.greenComponent < 0.1 && center.blueComponent < 0.1)
    }

    @Test("読み込み前に整理でファイルが消えた見本は描き直して表示する")
    func rebuildAfterEviction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ThemeSampleCache(directory: directory)
        let samples = ThemeSamples()
        samples.diskCache = cache
        samples.specimenLanguage = { "en" }
        samples.inputs = { (ThemeSpecimen.source(language: "en"), ThemeSpecimen.settings) }
        defer { samples.invalidate() }
        let theme = PrintTheme(id: "test", name: "Test", css: "")
        await samples.load(theme)
        try #require(samples.page(for: theme) != nil)
        let sample = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        samples.invalidate()
        try await evict(sample, from: cache)

        await samples.load(theme)
        #expect(samples.drawCount == 1)
        #expect(samples.page(for: theme) != nil)
    }

    private func evict(_ sample: URL, from cache: ThemeSampleCache) async throws {
        // A newer sparse file fills the budget, so pruning must remove the intact sample.
        let filler = cache.directory.appendingPathComponent("filler.pdf")
        try Data().write(to: filler)
        let file = try FileHandle(forWritingTo: filler)
        try file.truncate(atOffset: 50 * 1024 * 1024)
        try file.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: sample.path)
        cache.schedulePruning()
        try await ShortcutMenuBaselineTests.waitForMenu { !FileManager.default.fileExists(atPath: sample.path) }
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
