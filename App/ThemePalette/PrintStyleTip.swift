import SwiftUI

struct PrintStyleTip: ViewModifier {
    let model: DocumentViewModel
    @State private var isPresented = false

    init(model: DocumentViewModel) {
        self.model = model
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isPresented {
                    Button {
                        isPresented = false
                    } label: {
                        Text("Choose a style from samples")
                            .font(.system(size: 12))
                            .foregroundStyle(PrintPalette.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .paperOverlayBackground(cornerRadius: 8)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PrintPalette.line2))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .offset(y: 44)
                }
            }
            .task {
                guard model.preferences.takePrintStyleTip(usesPrintTheme: model.usesPrintTheme) else { return }
                isPresented = !model.isThemePalettePresented
                defer { isPresented = false }
                try? await Task.sleep(for: .seconds(5))
            }
            .onChange(of: model.isThemePalettePresented) { _, presented in
                if presented { isPresented = false }
            }
    }
}
