import CoreGraphics
import Testing

@testable import Surimono

@MainActor
struct PrintTopBarFoldTests {
    /// The bar's width with none of the steps taken, then with one more at a time.
    private let needed: [CGFloat] = [760, 730, 700, 640, 600, 520, 480]

    @Test("全部が入る幅では何も外さない")
    func nothingFolds() {
        let fold = PrintTopBarFold(available: 800, needed: needed)
        #expect(fold.foldedCount == 0)
        #expect(!fold.folds(.escTag))
    }

    @Test("狭いときは、戻るボタンの esc の札と設定セットの名前を先に外す")
    func tagAndSetNameFirst() {
        #expect(PrintTopBarFold(available: 759, needed: needed).foldedCount == 1)
        let fold = PrintTopBarFold(available: 700, needed: needed)
        #expect(fold.folds(.escTag) && fold.folds(.setName))
        #expect(!fold.folds(.pageCount) && !fold.folds(.backTitle))
    }

    @Test("外す順はいつも同じで、後の段だけを外すことはない")
    func foldsInOrder() {
        for width in stride(from: 300, through: 900, by: 5) {
            let fold = PrintTopBarFold(available: CGFloat(width), needed: needed)
            let folded = PrintTopBarFold.Step.allCases.map(fold.folds)
            // Once a step is kept, every later step is kept too.
            #expect(folded == folded.sorted { $0 && !$1 }, "\(width)")
        }
    }

    @Test("どの段でも入らない幅では、全部の段を外したところで止まる")
    func foldsEverythingAtMost() {
        let fold = PrintTopBarFold(available: 100, needed: needed)
        #expect(fold.foldedCount == PrintTopBarFold.Step.allCases.count)
        #expect(fold.folds(.setsTitle))
    }

    @Test("戻るボタンの文字は、スタイルの見出しより後に外す")
    func backTitleAfterStyleTitle() {
        let fold = PrintTopBarFold(available: 600, needed: needed)
        #expect(fold.folds(.styleTitle))
        #expect(!fold.folds(.backTitle))
    }
}
