import SurimonoCore
import SwiftUI

// Both modes share the choices and sample cache; only the viewing mode may replace the paper on hover.
struct ThemePalette: View {
    @Bindable var model: DocumentViewModel
    @State private var query = ""
    /// The reader's choice to show or hide the code colors; until then a document with code shows them.
    @State private var showsCodeColumn: Bool?

    init(model: DocumentViewModel) {
        self.model = model
    }

    static let columns = 5
    /// Beside the code colors the samples give up two columns, so that the palette still fits next to the window: a
    /// palette too wide for that lands on the paper it tries things on.
    static let columnsBesideCode = 3
    /// The columns share the pane's width between them, so that the last sample ends where the search field does; a
    /// fixed width left the room of a fraction of a column beside the scroll bar.
    static let cellMinimumWidth: CGFloat = 96
    static let width: CGFloat = 628
    static let widthBesideCode: CGFloat = 400
    static let height: CGFloat = 660

    private var isPrinting: Bool { model.mode == .print }
    private var isCodeColumnShown: Bool { showsCodeColumn ?? (!isPrinting && model.themeSamples.containsCode) }
    private var hasSideColumn: Bool { isPrinting || isCodeColumnShown }

    var body: some View {
        HStack(spacing: 0) {
            styles
            if isPrinting {
                Rectangle().fill(PrintPalette.line).frame(width: DisplayAccessibility.hairline)
                PrintThemePreview(model: model)
            } else if isCodeColumnShown {
                Rectangle().fill(PrintPalette.line).frame(width: DisplayAccessibility.hairline)
                CodePaletteColumn(model: model)
            }
        }
        .frame(height: Self.height)
        // The controls stay readable over whatever shows through the popover behind them.
        .paperOverlayBackground(nil, tintOpacity: 0.94)
        .onAppear { model.followThemeSamples() }
        .onChange(of: model.renderSettings) { _, _ in model.followThemeSamples() }
        .onChange(of: model.preferences.themeSampleSource) { _, _ in model.followThemeSamples() }
        .onChange(of: model.preferences.triesThemeOnHover) { _, enabled in
            if !enabled { model.endThemeTrial() }
        }
        .onExitCommand { model.themePaletteDidClose() }
        .onDisappear { model.themePaletteDidClose() }
    }

