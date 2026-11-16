import SurimonoCore
import SwiftUI

/// The press bar (刷り台バー): two groups. On the left, how to print: the paper series and orientation menus over the
/// layout cards. On the right, the result and the ways to send it out: the paper it takes, the copies and pages, the
/// printer, PDF and Print. A window too narrow for both side by side puts the second under the first, and folds further
/// as `PrintPressArrangement` says.
struct PrintPressBar: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        PrintPressLayout {
            menus
            cards
            summary
            PrinterPicker(model: model)
            pdfButton
            printButton
            // The rule between the groups; the layout empties it where they are stacked.
            Rectangle().fill(PrintPalette.line)
            // Measures the result's first line, which the layout keeps from wrapping while it can.
            Text(verbatim: lead).font(Self.leadFont).monospacedDigit().lineLimit(1).fixedSize().hidden()
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(PrintPalette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
        .onChange(of: model.printIssueCount) { _, count in
            if count == 0 { model.isPrintIssuesPresented = false }
        }
        .popover(isPresented: $model.isPrintIssuesPresented, arrowEdge: .top) {
            // The popover can lie over the white paper, where a bare material turns mid-grey and its hints fade.
            PrintIssuesPopover(model: model).presentationBackground(PrintPalette.raised)
        }
    }

    /// The bar's three sizes of type: 11 for hints and labels, 12 to 13 for values and card titles, 16 for Print.
    private static let leadFont = Font.system(size: 13, weight: .semibold)

