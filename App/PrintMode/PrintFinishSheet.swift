import SurimonoCore
import SwiftUI

/// The sections of the print settings, which the tray's items open directly.
enum PrintFinishSection: Hashable {
    case furniture, breaks, contents, notes, printer
}

/// All the print settings, one panel for both modes. It stays beside the pages, which show each change as it is made:
/// on the tray it lies beside the sheets, and in the view mode it hangs off the window's edge in a popover. The view
/// mode's paper shows the header and footer too; only the note pages, which the tray alone adds, show on the tray only.
struct PrintFinishSheet: View {
    @Bindable var model: DocumentViewModel
    /// In a popover, which draws the panel's background and edge itself.
    let isInPopover: Bool
    @State private var slot = PageFurniture.Slot.bottomCenter
    @State private var customLine = ""
    @FocusState private var isEditingCustomLine: Bool

    init(model: DocumentViewModel, isInPopover: Bool = false) {
        self.model = model
        self.isInPopover = isInPopover
    }

    static let width: CGFloat = 460
    /// The popover's height, short enough for a small screen; the settings scroll inside it.
    static let popoverHeight: CGFloat = 560

    var body: some View {
        if isInPopover {
            panel
                .frame(width: Self.width, height: Self.popoverHeight)
                .presentationBackground(PrintPalette.raised)
        } else {
            panel
                .frame(maxWidth: Self.width)
                .background(CornerRole.sheet.shape.fill(PrintPalette.raised))
                .clipShape(CornerRole.sheet.shape)
                .overlay(CornerRole.sheet.shape.strokeBorder(PrintPalette.line, lineWidth: 1))
                .shadow(color: PrintPalette.popShadow, radius: 20, y: 6)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            heading
            Rectangle().fill(PrintPalette.line).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView {
                    content
                }
                .onAppear { scrollToSection(scroller) }
                .onChange(of: model.finishSection) { _, _ in scrollToSection(scroller) }
            }
            // The popover closes from the × in its heading; a second way to close it would only repeat it.
            if !isInPopover {
                Rectangle().fill(PrintPalette.line).frame(height: 1)
                footer
            }
        }
        .foregroundStyle(PrintPalette.ink)
        // The view mode's standard controls draw white text on their fill, which needs the darker night indigo.
        .tint(PrintPalette.aiControl)
        .environment(\.printAccent, PrintPalette.ai)
        .environment(\.printAccentInk, PrintPalette.raised)
        .clearsInitialFocus()
        .onAppear { customLine = model.printFinish.breaks.customLine }
    }

    private func scrollToSection(_ scroller: ScrollViewProxy) {
        guard let section = model.finishSection else { return }
        model.finishSection = nil
        scroller.scrollTo(section, anchor: .top)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.layout.kind == .booklet {
                section("Booklet Binding", isFirst: true) {
                    Picker(
                        "Booklet Binding",
                        selection: model.controlBinding(get: \.effectiveBookletBinding, set: { $0.bookletBinding = $1 })
                    ) {
                        Text("Left Binding").tag(BookletBinding.left)
                        Text("Right Binding").tag(BookletBinding.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if model.marginsAffectPrinting {
                section("Paper & Margins", isFirst: true) { PrintMarginEditor(model: model, unit: .current) }
            }
            section("Header & Footer", isFirst: !model.marginsAffectPrinting) {
                PrintFurnitureChoice(model: model)
                furnitureDetails
            }
            .id(PrintFinishSection.furniture)
            if model.finishAppliesToText {
                section("Page Breaks") {
                    PrintChapterBreakChoice(model: model)
                    hint(breakHint)
                    breakDetails
                }
                .id(PrintFinishSection.breaks)
                section("Contents Page") {
                    PrintContentsChoice(model: model)
                    hint(contentsHint)
                    contentsDetails
                }
                .id(PrintFinishSection.contents)
                if model.format == .markdown, model.binder == nil {
                    section("Proof Marks") {
                        Picker("Proof Marks", selection: model.controlBinding(\.printFinish.proof)) {
                            Text("Show Marks").tag(ProofMarks.shown)
                            Text("Print as Accepted").tag(ProofMarks.accepted)
                            Text("Print as Original").tag(ProofMarks.original)
                        }
                        .labelsHidden()
                    }
                }
                section("Footnotes") {
                    Picker("Footnotes", selection: model.controlBinding(\.printFinish.footnotes)) {
                        Text("At the End").tag(FootnotePlacement.end)
                        Text("At the Bottom of the Page (Beta)").tag(FootnotePlacement.pageBottom)
                    }
                    .labelsHidden()
                }
                section("Links on Paper") {
                    Picker("Links on Paper", selection: model.controlBinding(\.printFinish.links)) {
                        Text("As They Are").tag(PaperLinks.asIs)
                        Text("List at the End").tag(PaperLinks.endnotes)
                        Text("After the Text").tag(PaperLinks.inline)
                    }
                    .labelsHidden()
                }
            }
            if model.offersNotes {
                section("Note Pages") { PrintNoteSection(model: model) }.id(PrintFinishSection.notes)
            }
            section("Printer Adjustments") { PrintPrinterOptions(model: model) }.id(PrintFinishSection.printer)
            newDocumentsDefault
        }
        #if DEBUG
            .reportPrintFinishFrame(.content)
        #endif
        // A wide control in one section must not shift the leading edge of every other section.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Print Settings").font(.system(size: 14, weight: .bold))
            }
            Spacer(minLength: 0)
            // Centred on the title's line rather than on the two lines.
            if isInPopover { PopoverCloseButton().padding(.top, -3) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                model.isPrintFinishPresented = false
            } label: {
                Text("Close").padding(.horizontal, 12)
            }
            .buttonStyle(PrintBorderedButtonStyle())
            .fixedSize()
            .keyboardShortcut(model.printEscapeTarget == .settings ? .cancelAction : nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// What reaches every new document is a wider matter than this sheet's own settings, so it is a quiet text at the
    /// end of them, not a button in reach of 「閉じる」.
    private var newDocumentsDefault: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(PrintPalette.line).frame(height: 1).padding(.bottom, 11)
            Button {
                model.preferences.setFinishDefaults(options: model.printOptions, finish: model.printFinish)
            } label: {
                Text("Use These Print Settings for New Documents")
            }
            .buttonStyle(PrintLinkButtonStyle())
            Text("Note pages are not included.")
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey, isFirst: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                Rectangle().fill(PrintPalette.line).frame(height: 1)
                    #if DEBUG
                        .reportPrintFinishFrame(.divider(title))
                    #endif
                    .padding(.bottom, 11)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
                #if DEBUG
                    .reportPrintFinishFrame(.heading(title))
                #endif
                .padding(.bottom, 7)
            content()
        }
        .padding(.bottom, 11)
    }

    /// A consequence the choice above does not show; nil when its name says it all.
    @ViewBuilder private func hint(_ text: LocalizedStringKey?) -> some View {
        if let text {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(PrintPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func subheading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(PrintPalette.ink2)
            .padding(.top, 10)
            .padding(.bottom, 5)
    }

    private func switchRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, count: String? = nil) -> some View {
        PrintSwitchRow(isOn: isOn) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13))
                if let count {
                    Text(verbatim: count).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                }
            }
        }
    }

    private func codeRow(_ code: String, isOn: Binding<Bool>, count: Int) -> some View {
        PrintSwitchRow(isOn: isOn) {
            HStack(spacing: 8) {
                Text(verbatim: code).font(.system(size: 12, design: .monospaced))
                Text(verbatim: PrintModeText.format("%lld places", language: model.language, count))
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.ink2)
            }
        }
    }

    /// A name on the left edge and its choice beside it, at the same place in every row. Pushed to the far end of
    /// the row, the choices swung the eye from side to side.
    private func choiceRow<Name: View, Choice: View>(
        @ViewBuilder name: () -> Name, @ViewBuilder choice: () -> Choice
    ) -> some View {
        HStack(spacing: 10) {
            name().frame(width: Self.nameColumnWidth, alignment: .leading)
            // The choices need the entire remaining column to decide whether one row fits.
            choice()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
    }

    /// The width of the names in front of the choices, as in the printer adjustments.
    private static let nameColumnWidth: CGFloat = 145

    // MARK: Header and footer

    /// The fields are for writing one's own; the presets fill them, so with a preset there is nothing to type.
    private var furnitureDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            let choice = model.furnitureChoice
            if choice == .custom && !model.usesDocumentFurniture {
                slotFields([.topLeft, .topCenter, .topRight]).padding(.top, 10)
                Text("Text")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(.sRGB, red: 0.33, green: 0.34, blue: 0.35, opacity: 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(CornerRole.thumbnail.shape.fill(PrintPalette.paper))
                    .overlay(CornerRole.thumbnail.shape.strokeBorder(PrintPalette.line2, lineWidth: 1))
                    .padding(.vertical, 5)
                slotFields([.bottomLeft, .bottomCenter, .bottomRight])
                subheading("Items to Insert")
                HStack(spacing: 4) {
                    chip("File Name", .fileName)
                    chip("Title", .title)
                    chip("Chapter", .chapter)
                }
                HStack(spacing: 4) {
                    chip("Date", .date)
                    chip("Page", .page)
                    chip("Total Pages", .pageCount)
                }
            }
            if !model.usesDocumentFurniture && (choice == .custom || choice == .nameAndDate) {
                subheading("Date Format")
                HStack(spacing: 8) {
                    Picker("Date Format", selection: dateChoice) {
                        ForEach(Self.dateFormats, id: \.self) { format in
                            Text(verbatim: sample(format)).tag(format)
                        }
                        Text("Write Your Own").tag("")
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    PrintTextField(
                        title: "Date Format", text: model.controlBinding(\.printOptions.furniture.dateFormat))
                }
            }
            if choice != .none && !model.usesDocumentFurniture {
                switchRow(
                    "Leave Out of the First Page", isOn: model.controlBinding(\.printOptions.furniture.skipsFirstPage)
                )
                .padding(.top, 8)
                switchRow(
                    "Swap Left and Right on Spreads",
                    isOn: model.controlBinding(\.printOptions.furniture.swapsOnSpreads)
                )
                .disabled(!model.layout.hasFacingPages)
            }
        }
    }

    private func slotFields(_ slots: [PageFurniture.Slot]) -> some View {
        HStack(spacing: 5) {
            ForEach(slots, id: \.self) { slot in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.slotTitle(slot)).font(.system(size: 10.5)).foregroundStyle(PrintPalette.ink2)
                    PrintTextField(
                        title: Self.slotTitle(slot), text: $model.printOptions.furniture[slot],
                        isHighlighted: slot == self.slot
                    ) { self.slot = slot }
                }
            }
        }
    }

    private static func slotTitle(_ slot: PageFurniture.Slot) -> LocalizedStringKey {
        switch slot {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }

    private func chip(_ title: LocalizedStringKey, _ variable: PageFurniture.Variable) -> some View {
        Button {
            model.printOptions.furniture[slot] += variable.rawValue
        } label: {
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                .overlay(AppCornerShape.capsule.strokeBorder(PrintPalette.line2, lineWidth: 1))
                .contentShape(AppCornerShape.capsule)
        }
        .buttonStyle(.plain)
    }

    private static let dateFormats = ["YYYY年M月D日", "YYYY/MM/DD", "YYYYMMDD", "M/D（曜）"]

    private func sample(_ format: String) -> String {
        var furniture = PageFurniture()
        furniture.dateFormat = format
        return furniture.dateText(Date(), language: model.language)
    }

    private var dateChoice: Binding<String> {
        model.controlBinding(
            get: { model in
                let format = model.printOptions.furniture.dateFormat
                return Self.dateFormats.contains(format) ? format : ""
            },
            set: { if !$1.isEmpty { $0.printOptions.furniture.dateFormat = $1 } })
    }

    // MARK: Page breaks

    private var breakHint: LocalizedStringKey? {
        switch model.printFinish.breaks.h1 {
        case .none, .page: nil
        case .rightPage:
            model.layout.hasFacingPages
                ? "Adds blank pages so that chapters start on a right-hand page."
                : "Single-sided sheets only break the page before chapters."
        }
    }

    private var facts: DocumentFacts? { model.result?.facts }

    private var breakDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            subheading("By Heading")
            levelRow(level: 1, rule: model.controlBinding(\.printFinish.breaks.h1))
            levelRow(level: 2, rule: model.controlBinding(\.printFinish.breaks.h2))
            levelRow(level: 3, rule: model.controlBinding(\.printFinish.breaks.h3))
            if model.format == .markdown {
                subheading("Syntax in the Text")
                codeRow("<!--BREAK-->", isOn: syntax(.comment), count: facts?.pageBreakCounts[.comment] ?? 0)
                codeRow("<!-- pagebreak -->", isOn: syntax(.pagebreak), count: facts?.pageBreakCounts[.pagebreak] ?? 0)
                codeRow("\\newpage", isOn: syntax(.newpage), count: facts?.pageBreakCounts[.newpage] ?? 0)
                codeRow("{::pagebreak /}", isOn: syntax(.kramdown), count: facts?.pageBreakCounts[.kramdown] ?? 0)
                switchRow(
                    "Break at ---", isOn: model.controlBinding(\.printFinish.breaks.breaksAtThematicBreaks),
                    count: PrintModeText.format(
                        "%lld places", language: model.language, facts?.thematicBreakCount ?? 0))
                subheading("Your Own Syntax")
                TextField("Your Own Syntax", text: $customLine, prompt: Text("==page break=="))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isEditingCustomLine)
                    .onSubmit { model.printFinish.breaks.customLine = customLine }
                    // Each change lays the text out again, so it applies once the line is written.
                    .onChange(of: isEditingCustomLine) { _, editing in
                        if !editing { model.printFinish.breaks.customLine = customLine }
                    }
            }
            subheading("Paper Rules")
            switchRow(
                "Keep Headings with Their Text", isOn: model.controlBinding(\.printFinish.breaks.keepsHeadingsWithText))
            switchRow("Do Not Split Tables", isOn: model.controlBinding(\.printFinish.breaks.keepsTablesWhole))
        }
    }

    func levelRow(level: Int, rule: Binding<HeadingBreak>) -> some View {
        let count = facts?.headings.filter { $0.level == level }.count ?? 0
        return choiceRow {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: PrintModeText.format("Heading %lld", language: model.language, level))
                    .font(.system(size: 13))
                Text(verbatim: PrintModeText.format("%lld places", language: model.language, count))
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.ink2)
            }
        } choice: {
            PrintSegments(
                label: "Page Breaks",
                options: [
                    .init(HeadingBreak.none, "None"), .init(.page, "Page Break"), .init(.rightPage, "From Right Page"),
                ],
                selection: rule.wrappedValue
            ) { rule.wrappedValue = $0 }
        }
    }

    private func syntax(_ syntax: PageBreakSyntax) -> Binding<Bool> {
        model.controlBinding(
            get: { !$0.printFinish.breaks.ignoredSyntaxes.contains(syntax) },
            set: { model, isOn in
                if isOn {
                    model.printFinish.breaks.ignoredSyntaxes.remove(syntax)
                } else {
                    model.printFinish.breaks.ignoredSyntaxes.insert(syntax)
                }
            })
    }

    // MARK: Contents

    private var contentsHint: LocalizedStringKey? {
        let hasSource = facts?.hasSourceContents == true
        switch model.printFinish.toc.mode {
        case .hidden: return hasSource ? "The text's [TOC] does not print." : nil
        case .source:
            return hasSource ? nil : "This document has no [TOC]. Choose “Add Contents to Front” to add one."
        case .front: return nil
        }
    }

    @ViewBuilder private var contentsDetails: some View {
        choiceRow {
            Text("Depth").font(.system(size: 13))
        } choice: {
            PrintSegments(
                label: "Depth", options: [.init(PaperTOC.Depth.chapters, "Chapters"), .init(.sections, "Sections")],
                selection: model.printFinish.toc.depth
            ) { model.printFinish.toc.depth = $0 }
        }
        .padding(.top, 8)
        choiceRow {
            Text("Look").font(.system(size: 13))
        } choice: {
            PrintSegments(
                label: "Look",
                options: [
                    .init(PaperTOC.Look.dotted, "Dotted"), .init(.plain, "No Lines"), .init(.ruled, "Chapter Lines"),
                ],
                selection: model.printFinish.toc.look
            ) { model.printFinish.toc.look = $0 }
        }
        if model.printFinish.toc.mode == .front, facts?.hasSourceContents == true {
            switchRow("Keep the Text's [TOC] as Well", isOn: model.controlBinding(\.printFinish.toc.keepsSourceTOC))
        }
    }
}

