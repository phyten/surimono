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
        .disabled(isFixed)
        .help(
            isFixed
                ? Text("This layout uses a fixed paper orientation.") : Text("Paper Orientation")
        )
        .accessibilityLabel(Text("Paper Orientation"))
        .accessibilityValue(Text(value))
    }

    var isFixed: Bool { model.layout.kind == .booklet || model.layout.kind == .handout3 }

    var value: LocalizedStringKey {
        if isFixed {
            return model.layout.sheetSize.width > model.layout.sheetSize.height ? "Landscape" : "Portrait"
        }
        return switch model.paperOrientation {
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        case .auto:
            if !model.isUpToDate {
                "Auto"
            } else {
                Self.automaticValue(for: model.printResult?.sheetOrientations ?? [])
            }
        }
    }
    static func automaticValue(for orientations: [PaperOrientation]) -> LocalizedStringKey {
        if Set(orientations).count > 1 { return "Auto (Mixed)" }
        guard let orientation = orientations.first else { return "Auto" }
        return orientation == .landscape ? "Auto (Landscape)" : "Auto (Portrait)"
    }

}