    private var printButton: some View {
        Button {
            model.performPrintCommand()
        } label: {
            VStack(spacing: 0) {
                Text("Print").font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: ShortcutHints.keys([.documentPrint])).font(.system(size: 11)).opacity(0.85)
            }
            .padding(.top, 14)
            .padding(.bottom, 11)
        }
        .buttonStyle(SealButtonStyle())
        .disabled(!model.canStartPrint)
        .help(Text(verbatim: printHelp))
        .accessibilityLabel(Text(verbatim: printAccessibilityLabel))
    }

    /// The series of paper the layouts are made from, and which way the paper lies: the two choices that apply to all
    /// the cards, side by side over them at every width.
    private var menus: some View {
        HStack(spacing: 8) {
            PaperSeriesMenu(model: model)
            OrientationPicker(model: model)
        }
        .fixedSize()
    }

    private var cards: some View {
        PrintCardGrid {
            let cards = Array(PrintLayout.presets(in: model.trayPaperSeries).enumerated())
            ForEach(cards, id: \.element.id) { index, preset in
                let compact =
                    index == 4 && model.layout.series == model.trayPaperSeries
                    && (model.layout.kind == .twoUp || model.layout.kind == .fourUp)
                let layout = compact ? model.layout : preset
                let issue = model.printerIssue(for: layout)
                LayoutCard(
                    layout: layout, title: PrintModeText.cardTitle(layout, language: model.language),
                    sheet: PrintModeText.cardSheet(layout),
                    issue: issue.map { PrintModeText.issueBadge($0, language: model.language) },
                    help: PrintModeText.cardHelp(
                        [
                            ShortcutHints.help(
                                PrintModeText.cardTitleLine(layout, language: model.language),
                                [ShortcutHints.layout(layout, index: index, compact: compact)]),
                            PrintModeText.cardPaper(layout, language: model.language),
                        ].compactMap { $0 }.joined(separator: "\n"),
                        issue: issue, language: model.language),
                    accessibilityLabel: PrintModeText.cardLabel(layout, issue: issue, language: model.language),
                    isSelected: model.layoutID == layout.id,
                    variants: index == 4 ? [preset] + PrintLayout.compactPresets(in: model.trayPaperSeries) : [],
                    model: model
                ) {
                    model.chooseLayout(layout.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: outcome == nil ? String(localized: "Preparing pages…") : lead)
                    .font(Self.leadFont)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if model.isRendering { ProgressView().controlSize(.mini) }
            }
            // What the first line does not say: what the sheets make, what the pages are, the copies. It wraps rather
            // than being cut, at any width.
            if let detail = outcome?.detail(language: model.language) {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.ink2)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.printIssueCount > 0 {
                Button("Check \(model.printIssueCount)") { model.reviewPrintIssues() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PrintPalette.ai)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PrintPalette.aiTint, in: RoundedRectangle(cornerRadius: 6))
            }
            if let line = reminderLine {
                Text(verbatim: line).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                    .lineLimit(1).help(Text(verbatim: line))
            }
            PrinterIssueLine(model: model)
            PrintJobControls(model: model).padding(.top, 2)
        }
    }

    /// The PDF button keeps its icon and drops its label when the bar gives it no room for both.
    private var pdfButton: some View {
        Button {
            model.exportPDF()
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    pdfIcon
                    Text("Export PDF").lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                pdfIcon.padding(.horizontal, 10)
            }
        }
        .buttonStyle(PrintBorderedButtonStyle())
        .disabled(!model.canOutput)
        .help(ShortcutHints.help(String(localized: "Export the imposed sheets as a PDF"), [.documentExportPDF]))
        .accessibilityLabel(Text("Export PDF"))
    }

    private var pdfIcon: some View {
        Image(systemName: "arrow.down.doc").font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
            .frame(width: 15)
    }

    /// The paper, the sheets and the sides, as `PrintOutcome` reads them from the sheets on the tray.
    private var lead: String {
        outcome?.lead(language: model.language) ?? String(localized: "Preparing pages…")
    }

    private var outcome: PrintOutcome? { model.printOutcome }

    /// What the choices add to the sheets beyond the summary; the amount of text belongs to the document's information.
    private var reminderLine: String? {
        // The options of the sheets shown, which may be older than the choices while newer sheets are composed.
        let sheets = model.shownSheets
        var parts = [
            PrintModeText.options(
                model.shownSheetSettings?.options ?? model.effectivePrintOptions,
                layout: sheets?.layout ?? model.printerLayout, language: model.language)
        ].compactMap { $0 }
        if let sheets, sheets.addedNotePages > 0 {
            if model.coverIsNotePage {
                parts.append(PrintModeText.string("The cover is a note page too", language: model.language))
            }
            if (model.shownSheetSettings?.notes ?? model.notes).style.isFaint {
                parts.append(
                    PrintModeText.string("The lines are faint and may fade when printed", language: model.language))
            }
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { PrintModeText.format("%@ · %@", language: model.language, $0, $1) }
    }

    private var printAccessibilityLabel: String {
        // The same words as the result's first line, so that VoiceOver says what the button sends.
        [
            PrintModeText.string("Print", language: model.language), model.selectedPrinterName,
            outcome?.lead(language: model.language) ?? model.summary,
        ]
        .compactMap { $0 }.joined(separator: ", ")
    }

    private var printHelp: String {
        guard let printer = model.selectedPrinterName else {
            return ShortcutHints.help(
                PrintModeText.string(
                    "No printer is set up, so Print opens the system print dialog", language: model.language),
                [.documentPrint])
        }
        if let issue = model.printerIssue {
            return ShortcutHints.help(PrintModeText.issuePrintHelp(issue, language: model.language), [.documentPrint])
        }
        return ShortcutHints.help(
            PrintModeText.format("Print to %@ right away", language: model.language, printer), [.documentPrint])
    }
}

/// The paper's orientation, drawn like the strip's menus: it is a choice, as they are, where the buttons beside Print
/// are actions. A layout that fixes the orientation has nothing to choose, so it shows no menu at all rather than one
/// that is switched off.
private struct OrientationPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        let control = PaperOrientationControl(model: model)
        if !control.isFixed {
            Menu {
                control.choices
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.portrait.rotate").foregroundStyle(PrintPalette.ink2)
                    Text(control.value)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(PrintPalette.ink2)
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(PrintPalette.hover))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Paper Orientation")
            .accessibilityLabel(Text("Paper Orientation"))
            .accessibilityValue(Text(control.value))
        }
    }
}

