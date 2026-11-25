import PDFKit
import SurimonoCore
import SurimonoRendering

extension DocumentViewModel {
    typealias ChosenTrial = (
        themeID: String, codePaletteID: String, settings: RenderSettings?, document: PDFDocument,
        changeMarks: [ChangeMark],
        furniture: [Int: FurniturePlacement], diagrams: [RenderedDiagram], formulaIndex: PaperFormulaIndex?
    )

    /// The pages the paper shows: a theme being tried, a trial just chosen, or the document's own pages.
    var paperDocument: PDFDocument? {
        if let readingPreview { return readingPreview.document }
        if themeTrial.themeID != nil, let document = themeTrial.document { return document }
        if let chosenTrial, isCurrentLook(chosenTrial) { return chosenTrial.document }
        return result?.viewDocument
    }

    /// A vertical trial can turn a single horizontal page into several reading pages.
    /// Navigation on that temporary PDF must not change the saved position or print range.
    var verticalTrialPaper: PDFDocument? {
        guard mode == .view else { return nil }
        if let document = themeTrial.document {
            return themeTrial.requestedSettings?.theme.flow == .vertical ? document : nil
        }
        if let chosenTrial, isCurrentLook(chosenTrial), chosenTrial.settings?.theme.flow == .vertical {
            return chosenTrial.document
        }
        return nil
    }

    var paperPageCount: Int { readingPreview?.document.pageCount ?? verticalTrialPaper?.pageCount ?? pageCount }
    var paperPageIndex: Int {
        if readingPreview != nil { return shownPageIndex }
        guard let trial = verticalTrialPaper else { return currentPageIndex }
        return min(shownPageIndex, max(0, trial.pageCount - 1))
    }

    func jumpToPaperPage(_ page: Int) {
        if let readingPreview {
            guard (0..<readingPreview.document.pageCount).contains(page) else { return }
            paper.goToPage(index: page, in: readingPreview.document)
        } else if let trial = verticalTrialPaper {
            guard (0..<trial.pageCount).contains(page) else { return }
            paper.goToPage(index: page, in: trial)
        } else {
            jumpToReadingPage(page)
        }
    }

    var paperFormulaIndex: PaperFormulaIndex? {
        if readingPreview != nil { return nil }
        if themeTrial.themeID != nil, themeTrial.document != nil { return themeTrial.formulaIndex }
        if let chosenTrial, isCurrentLook(chosenTrial) { return chosenTrial.formulaIndex }
        return result?.formulaIndex
    }

    var paperDiagrams: [RenderedDiagram] {
        if readingPreview != nil { return [] }
        if themeTrial.themeID != nil, themeTrial.document != nil { return themeTrial.diagrams }
        if let chosenTrial, isCurrentLook(chosenTrial) { return chosenTrial.diagrams }
        return result?.diagrams ?? []
    }

    var paperChangeMarks: [ChangeMark] {
        guard mode == .view, readingPreview == nil else { return [] }
        let marks: [ChangeMark]
        if themeTrial.themeID != nil, themeTrial.document != nil {
            marks = themeTrial.changeMarks
        } else if let chosenTrial, isCurrentLook(chosenTrial) {
            marks = chosenTrial.changeMarks
        } else {
            marks = result?.changeMarks ?? []
        }
        return marks.map { mark in
            var updated = mark
            updated.backgroundHex = preferences.changeBackgroundHex
            updated.textHex = preferences.changeTextHex
            updated.emphasizesEdge = DisplayAccessibility.shared.options.increasedContrast
            return updated
        }
    }

    /// The header and footer the sheets draw on the pages the paper shows, so that what is read is what prints.
    var paperFurniture: [Int: FurniturePlacement] {
        if let readingPreview { return readingPreview.furniture }
        if themeTrial.themeID != nil, themeTrial.document != nil { return themeTrial.furniture }
        if let chosenTrial, isCurrentLook(chosenTrial) { return chosenTrial.furniture }
        return shownFurniture
    }

