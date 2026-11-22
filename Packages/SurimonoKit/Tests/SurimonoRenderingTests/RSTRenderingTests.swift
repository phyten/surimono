import AppKit
import Foundation
import RobustnessSupport
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct RSTRenderingTests {
    @Test("紙の見出しと読む順が HTML 書き出しにも残る", .timeLimit(.minutes(1)))
    func themedDocument() async throws {
        _ = NSApplication.shared
        let input = "Quay notes\n=========\n\nFirst watch.\n\nUpper rail\n----------\n\nThe *brass* ring shines."
        let source = DocumentSource(data: Data(input.utf8), format: .rst)
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        #expect(result.logicalDocument.pageCount == 1)
        let text = try #require(result.logicalDocument.page(at: 0)?.string)
        let structure = try #require(DocumentRenderer.structureHTML(of: source))
        let headings = DocumentOutline.headings(inHTML: structure)
        #expect(headings.map(\.text) == ["Quay notes", "Upper rail"])
        #expect(DocumentOutline.pages(of: headings, inPageTexts: [text]).allSatisfy { $0 != nil })
        #expect(text.contains("The brass ring shines."))
        let html = try await HTMLExporter.html(source: source, settings: settings, title: "Quay notes")
        #expect(html.contains("<em>brass</em>"))
        #expect(html.contains("id=\"upper-rail\""))
    }
}

extension RSTRenderingTests {
    @Test("原稿を読み直すと変更した段落が印の対象になる")
    func changeFollowing() async throws {
        let before = DocumentSource(data: Data("Before dusk.\n\nSame card.".utf8), format: .rst)
        let after = DocumentSource(data: Data("After dusk.\n\nSame card.".utf8), format: .rst)
        let changes = await DocumentRenderer().changeRequests(from: before, to: after, finish: .init())
        #expect(changes.map(\.blockID) == ["fragment-0"])
        let html = try #require(DocumentRenderer.structureHTML(of: after))
        #expect(DocumentStatistics(html: html).characters == 19)
    }

    @Test("原稿の隣の取り込みはフォルダの許可を反映する")
    func folderAccess() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("Shared gauge notes.".utf8).write(to: folder.appending(path: "log.inc"))
        let url = folder.appending(path: "watch.rst")
        let source = DocumentSource(data: Data(".. include:: log.inc".utf8), fileURL: url, format: .rst)
        let denied = Locked(false)
        let blocked = try #require(
            try DocumentRenderer.themedFragment(
                source, access: LocalResourceAccess(documentURL: url), onDenied: { denied.value = true }))
        #expect(denied.value)
        #expect(!blocked.body.contains("Shared gauge notes."))
        let accepted = try #require(
            try DocumentRenderer.themedFragment(
                source, access: LocalResourceAccess(documentURL: url, folders: [folder])))
        #expect(accepted.body.contains("Shared gauge notes."))
    }
}

extension RSTRenderingTests {
    @Test("読むための紙面ではリテラルの時刻と英単語が同じ通常ウェイトの等幅書体になる", .timeLimit(.minutes(1)))
    func literalFontInPDF() async throws {
        _ = NSApplication.shared
        let source = DocumentSource(
            data: Data("Time::\n\n   17:00   west   blue\n   18:00   west   white".utf8), format: .rst)
        let themes = try PrintThemeLibrary.load()
        for id in ["standard", "essay", "blueprint"] {
            let theme = try #require(themes.first { $0.id == id })
            let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
            let result = try await DocumentRenderer().render(source, settings: settings)
            let text = try #require(result.logicalDocument.page(at: 0)?.attributedString)
            let plain = text.string as NSString
            var fonts: Set<String> = []
            for word in ["17:00", "18:00", "west", "white"] {
                let range = plain.range(of: word)
                try #require(range.location != NSNotFound)
                for offset in range.location..<NSMaxRange(range) {
                    let font = try #require(text.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
                    fonts.insert(font.fontName)
                    #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
                    #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
                }
            }
            #expect(fonts.count == 1)
        }
    }
}
