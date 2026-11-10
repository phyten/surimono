import SwiftUI

struct PrintThemePreview: View {
    let model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let theme = model.theme(model.palettePreviewThemeID ?? model.themeID) {
                Text(verbatim: theme.displayName(language: model.language))
                    .font(.system(size: 14, weight: .semibold))
                ScrollView([.horizontal, .vertical]) {
                    ThemeSampleView(
                        page: model.paletteSamples.page(for: theme), paperSize: model.paletteSamples.paperSize,
                        margins: model.paletteSamples.margins
                    )
                    .frame(width: 420)
                    .padding(4)
                }
                .task(id: model.paletteSamples.taskID(for: theme)) { await model.paletteSamples.load(theme) }
                .id(model.preferences.themeSampleSource)
            }
        }
        .padding(14)
        .frame(width: 456)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("printThemePreview")
    }
}
