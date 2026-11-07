import SurimonoCore
import SwiftUI

/// The press bar (刷り台バー): two groups. On the left, how to print: the paper and its orientation over the layout
/// cards. On the right, the result and the ways to send it out: what comes out, the printer, PDF and Print. A window
/// too narrow for both side by side puts the second under the first (`PrintPressArrangement`).
struct PrintPressBar: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        PrintPressLayout {
            paperRow
            cards
            summary
            actions
            printButton
            // The rule between the groups; the layout empties it where they are stacked.
            Rectangle().fill(PrintPalette.line)
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

    private var printButton: some View {
        Button {
            model.performPrintCommand()
        } label: {
            VStack(spacing: 0) {
                Text("Print").font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: "⌘P").font(.system(size: 9.5)).tracking(0.4).opacity(0.85)
            }
            .padding(.top, 15)
            .padding(.bottom, 12)
        }
        .buttonStyle(SealButtonStyle())
        .disabled(!model.canOutput)
        .help(Text(verbatim: printHelp))
        .accessibilityLabel(Text(verbatim: printAccessibilityLabel))
    }

    /// The paper the layouts are made on, and which way it lies.
    private var paperRow: some View {
        HStack(spacing: 8) {
            Text("Paper to Use").font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
            PrintSeriesSwitch(model: model)
            OrientationPicker(model: model)
        }
        .fixedSize()
    }

    private var cards: some View {
        PrintFlowLayout(spacing: 2, lineSpacing: 4, alignment: .leading) {
            let cards = Array(PrintLayout.presets(in: model.trayPaperSeries).enumerated())
            ForEach(cards, id: \.element.id) { index, layout in
                LayoutCard(
                    layout: layout, title: PrintModeText.cardTitle(layout, language: model.language),
                    paper: PrintModeText.cardPaper(layout, language: model.language),
                    help: "\(layout.displayName(language: model.language)) (⌘\(index + 1))",
                    isSelected: model.layoutID == layout.id
                ) {
                    model.chooseCard(at: index)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: outcome?.finished ?? String(localized: "Preparing pages…"))
                        .font(.system(size: 12, weight: .semibold))
                    if let paper = outcome?.paper {
                        Text(verbatim: paper).font(.system(size: 12))
                    }
                }
                .monospacedDigit()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                if model.isRendering { ProgressView().controlSize(.mini) }
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
            // The notes are the part of the result that can be cut to the room there is; the hint shows them whole.
            if let note {
                Text(verbatim: note)
                    .font(.system(size: 11))
                    .foregroundStyle(PrintPalette.ink2)
                    .lineLimit(1)
                    .help(Text(verbatim: note))
            }
            if let line = reminderLine {
                Text(verbatim: line).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
                    .monospacedDigit().lineLimit(1).help(Text(verbatim: line))
            }
            if model.canSaveAsFile {
                Button {
                    model.saveAsFile()
                } label: {
                    Text("Save as File…").underline()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(PrintPalette.ink2)
                .help("Kept in memory only")
            }
        }
    }

    private var actions: some View {
        // Two buttons as tall as the Print button beside them, so that their top and bottom edges line up with it.
        VStack(spacing: 6) {
            PrinterPicker(model: model)
            actionButton("Export PDF", systemImage: "arrow.down.doc", help: "Export the imposed sheets as a PDF (⇧⌘E)")
            {
                model.exportPDF()
            }
            .disabled(!model.canOutput)
        }
    }

    private func actionButton(
        _ title: LocalizedStringKey, systemImage: String, help: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
                    .frame(width: 15)
                // The label is the narrowest the button is made, so that it never folds into two lines.
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 130)
        }
        .buttonStyle(PrintBorderedButtonStyle())
        .help(help)
    }

    private var note: String? {
        guard model.hasCurrentPrintPreview, let result = model.printResult else { return nil }
        return PrintModeText.mixedNote(result.sheetOrientations, language: model.language)
            ?? PrintModeText.note(result.layout, pageCount: result.plan.logicalPageCount, language: model.language)
    }

    /// What comes out, and what it takes: the pages of the finished piece and the paper for them.
    private var outcome: (finished: String, paper: String)? {
        guard let result = model.printResult, model.summary != nil else { return nil }
        let slots = result.plan.sides.flatMap(\.slots)
        let blanks = slots.filter { $0 == nil }.count + result.blankPages.count
        let contents = model.finishAppliesToText ? result.addedContentsPages : 0
        let notes = result.addedNotePages
        return (
            PrintModeText.finished(
                pages: slots.count, body: slots.count - blanks - contents - notes, contents: contents, notes: notes,
                blanks: blanks, language: model.language),
            PrintModeText.paper(
                result.plan.paper.shortName, sheets: result.plan.sheetCount, duplex: result.layout.duplex,
                language: model.language)
        )
    }

    /// What the choices add to the sheets beyond the summary; the amount of text belongs to the document's information.
    private var reminderLine: String? {
        var parts = [
            PrintModeText.options(model.effectivePrintOptions, layout: model.layout, language: model.language)
        ].compactMap { $0 }
        if model.hasCurrentPrintPreview, model.printResult?.addedNotePages ?? 0 > 0 {
            if model.coverIsNotePage {
                parts.append(PrintModeText.string("The cover is a note page too", language: model.language))
            }
            if model.notes.style.isFaint {
                parts.append(
                    PrintModeText.string("The lines are faint and may fade when printed", language: model.language))
            }
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { PrintModeText.format("%@ · %@", language: model.language, $0, $1) }
    }

    private var printAccessibilityLabel: String {
        [PrintModeText.string("Print", language: model.language), model.selectedPrinterName, model.summary]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private var printHelp: String {
        guard let printer = model.selectedPrinterName else {
            return PrintModeText.string(
                "No printer is set up, so Print opens the system print dialog (⌘P)", language: model.language)
        }
        return PrintModeText.format("Print to %@ right away (⌘P)", language: model.language, printer)
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
            Button("Duplex Test Print…") { model.printDuplexTest() }
                .disabled(!model.canPrintDuplexTest)
            if model.layout.duplex == .none { Text("Choose a duplex layout to test back-side orientation.") }
            Divider()
            Button("Print with System Dialog…") { model.printDocument(quick: false) }
                .disabled(!model.canOutput)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "printer").font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
                    .frame(width: 15)
                Text(
                    verbatim: model.selectedPrinterName ?? PrintModeText.string("No Printers", language: model.language)
                )
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink3)
            }
            .padding(.horizontal, 9)
            // Room for a typical model name such as "Brother MFC-J7100CDW"; longer names lose their middle.
            .frame(minWidth: 130, maxWidth: 230)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PrintBorderedButtonStyle())
        // A printer set up while the tray is open shows up the next time the pointer comes back to the menu.
        .onHover { if $0 { model.refreshPrinters() } }
        .help("Choose the printer for Print, or print with the system dialog")
        .accessibilityLabel(Text("Printer"))
    }

    private func title(for name: String) -> String {
        name == model.printers.defaultName
            ? PrintModeText.format("%@ (Default)", language: model.language, name) : name
    }
}

/// A layout choice with a small paper pictogram; the selected card is drawn in ai. Every card is as wide and as high as
/// the others and its title takes two lines whether it needs them or not, so that the paper lines under the titles
/// stand in a row.
private struct LayoutCard: View {
    let layout: PrintLayout
    let title: String
    /// The paper it prints on, where the title names what comes out.
    let paper: String?
    let help: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let titleFont = Font.system(size: 12, weight: .semibold)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                LayoutPictogram(layout: layout)
                    .frame(width: 40, height: 26)
                    .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink2)
                    .padding(.bottom, 4)
                titleLines
                if let paper {
                    Text(verbatim: paper)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .frame(width: 80, height: 88, alignment: .top)
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
        .accessibilityLabel(
            Text(verbatim: layout.displayName(language: Bundle.main.preferredLocalizations.first ?? "en"))
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The title, centered in the room for two lines.
    private var titleLines: some View {
        ZStack {
            Text(verbatim: " \n ").font(Self.titleFont).lineLimit(2, reservesSpace: true).hidden()
            Text(verbatim: title)
                .font(Self.titleFont)
                .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
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
        case .booklet where layout.sheet == .a3 || layout.sheet == .b4:
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
