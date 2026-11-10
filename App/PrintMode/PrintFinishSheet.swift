import SurimonoCore
import SwiftUI

/// The sections of the print settings, which the tray's items open directly.
enum PrintFinishSection: Hashable {
    case furniture, breaks, contents, notes, printer
}

/// All the print settings. It stays beside the sheets, which show each change right away.
struct PrintFinishSheet: View {
    @Bindable var model: DocumentViewModel
    @State private var slot = PageFurniture.Slot.bottomCenter
    @State private var customLine = ""
    @FocusState private var isEditingCustomLine: Bool

    init(model: DocumentViewModel) {
        self.model = model
    }

    var body: some View {
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
            Rectangle().fill(PrintPalette.line).frame(height: 1)
            footer
        }
        .frame(maxWidth: 460)
        .foregroundStyle(PrintPalette.ink)
        .tint(PrintPalette.ai)
        .background(RoundedRectangle(cornerRadius: 14).fill(PrintPalette.raised))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PrintPalette.line, lineWidth: 1))
        .shadow(color: PrintPalette.popShadow, radius: 20, y: 6)
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
                        selection: Binding(get: { model.effectiveBookletBinding }, set: { model.bookletBinding = $0 })
                    ) {
                        Text("Left Binding").tag(BookletBinding.left)
                        Text("Right Binding").tag(BookletBinding.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if model.marginsAffectPrinting {
                section("Paper & Margins", isFirst: true) { PrintMarginEditor(model: model) }
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
            }
            if model.offersNotes {
                section("Note Pages") { PrintNoteSection(model: model) }.id(PrintFinishSection.notes)
            }
            section("Printer Adjustments") { PrintPrinterOptions(model: model) }.id(PrintFinishSection.printer)
            newDocumentsDefault
        }
        .padding(16)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Print Settings").font(.system(size: 14, weight: .bold))
            Text("Added only when printing. The document does not change.")
                .font(.system(size: 11.5))
                .foregroundStyle(PrintPalette.ink2)
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
            .keyboardShortcut(.cancelAction)
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
            Text("New documents start with these margins, header and footer, page breaks and contents")
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey, isFirst: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst { Rectangle().fill(PrintPalette.line).frame(height: 1).padding(.bottom, 11) }
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 7)
            content()
        }
        .padding(.bottom, 11)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(PrintPalette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
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
            choice()
            Spacer(minLength: 0)
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
            if choice == .custom {
                slotFields([.topLeft, .topCenter, .topRight]).padding(.top, 10)
                Text("Text")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(.sRGB, red: 0.33, green: 0.34, blue: 0.35, opacity: 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 2).fill(PrintPalette.paper))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(PrintPalette.line2, lineWidth: 1))
                    .padding(.vertical, 5)
                slotFields([.bottomLeft, .bottomCenter, .bottomRight])
                subheading("Items to Insert")
                HStack(spacing: 4) {
                    chip("File Name", .fileName)
                    chip("Title", .title)
                    chip("Date", .date)
                    chip("Page", .page)
                    chip("Total Pages", .pageCount)
                }
            }
            if choice == .custom || choice == .nameAndDate {
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
                    PrintTextField(title: "Date Format", text: $model.printOptions.furniture.dateFormat)
                }
            }
            if choice != .none {
                switchRow("Leave Out of the First Page", isOn: $model.printOptions.furniture.skipsFirstPage)
                    .padding(.top, 8)
                switchRow("Swap Left and Right on Spreads", isOn: $model.printOptions.furniture.swapsOnSpreads)
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
                .overlay(Capsule().strokeBorder(PrintPalette.line2, lineWidth: 1))
                .contentShape(Capsule())
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
        Binding(
            get: {
                let format = model.printOptions.furniture.dateFormat
                return Self.dateFormats.contains(format) ? format : ""
            },
            set: { if !$0.isEmpty { model.printOptions.furniture.dateFormat = $0 } })
    }

    // MARK: Page breaks

    private var breakHint: LocalizedStringKey {
        switch model.printFinish.breaks.h1 {
        case .none: "Headings do not break the page."
        case .page: "Breaks the page before the largest headings."
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
            levelRow(level: 1, rule: $model.printFinish.breaks.h1)
            levelRow(level: 2, rule: $model.printFinish.breaks.h2)
            levelRow(level: 3, rule: $model.printFinish.breaks.h3)
            if model.format == .markdown {
                subheading("Syntax in the Text (Read Only; the Text Does Not Change)")
                codeRow("<!--BREAK-->", isOn: syntax(.comment), count: facts?.pageBreakCounts[.comment] ?? 0)
                codeRow("<!-- pagebreak -->", isOn: syntax(.pagebreak), count: facts?.pageBreakCounts[.pagebreak] ?? 0)
                codeRow("\\newpage", isOn: syntax(.newpage), count: facts?.pageBreakCounts[.newpage] ?? 0)
                codeRow("{::pagebreak /}", isOn: syntax(.kramdown), count: facts?.pageBreakCounts[.kramdown] ?? 0)
                switchRow(
                    "Break at ---", isOn: $model.printFinish.breaks.breaksAtThematicBreaks,
                    count: PrintModeText.format(
                        "%lld places", language: model.language, facts?.thematicBreakCount ?? 0))
                subheading("Your Own Syntax")
                TextField("Your Own Syntax", text: $customLine, prompt: Text(verbatim: "＝＝改ページ＝＝"))
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
            switchRow("Keep Headings with Their Text", isOn: $model.printFinish.breaks.keepsHeadingsWithText)
            switchRow("Do Not Split Tables", isOn: $model.printFinish.breaks.keepsTablesWhole)
        }
    }

    private func levelRow(level: Int, rule: Binding<HeadingBreak>) -> some View {
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
        Binding(
            get: { !model.printFinish.breaks.ignoredSyntaxes.contains(syntax) },
            set: { isOn in
                if isOn {
                    model.printFinish.breaks.ignoredSyntaxes.remove(syntax)
                } else {
                    model.printFinish.breaks.ignoredSyntaxes.insert(syntax)
                }
            })
    }

    // MARK: Contents

    private var contentsHint: LocalizedStringKey {
        let hasSource = facts?.hasSourceContents == true
        switch model.printFinish.toc.mode {
        case .hidden: return hasSource ? "The text's [TOC] does not print." : "No contents on the paper."
        case .source:
            return hasSource
                ? "Prints where the text's [TOC] stands."
                : "This document does not say where contents go. To add them, choose “Add Contents to Front”."
        case .front: return "Adds pages of contents in front, with or without a [TOC] in the text."
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
            switchRow("Keep the Text's [TOC] as Well", isOn: $model.printFinish.toc.keepsSourceTOC)
        }
    }
}

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
        .opacity(isEnabled ? 1 : 0.45)
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
            .background(RoundedRectangle(cornerRadius: 5).fill(PrintPalette.chrome))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(
                    isHighlighted ? PrintPalette.ai : PrintPalette.line2, lineWidth: 1)
            )
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
    }
}