/// Where Print sends the sheets: the printers that are set up, and the system dialog for everything else (copies,
/// page ranges, paper trays).
private struct PrinterPicker: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Menu {
            if model.printers.names.isEmpty {
                Text("No Printers")
            } else {
                Picker(
                    "Printer",
                    selection: Binding(get: { model.selectedPrinterName ?? "" }, set: { model.selectPrinter($0) })
                ) {
                    ForEach(model.printers.names, id: \.self) { name in
                        Text(verbatim: title(for: name)).tag(name)
                    }
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button("Print Both Sides Manually…") { model.printDocument(intent: .manualDuplex) }
                .disabled(!model.canPrintManualDuplex)
            Button("Duplex Test Print…") { model.printDuplexTest() }
                .disabled(!model.canPrintDuplexTest)
            if model.layout.duplex == .none { Text("Choose a duplex layout to test back-side orientation.") }
            Divider()
            Button("Print with System Dialog…") { model.printDocument(quick: false) }
                .disabled(!model.canStartPrint)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "printer").font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
                    .frame(width: 15)
                // A short word in the narrow button; the menu says it in full.
                Text(
                    verbatim: model.selectedPrinterName ?? PrintModeText.string("No Printer", language: model.language)
                )
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink3)
            }
            .padding(.horizontal, 9)
            // The bar gives the menu its whole name where it can (`PrintPressArrangement.printerLimit` at most), and
            // cuts the middle of the name last of all.
            .frame(minWidth: PrintPressArrangement.printerMinimum, maxWidth: .infinity)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PrintBorderedButtonStyle())
        // A printer set up while the tray is open shows up the next time the pointer comes back to the menu.
        .onHover { if $0 { model.refreshPrinters() } }
        // The printer's whole name, which the menu may cut in the middle.
        .help(Text(verbatim: model.selectedPrinterName ?? ""))
        .accessibilityLabel(Text("Printer"))
        .accessibilityValue(
            Text(
                verbatim: model.selectedPrinterName
                    ?? PrintModeText.string("No Printer", language: model.language)))
    }

    private func title(for name: String) -> String {
        name == model.printers.defaultName
            ? PrintModeText.format("%@ (Default)", language: model.language, name) : name
    }
}

/// The series of paper the cards are made from: A4 and A3, B5 and B4, or Letter and Tabloid. Closed, it names the
/// series by itself ("A Sizes"), so that it does not read as paper that both sizes are used on; the paper a print
/// takes is the result's first line.
private struct PaperSeriesMenu: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Menu {
            Section("Paper Size Series") {
                Picker(
                    "Paper Size Series",
                    selection: Binding(
                        get: { model.trayPaperSeries }, set: { model.choosePaperSeries($0) })
                ) {
                    ForEach(PaperSeries.allCases, id: \.self) { series in
                        Text(series.menuTitle).tag(series)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ruler").foregroundStyle(PrintPalette.ink2)
                Text(model.trayPaperSeries.shortTitle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink2)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(PrintPalette.hover))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Paper Size Series")
        .accessibilityLabel(Text("Paper Size Series"))
        .accessibilityValue(Text(model.trayPaperSeries.menuTitle))
    }
}

extension PaperSeries {
    /// The series in a word or two, for the closed menu.
    var shortTitle: LocalizedStringKey {
        switch self {
        case .a: "A Sizes"
        case .b: "B Sizes (JIS)"
        case .letter: "US Sizes"
        }
    }

    /// The series with its sizes, for the open menu.
    var menuTitle: LocalizedStringKey {
        switch self {
        case .a: "A Sizes (A4, A3)"
        case .b: "B Sizes, JIS (B5, B4)"
        case .letter: "US Sizes (Letter, Tabloid)"
        }
    }
}

/// A layout choice with a small paper pictogram; the selected card is drawn in ai. Every card is as wide and as high as
/// the others, and its title keeps two lines whether it needs them or not, so that the titles stand in a row. A card
/// whose paper is not what it makes (a booklet, two pages on one sheet) carries the paper in its top right corner. The
/// fifth card has a menu of its own there for the other papers and pages it comes in.
private struct LayoutCard: View {
    let layout: PrintLayout
    let title: String
    /// The paper it prints on, where that is not what the title names.
    let sheet: String?
    /// What the chosen printer cannot do with it, in a word or two.
    let issue: String?
    let help: String
    let accessibilityLabel: String
    let isSelected: Bool
    /// The layouts the card's menu offers; none for a card without a menu.
    let variants: [PrintLayout]
    let model: DocumentViewModel
    let action: () -> Void
    @State private var hovering = false