    private func isCurrentLook(_ trial: ChosenTrial) -> Bool {
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
        guard readingPreview == nil, !paperShowsTrial else { return }
        let previousPage = currentPageIndex
        currentPageIndex = index
        let units = displayUnits
        let pages =
            SpreadLayout.unitIndex(containing: index + 1, in: units).map { units[$0].pages.map { $0 - 1 } } ?? [index]
        binder?.follow(page: index, visiblePages: pages)
        if let bundle = imageBundle {
            let urls = readingImageURLs
            let selected = bundle.selection.flatMap { urls.firstIndex(of: $0) }
            // PDFKit reports the spread's first page even when the restored image is its second.
            guard !pages.contains(previousPage) || selected == nil else { return }
            if let next = BinderPagination.selection(
                current: selected, visiblePages: pages,
                starts: Array(urls.indices), pageCount: urls.count), urls.indices.contains(next)
            {
                bundle.selection = urls[next]
            }
        }
    }

    var canTryThemesOnHover: Bool {
        preferences.triesThemeOnHover && (lastLayoutDuration ?? .zero) < hoverTrialLimit
    }

    /// The name of the theme or code palette being tried, while the pointer rests on one.
    var trialThemeName: String? {
        themeTrial.themeID.map { id in
            if id.hasPrefix(Self.codeTrialPrefix) {
                return codePaletteName(String(id.dropFirst(Self.codeTrialPrefix.count)))
            }
            return theme(id)?.displayName(language: language) ?? id
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
        guard !isWindowClosed else { return }
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

    func theme(_ id: String) -> PrintTheme? { library.theme(id, for: themeFormat, classStyle: classStyle) }

    func isFavoriteTheme(_ id: String) -> Bool { preferences.favoriteThemeIDs.contains(id) }

    func toggleFavoriteTheme(_ id: String) {
        guard !isWindowClosed else { return }
        preferences.toggleFavoriteTheme(id)
    }

    /// Shows `id` on the paper until the pointer moves on; the current theme ends the trial.
    func tryTheme(_ id: String) {
        guard !isWindowClosed else { return }
        guard mode == .view, canTryThemesOnHover, id != themeID, let source = themedSource,
            var settings = renderSettings, let theme = theme(id)
        else {
            themeTrial.end()
            return
        }
        settings.theme = theme
        themeTrial.begin(source: source, settings: settings, isBusy: { [weak self] in self?.isRendering ?? false })
    }

    func endThemeTrial() {
        guard !isWindowClosed else { return }
        themeTrial.end()
    }

    /// Opens the palette from the band's style button or from "…" when the band has folded the style into it.
    func openThemePalette() {
        guard usesPrintTheme, mode == .view || mode == .print else { return }
        // Before it opens, so that it opens at its size with or without the code colors.
        specimenSamples.diskCache?.prune()
        followThemeSamples()
        // Both hang off the same edge of the view mode's window; the tray keeps its settings beside the sheets.
        if mode == .view { isPrintFinishPresented = false }
        isThemePalettePresented = true
    }

    /// Called as the palette closes, however it was closed.
    func themePaletteDidClose() {
        guard !isWindowClosed else { return }
        isThemePalettePresented = false
        palettePreviewThemeID = nil
        themeTrial.end()
    }

    /// Keeps the samples in step with the document and its layout while the palette or the stage shows them.
    func followThemeSamples() {
        guard !isWindowClosed else { return }
        themeSamples.refresh()
        if preferences.themeSampleSource == .specimen { specimenSamples.refresh() }
    }

    var paletteSamples: ThemeSamples {
        preferences.themeSampleSource == .specimen ? specimenSamples : themeSamples
    }

    func hoverPaletteTheme(_ id: String) {
        guard !isWindowClosed else { return }
        if mode == .print {
            palettePreviewThemeID = id
        } else {
            tryTheme(id)
        }
    }

    /// Reads the document's places for the stage. A place chosen before the document changed follows its words, or
    /// gives way to the first page when they are gone.
    func followComparePlaces() async {
        guard await themeSamples.loadPlaces() else { return }
        comparePlace = comparePlace?.found(in: themeSamples.places)
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
        PrintThemeMenu.search(
            query, in: library.themes, categories: library.themeCategories, language: language, format: themeFormat,
            classStyle: classStyle)
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
