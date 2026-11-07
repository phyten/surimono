import PDFKit
import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    /// The pages the paper shows: a theme being tried, a trial just chosen, or the document's own pages.
    var paperDocument: PDFDocument? {
        if themeTrial.themeID != nil, let document = themeTrial.document { return document }
        if let chosenTrial, isCurrentLook(chosenTrial) { return chosenTrial.document }
        return result?.viewDocument
    }

    var paperChangeMarks: [ChangeMark] {
        guard mode == .view else { return [] }
        if themeTrial.themeID != nil, themeTrial.document != nil { return themeTrial.changeMarks }
        if let chosenTrial, isCurrentLook(chosenTrial) { return chosenTrial.changeMarks }
        return result?.changeMarks ?? []
    }

    private func isCurrentLook(
        _ trial: (themeID: String, codePaletteID: String, document: PDFDocument, changeMarks: [ChangeMark])
    ) -> Bool {
        trial.themeID == themeID && trial.codePaletteID == codePaletteID
    }

    /// The paper shows pages of a trial rather than the document's own.
    var paperShowsTrial: Bool {
        guard let shown = paperDocument, let own = result?.viewDocument else { return false }
        return shown !== own
    }

    /// The paper turned to `index`. A trial's pages do not move the reading position: a theme with fewer pages shows
    /// its last page, and the document opens at the page the reader was on again once the trial ends.
    func paperDidChangePage(_ index: Int) {
        shownPageIndex = index
        guard !paperShowsTrial else { return }
        currentPageIndex = index
        let units = displayUnits
        let pages =
            SpreadLayout.unitIndex(containing: index + 1, in: units).map { units[$0].pages.map { $0 - 1 } } ?? [index]
        binder?.follow(page: index, visiblePages: pages)
        if let bundle = imageBundle {
            let urls = bundle.urls.filter { !unreadableImageURLs.contains($0) }
            let selected = bundle.selection.flatMap { urls.firstIndex(of: $0) }
            if let next = BinderPagination.selection(
                current: selected, visiblePages: pages,
                starts: Array(urls.indices), pageCount: urls.count), urls.indices.contains(next)
            {
                bundle.selection = urls[next]
            }
        }
    }

    var canTryThemesOnHover: Bool { (lastLayoutDuration ?? .zero) < hoverTrialLimit }

    /// The name of the theme or code palette being tried, while the pointer rests on one.
    var trialThemeName: String? {
        themeTrial.themeID.map { id in
            if id.hasPrefix(Self.codeTrialPrefix) {
                return codePaletteName(String(id.dropFirst(Self.codeTrialPrefix.count)))
            }
            return library.themes.first { $0.id == id }?.displayName(language: language) ?? id
        }
    }

    private static let codeTrialPrefix = "code:"

    /// What a trial of a code palette goes by, apart from the theme ids.
    static func codeTrialID(_ id: String) -> String { codeTrialPrefix + id }

    func codePaletteName(_ id: String) -> String {
        library.codePalette(id)?.displayName(language: language) ?? String(localized: "Match Style")
    }

    /// Shows the code in `id` on the paper until the pointer moves on; the current palette ends the trial.
    func tryCodePalette(_ id: String) {
        guard mode == .view, canTryThemesOnHover, id != codePaletteID, let source = themedSource,
            var settings = renderSettings
        else {
            themeTrial.end()
            return
        }
        settings.code.palette = library.codePalette(id)
        themeTrial.begin(
            id: Self.codeTrialID(id), source: source, settings: settings,
            isBusy: { [weak self] in self?.isRendering ?? false })
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
        guard usesPrintTheme, mode == .view else { return }
        // Before it opens, so that it opens at its size with or without the code colors.
        followThemeSamples()
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
