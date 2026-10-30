import CoreGraphics
import Foundation
import SurimonoCore
import Testing

struct DocumentSettingsTests {
    @Test("すべての項目を JSON に書いて読み戻せる")
    func roundTrip() throws {
        let settings = DocumentSettings(
            view: ViewOptions(
                layout: .spread, direction: .rightToLeft, scrollAxis: .horizontal, transition: .pageCurl,
                showsCoverAlone: true),
            zoom: 1.5, windowSize: CGSize(width: 1190, height: 842), layoutID: "a3BookletA4", themeID: "mincho",
            presetID: "clean", smartRemoval: DocumentSettings.SmartRemoval(isEnabled: true, keptIDs: ["aside#ad"]),
            printOptions: PrintOptions(marginsInMillimeters: 12, showsPageNumbers: true, rotatesBackSides: true),
            imageOrder: ["b", "a"], htmlPresentation: .paper)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test("書かれていない項目は nil として読み、知らない項目は無視する")
    func partialAndUnknownFields() throws {
        let json = Data(#"{"layoutID":"a4Duplex","futureField":42}"#.utf8)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: json)
        #expect(decoded == DocumentSettings(layoutID: "a4Duplex"))
    }

    @Test("読めない表示の設定は捨て、ほかの項目は残す")
    func unknownTransitionKeepsOtherFields() throws {
        let json = Data(
            #"""
            {"zoom":1.5,"view":{"layout":"spread","direction":"leftToRight","scrollAxis":"vertical",
            "transition":"warp","showsCoverAlone":true}}
            """#.utf8)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: json)
        #expect(decoded == DocumentSettings(zoom: 1.5))
    }

    @Test("スマート削除の残す一覧がなければ空として読む")
    func missingKeptIDs() throws {
        let json = Data(#"{"zoom":1.5,"smartRemoval":{"isEnabled":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: json)
        #expect(decoded == DocumentSettings(zoom: 1.5, smartRemoval: DocumentSettings.SmartRemoval(isEnabled: true)))
    }

    @Test("型の違う項目だけを捨てる")
    func wrongTypeKeepsOtherFields() throws {
        let json = Data(#"{"zoom":"large","layoutID":"a4Duplex"}"#.utf8)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: json)
        #expect(decoded == DocumentSettings(layoutID: "a4Duplex"))
    }

    @Test("HTML の見え方はウェブか紙面で、読めない値は捨ててほかの項目を残す")
    func htmlPresentation() throws {
        let paper = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"htmlPresentation":"paper"}"#.utf8))
        #expect(paper == DocumentSettings(htmlPresentation: .paper))
        let unknown = try JSONDecoder().decode(
            DocumentSettings.self, from: Data(#"{"htmlPresentation":"hologram","layoutID":"a4Duplex"}"#.utf8))
        #expect(unknown == DocumentSettings(layoutID: "a4Duplex"))
    }

    @Test("「スライドとして扱わない」を読み書きし、読めない値は捨ててほかの項目を残す")
    func ignoresSlides() throws {
        let saved = try JSONEncoder().encode(DocumentSettings(ignoresSlides: true))
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: saved) == DocumentSettings(ignoresSlides: true))
        let broken = try JSONDecoder().decode(
            DocumentSettings.self, from: Data(#"{"ignoresSlides":"yes","layoutID":"a4Duplex"}"#.utf8))
        #expect(broken == DocumentSettings(layoutID: "a4Duplex"))
    }

    @Test("保存した画像の順番を内容のハッシュで戻す")
    func restoreImageOrder() {
        let items = [("fuji.png", "f"), ("sakura.png", "s"), ("neko.png", "n")]
        let ordered = ImageOrder.apply(["n", "f", "s"], to: items) { $0.1 }
        #expect(ordered?.map(\.0) == ["neko.png", "fuji.png", "sakura.png"])
    }

    @Test("同じ画像が2枚あっても、それぞれの位置に戻す")
    func restoreDuplicateImages() {
        let items = [("a.png", "x"), ("b.png", "y"), ("c.png", "x")]
        let ordered = ImageOrder.apply(["y", "x", "x"], to: items) { $0.1 }
        #expect(ordered?.map(\.0) == ["b.png", "a.png", "c.png"])
    }

    @Test("画像の組が違えば保存した順番を使わない", arguments: [["x", "y"], ["x", "x", "y"], ["x", "y", "w"]])
    func mismatchedImages(_ saved: [String]) {
        let items = [("a.png", "x"), ("b.png", "y"), ("c.png", "z")]
        #expect(ImageOrder.apply(saved, to: items) { $0.1 } == nil)
    }
}
