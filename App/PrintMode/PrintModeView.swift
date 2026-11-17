import AppKit
import SurimonoCore
import SwiftUI

/// The print mode (刷り台): the sheets as they come out of the printer, with the layouts and output at hand.
struct PrintModeView: View {
    @Bindable var model: DocumentViewModel
    @State private var trayMemory = TrayMemory()

    var body: some View {
        VStack(spacing: 0) {
            // The bars stay above the tray's scroll view, whose backdrop reaches under them.
            PrintTopBar(
                model: model,
                cancelsWithEscape: model.printEscapeTarget == .screen
            ).zIndex(1)
            HStack(spacing: 0) {
                if model.imageBundle != nil { ImageBundleDrawer(model: model) }
                if model.binder != nil { BinderDrawer(model: model) }
                stage
            }
            PrintFinishStrip(model: model).zIndex(1)
            PrintPressBar(model: model).zIndex(1)
        }
        .overlay { ThemePaletteAnchor(model: model) }
        .foregroundStyle(PrintPalette.ink)
        .tint(PrintPalette.ai)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.layout.kind) { _, kind in
            if kind != .booklet { model.showsFold = false }
        }
        .onChange(of: model.canShowFold) { _, _ in model.foldAvailabilityDidChange() }
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
            .onAppear { if DebugSnapshot.flag("SurimonoFold") { model.showsFold = true } }
        #endif
    }

    private var stage: some View {
        ZStack {
            PrintPalette.stage
            if model.showsTrayPreview, let tray = model.printTray, let document = model.printResult?.sheetDocument {
                PrintTrayView(
                    model: model, tray: tray, document: document, memory: trayMemory)
            } else if model.error == nil {
                VStack(spacing: 10) {
                    if model.isRendering { ProgressView().controlSize(.small) }
                    Text(model.isRendering ? "Preparing pages…" : "No preview is available.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PrintPalette.ink2)
                }
            }
            if model.showsFold, model.canShowFold {
                PrintFoldView(model: model) { model.showsFold = false }
                    .transition(.opacity)
            }
            if model.isPrintFinishPresented {
                // At the side rather than over the middle: the changes show on the sheets while it is open.
                PrintFinishSheet(model: model)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(14)
            }
        }
        .overlay(alignment: .top) { errorBanner }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeOut(duration: 0.2), value: model.showsFold)
        // The tray takes whatever height it is given, so the window's smallest height keeps room for its navigator.
        .frame(minHeight: Self.minimumStageHeight)
    }

    static let minimumStageHeight: CGFloat = 200

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
                NoticePlate(
                    text: String(
                        format: String(localized: "Could not open: %@"),
                        model.unreadableImageURLs.map(\.lastPathComponent).joined(separator: ", "))
                )
                .padding(.bottom, model.toast == nil ? 18 : 0)
            }
            ToastOverlay(model: model)
        }
    }
}

/// The minimal toolbar of the print mode: back to the view mode, what is being printed, and its style. A narrow
/// window takes its parts away in the order of `PrintTopBarFold`, so that the file name keeps its room.
struct PrintTopBar: View {
    @Bindable var model: DocumentViewModel
    /// The bar's height. The toolbar the stage keeps makes the title bar as tall, with the buttons in its middle.
    static let height: CGFloat = 52
    /// The room the file name keeps at every width, or less for a shorter name.
    static let nameMinimum: CGFloat = 120
    @State private var lights: TrafficLights?
    var cancelsWithEscape: Bool
    /// The widths of the bar's parts in each of their forms, measured from copies drawn out of sight.
    @State private var widths: [Part: CGFloat] = [:]
    @State private var barWidth: CGFloat = 0

    enum Part: Hashable {
        case back(BackForm)
        case badge, name, pageCount, styleName
        case style(showsTitle: Bool)
        case sets(SetsForm)
        case modified
    }

    enum BackForm: Hashable { case full, withoutTag, arrow }
    enum SetsForm: Hashable { case full, withoutName, icon }