#if DEBUG
    // SwiftUI headings and decorative rules need not have AppKit views. Report their unclipped layout bounds.
    struct PrintFinishFrame: Equatable {
        enum Element: Equatable {
            case content
            case heading(LocalizedStringKey)
            case divider(LocalizedStringKey)
            case segment(LocalizedStringKey)
        }

        let element: Element
        let rect: CGRect
    }

    struct PrintFinishFrames: PreferenceKey {
        static var defaultValue: [PrintFinishFrame] { [] }
        static func reduce(value: inout [PrintFinishFrame], nextValue: () -> [PrintFinishFrame]) {
            value += nextValue()
        }
    }

    extension View {
        func reportPrintFinishFrame(_ element: PrintFinishFrame.Element) -> some View {
            background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PrintFinishFrames.self,
                        value: [
                            PrintFinishFrame(element: element, rect: geometry.frame(in: .named("printFinishPanel")))
                        ])
                }
            }
        }
    }
#endif

/// A switch with its name beside it, on the left edge of its section like the other controls. At the far end of the
/// row, the switch sent the eye to the right for the control and back to the left for its name.
struct PrintSwitchRow<Name: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Name
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isOn) { label }.toggleStyle(.switch).controlSize(.small).labelsHidden()
            // The switch carries the name for accessibility; the visible name only lends it a larger place to click.
            label
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { isOn.toggle() } }
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isEnabled ? PrintPalette.ink : PrintPalette.disabledInk)
        .frame(minHeight: 28)
    }
}

