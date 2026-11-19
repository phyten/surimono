import SurimonoCore
import SwiftUI

struct TypefaceChoices: View {
    var body: some View {
        Text("As the Style").tag(Typeface.style)
        Text("LaTeX Typeface").tag(Typeface.latex)
    }
}

struct DocumentTypefacePicker: View {
    let model: DocumentViewModel

    var body: some View {
        if model.offersTypeface {
            Picker("Typeface", selection: Binding(get: { model.typeface }, set: model.setTypeface)) {
                TypefaceChoices()
            }
            .pickerStyle(.menu)
        }
    }
}
