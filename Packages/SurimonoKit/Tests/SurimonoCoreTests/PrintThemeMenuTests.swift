import SurimonoCore
import Testing

struct PrintThemeMenuTests {
    private let categories = [
        PrintThemeCategory(id: "everyday", name: "Everyday"), PrintThemeCategory(id: "pop", name: "Pop"),
        PrintThemeCategory(id: "empty", name: "Empty"),
    ]

    private let themes = [
        PrintTheme(id: "standard", name: "Standard", css: "", isBuiltIn: true, category: "everyday", featuredRank: 0),
        PrintTheme(id: "compact", name: "Compact", css: "", isBuiltIn: true, category: "everyday"),
        PrintTheme(id: "confetti", name: "Confetti", css: "", isBuiltIn: true, category: "pop", featuredRank: 1),
        PrintTheme(id: "neon", name: "Neon", css: "", isBuiltIn: true, category: "pop"),
        PrintTheme(id: "user:Mine.css", name: "Mine", css: ""),
    ]

    private func ids(_ menu: PrintThemeMenu, _ kind: PrintThemeMenu.Kind) -> [String]? {
        menu.sections.first { $0.kind == kind }.map { $0.themes.map(\.id) }
    }

    @Test("最近使った・お気に入り・定番・カテゴリー・自分のスタイルの順に並べ、空の区切りは出さない")
    func sectionOrder() {
        let menu = PrintThemeMenu(
            themes: themes, categories: categories, recentIDs: ["neon"], favoriteIDs: ["compact"])
        #expect(
            menu.sections.map(\.kind) == [
                .recent, .favorites, .featured, .category(categories[0]), .category(categories[1]), .user,
            ])
    }

    @Test("最近使ったものは新しい順に最大5つで、消えたテーマと重複は除く")
    func recentThemes() {
        let menu = PrintThemeMenu(
            themes: themes, categories: categories,
            recentIDs: ["neon", "gone", "neon", "standard", "compact", "confetti", "user:Mine.css"], favoriteIDs: [])
        #expect(ids(menu, .recent) == ["neon", "standard", "compact", "confetti", "user:Mine.css"])
    }

    @Test("お気に入りは足した順に並ぶ")
    func favoriteThemes() {
        let menu = PrintThemeMenu(
            themes: themes, categories: categories, recentIDs: [], favoriteIDs: ["neon", "standard", "gone"])
        #expect(ids(menu, .favorites) == ["neon", "standard"])
    }

    @Test("定番は目録の順に並び、カテゴリーにも重ねて入る")
    func featuredThemesAlsoStayInTheirCategory() {
        let menu = PrintThemeMenu(themes: themes, categories: categories, recentIDs: [], favoriteIDs: [])
        #expect(ids(menu, .featured) == ["standard", "confetti"])
        #expect(ids(menu, .category(categories[1])) == ["confetti", "neon"])
        #expect(ids(menu, .user) == ["user:Mine.css"])
        #expect(ids(menu, .recent) == nil)
    }

    @Test("選んだテーマは最近使ったものの先頭へ移り、6つ目からは古いものが落ちる")
    func recording() {
        #expect(PrintThemeMenu.recording("b", in: ["a", "b", "c"]) == ["b", "a", "c"])
        #expect(PrintThemeMenu.recording("f", in: ["a", "b", "c", "d", "e"]) == ["f", "a", "b", "c", "d"])
    }

    @Test("お気に入りは切り替えるたびに足したり外したりする")
    func toggling() {
        #expect(PrintThemeMenu.toggling("a", in: ["b"]) == ["b", "a"])
        #expect(PrintThemeMenu.toggling("b", in: ["a", "b"]) == ["a"])
    }
}