    static let size = CGSize(width: 80, height: 86)
    private static let titleFont = Font.system(size: 12, weight: .semibold)
    private static let menuSize: CGFloat = 20

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                topRow.frame(height: 18)
                LayoutPictogram(layout: layout)
                    .frame(width: 40, height: 26)
                    .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink2)
                    .padding(.bottom, 3)
                titleLines
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? PrintPalette.aiTint : hovering ? PrintPalette.hover : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? PrintPalette.ai : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: help))
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Beside the card's button, not in it: a control of its own, which VoiceOver reads as one.
        .overlay(alignment: .topTrailing) {
            if !variants.isEmpty { variantMenu.padding(.top, 1).padding(.trailing, 1) }
        }
    }

    /// The paper, or what the printer cannot do, which matters more; the menu's room is kept clear at the end.
    private var topRow: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            if let issue {
                Text(verbatim: issue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .background(PrintPalette.raised, in: Capsule())
                    .overlay { Capsule().strokeBorder(PrintPalette.line3, lineWidth: 1) }
            } else if let sheet {
                HStack(spacing: 3) {
                    SheetMark().frame(width: 7, height: 9)
                    Text(verbatim: sheet).font(.system(size: 11)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink2)
            }
            if !variants.isEmpty { Color.clear.frame(width: Self.menuSize - 4) }
        }
    }

    private var variantMenu: some View {
        Menu {
            Picker(
                "Paper & Pages",
                selection: Binding(get: { model.layoutID }, set: { model.chooseLayout($0) })
            ) {
                ForEach(variants) { option in
                    Text(verbatim: option.displayName(language: model.language)).tag(option.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            VariantMenuLabel(isSelected: isSelected)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Paper & Pages")
        .accessibilityLabel(Text("Paper & Pages"))
        .accessibilityValue(Text(verbatim: layout.displayName(language: model.language)))
        .accessibilityIdentifier("compactLayoutMenu")
    }

    /// The title, centered in the room for two lines. A title that needs two lines takes them; it is never shrunk or
    /// cut to stay on one.
    private var titleLines: some View {
        ZStack {
            Text(verbatim: " \n ").font(Self.titleFont).lineLimit(2, reservesSpace: true).hidden()
            Text(verbatim: title)
                .font(Self.titleFont)
                .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The ▼ of a card's menu: a target of 20 by 20 points that shows under the pointer, apart from the card around it.
private struct VariantMenuLabel: View {
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink2)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? PrintPalette.press : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

/// A sheet of paper with a folded corner, small enough to stand before the name of a paper size.
private struct SheetMark: View {
    var body: some View {
        Canvas { context, size in
            let fold = min(size.width, size.height) * 0.35
            var path = Path()
            path.move(to: CGPoint(x: 0.5, y: 0.5))
            path.addLine(to: CGPoint(x: size.width - fold, y: 0.5))
            path.addLine(to: CGPoint(x: size.width - 0.5, y: fold))
            path.addLine(to: CGPoint(x: size.width - 0.5, y: size.height - 0.5))
            path.addLine(to: CGPoint(x: 0.5, y: size.height - 0.5))
            path.closeSubpath()
            context.stroke(path, with: .foreground, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Paper pictograms for the layouts (drawn in a 46 × 30 box).
struct LayoutPictogram: View {
    let layout: PrintLayout

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 46, size.height / 30)
            context.translateBy(x: (size.width - 46 * scale) / 2, y: (size.height - 30 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let parts = Self.parts(for: layout)
            for rect in parts.papers {
                let path = Path(rect)
                context.fill(path, with: .color(PrintPalette.pictogramPaper))
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
            }
            if let fold = parts.fold {
                context.stroke(fold, with: .foreground, style: StrokeStyle(lineWidth: 1.25, dash: [2, 1.6]))
            }
            if let extra = parts.extra {
                context.stroke(
                    extra, with: .foreground, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            var text = context
            text.opacity = 0.55
            text.stroke(parts.text, with: .foreground, style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        .accessibilityHidden(true)
    }

    private struct Parts {
        var papers: [CGRect]
        var fold: Path?
        var extra: Path?
        var text: Path
    }

    private static func lines(_ segments: [(CGFloat, CGFloat, CGFloat)]) -> Path {
        var path = Path()
        for (x, y, length) in segments {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + length, y: y))
        }
        return path
    }

    private static func parts(for layout: PrintLayout) -> Parts {
        switch layout.kind {
        case .normal where layout.duplex == .none:
            return Parts(
                papers: [CGRect(x: 16, y: 4, width: 14, height: 20)],
                text: lines([(19, 8.5, 8), (19, 11.5, 8), (19, 14.5, 8), (19, 17.5, 5)]))
        case .normal:
            var arrow = Path()
            arrow.move(to: CGPoint(x: 36.5, y: 9.5))
            arrow.addCurve(
                to: CGPoint(x: 36.5, y: 16.9), control1: CGPoint(x: 38.5, y: 11.3),
                control2: CGPoint(x: 38.5, y: 15.1))
            arrow.move(to: CGPoint(x: 35, y: 15.9))
            arrow.addLine(to: CGPoint(x: 36.5, y: 17))
            arrow.addLine(to: CGPoint(x: 37.9, y: 15.7))
            return Parts(
                papers: [
                    CGRect(x: 20, y: 2.5, width: 13, height: 18.5), CGRect(x: 13.5, y: 7, width: 13, height: 18.5),
                ],
                extra: arrow, text: lines([(16.5, 11.5, 7), (16.5, 14.5, 7), (16.5, 17.5, 5)]))
        case .booklet where layout.sheet == .a3 || layout.sheet == .b4 || layout.sheet == .tabloid:
            var fold = Path()
            fold.move(to: CGPoint(x: 23, y: 4.5))
            fold.addLine(to: CGPoint(x: 23, y: 26.5))
            return Parts(
                papers: [CGRect(x: 5, y: 4.5, width: 36, height: 22)], fold: fold,
                text: lines([
                    (8.5, 9.5, 11), (8.5, 12.5, 11), (8.5, 15.5, 8), (26.5, 9.5, 11), (26.5, 12.5, 11),
                    (26.5, 15.5, 11), (26.5, 18.5, 6),
                ]))
        case .booklet:
            var fold = Path()
            fold.move(to: CGPoint(x: 23, y: 8))
            fold.addLine(to: CGPoint(x: 23, y: 24))
            return Parts(
                papers: [CGRect(x: 10, y: 8, width: 26, height: 16)], fold: fold,
                text: lines([(13, 12, 7), (13, 15, 7), (26, 12, 7), (26, 15, 7), (26, 18, 4)]))
        case .fourUp:
            var text = Path()
            for y in [6.0, 16.0] {
                for x in [15.0, 24.0] { text.addRect(CGRect(x: x, y: y, width: 7, height: 8)) }
            }
            return Parts(papers: [CGRect(x: 12, y: 3, width: 22, height: 24)], text: text)
        case .handout3:
            var text = lines([(27, 9, 6), (27, 13, 6), (27, 17, 6), (27, 21, 6)])
            for y in [6.5, 12.5, 18.5] {
                text.addRect(CGRect(x: 13, y: y, width: 11, height: 4.5))
            }
            return Parts(papers: [CGRect(x: 10, y: 3.5, width: 26, height: 23)], text: text)
        case .twoUp:
            var text = Path()
            text.addRect(CGRect(x: 8, y: 7.5, width: 13, height: 16))
            text.addRect(CGRect(x: 25, y: 7.5, width: 13, height: 16))
            return Parts(papers: [CGRect(x: 5, y: 4.5, width: 36, height: 22)], text: text)
        }
    }
}

/// The order the printer prints the sheets in. It belongs to the printer rather than the document, so one choice
/// applies to every window, and it changes only the print job, not the sheets on the tray.
struct PrintPageOrderPicker: View {
    @Binding var order: PrintPageOrder

    static let hint: LocalizedStringKey =
        "Initial values for printers without remembered settings. Last Sheet First keeps face-up sheets in page order."

    var body: some View {
        Picker("Output Order", selection: $order) {
            Text("Last Sheet First").tag(PrintPageOrder.lastSheetFirst)
            Text("First Sheet First").tag(PrintPageOrder.firstSheetFirst)
        }
        .pickerStyle(.segmented)
    }
}
