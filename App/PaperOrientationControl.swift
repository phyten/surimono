import SurimonoCore
import SwiftUI

struct PaperOrientationControl: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Menu {
            Picker("Paper Orientation", selection: $model.paperOrientation) {
                Text("Auto").tag(PaperOrientation.auto)
                Text("Portrait").tag(PaperOrientation.portrait)
                Text("Landscape").tag(PaperOrientation.landscape)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.portrait.rotate")
                Text(value)
            }
        }
        .disabled(model.layout.kind == .booklet)
        .help(
            model.layout.kind == .booklet
                ? Text("Booklets use a fixed paper orientation.") : Text("Paper Orientation")
        )
        .accessibilityLabel(Text("Paper Orientation"))
        .accessibilityValue(Text(value))
    }

    private var value: LocalizedStringKey {
        switch model.paperOrientation {
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        case .auto:
            if model.layout.kind == .booklet || !model.isUpToDate {
                "Auto"
            } else {
                model.result?.resolvedOrientation == .landscape ? "Auto (Landscape)" : "Auto (Portrait)"
            }
        }
    }
}
