import PDFKit
import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    /// The pages the paper shows: a theme being tried, a trial just chosen, or the document's own pages.
    var paperDocument: PDFDocument? {
        if themeTrial.themeID != nil, let document = themeTrial.document { return document }
        if let chosenTrial, chosenTrial.themeID == themeID { return chosenTrial.document }
        return result?.viewDocument
    }

    var paperChangeMarks: [ChangeMark] {
        guard mode == .view else { return [] }
        if themeTrial.themeID != nil, themeTrial.document != nil { return themeTrial.changeMarks }
        if let chosenTrial, chosenTrial.themeID == themeID { return chosenTrial.changeMarks }
        return result?.changeMarks ?? []
    }

    /// The paper shows pages of a trial rather than the document's own.
    var paperShowsTrial: Bool {
        guard let shown = paperDocument, let own = result?.viewDocument else { return false }
        return shown !== own
    }

    /// The paper turned to `index`. A trial's pages do not move the reading position: a theme with fewer pages shows
    /// its last page, and the document opens at the page the reader was on again once the trial ends.
    func paperDidChangePage(_ index: Int) {
        guard !paperShowsTrial else { return }
        currentPageIndex = index
    }

    var canTryThemesOnHover: Bool { (lastLayoutDuration ?? .zero) < hoverTrialLimit }

    /// The name of the theme being tried, while the pointer rests on one.
    var trialThemeName: String? {
        themeTrial.themeID.map { id in
            library.themes.first { $0.id == id }?.displayName(language: language) ?? id
        }
    }

    func theme(_ id: String) -> PrintTheme? { library.themes.first { $0.id == id } }

    func isFavoriteTheme(_ id: String) -> Bool { preferences.favoriteThemeIDs.contains(id) }

    func toggleFavoriteTheme(_ id: String) { preferences.toggleFavoriteTheme(id) }

    /// Shows `id` on the paper until the pointer moves on; the current theme ends the trial.
    func tryTheme(_ id: String) {
        guard mode == .view, canTryThemesOnHover, id != themeID, let source = themedSource,
            var settings = renderSettings, let theme = theme(id)
        else {
            themeTrial.end()
            return
        }
        settings.theme = theme
        themeTrial.begin(source: source, settings: settings, isBusy: { [weak self] in self?.isRendering ?? false })
    }

    func endThemeTrial() { themeTrial.end() }

    /// Opens the palette from the band's style button or from "…" when the band has folded the style into it.
    func openThemePalette() {
        guard format.usesPrintTheme, mode == .view else { return }
        isThemePalettePresented = true
    }

    /// Called as the palette closes, however it was closed.
    func themePaletteDidClose() {
        isThemePalettePresented = false
        themeTrial.end()
    }

    /// Keeps the samples in step with the document and its layout while the palette or the stage shows them.
    func followThemeSamples() {
        themeSamples.refresh()
    }

    /// 「おまかせ」: any built-in theme but the current one.
    func chooseRandomTheme() {
        let others = library.themes.filter { $0.isBuiltIn && $0.id != themeID }
        guard let theme = others.randomElement() else { return }
        selectTheme(theme.id)
    }

    /// The themes in the palette's 「よく使う」: the recent, favorite and suggested sections of the style menu.
    var frequentThemeSections: [PrintThemeMenu.Section] {
        themeMenu.sections.filter { [.recent, .favorites, .featured].contains($0.kind) }
    }

    /// The groups the palette and the stage filter by: each category, then the user's own styles if any.
    var themeGroups: [PrintThemeMenu.Section] {
        themeMenu.sections.filter { section in
            switch section.kind {
            case .category, .user: true
            default: false
            }
        }
    }

    func searchThemes(_ query: String) -> [PrintTheme] {
        PrintThemeMenu.search(query, in: library.themes, categories: library.themeCategories, language: language)
    }
}

extension PrintThemeMenu.Section {
    /// Stable within one menu: each kind appears at most once.
    var id: String {
        switch kind {
        case .recent: "recent"
        case .favorites: "favorites"
        case .featured: "featured"
        case .category(let category): "category:\(category.id)"
        case .user: "user"
        }
    }
}
