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
            // A closure, not the method reference: Swift 6.3 crashes generating the isolation thunk for the latter.
            let selection = Binding(get: { model.typeface }, set: { model.setTypeface($0) })
            Picker("Typeface", selection: selection) {
                TypefaceChoices()
            }
            .pickerStyle(.menu)
        }
    }
}
