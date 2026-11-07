import SurimonoCore
import SwiftUI

/// The style palette (案 A): every print theme as a sample of this document's first page. Resting the pointer on a
/// sample tries it on the paper; a click chooses it and leaves the palette open for the next look.
struct ThemePalette: View {
    @Bindable var model: DocumentViewModel
    @State private var query = ""
    /// The reader's choice to show or hide the code colors; until then a document with code shows them.
    @State private var showsCodeColumn: Bool?

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

    private var isCodeColumnShown: Bool { showsCodeColumn ?? model.themeSamples.containsCode }

    var body: some View {
        HStack(spacing: 0) {
            styles
            if isCodeColumnShown {
                Divider()
                CodePaletteColumn(model: model)
            }
        }
        .frame(height: Self.height)
        // The controls stay readable over whatever shows through the popover behind them.
        .background(PrintPalette.raised.opacity(0.94))
        .onAppear { model.followThemeSamples() }
        .onChange(of: model.renderSettings) { _, _ in model.followThemeSamples() }
        .onDisappear { model.themePaletteDidClose() }
    }

    private var styles: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Leaving the samples puts the paper back; moving between them keeps the last trial meanwhile.
            .onHover { inside in if !inside { model.endThemeTrial() } }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: isCodeColumnShown ? Self.widthBesideCode : Self.width)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Style").font(.system(size: 14, weight: .semibold)).fixedSize()
                Text(verbatim: model.theme(model.themeID)?.displayName(language: model.language) ?? model.themeID)
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or category", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear Search"))
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        }
    }

    @ViewBuilder private var content: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = model.searchThemes(query)
            section(
                String(format: String(localized: "Matching “%@”"), query.trimmingCharacters(in: .whitespaces)),
                count: matches.count, themes: matches,
                empty: String(localized: "No styles match. Try a category instead."))
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
                Text(verbatim: title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                if let count {
                    Text(verbatim: "\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if themes.isEmpty, let empty {
                Text(verbatim: empty)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.quaternary))
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: Self.cellMinimumWidth), spacing: 10, alignment: .top),
                        count: isCodeColumnShown ? Self.columnsBesideCode : Self.columns),
                    alignment: .leading, spacing: 12
                ) {
                    ForEach(themes) { theme in
                        ThemePaletteCell(model: model, theme: theme)
                    }
                }
                // A cell keeps 4 pt around its sample for the highlight; the samples themselves stand on the same left
                // edge as the headings and the footer.
                .padding(.horizontal, -4)
            }
        }
    }

    /// Beside the code column the two groups take a row each: the row is too narrow to name the text size otherwise.
    @ViewBuilder private var footer: some View {
        if isCodeColumnShown {
            VStack(alignment: .leading, spacing: 8) {
                actions
                textSize
            }
            .controlSize(.small)
        } else {
            HStack(spacing: 8) {
                actions
                Spacer(minLength: 8)
                textSize
            }
            .controlSize(.small)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.enterCompareMode()
            } label: {
                Label("Compare…", systemImage: "square.grid.2x2")
            }
            .help("Lay a few styles side by side")
            Toggle(isOn: Binding(get: { isCodeColumnShown }, set: { showsCodeColumn = $0 })) {
                Text("Code Appearance")
            }
            .toggleStyle(.button)
            .help("Code Appearance")
        }
    }

    private var textSize: some View {
        HStack(spacing: 8) {
            Text("Body Text Size").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize()
            ControlGroup {
                Button {
                    model.decreaseTextSize()
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel(Text("Smaller"))
                Button {
                    model.resetTextSize()
                } label: {
                    Text(verbatim: model.textScalePercentage).monospacedDigit().frame(minWidth: 38)
                }
                .help("Original Size")
                Button {
                    model.increaseTextSize()
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel(Text("Larger"))
            }
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

    var body: some View {
        let isCurrent = theme.id == model.themeID
        let isFavorite = model.isFavoriteTheme(theme.id)
        let name = theme.displayName(language: model.language)
        Button {
            model.selectTheme(theme.id)
        } label: {
            VStack(spacing: 5) {
                ThemeSampleView(
                    page: model.themeSamples.page(for: theme), paperSize: model.themeSamples.paperSize,
                    margins: model.themeSamples.margins
                )
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.12)),
                            lineWidth: isCurrent ? 2 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isCurrent {
                        // Off the page's corner: at its top left it covered the heading the page starts with.
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .background(Circle().fill(.white).padding(-1.5))
                            .offset(x: 6, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                Text(verbatim: name)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovering ? Color.primary.opacity(0.06) : .clear))
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
            if inside { model.tryTheme(theme.id) }
        }
        .task(id: model.themeSamples.taskID(for: theme)) { await model.themeSamples.load(theme) }
        .help(name)
        .accessibilityLabel(Text(verbatim: name))
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
    var idleColor: Color = .secondary
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
    /// The text on the tint when selected; a light tint, such as the stage's indigo at night, needs dark text.
    var selectedText: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .foregroundStyle(isSelected ? AnyShapeStyle(selectedText) : AnyShapeStyle(.primary))
                .background(
                    Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.06)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
