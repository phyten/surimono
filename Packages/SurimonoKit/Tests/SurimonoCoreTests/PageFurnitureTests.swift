import Foundation
import SurimonoCore
import Testing

struct PageFurnitureTests {
    private let context = PageFurniture.Context(fileName: "手引き.md", title: "手引き", date: "2026年11月4日")

    private var november4: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12)) ?? Date()
    }

    private func dateText(_ format: String, language: String = "ja") -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        var furniture = PageFurniture()
        furniture.dateFormat = format
        return furniture.dateText(november4, language: language, calendar: calendar)
    }

    @Test("既定は何も入れず、番号は下の中央だけに入れる")
    func presets() {
        #expect(PageFurniture().isEmpty)
        #expect(PageFurniture().preset == PageFurniture.Preset.none)
        #expect(PageFurniture.pageNumber.bottomCenter == "{ページ}")
        #expect(PageFurniture.pageNumber.preset == .number)
        #expect(PageFurniture.name.preset == .name)
        #expect(PageFurniture.nameAndDate.topRight == "{日付}")
    }

    @Test("6 か所のどれかを書き換えると自由になり、書式やスイッチはプリセットの判定に関わらない")
    func customPreset() {
        var furniture = PageFurniture.name
        furniture.dateFormat = "YYYY/MM/DD"
        furniture.skipsFirstPage = true
        #expect(furniture.preset == .name)
        furniture.topRight = "社外秘"
        #expect(furniture.preset == .custom)
        furniture.apply(.number)
        #expect(furniture.preset == .number)
        #expect(furniture.dateFormat == "YYYY/MM/DD")
        #expect(furniture.skipsFirstPage)
    }

    @Test("変数をファイル名・題名・日付・ページ・総ページに置き換える")
    func variables() throws {
        var furniture = PageFurniture()
        furniture.topLeft = "{ファイル名}"
        furniture.topCenter = "{題名}"
        furniture.topRight = "{日付}"
        furniture.bottomCenter = "{ページ} / {総ページ}"
        let lines = try #require(furniture.lines(forPage: 2, pageCount: 9, context: context, hasFacingPages: false))
        #expect(lines.top == ["手引き.md", "手引き", "2026年11月4日"])
        #expect(lines.bottom == ["", "3 / 9", ""])
    }

    @Test("最初のページを飛ばす設定と、足した白紙には何も入れない")
    func skippedPages() {
        var furniture = PageFurniture.pageNumber
        furniture.skipsFirstPage = true
        var context = context
        context.blankPages = [3]
        #expect(furniture.lines(forPage: 0, pageCount: 5, context: context, hasFacingPages: false) == nil)
        #expect(furniture.lines(forPage: 3, pageCount: 5, context: context, hasFacingPages: false) == nil)
        #expect(furniture.lines(forPage: 1, pageCount: 5, context: context, hasFacingPages: false) != nil)
    }

    @Test("見開きで入れ替えるのは向かい合う紙の偶数ページだけ")
    func swapping() throws {
        var furniture = PageFurniture()
        furniture.topLeft = "左"
        furniture.topRight = "右"
        furniture.swapsOnSpreads = true
        func top(_ index: Int, facing: Bool) -> [String]? {
            furniture.lines(forPage: index, pageCount: 4, context: context, hasFacingPages: facing)?.top
        }
        #expect(top(0, facing: true) == ["左", "", "右"])
        #expect(top(1, facing: true) == ["右", "", "左"])
        #expect(top(1, facing: false) == ["左", "", "右"])
    }

    @Test(
        "日付は YYYY・MM・DD・M・D・曜 の書式で書ける",
        arguments: [
            ("YYYY年M月D日", "2026年11月4日"), ("YYYY/MM/DD", "2026/11/04"), ("YYYYMMDD", "20261104"),
            ("M/D（曜）", "11/4（水）"), ("MM-DD", "11-04"), ("締切 YYYY", "締切 2026"),
        ])
    func dateFormats(format: String, expected: String) {
        #expect(dateText(format) == expected)
    }

    @Test("曜は言語に従う")
    func weekdayLanguage() {
        #expect(dateText("曜", language: "en") == "Wed")
    }

    @Test("読めない項目があっても他の項目を残す")
    func tolerantDecoding() throws {
        let data = Data(#"{"topLeft":"上","dateFormat":3,"skipsFirstPage":true}"#.utf8)
        let furniture = try JSONDecoder().decode(PageFurniture.self, from: data)
        #expect(furniture.topLeft == "上")
        #expect(furniture.dateFormat == PageFurniture.defaultDateFormat)
        #expect(furniture.skipsFirstPage)
    }

    @Test(
        "日付の書式の英字は、ほかの英字と並ぶ語の中では日付にならない",
        arguments: [
            ("Date: YYYY-MM-DD", "Date: 2026-11-04"), ("Dec D", "Dec 4"), ("MMM", "MMM"), ("M月D日", "11月4日"),
            ("Printed YYYY/M/D", "Printed 2026/11/4"), ("YYYYMMDD", "20261104"), ("DDay", "DDay"),
        ])
    func dateLettersInWords(format: String, expected: String) {
        #expect(dateText(format) == expected)
    }

    @Test("Mac の暦が和暦でも、年は西暦で書く")
    func gregorianYear() {
        var furniture = PageFurniture()
        furniture.dateFormat = "YYYY/M/D"
        #expect(furniture.dateText(november4, language: "ja").hasPrefix("2026/11/"))
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        #expect(furniture.dateText(november4, language: "ja", calendar: japanese).hasPrefix("8/11/"))
    }

    @Test("範囲の中の位置で見開きの左右を決め、番号と総数は文書のままにする")
    func positionDecidesTheSide() throws {
        var furniture = PageFurniture()
        furniture.topLeft = "L"
        furniture.topRight = "R"
        furniture.bottomCenter = "{ページ} / {総ページ}"
        furniture.swapsOnSpreads = true
        let context = PageFurniture.Context()
        // Pages 2-5 of 12: page 2 is printed first, page 3 second.
        let first = try #require(
            furniture.lines(forPage: 1, pageCount: 12, context: context, hasFacingPages: true, position: 0))
        #expect(first.top == ["L", "", "R"])
        #expect(first.bottom == ["", "2 / 12", ""])
        let second = try #require(
            furniture.lines(forPage: 2, pageCount: 12, context: context, hasFacingPages: true, position: 1))
        #expect(second.top == ["R", "", "L"])
        #expect(second.bottom == ["", "3 / 12", ""])
    }

    @Test("右とじでは、範囲の先頭のページから左右を入れ替える")
    func positionOnRightBinding() throws {
        var furniture = PageFurniture()
        furniture.topLeft = "L"
        furniture.topRight = "R"
        furniture.swapsOnSpreads = true
        let context = PageFurniture.Context()
        let first = try #require(
            furniture.lines(
                forPage: 1, pageCount: 12, context: context, hasFacingPages: true, rightBound: true, position: 0))
        #expect(first.top == ["R", "", "L"])
        let second = try #require(
            furniture.lines(
                forPage: 2, pageCount: 12, context: context, hasFacingPages: true, rightBound: true, position: 1))
        #expect(second.top == ["L", "", "R"])
    }

    @Test("位置を渡さなければ、今までどおり文書の中の番号で左右を決める")
    func sideWithoutPosition() throws {
        var furniture = PageFurniture()
        furniture.topLeft = "L"
        furniture.topRight = "R"
        furniture.swapsOnSpreads = true
        let lines = try #require(
            furniture.lines(forPage: 1, pageCount: 12, context: PageFurniture.Context(), hasFacingPages: true))
        #expect(lines.top == ["R", "", "L"])
    }
}
