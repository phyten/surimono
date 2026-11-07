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

    @Test("読めない画像・壊れた数式・図・未対応の LaTeX は内容を刷れない問題、はみ出しは配置を確かめる問題に分かれる")
    func groups() {
        for kind in [PrintIssue.Kind.image, .math, .mermaid, .latex] {
            #expect(PrintIssue(id: "0", kind: kind, detail: "x").group == .content)
        }
        for element in [PrintIssue.Element.table, .image, .figure, .code, .math] {
            #expect(PrintIssue(id: "0", kind: .overflow, detail: "", element: element).group == .layout)
        }
    }

    @Test("分けた一覧は内容を刷れないものを先に置き、問題のない組は出さず、組の中の順は変えない")
    func groupedIssues() {
        let issues = [
            PrintIssue(id: "table", kind: .overflow, detail: "", element: .table, pageNumber: 1),
            PrintIssue(id: "image", kind: .image, detail: "a.png", pageNumber: 2),
            PrintIssue(id: "code", kind: .overflow, detail: "", element: .code, pageNumber: 3),
            PrintIssue(id: "math", kind: .math, detail: "x", pageNumber: 4),
        ]
        let groups = PrintIssue.grouped(issues)
        #expect(groups.map(\.group) == [.content, .layout])
        #expect(groups[0].issues.map(\.id) == ["image", "math"])
        #expect(groups[1].issues.map(\.id) == ["table", "code"])
        #expect(PrintIssue.grouped(Array(issues.filter { $0.kind == .overflow })).map(\.group) == [.layout])
        #expect(PrintIssue.grouped([]).isEmpty)
    }

    private let page = CGRect(x: 0, y: 0, width: 595.2756, height: 841.8898)

    @Test("枠は問題の要素の左上を示すリンクから、ページの右端へ向かって、少し上から 32pt の高さで囲む")
    func spotFrame() {
        let anchor = CGRect(x: 46.5, y: 702.5, width: 0.5, height: 0.5)
        let frame = PrintIssue.spotFrame(around: anchor, in: page)
        // 8pt left of the element, 4pt above its top (703), and 32pt tall; the right edge keeps 8pt from the page.
        #expect(abs(frame.minX - 38.5) < 0.001)
        #expect(abs(frame.maxX - (595.2756 - 8)) < 0.001)
        #expect(abs(frame.maxY - 707) < 0.001)
        #expect(abs(frame.height - 32) < 0.001)
    }

    @Test("枠はページの上端と下端からはみ出さず、左端にも 8pt の余白を残す")
    func spotFrameStaysOnThePage() {
        let top = PrintIssue.spotFrame(around: CGRect(x: 2, y: 840, width: 0.5, height: 0.5), in: page)
        #expect(top.maxY <= page.maxY - 2 + 0.001)
        #expect(top.minX >= 8 - 0.001)
        let bottom = PrintIssue.spotFrame(around: CGRect(x: 100, y: 10, width: 0.5, height: 0.5), in: page)
        #expect(bottom.minY >= page.minY + 2 - 0.001)
        #expect(bottom.height > 0)
    }

    @Test("ページの余白が原点でなくても、枠はそのページの範囲で決まる")
    func spotFrameFollowsThePageBox() {
        let shifted = CGRect(x: 20, y: 30, width: 420, height: 595)
        let frame = PrintIssue.spotFrame(around: CGRect(x: 60, y: 500, width: 0.5, height: 0.5), in: shifted)
        #expect(abs(frame.minX - 52) < 0.001)
        #expect(abs(frame.maxX - (440 - 8)) < 0.001)
    }
}