    private var styles: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Rectangle().fill(PrintPalette.line).frame(height: DisplayAccessibility.hairline)
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Leaving the samples puts the paper back; moving between them keeps the last trial meanwhile.
            .onHover { inside in if !inside { model.endThemeTrial() } }
            Rectangle().fill(PrintPalette.line).frame(height: DisplayAccessibility.hairline)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: hasSideColumn ? Self.widthBesideCode : Self.width)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Style").font(.system(size: 14, weight: .semibold)).fixedSize()
                Text(verbatim: model.theme(model.themeID)?.displayName(language: model.language) ?? model.themeID)
                    .font(.system(size: 12))
                    .foregroundStyle(PrintPalette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                PopoverCloseButton()
            }
            // Named, because it chooses what the samples show, not what the style is applied to.
            HStack(spacing: 8) {
                Text("Sample From").font(.system(size: 11.5)).foregroundStyle(PrintPalette.ink2).fixedSize()
                CornerSegments(
                    title: "Sample From",
                    selection: Binding(
                        get: { model.preferences.themeSampleSource }, set: { model.preferences.themeSampleSource = $0 }),
                    values: [ThemeSampleSource.document, .specimen], preset: model.preferences.corners
                ) { source in
                    Text(source == .document ? LocalizedStringKey("This Document") : "Sample Document")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(PrintPalette.ink2)
                TextField("Search by name or category", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(PrintPalette.ink2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear Search"))
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(CornerRole.largeControl.shape.fill(Color(nsColor: .textBackgroundColor)))
            .overlay(CornerRole.largeControl.shape.strokeBorder(PrintPalette.line2))
        }
    }

    @ViewBuilder private var content: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = model.searchThemes(query)
            section(
                String(format: String(localized: "Matching “%@”"), query.trimmingCharacters(in: .whitespaces)),
                count: matches.count, themes: matches,
                empty: String(localized: "No matching styles"))
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.themeMenu.sections, id: \.id) { group in
                    section(groupTitle(group), themes: group.themes)
                }
            }
        }
    }

    private func section(_ title: String, count: Int? = nil, themes: [PrintTheme], empty: String? = nil)
        -> some View
    {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PrintPalette.ink2)
                if let count {
                    Text(verbatim: "\(count)").font(.system(size: 11)).foregroundStyle(PrintPalette.ink3)
                }
            }
            if themes.isEmpty, let empty {
                Text(verbatim: empty)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PrintPalette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: Self.cellMinimumWidth), spacing: 10, alignment: .top),
                        count: hasSideColumn ? Self.columnsBesideCode : Self.columns),
                    alignment: .leading, spacing: 12
                ) {
                    ForEach(themes) { theme in
                        // One identity per theme and source: the same identity on every cell left the grid with a
                        // single sample in each group.
                        ThemePaletteCell(model: model, theme: theme)
                            .id("\(theme.id) \(model.preferences.themeSampleSource.rawValue)")
                    }
                }
                // A cell keeps 4 pt around its sample for the highlight; the samples themselves stand on the same left
                // edge as the headings and the footer.
                .padding(.horizontal, -4)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        Group {
            if hasSideColumn {
                stackedFooter
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actions
                        Spacer(minLength: 8)
                        typeControls
                    }
                    stackedFooter
                }
            }
        }
        .controlSize(.small)
    }

    private var stackedFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            actions
            ViewThatFits(in: .horizontal) {
                typeControls
                VStack(alignment: .leading, spacing: 6) {
                    textSize
                    DocumentTypefacePicker(model: model)
                }
            }
        }
    }

    private var typeControls: some View {
        HStack(spacing: 8) {
            textSize
            DocumentTypefacePicker(model: model)
        }
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !isPrinting {
                Button {
                    model.enterCompareMode()
                } label: {
                    Label("Compare…", systemImage: "square.grid.2x2")
                }
                .cornerButton(model.preferences.corners)
            }
            if isPrinting {
                if model.preferences.corners.usesSystemControls {
                    Menu("Code Colors") { CodePaletteMenuContent(model: model) }
                } else {
                    Menu("Code Colors") { CodePaletteMenuContent(model: model) }
                        .menuStyle(.button)
                        .cornerButton(model.preferences.corners)
                }
                Button("Open Styles Folder") { model.library.openFolder("Styles") }
                    .cornerButton(model.preferences.corners)
            } else {
                Toggle(isOn: Binding(get: { isCodeColumnShown }, set: { showsCodeColumn = $0 })) {
                    Text("Code Appearance")
                }
                .toggleStyle(.button)
                .cornerButton(model.preferences.corners, isCodeColumnShown ? .selected : .normal)
            }
        }
    }

    private var textSize: some View {
        HStack(spacing: 8) {
            // The same name as in the view options, for the same setting.
            Text("Text Size").font(.system(size: 11.5)).foregroundStyle(PrintPalette.ink2).fixedSize()
            // Any percent typed or stepped by 1%; the buttons beside it move to the next step, from an in-between size too.
            TextSizeField(title: "Text Size", scale: model.textScale, corners: model.preferences.corners) {
                model.setTextScale($0)
            }
            let smaller = Image(systemName: "textformat.size.smaller")
            let larger = Image(systemName: "textformat.size.larger")
            ControlGroup {
                Button {
                    model.decreaseTextSize()
                } label: {
                    smaller
                }
                .accessibilityLabel(Text("Smaller"))
                .help("Smaller")
                Button {
                    model.increaseTextSize()
                } label: {
                    larger
                }
                .accessibilityLabel(Text("Larger"))
                .help("Larger")
            }
            .modifier(
                CornerBezel(preset: model.preferences.corners, role: .control) { _ in
                    HStack(spacing: 0) {
                        smaller.frame(maxWidth: .infinity)
                        Rectangle().fill(PrintPalette.line2).frame(width: 1).padding(.vertical, 3)
                        larger.frame(maxWidth: .infinity)
                    }
                    .background(
                        AppCornerShape(role: .control, preset: model.preferences.corners).fill(PrintPalette.press))
                }
            )
            .fixedSize()
        }
    }

    private func groupTitle(_ group: PrintThemeMenu.Section) -> String {
        switch group.kind {
        case .category(let category): category.displayName(language: model.language)
        case .recent: String(localized: "Recent")
        case .favorites: String(localized: "Favorites")
        case .featured: String(localized: "Suggested")
        case .user: String(localized: "My Styles")
        }
    }
}

