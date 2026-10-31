import SurimonoCore
import SwiftUI

struct DefaultStyleChoices: View {
    let library: UserLibrary
    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    var body: some View {
        ForEach(library.themeCategories) { category in
            Section {
                ForEach(library.themes.filter { $0.category == category.id }) { theme in
                    Text(verbatim: theme.displayName(language: language)).tag(theme.id)
                }
            } header: {
                Text(verbatim: category.displayName(language: language))
            }
        }
        // Themes without a known category: the user's styles, or every theme if the catalog failed.
        let others = library.themes.filter { theme in
            !library.themeCategories.contains { $0.id == theme.category }
        }
        if !others.isEmpty {
            Section("My Styles") {
                ForEach(others) { theme in
                    Text(verbatim: theme.displayName(language: language)).tag(theme.id)
                }
            }
        }
    }
}
