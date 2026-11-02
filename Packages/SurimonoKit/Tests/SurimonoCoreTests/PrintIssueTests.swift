import Foundation
import Testing

@testable import SurimonoCore

struct PrintIssueTests {
    @Test("問題はページ順で並び、同じページは検出順、場所不明は最後になる")
    func ordering() {
        let issues = [
            PrintIssue(id: "unknown", kind: .math, detail: "x"),
            PrintIssue(id: "second", kind: .overflow, detail: "", pageNumber: 2),
            PrintIssue(id: "first", kind: .image, detail: "a.png", pageNumber: 1),
            PrintIssue(id: "same", kind: .latex, detail: "figure", pageNumber: 2),
        ]
        #expect(PrintIssue.sorted(issues).map(\.id) == ["first", "second", "same", "unknown"])
    }

    @Test("問題の種類と理由とページ上の矩形を保存して復元できる")
    func coding() throws {
        let issue = PrintIssue(
            id: "image", kind: .image, detail: "images/flow.png", imageFailure: .folderAccess,
            pageNumber: 2, rect: CGRect(x: 20, y: 30, width: 1, height: 8), locationKey: "image:flow:1")
        #expect(try JSONDecoder().decode(PrintIssue.self, from: JSONEncoder().encode(issue)) == issue)
    }

    @Test("検出IDと表示文が同じでも移動先は元の出現箇所の鍵で選ぶ")
    func destinationMatchesSource() {
        let source = PrintIssue(id: "1", kind: .math, detail: "x", pageNumber: 9, locationKey: "math:x:1")
        let view = [
            PrintIssue(id: "1", kind: .math, detail: "x", pageNumber: 5, locationKey: "math:x:0"),
            PrintIssue(id: "0", kind: .math, detail: "x", pageNumber: 2, locationKey: "math:x:1"),
        ]
        #expect(source.pageIndex(in: view, pageCount: 6, sourcePageCount: 12) == 1)
    }

    @Test("表示に問題がなければ文書内の割合で近似し端のページと一枚の文書にも収める")
    func approximateDestination() {
        let source = PrintIssue(id: "0", kind: .overflow, detail: "", pageNumber: 9)
        #expect(source.pageIndex(in: [], pageCount: 6, sourcePageCount: 12) == 4)
        #expect(source.pageIndex(in: [], pageCount: 1, sourcePageCount: 12) == 0)
        let last = PrintIssue(id: "0", kind: .overflow, detail: "", pageNumber: 12)
        #expect(last.pageIndex(in: [], pageCount: 6, sourcePageCount: 12) == 5)
    }

    @Test("画像の表示名は文書からの相対パスかファイル名になり数式は40文字で省略する")
    func details() {
        let directory = URL(fileURLWithPath: "/tmp/article", isDirectory: true)
        #expect(
            PrintIssue.imageName(URL(fileURLWithPath: "/tmp/article/images/flow.png"), directory: directory)
                == "images/flow.png")
        #expect(PrintIssue.imageName(URL(fileURLWithPath: "/elsewhere/flow.png"), directory: directory) == "flow.png")
        #expect(PrintIssue.excerpt("a\n b") == "a b")
        #expect(PrintIssue.excerpt(String(repeating: "あ", count: 41)) == String(repeating: "あ", count: 40) + "…")
    }
}
