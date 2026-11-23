import CoreGraphics
import SurimonoCore
import Testing

struct PageGridTests {
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
        #expect(portrait.paper == CGSize(width: 104, height: 208))
        #expect(landscape.paper == CGSize(width: 160, height: 80))
        #expect(portrait.paperAreaHeight == 208 && landscape.paperAreaHeight == 208)
        #expect(PageTileSize(width: 160, aspect: 2, rowMateAspect: nil).paperAreaHeight == 80)
    }
}
