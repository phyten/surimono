import Foundation
import SurimonoCore
import Testing

struct NotePaperStyleTests {
    @Test("17プリセットはモックの順序と識別子を保ちCodableで往復できる")
    func presets() throws {
        #expect(
            NotePaperPreset.all.map(\.id) == [
                "daigaku", "hougan", "dot", "cornell", "genko", "gijiroku",
                "gakufu", "hyou", "gingham", "mizutama", "stripe", "ichigo", "hoshizora", "kumo", "ribbon", "nikukyu",
                "hana",
            ])
        #expect(
            NotePaperPreset.all.map(\.japaneseName) == [
                "大学ノート", "5mm 方眼", "ドット", "コーネル", "原稿用紙",
                "議事録", "五線譜", "日付の表", "ギンガム", "水玉", "ストライプ", "いちご", "星空", "雲", "リボン", "肉球", "花の縁",
            ])
        #expect(Set(NotePaperPreset.all.map(\.englishName)).count == 17)
        for preset in NotePaperPreset.all {
            let data = try JSONEncoder().encode(preset.style)
            #expect(try JSONDecoder().decode(NotePaperStyle.self, from: data) == preset.style)
        }
    }

    @Test("未知の線と柄や壊れた単一項目があっても残りの設定を復元する")
    func futureValues() throws {
        let data = Data(
            ##"{"kind":"future","decoration":"future","weightInMillimeters":"bad","spacingInMillimeters":9,"marginInMillimeters":18,"colorHex":"#123456","header":{"date":true,"title":"bad","pageNumber":false,"future":1},"future":{}}"##
                .utf8)
        let style = try JSONDecoder().decode(NotePaperStyle.self, from: data)
        #expect(style.kind == .ruled)
        #expect(style.decoration == .none)
        #expect(style.weightInMillimeters == 0.2)
        #expect(style.spacingInMillimeters == 9)
        #expect(style.marginInMillimeters == 18)
        #expect(style.colorHex == "#123456")
        #expect(style.header == .init(date: true, title: false, pageNumber: false))
    }

    @Test("古い空の設定は既定値で復元する")
    func missingFields() throws {
        #expect(try JSONDecoder().decode(NotePaperStyle.self, from: Data("{}".utf8)) == NotePaperStyle())
    }

    @Test("線と柄の全種類を列挙できる")
    func catalog() {
        #expect(NotePaperStyle.Kind.allCases.count == 11)
        #expect(NotePaperStyle.Decoration.allCases.count == 11)
        #expect(NotePaperPreset.all.filter { $0.group == .practical }.count == 8)
        #expect(NotePaperPreset.all.filter { $0.group == .cute }.count == 9)
    }
}
