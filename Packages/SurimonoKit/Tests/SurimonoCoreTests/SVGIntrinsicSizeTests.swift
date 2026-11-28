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

struct SVGIntrinsicSizeOverflowTests {
    @Test("算出した寸法が有限でない SVG や不正な viewBox の寸法を返さない")
    func overflowAndViewBox() {
        let tall = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" viewBox="0 0 1e-308 10"/>"#
        #expect(SVGIntrinsicSize.of(Data(tall.utf8)) == nil)
        let extra = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 invalid 200 100"/>"#
        #expect(SVGIntrinsicSize.of(Data(extra.utf8)) == SVGIntrinsicSize.defaultSize)
        let spaced = String(repeating: " ", count: 200) + #"<svg xmlns="http://www.w3.org/2000/svg"/>"#
        #expect(SVGIntrinsicSize.of(Data(spaced.utf8)) == SVGIntrinsicSize.defaultSize)
        #expect(SVGIntrinsicSize.of(Data(#"<svg xmlns="urn:not-svg"/>"#.utf8)) == nil)
    }
}

struct SVGIntrinsicSizeLimitTests {
    private func read(_ svg: String) -> SVGIntrinsicSize.Reading? { SVGIntrinsicSize.read(Data(svg.utf8)) }

    @Test("縦横比から算出した寸法が有限でなければ、使えない SVG にする")
    func computedOverflow() {
        let tall = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" viewBox="0 0 1e-308 10"/>"#
        #expect(read(tall) == .unusable(.unreadable))
        let wide = #"<svg xmlns="http://www.w3.org/2000/svg" height="10" viewBox="0 0 10 1e-308"/>"#
        #expect(read(wide) == .unusable(.unreadable))
    }

    @Test("viewBox は有限な数がちょうど 4 つのときだけ使う")
    func strictViewBox() {
        let extra = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 invalid 200 100"/>"#
        #expect(read(extra) == .size(SVGIntrinsicSize.defaultSize))
        let notANumber = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="nan 0 200 100"/>"#
        #expect(read(notANumber) == .size(SVGIntrinsicSize.defaultSize))
    }

    @Test("上限を超えるマークアップは解析せず、大きすぎる SVG として断る")
    func tooLarge() {
        var data = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">"#.utf8)
        data.append(Data(repeating: 0x20, count: SVGIntrinsicSize.maximumBytes))
        #expect(SVGIntrinsicSize.read(data) == .unusable(.tooLarge))
    }

    @Test("根要素の前の序文が長すぎる SVG は読めない画像にする")
    func longProlog() {
        let comment = "<!--" + String(repeating: "x", count: 200_000) + "-->"
        #expect(read(comment + #"<svg xmlns="http://www.w3.org/2000/svg"/>"#) == .unusable(.unreadable))
    }

    @Test("先頭の長い空白と UTF-16 の BOM のあとの svg も読む")
    func leadingWhitespaceAndUTF16() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="20"/>"#
        let spaced = String(repeating: " ", count: 200) + svg
        #expect(read(spaced) == .size(CGSize(width: 10, height: 20)))
        let utf16 = try #require(svg.data(using: .utf16))
        #expect(utf16.starts(with: [0xFF, 0xFE]) || utf16.starts(with: [0xFE, 0xFF]))
        #expect(SVGIntrinsicSize.read(utf16) == .size(CGSize(width: 10, height: 20)))
    }

    @Test("SVG の名前空間でない svg 要素は使えない SVG にする")
    func namespace() {
        #expect(read(#"<svg width="10" height="20"/>"#) == .unusable(.unreadable))
        #expect(read(#"<svg xmlns="urn:not-svg" width="10" height="20"/>"#) == .unusable(.unreadable))
        let prefixed = #"<s:svg xmlns:s="http://www.w3.org/2000/svg" width="10" height="20"/>"#
        #expect(read(prefixed) == .size(CGSize(width: 10, height: 20)))
    }

    @Test("画像のバイト列はマークアップでないので SVG の判定に入らない")
    func binary() {
        #expect(SVGIntrinsicSize.read(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == nil)
        #expect(SVGIntrinsicSize.read(Data()) == nil)
    }
}

struct SVGComplexityTests {
    private func read(_ svg: String) -> SVGIntrinsicSize.Reading? { SVGIntrinsicSize.read(Data(svg.utf8)) }

    /// Eleven levels that each use the one below ten times: 10^11 copies of one rectangle once drawn.
    private func fanOut(levels: Int) -> String {
        var svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><defs>"#
        svg += #"<rect id="l0" width="1" height="1"/>"#
        for level in 1...levels {
            svg += "<g id=\"l\(level)\">" + String(repeating: "<use href=\"#l\(level - 1)\"/>", count: 10) + "</g>"
        }
        return svg + "</defs><use href=\"#l\(levels)\"/></svg>"
    }

    @Test("use の入れ子で描く要素が爆発する SVG は描かずに断る")
    func useFanOut() {
        #expect(read(fanOut(levels: 11)) == .unusable(.tooComplex))
    }

    @Test("ふつうに use で部品を使い回す SVG はそのまま読む")
    func ordinaryUse() {
        #expect(read(fanOut(levels: 3)) == .size(CGSize(width: 100, height: 100)))
    }

    @Test("自分を参照する use の輪は断る")
    func cycle() {
        var svg = #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">"#
        svg += ##"<g id="a"><use xlink:href="#a"/><use href="#b"/></g><g id="b"><use href="#a"/></g></svg>"##
        #expect(read(svg) == .unusable(.tooComplex))
    }

    @Test("模様や効果を url で重ねて爆発する SVG も断る")
    func patternFanOut() {
        var svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><defs>"#
        svg += #"<pattern id="p0" width="1" height="1"><rect width="1" height="1"/></pattern>"#
        for level in 1...11 {
            let fill = "<rect width=\"1\" height=\"1\" fill=\"url(#p\(level - 1))\"/>"
            svg += "<pattern id=\"p\(level)\" width=\"1\" height=\"1\">" + String(repeating: fill, count: 10)
            svg += "</pattern>"
        }
        svg += #"</defs><rect width="100" height="100" style="fill: url(#p11)"/></svg>"#
        #expect(read(svg) == .unusable(.tooComplex))
    }
}
