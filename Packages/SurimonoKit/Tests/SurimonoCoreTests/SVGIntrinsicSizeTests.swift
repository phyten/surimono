import Foundation
import SurimonoCore
import Testing

struct SVGIntrinsicSizeTests {
    private func size(_ svg: String) -> CGSize? { SVGIntrinsicSize.of(Data(svg.utf8)) }

    @Test("幅と高さを書いた SVG はその寸法になる")
    func widthAndHeight() {
        let svg1 = #"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"></svg>"#
        #expect(size(svg1) == CGSize(width: 200, height: 100))
    }

    @Test("単位つきの幅と高さは CSS の px に換算する")
    func units() {
        let svg2 = #"<svg xmlns="http://www.w3.org/2000/svg" width="72pt" height="1in"/>"#
        #expect(size(svg2) == CGSize(width: 96, height: 96))
        let metric = size(#"<svg xmlns="http://www.w3.org/2000/svg" width="25.4mm" height="2.54cm"/>"#)
        #expect(metric.map { abs($0.width - 96) < 0.001 && abs($0.height - 96) < 0.001 } == true)
    }

    @Test("viewBox だけの SVG は viewBox の幅と高さになる")
    func viewBoxOnly() {
        let svg3 = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640, 480"/>"#
        #expect(size(svg3) == CGSize(width: 640, height: 480))
    }

    @Test("幅だけと viewBox の SVG は viewBox の比で高さを決める")
    func widthWithViewBox() {
        let svg4 = #"<svg xmlns="http://www.w3.org/2000/svg" width="300" viewBox="0 0 600 200"/>"#
        #expect(size(svg4) == CGSize(width: 300, height: 100))
    }

    @Test("割合の幅は寸法に使わず viewBox から決める")
    func percentageFallsBackToViewBox() {
        let svg5 = #"<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 40 30"/>"#
        #expect(size(svg5) == CGSize(width: 40, height: 30))
    }

    @Test("寸法も viewBox もない SVG は 300 × 150 になる")
    func defaultSize() {
        let svg6 = #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="5" height="5"/></svg>"#
        #expect(size(svg6) == CGSize(width: 300, height: 150))
    }

    @Test("XML 宣言・コメント・DOCTYPE のあとの svg も読む")
    func prolog() {
        let svg = """
            \u{FEFF}<?xml version="1.0" encoding="UTF-8"?>
            <!-- drawn by hand -->
            <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
            <svg xmlns="http://www.w3.org/2000/svg" width="10" height="20"/>
            """
        #expect(size(svg) == CGSize(width: 10, height: 20))
    }

    @Test("ゼロ・負・数でない・巨大な寸法は使わない")
    func invalidDimensions() {
        let svg7 = #"<svg xmlns="http://www.w3.org/2000/svg" width="0" height="-5" viewBox="0 0 8 4"/>"#
        #expect(size(svg7) == CGSize(width: 8, height: 4))
        let svg8 = #"<svg xmlns="http://www.w3.org/2000/svg" width="1e400" height="abc"/>"#
        #expect(size(svg8) == CGSize(width: 300, height: 150))
    }

    @Test("svg でない XML や画像のバイト列は SVG と見なさない")
    func notSVG() {
        #expect(size("<html><body></body></html>") == nil)
        #expect(SVGIntrinsicSize.of(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == nil)
        #expect(SVGIntrinsicSize.of(Data()) == nil)
        #expect(size("<?xml version=\"1.0\"?>\n<!-- no element -->") == nil)
    }
}