/// A small text field in the tray's colors.
struct PrintTextField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var isHighlighted: Bool
    var onFocus: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.printAccent) private var accent

    init(
        title: LocalizedStringKey, text: Binding<String>, isHighlighted: Bool = false,
        onFocus: @escaping () -> Void = {}
    ) {
        self.title = title
        _text = text
        self.isHighlighted = isHighlighted
        self.onFocus = onFocus
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(verbatim: ""))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .padding(.horizontal, 6)
            .frame(height: 27)
            .background(CornerRole.smallControl.shape.fill(PrintPalette.chrome))
            .overlay(
                CornerRole.smallControl.shape.strokeBorder(
                    isHighlighted ? accent : PrintPalette.line2, lineWidth: 1)
            )
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
    }
}

/// The four margins around a sheet of paper, with the text area drawn to scale.
struct PrintMarginEditor: View {
    @Bindable var model: DocumentViewModel
    let unit: MarginUnit

    var body: some View {
        VStack(spacing: 0) {
            Text(unit.fieldTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrintPalette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 5)
            if model.themeFormat == .latex {
                toggle(
                    "As the Document",
                    isOn: model.controlBinding(
                        get: { $0.usesDocumentMargins },
                        set: { $0.printOptions.latexMargins = $1 ? .document : nil }))
            }
            if !model.usesDocumentMargins {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        field("Top", \.top)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    GridRow {
                        field(mirrors ? "Inside" : "Left", \.left)
                        paper
                        field(mirrors ? "Outside" : "Right", \.right)
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        field("Bottom", \.bottom)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                toggle(
                    "Keep All Four Sides Even",
                    isOn: model.controlBinding(get: \.printOptions.linksMargins, set: { $0.setMarginsLinked($1) }))
                if model.layout.hasFacingPages, model.binder == nil {
                    toggle(
                        "Treat Left and Right as Inside and Outside",
                        isOn: model.controlBinding(\.printOptions.mirrorsMargins))
                }
            }
            Text("PDFs keep their own margins.")
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private var mirrors: Bool { model.layout.mirrorsMargins(options: model.printOptions) }

    private func toggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        PrintSwitchRow(isOn: isOn) { Text(title).font(.system(size: 13)) }
    }

    private func field(
        _ title: LocalizedStringKey, _ side: WritableKeyPath<PageMargins, Double>
    ) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
            TextField(
                title,
                value: model.controlBinding(
                    get: { [unit] in unit.value(fromMillimeters: $0.printOptions.margins[keyPath: side]) },
                    set: { [unit] model, value in
                        let current = model.printOptions.margins[keyPath: side]
                        if let millimeters = unit.millimeters(from: value, replacing: current) {
                            model.setMargin(side, to: millimeters)
                        }
                    }),
                format: .number.precision(.fractionLength(0...unit.fractionDigits))
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.center)
            .frame(width: 54)
            .accessibilityLabel(Text(title))
        }
    }

