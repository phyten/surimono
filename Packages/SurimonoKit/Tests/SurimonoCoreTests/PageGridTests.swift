import CoreGraphics
import SurimonoCore
import Testing

struct PageGridTests {
    @Test("読めない画像をまたぐすき間では両側から同じ順番に移る", arguments: [1, 2])
    func hiddenGap(columns: Int) {
        let full = ["A", "X", "B", "C"]
        let visible = ["A", "B", "C"]
        for (page, position) in [(0, 99), (1, 1)] {
            let marker = PageGridInsertion(
                point: CGPoint(x: position, y: position), tile: CGSize(width: 100, height: 100),
                columns: columns, rightToLeft: false)
            let gap = PageGridGap(readable: visible, page: page, after: marker.after)
            #expect(gap.moving("C", in: full) == ["A", "X", "C", "B"])
        }
    }

    @Test("先頭は最初の可読画像の直前、末尾は読めない末尾画像の後に移す")
    func ends() {
        let full = ["H", "A", "B", "C", "T"]
        let visible = ["A", "B", "C"]
        #expect(
            PageGridGap(readable: visible, page: 0, after: false).moving("C", in: full) == ["H", "C", "A", "B", "T"])
        #expect(
            PageGridGap(readable: visible, page: 2, after: true).moving("A", in: full) == ["H", "B", "C", "T", "A"])
    }

    @Test("自身の両隣に落としても不可視の画像との順序を変えない")
    func adjacent() {
        let full = ["H", "A", "X", "B", "Y", "C", "T"]
        let visible = ["A", "B", "C"]
        for (page, after) in [(0, true), (1, false), (1, true), (2, false)] {
            #expect(PageGridGap(readable: visible, page: page, after: after).moving("B", in: full) == full)
        }
        #expect(PageGridGap(readable: visible, page: 2, after: true).moving("C", in: full) == full)
    }

    @Test("外枠の内側と縮図の間には2ptあり、枠を含めても列幅に収まる")
    func inset() {
        let tile = PageTileSize(width: 100, aspect: 1, rowMateAspect: nil)
        #expect(tile.paper == CGSize(width: 90, height: 90))
        #expect(PageTileSize.framePadding - PageTileSize.currentLineWidth == 2)
    }

    private let tile = CGSize(width: 100, height: 140)

    @Test("1列ではタイルの上半分と下半分で前後を選び、境界に横線を置く")
    func oneColumn() {
        let top = PageGridInsertion(point: CGPoint(x: 99, y: 69), tile: tile, columns: 1, rightToLeft: false)
        let bottom = PageGridInsertion(point: CGPoint(x: 1, y: 70), tile: tile, columns: 1, rightToLeft: false)
        #expect(!top.after && top.line == CGRect(x: 0, y: -1, width: 100, height: 2))
        #expect(bottom.after && bottom.line == CGRect(x: 0, y: 139, width: 100, height: 2))
    }

    @Test("2列では同じすき間を両隣から選べ、グリッドが右始まりでも移動先と縦線が一致する", arguments: [true, false])
    func twoColumns(rtl: Bool) {
        let left = PageGridInsertion(point: CGPoint(x: 49, y: 130), tile: tile, columns: 2, rightToLeft: rtl)
        let right = PageGridInsertion(point: CGPoint(x: 50, y: 10), tile: tile, columns: 2, rightToLeft: rtl)
        #expect(left.after == rtl && left.line == CGRect(x: -1, y: 0, width: 2, height: 140))
        #expect(right.after != rtl && right.line == CGRect(x: 99, y: 0, width: 2, height: 140))
        #expect(right.line == left.line.offsetBy(dx: 100, dy: 0))
    }

    @Test("画像の束の2列では余白を含むタイルが引き出し幅に収まる")
    func paperWidth() {
        #expect(PageTileSize.availableWidth(in: 260, columns: 2, bundle: true) == 112)
        #expect(PageTileSize.availableWidth(in: 260, columns: 2, bundle: false) == 119)
        #expect(PageTileSize.availableWidth(in: 176, columns: 1, bundle: true) == 154)
    }

    @Test("高さを共有するのは同じ節の同じ行の2枚だけで、1列と端数の最終行では共有しない")
    func rowMates() {
        #expect(PageTileSize.rowMate(of: 3, in: 3..<6, columns: 2) == 4)
        #expect(PageTileSize.rowMate(of: 4, in: 3..<6, columns: 2) == 3)
        #expect(PageTileSize.rowMate(of: 5, in: 3..<6, columns: 2) == nil)
        #expect(PageTileSize.rowMate(of: 3, in: 3..<6, columns: 1) == nil)
    }

    @Test("縦長と横長の画像は同じ高さの欄に収まり、単独文書の横長ページは余白を取らない")
    func paperSlots() {
        let portrait = PageTileSize(width: 160, aspect: 0.5, rowMateAspect: 2)
        let landscape = PageTileSize(width: 160, aspect: 2, rowMateAspect: 0.5)
        #expect(portrait.paper == CGSize(width: 99, height: 198))
        #expect(landscape.paper == CGSize(width: 150, height: 75))
        #expect(portrait.paperAreaHeight == 208 && landscape.paperAreaHeight == 208)
        #expect(PageTileSize(width: 160, aspect: 2, rowMateAspect: nil).paperAreaHeight == 85)
    }
}
