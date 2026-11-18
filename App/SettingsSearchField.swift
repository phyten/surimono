import SwiftUI

struct SettingsSearchField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(title))
                .labelsHidden().accessibilityLabel(Text(title))
                .multilineTextAlignment(.leading)
                .textFieldStyle(.plain)
                .focused($focused)
                .onKeyPress(.escape) {
                    guard focused, !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(CornerRole.largeControl.shape.fill(Color(nsColor: .textBackgroundColor)))
        .overlay(CornerRole.largeControl.shape.strokeBorder(.separator))
    }
}