    private var paper: some View {
        let scale = 80 / max(model.layout.logicalPageSize(options: model.printOptions).width * 25.4 / 72, 1)
        let margins = model.printOptions.margins
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(PrintPalette.paper)
            Rectangle()
                .strokeBorder(PrintPalette.foldLine, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .background(
                    DisplayAccessibility.shared.options.fill(PrintPalette.paperAi, opacity: 0.066, over: .white)
                )
                .padding(.top, margins.top * scale)
                .padding(.leading, margins.left * scale)
                .padding(.bottom, margins.bottom * scale)
                .padding(.trailing, margins.right * scale)
        }
        .frame(width: 80, height: 112)
        .overlay(Rectangle().strokeBorder(PrintPalette.line3, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// How the chosen printer handles the sheets.
struct PrintPrinterOptions: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Output Order", hint: printerOrderHint) {
                outputOrderPicker
            }
            row(
                "Rotate Back Sides 180°",
                hint: rotationHint
            ) {
                Toggle("Rotate Back Sides 180°", isOn: model.controlBinding(\.rotatesBackSides))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!isDuplex || model.selectedPrinterName == nil || !model.canOutput)
            }
        }
    }

    var outputOrderPicker: some View {
        let picker = PrintPageOrderPicker(order: model.controlBinding(\.printPageOrder))
        return ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).fixedSize()
            picker.pickerStyle(.menu)
        }
        .labelsHidden()
        .controlSize(.small)
        .disabled(model.selectedPrinterName == nil)
    }

    private var printerOrderHint: LocalizedStringKey {
        guard let name = model.selectedPrinterName else { return "Choose a printer to remember its settings." }
        return "Remembered for \(name). Last Sheet First keeps face-up sheets in page order."
    }

    /// Without a printer the order's hint above already says to choose one.
    private var rotationHint: LocalizedStringKey? {
        guard isDuplex else { return "Available for duplex layouts (A4 Duplex and booklets)." }
        guard let name = model.selectedPrinterName else { return nil }
        return model.printerLayout.sentDuplex == .longEdge
            ? "Remembered for \(name) with long-edge binding."
            : "Remembered for \(name) with short-edge binding."
    }

    private var isDuplex: Bool { model.layout.duplex != .none }

    private func row<Control: View>(
        _ title: LocalizedStringKey, hint: LocalizedStringKey?, @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(PrintPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(.system(size: 12.5))
                    .frame(width: 145, alignment: .leading)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    control()
                    if let hint {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(PrintPalette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
        }
    }
}
