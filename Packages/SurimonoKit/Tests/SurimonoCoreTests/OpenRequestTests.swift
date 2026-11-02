import Foundation
import SurimonoCore
import Testing

struct OpenRequestTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/" + name) }

    @Test("1つのファイルは形式によらず単独で開く", arguments: ["a.md", "a.pdf", "a.png", "a.unknown"])
    func single(_ name: String) {
        #expect(OpenRequest(urls: [url(name)]) == .single(url(name)))
    }

    @Test("3つの画像をファイル名の自然順にまとめる")
    func naturalOrder() {
        #expect(
            OpenRequest(urls: [url("10.jpg"), url("2.jpg"), url("1.jpg")])
                == .imageBundle([url("1.jpg"), url("2.jpg"), url("10.jpg")]))
    }

    @Test("種類と拡張子の大小文字が混ざっていても画像をまとめる")
    func mixedImageTypes() {
        let names = ["1.JPG", "2.png", "3.gif", "4.heic", "5.tiff", "6.webp"]
        #expect(OpenRequest(urls: names.reversed().map(url)) == .imageBundle(names.map(url)))
    }

    @Test("拡張子の表にない画像も単独で開くときと同じく内容の型で画像として束にまとめる")
    func imageByContentType() {
        #expect(OpenRequest(urls: [url("b.psd"), url("a.png")]) == .imageBundle([url("a.png"), url("b.psd")]))
    }

    @Test("画像以外を含む複数選択は自然順の合本になる")
    func binder() {
        #expect(
            OpenRequest(urls: [url("10.pdf"), url("2.md"), url("1.png"), url("2.md")])
                == .binder([url("1.png"), url("2.md"), url("10.pdf")], excluded: []))
    }

    @Test("対応するすべての文書形式を合本に含める")
    func allFormats() {
        let names = ["1.md", "2.org", "3.txt", "4.csv", "5.tex", "6.html", "7.pdf", "8.jpg"]
        #expect(OpenRequest(urls: names.reversed().map(url)) == .binder(names.map(url), excluded: []))
    }

    @Test("ZIPや未対応形式を除いて画像だけ残れば除外一覧を持つ画像の束になる")
    func excluded() {
        #expect(
            OpenRequest(urls: [url("a.jpg"), url("b.zip"), url("c.unknown")])
                == .imageBundle([url("a.jpg")], excluded: [url("b.zip"), url("c.unknown")]))
        #expect(OpenRequest(urls: [url("b.zip"), url("c.unknown")]) == .unsupported)
    }

    @Test("画像と除外ファイルの両方を重複排除して自然順にする")
    func imageExclusions() {
        #expect(
            OpenRequest(urls: [url("10.png"), url("2.jpg"), url("10.zip"), url("2.zip"), url("2.jpg"), url("2.zip")])
                == .imageBundle([url("2.jpg"), url("10.png")], excluded: [url("2.zip"), url("10.zip")]))
        #expect(
            OpenRequest(urls: [url("a.pdf"), url("b.zip"), url("c.jpg")])
                == .binder([url("a.pdf"), url("c.jpg")], excluded: [url("b.zip")]))
    }

    @Test("文書の拡張子が付いたフォルダーも除く")
    func directory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(
            OpenRequest(urls: [folder, url("a.pdf")]) == .binder([url("a.pdf")], excluded: [folder.standardizedFileURL])
        )
    }

    @Test("画像の束から重複URLを除き1種類だけでも束として扱う")
    func duplicates() {
        #expect(
            OpenRequest(urls: [url("2.jpg"), url("1.jpg"), url("2.jpg")])
                == .imageBundle([url("1.jpg"), url("2.jpg")]))
        #expect(OpenRequest(urls: [url("1.jpg"), url("1.jpg")]) == .imageBundle([url("1.jpg")]))
    }

    @Test("空の要求では何もしない")
    func empty() { #expect(OpenRequest(urls: []) == .empty) }
}