/// One sample in the palette: the page, its name, a star, and a mark on the current theme.
struct ThemePaletteCell: View {
    let model: DocumentViewModel
    let theme: PrintTheme
    @State private var isHovering = false
    @FocusState private var isStarFocused: Bool

    init(model: DocumentViewModel, theme: PrintTheme) {
        self.model = model
        self.theme = theme
    }

    var body: some View {
        let isCurrent = theme.id == model.themeID
        let isFavorite = model.isFavoriteTheme(theme.id)
        let name = theme.displayName(language: model.language)
        Button {
            model.selectTheme(theme.id)
        } label: {
            VStack(spacing: 5) {
                ThemeSampleView(
                    page: model.paletteSamples.page(for: theme), paperSize: model.paletteSamples.paperSize,
                    margins: model.paletteSamples.margins(for: theme)
                )
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                .overlay {
                    CornerRole.tag.shape
                        .strokeBorder(
                            isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(PrintPalette.paperRing),
                            lineWidth: isCurrent ? 2 : DisplayAccessibility.hairline)
                }
                .overlay(alignment: .topTrailing) {
                    if isCurrent {
                        // Off the page's corner: at its top left it covered the heading the page starts with.
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, PrintPalette.aiControl)
                            .background(Circle().fill(.white).padding(-1.5))
                            .offset(x: 6, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                // The border and the check mark the current style; the name stays plain.
                Text(verbatim: name)
                    .emphasisForDisplayContrast(isHovering)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(4)
            .background(CornerRole.control.shape.fill(isHovering ? PrintPalette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // Always there, so the keyboard can reach it; it shows on hover, when focused, or on a favorite. It keeps
            // clear of the check that hangs off the corner.
            let showsStar = isHovering || isFavorite || isStarFocused
            FavoriteStarButton(isFavorite: isFavorite, name: name, onPage: true) {
                model.toggleFavoriteTheme(theme.id)
            }
            .buttonStyle(.plain)
            .focused($isStarFocused)
            .opacity(showsStar ? 1 : 0)
            .allowsHitTesting(showsStar)
            .padding(10)
        }
        .onHover { inside in
            isHovering = inside
            if inside { model.hoverPaletteTheme(theme.id) }
        }
        .task(id: model.paletteSamples.taskID(for: theme)) { await model.paletteSamples.load(theme) }
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityIdentifier("themePaletteCell.\(theme.id)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAction(
            named: isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites")
        ) { model.toggleFavoriteTheme(theme.id) }
    }
}

/// The star that adds a theme to the favorites or takes it out: a plain 22 pt glyph, whose button style the caller
/// chooses. On a sample page `onPage` gives it a pale disc, to be read against the page's own text.
struct FavoriteStarButton: View {
    let isFavorite: Bool
    let name: String
    /// The star's color while the theme is not a favorite.
    var idleColor: Color = PrintPalette.ink2
    var onPage = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.orange : idleColor)
                .frame(width: 22, height: 22)
                .background {
                    if onPage {
                        Circle().fill(.background).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(verbatim: label))
        .help(isFavorite ? LocalizedStringKey("Remove from Favorites") : LocalizedStringKey("Add to Favorites"))
    }

    private var label: String {
        if isFavorite {
            String(format: String(localized: "Remove %@ from Favorites"), name)
        } else {
            String(format: String(localized: "Add %@ to Favorites"), name)
        }
    }
}

/// A category to show in the palette.
struct ThemeGroupChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .emphasisForDisplayContrast(isSelected)
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .foregroundStyle(isSelected ? AnyShapeStyle(PrintPalette.raised) : AnyShapeStyle(.primary))
                .background(
                    AppCornerShape.capsule.fill(
                        isSelected ? AnyShapeStyle(PrintPalette.ai) : AnyShapeStyle(PrintPalette.hover))
                )
                .contentShape(AppCornerShape.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
