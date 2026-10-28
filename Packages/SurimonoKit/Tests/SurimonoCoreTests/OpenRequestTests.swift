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

    @Test("画像以外を含む複数選択は全体を拒否する", arguments: [["a.jpg", "b.pdf"], ["a.md", "b.md"]])
    func rejected(_ names: [String]) {
        #expect(OpenRequest(urls: names.map(url)) == .rejectedMultipleNonImages)
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