/// The four margins around a sheet of paper, with the text area drawn to scale.
struct PrintMarginEditor: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            Text("Margins (mm)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrintPalette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 5)
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
                isOn: Binding(get: { model.printOptions.linksMargins }, set: { model.setMarginsLinked($0) }))
            if model.layout.hasFacingPages, model.binder == nil {
                toggle("Treat Left and Right as Inside and Outside", isOn: $model.printOptions.mirrorsMargins)
            }
            Text("Applies to text documents and images. PDFs keep their own margins.")
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
                value: Binding(
                    get: { model.printOptions.margins[keyPath: side] },
                    set: { model.setMargin(side, to: $0) }),
                format: .number.precision(.fractionLength(0...1))
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
                .background(PrintPalette.foldLine.opacity(0.12))
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
                PrintPageOrderPicker(order: $model.printPageOrder)
                    .disabled(model.selectedPrinterName == nil)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
            }
            row(
                "Rotate Back Sides 180°",
                hint: rotationHint
            ) {
                Toggle("Rotate Back Sides 180°", isOn: $model.rotatesBackSides)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!isDuplex || model.selectedPrinterName == nil || !model.canOutput)
            }
        }
    }

    private var printerOrderHint: LocalizedStringKey {
        guard let name = model.selectedPrinterName else { return "Choose a printer to remember its settings." }
        return "Remembered for \(name). Last Sheet First keeps face-up sheets in page order."
    }

    private var rotationHint: LocalizedStringKey {
        guard isDuplex else { return "Available for duplex layouts (A4 Duplex and booklets)." }
        guard let name = model.selectedPrinterName else { return "Choose a printer to remember its settings." }
        return model.printerLayout.sentDuplex == .longEdge
            ? "Remembered for \(name) with long-edge binding."
            : "Remembered for \(name) with short-edge binding."
    }

    private var isDuplex: Bool { model.layout.duplex != .none }

    private func row<Control: View>(
        _ title: LocalizedStringKey, hint: LocalizedStringKey, @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(PrintPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                Text(title).font(.system(size: 12.5)).frame(width: 145, alignment: .leading).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    control()
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(PrintPalette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
        }
    }
}