    var body: some View {
        let fold = PrintTopBarFold(
            available: barWidth, needed: neededWidths, styleNameWidth: widths[.styleName] ?? 0)
        HStack(spacing: 0) {
            backButton(backForm(fold))
                .keyboardShortcut(cancelsWithEscape ? .cancelAction : nil)
            HStack(spacing: 8) {
                badge
                name
                if !fold.folds(.pageCount), let count = pageCountText { pageCount(count) }
            }
            .padding(.leading, 16)
            .layoutPriority(-1)
            Spacer(minLength: 12)
            PrintStyleMenu(model: model, showsTitle: !fold.folds(.styleTitle), nameLimit: fold.styleNameLimit)
            setsMenu(setsForm(fold)).padding(.leading, 8)
            if model.isSettingSetChanged { modifiedMenu.padding(.leading, 8) }
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 12)
        .offset(y: TrafficLights.lineOffset(lights, barHeight: Self.height))
        .frame(height: Self.height)
        // The bar takes any width it is given, so that it never holds the window wider than the rest of the screen;
        // the fold keeps its parts inside.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            if barWidth != width { barWidth = width }
        }
        .background(PrintPalette.chrome)
        .background(alignment: .topLeading) { measurements }
        .overlay(alignment: .bottom) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
        .background { TrafficLightsReader { lights = $0 } }
    }

    private func backForm(_ fold: PrintTopBarFold) -> BackForm {
        fold.folds(.backTitle) ? .arrow : fold.folds(.escTag) ? .withoutTag : .full
    }

    private func setsForm(_ fold: PrintTopBarFold) -> SetsForm {
        fold.folds(.setsTitle) ? .icon : fold.folds(.setName) ? .withoutName : .full
    }

    /// The bar's width with none, then one, two and more of the fold's steps taken.
    private var neededWidths: [CGFloat] {
        // Each term is typed and named on its own: Xcode 26.6 cannot type-check the sums as one expression in time.
        let modifiedWidth: CGFloat = widths[.modified] ?? 0
        let modified: CGFloat = model.isSettingSetChanged ? 8 + modifiedWidth : 0
        let badgeWidth: CGFloat = widths[.badge] ?? 0
        let nameWidth: CGFloat = min(widths[.name] ?? 0, Self.nameMinimum)
        // Before the badge, the name, the style menu and the sets menu, and at the trailing edge.
        let gaps: CGFloat = 16 + 8 + 12 + 8 + 12
        let fixed: CGFloat = trafficLightInset + badgeWidth + nameWidth + gaps + modified
        let pageCountWidth: CGFloat = widths[.pageCount] ?? 0
        let pageCount: CGFloat = pageCountText == nil ? 0 : 8 + pageCountWidth
        func width(_ back: BackForm, _ pages: CGFloat, _ showsTitle: Bool, _ sets: SetsForm) -> CGFloat {
            let backWidth: CGFloat = widths[.back(back)] ?? 0
            let styleWidth: CGFloat = widths[.style(showsTitle: showsTitle)] ?? 0
            let setsWidth: CGFloat = widths[.sets(sets)] ?? 0
            return fixed + backWidth + pages + styleWidth + setsWidth
        }
        return [
            width(.full, pageCount, true, .full),
            width(.withoutTag, pageCount, true, .full),
            width(.withoutTag, pageCount, true, .withoutName),
            width(.withoutTag, 0, true, .withoutName),
            width(.withoutTag, 0, false, .withoutName),
            width(.arrow, 0, false, .withoutName),
            width(.arrow, 0, false, .icon),
        ]
    }

    private var measurements: some View {
        ZStack(alignment: .leading) {
            measured(.back(.full)) { backButton(.full) }
            measured(.back(.withoutTag)) { backButton(.withoutTag) }
            measured(.back(.arrow)) { backButton(.arrow) }
            measured(.badge) { badge }
            measured(.name) { nameText.fixedSize() }
            if let count = pageCountText { measured(.pageCount) { pageCount(count) } }
            measured(.style(showsTitle: true)) { PrintStyleMenu(model: model, showsTitle: true, showsTip: false) }
            measured(.style(showsTitle: false)) { PrintStyleMenu(model: model, showsTitle: false, showsTip: false) }
            measured(.styleName) {
                Text(verbatim: PrintStyleMenu.value(for: model)).font(.system(size: 12.5, weight: .semibold))
            }
            measured(.sets(.full)) { setsMenu(.full) }
            measured(.sets(.withoutName)) { setsMenu(.withoutName) }
            measured(.sets(.icon)) { setsMenu(.icon) }
            measured(.modified) { modifiedMenu }
        }
        .fixedSize()
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func measured(_ part: Part, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                if widths[part] != width { widths[part] = width }
            }
    }

    private func backButton(_ form: BackForm) -> some View {
        Button {
            model.exitPrintMode()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink2)
                if form != .arrow { Text("Back to View") }
                if form == .full {
                    PrintTag(
                        text: "esc", font: .system(size: 9.5), color: PrintPalette.ink3, border: PrintPalette.line2
                    )
                    .padding(.leading, 3)
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 7)
        }
        .buttonStyle(PrintBorderedButtonStyle())
        .help("Back to the view mode (Esc)")
        .accessibilityLabel(Text("Back to View"))
        .fixedSize()
    }

    private var badge: some View {
        PrintTag(
            text: model.formatBadge, font: .system(size: 9, weight: .semibold, design: .monospaced),
            color: PrintPalette.ink2, border: PrintPalette.line3
        )
        .frame(minWidth: 28)
    }

    private var nameText: some View {
        Text(verbatim: model.displayName)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// The name keeps `nameMinimum` (or its whole width, if shorter) however narrow the window: the fold makes room.
    private var name: some View {
        nameText
            .frame(minWidth: min(widths[.name] ?? 0, Self.nameMinimum), alignment: .leading)
            .help(Text(verbatim: model.displayName))
    }

    private var pageCountText: String? {
        model.trayPageCount.map {
            PrintModeText.pageCount($0.pages, notes: $0.notes, language: model.language)
        }
    }

    private func pageCount(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(PrintPalette.ink2)
            .lineLimit(1)
            .fixedSize()
    }

    /// Drawn like the style menu beside it, so the tray's top bar keeps one kind of control.
    private func setsMenu(_ form: SetsForm) -> some View {
        SettingSetMenu(preferences: model.preferences, library: model.library, model: { model }) {
            HStack(spacing: 7) {
                if form == .icon {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(PrintPalette.ink2)
                } else {
                    Text("Setting Sets").foregroundStyle(
                        model.activeSettingSet == nil ? PrintPalette.ink : PrintPalette.ink2)
                }
                if form == .full, let set = model.activeSettingSet {
                    Text(verbatim: set.name).fontWeight(.semibold).lineLimit(1)
                }
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
        }
        .help(
            Text(
                verbatim: [
                    String(localized: "Setting Sets"),
                    model.activeSettingSet.map { SettingSetSummary(library: model.library).oneLine($0) },
                ].compactMap { $0 }.joined(separator: "\n"))
        )
        .accessibilityLabel(Text("Setting Sets"))
        .accessibilityValue(Text(verbatim: model.activeSettingSet?.name ?? ""))
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A changed set can be saved over the reader's own set, or as a new one from any set: both in one menu, so that
    /// the bar gains one control rather than three.
    private var modifiedMenu: some View {
        Menu {
            if model.activeSettingSet?.isBuiltIn == false {
                Button("Overwrite") { model.overwriteActiveSettingSet() }
            }
            Button("Save New…") { SettingSetDialogs.save(model) }
        } label: {
            HStack(spacing: 5) {
                Text("Modified")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PrintPalette.ai)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(PrintPalette.aiTint))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The traffic lights stay where the window draws them; the bar starts after them. Read live: entering the stage
    /// adds the toolbar that moves them, after this bar is first drawn.
    private var trafficLightInset: CGFloat {
        guard let lights = lights ?? model.window.flatMap({ TrafficLights(window: $0) }) else { return 86 }
        return max(lights.titleLeading, 76)
    }
}

/// Print themes for text formats, cleanup presets for HTML; PDFs and images print as they are.
struct PrintStyleMenu: View {
    @Bindable var model: DocumentViewModel
    /// Whether the menu says "Style" or "Preset" before its value; a narrow top bar shows the value alone.
    var showsTitle = true
    /// Whether the first-time tip may show; copies drawn only to be measured must not take it.
    var showsTip = true
    /// The widest the style's name is drawn, where the top bar has folded all it can and still lacks room; the name
    /// loses its middle, and its hint and VoiceOver give it whole.
    var nameLimit: CGFloat?

    /// The name the menu shows: the print style, the HTML preset, or that the document prints as it is.
    static func value(for model: DocumentViewModel) -> String {
        if model.usesPrintTheme { return model.styleName }
        if model.usesHTMLPreset {
            return model.library.presets.first { $0.id == model.presetID }?.displayName(language: model.language)
                ?? model.presetID
        }
        return String(localized: model.format == .pdf ? "PDF is shown as is" : "Images are shown as is")
    }

    var body: some View {
        if model.usesPrintTheme {
            Button {
                model.openThemePalette()
            } label: {
                label(
                    "Style",
                    value: model.styleName)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("printStylePaletteButton")
            .help(fullName)
            .accessibilityLabel(Text("Style"))
            .accessibilityValue(Text(verbatim: model.styleName))
            .modifier(OptionalStyleTip(model: model, isEnabled: showsTip))
        }
        if model.usesHTMLPreset {
            Menu {
                Picker("HTML Preset", selection: $model.presetID) {
                    ForEach(model.library.presets) { preset in
                        Text(verbatim: preset.displayName(language: model.language)).tag(preset.id)
                    }
                }
                .pickerStyle(.inline)
                if model.binder == nil { SmartRemovalMenuItems(model: model) }
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
            .help(fullName)
            .accessibilityLabel(Text("Preset"))
            .accessibilityValue(Text(verbatim: Self.value(for: model)))
        } else if !model.usesPrintTheme {
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
            if showsTitle { Text(title).foregroundStyle(PrintPalette.ink2) }
            Text(verbatim: value).fontWeight(isEnabled ? .semibold : .regular).lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: nameLimit, alignment: .leading)
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

    /// The hint, with the whole name before it while the name is cut.
    /// The whole name, only where the bar may have cut it short.
    private var fullName: Text { Text(verbatim: nameLimit == nil ? "" : Self.value(for: model)) }
}

/// The style tip on the menu the bar shows, and none on the copies it measures.
private struct OptionalStyleTip: ViewModifier {
    let model: DocumentViewModel
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled { content.modifier(PrintStyleTip(model: model)) } else { content }
    }
}
