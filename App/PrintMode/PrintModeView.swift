import AppKit
import SurimonoCore
import SwiftUI

/// The print mode (刷り台): the sheets as they come out of the printer, with the layouts and output at hand.
struct PrintModeView: View {
    @Bindable var model: DocumentViewModel
    @State private var showsFold = false

    var body: some View {
        VStack(spacing: 0) {
            // The bars stay above the tray's scroll view, whose backdrop reaches under them.
            PrintTopBar(model: model, cancelsWithEscape: !showsFold).zIndex(1)
            HStack(spacing: 0) {
                if let bundle = model.imageBundle {
                    ImageBundleList(model: bundle)
                        .frame(width: 220)
                        .scrollContentBackground(.hidden)
                        .background(PrintPalette.chrome)
                    Rectangle().fill(PrintPalette.line).frame(width: 1)
                }
                stage
            }
            PrintPressBar(model: model).zIndex(1)
        }
        .foregroundStyle(PrintPalette.ink)
        .tint(PrintPalette.ai)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.layout.kind) { _, kind in
            if kind != .booklet { showsFold = false }
        }
        .onAppear {
            // The view mode shows the traffic lights only with its menu; the tray always shows them.
            if let window = model.window { ViewerWindow.setTrafficLightsVisible(true, in: window) }
        }
        .alert(
            "Output Failed",
            isPresented: Binding(
                get: { model.outputError != nil },
                set: { if !$0 { model.outputError = nil } })
        ) {
            Button("OK", role: .cancel) { model.outputError = nil }
        } message: {
            Text(verbatim: model.outputError ?? "")
        }
        #if DEBUG
            .onAppear { if DebugSnapshot.flag("SurimonoFold") { showsFold = true } }
        #endif
    }

    private var stage: some View {
        ZStack {
            PrintPalette.stage
            if let tray = model.printTray, let document = model.result?.sheetDocument {
                PrintTrayView(model: model, tray: tray, document: document, showsFold: $showsFold)
            } else if model.error == nil {
                VStack(spacing: 10) {
                    if model.isRendering { ProgressView().controlSize(.small) }
                    Text(model.isRendering ? "Preparing pages…" : "No preview is available.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PrintPalette.ink2)
                }
            }
            if showsFold, model.printTray?.isBooklet == true {
                PrintFoldView(model: model) { showsFold = false }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { errorBanner }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeOut(duration: 0.2), value: showsFold)
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = model.error {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(PrintPalette.ink2)
                Text(verbatim: error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("Reload") { model.reload() }
                    .buttonStyle(PrintBorderedButtonStyle()).fixedSize()
                if model.format.isWebRendered && model.format != .plainText {
                    Button("Open as Plain Text") { model.reopenAsText() }
                        .buttonStyle(PrintBorderedButtonStyle()).fixedSize()
                }
            }
            .font(.system(size: 12.5))
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(PrintPalette.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PrintPalette.line2))
            .padding(16)
        }
    }

    @ViewBuilder private var toast: some View {
        VStack(spacing: 8) {
            if !model.unreadableImageURLs.isEmpty {
                Text(
                    verbatim: String(
                        format: String(localized: "Could not open: %@"),
                        model.unreadableImageURLs.map(\.lastPathComponent).joined(separator: ", "))
                )
                .font(.system(size: 12))
                .foregroundStyle(PrintPalette.toastInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(PrintPalette.toast))
                .padding(.bottom, model.toast == nil ? 18 : 0)
            }
            ToastOverlay(model: model)
        }
    }
}

/// The minimal toolbar of the print mode: back to the view mode, what is being printed, and its style.
struct PrintTopBar: View {
    @Bindable var model: DocumentViewModel
    var cancelsWithEscape: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.exitPrintMode()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PrintPalette.ink2)
                    Text("Back to View")
                    PrintTag(
                        text: "esc", font: .system(size: 9.5), color: PrintPalette.ink3, border: PrintPalette.line2
                    )
                    .padding(.leading, 3)
                }
                .padding(.leading, 7)
                .padding(.trailing, 7)
            }
            .buttonStyle(PrintBorderedButtonStyle())
            .keyboardShortcut(cancelsWithEscape ? .cancelAction : nil)
            .help("Back to the view mode (Esc)")
            .fixedSize()
            HStack(spacing: 8) {
                PrintTag(
                    text: model.formatBadge, font: .system(size: 9, weight: .semibold, design: .monospaced),
                    color: PrintPalette.ink2, border: PrintPalette.line3
                )
                .frame(minWidth: 28)
                Text(verbatim: model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let count = model.result?.plan.logicalPageCount {
                    Text(verbatim: PrintModeText.pageCount(count, language: model.language))
                        .font(.system(size: 12))
                        .foregroundStyle(PrintPalette.ink2)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, 16)
            .layoutPriority(-1)
            Spacer(minLength: 12)
            PrintStyleMenu(model: model)
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(PrintPalette.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
    }

    /// The traffic lights stay where the window draws them; the bar starts after them.
    private var trafficLightInset: CGFloat {
        guard let button = model.window?.standardWindowButton(.zoomButton) else { return 86 }
        return max(button.convert(button.bounds, to: nil).maxX + 14, 76)
    }
}

/// Print themes for text formats, cleanup presets for HTML; PDFs and images print as they are.
struct PrintStyleMenu: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if model.format.usesPrintTheme {
            Menu {
                Picker("Print Theme", selection: $model.themeID) {
                    ForEach(model.library.themes) { theme in
                        Text(verbatim: theme.displayName(language: model.language)).tag(theme.id)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Open Styles Folder") { model.library.openFolder("Styles") }
            } label: {
                label(
                    "Style",
                    value: model.library.themes.first { $0.id == model.themeID }?.displayName(language: model.language)
                        ?? model.themeID)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Print Theme")
        } else if model.format.usesHTMLPreset {
            Menu {
                Picker("HTML Preset", selection: $model.presetID) {
                    ForEach(model.library.presets) { preset in
                        Text(verbatim: preset.displayName(language: model.language)).tag(preset.id)
                    }
                }
                .pickerStyle(.inline)
                SmartRemovalMenuItems(model: model)
                Divider()
                Button("Open Presets Folder") { model.library.openFolder("Presets") }
            } label: {
                label(
                    "Preset",
                    value: model.library.presets.first { $0.id == model.presetID }?.displayName(
                        language: model.language) ?? model.presetID)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("HTML Preset")
        } else {
            label(
                "Style",
                value: String(
                    localized: model.format == .pdf ? "PDF is shown as is" : "Images are shown as is"),
                isEnabled: false
            )
            .fixedSize()
            .help("Printed as they are, without a print style")
        }
    }

    private func label(_ title: LocalizedStringKey, value: String, isEnabled: Bool = true) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(PrintPalette.ink2)
            Text(verbatim: value).fontWeight(isEnabled ? .semibold : .regular).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PrintPalette.ink2)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(PrintPalette.ink)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(PrintPalette.raised))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PrintPalette.line2, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .opacity(isEnabled ? 1 : 0.6)
    }
}
