import SurimonoCore
import SwiftUI

/// The press bar (刷り台バー): layouts, what comes out, options, and the ways to output.
struct PrintPressBar: View {
    @Bindable var model: DocumentViewModel
    @State private var showsOptions = false

    var body: some View {
        GeometryReader { geometry in
            let density = Density(width: geometry.size.width)
            HStack(spacing: density == .regular ? 14 : 12) {
                layouts(density)
                summary(density)
                actions
                Button {
                    model.performPrintCommand()
                } label: {
                    VStack(spacing: 0) {
                        Text("Print").font(.system(size: 16, weight: .bold)).tracking(1.6)
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
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 92)
        .background(PrintPalette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
    }

    /// The bar tightens in narrow windows, like the mock's container queries.
    enum Density {
        case regular, medium, compact

        init(width: CGFloat) {
            self = width >= 1080 ? .regular : width >= 940 ? .medium : .compact
        }
    }

    private func layouts(_ density: Density) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(PrintLayout.presets.enumerated()), id: \.element.id) { index, layout in
                LayoutCard(
                    layout: layout, title: PrintModeText.cardTitle(layout, language: model.language),
                    help: "\(layout.displayName(language: model.language)) (⌘\(index + 1))",
                    shortcut: index + 1, isSelected: model.layoutID == layout.id, density: density
                ) {
                    model.chooseLayout(layout.id)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
    }

    private func summary(_ density: Density) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: model.summary ?? String(localized: "Preparing pages…"))
                        .font(.system(size: density == .regular ? 13.5 : 12.5))
                        .monospacedDigit()
                        .lineLimit(1)
                    if model.isRendering { ProgressView().controlSize(.mini) }
                }
                if let note {
                    // Notes about blank pages run long; they may take a second line.
                    Text(verbatim: note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PrintPalette.ink2)
                        .lineLimit(optionsText == nil ? 2 : 1)
                }
                if let options = optionsText {
                    Text(verbatim: options).font(.system(size: 11)).foregroundStyle(PrintPalette.ai).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showsOptions.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(PrintPalette.ink2)
                    .frame(width: 30)
                    .overlay(alignment: .topTrailing) {
                        if optionsText != nil {
                            Circle().fill(PrintPalette.ai).frame(width: 6, height: 6).offset(x: 2, y: 3)
                        }
                    }
            }
            .buttonStyle(PrintBorderedButtonStyle(height: 27))
            .help("Page numbers, margins, and back side rotation")
            .accessibilityLabel(Text("Print Options"))
            .popover(isPresented: $showsOptions, arrowEdge: .top) {
                PrintOptionsPopover(model: model)
            }
        }
        .padding(.leading, 16)
        .overlay(alignment: .leading) { Rectangle().fill(PrintPalette.line).frame(width: 1, height: 50) }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        VStack(spacing: 6) {
            PrinterPicker(model: model)
            actionButton("Export PDF", systemImage: "arrow.down.doc", help: "Export the imposed sheets as a PDF (⇧⌘E)")
            {
                model.exportPDF()
            }
            .disabled(!model.canOutput)
        }
        .fixedSize()
    }

    private func actionButton(
        _ title: LocalizedStringKey, systemImage: String, help: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
                    .frame(width: 15)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 130)
        }
        .buttonStyle(PrintBorderedButtonStyle(height: 27))
        .help(help)
    }

    private var note: String? {
        guard let result = model.result, let settings = model.renderedSettings else { return nil }
        return PrintModeText.note(settings.layout, pageCount: result.plan.logicalPageCount, language: model.language)
    }

    private var optionsText: String? {
        PrintModeText.options(model.printOptions, layout: model.layout, language: model.language)
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
        .buttonStyle(PrintBorderedButtonStyle(height: 27))
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

/// A layout choice with a small paper pictogram; the selected card is drawn in ai.
private struct LayoutCard: View {
    let layout: PrintLayout
    let title: String
    let help: String
    let shortcut: Int
    let isSelected: Bool
    let density: PrintPressBar.Density
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LayoutPictogram(layout: layout)
                    .frame(width: compact ? 40 : 46, height: compact ? 26 : 30)
                    .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink2)
                Text(verbatim: title)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(isSelected ? PrintPalette.ai : PrintPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 2)
            .frame(
                width: density == .regular ? 90 : density == .medium ? 80 : 68, height: density == .regular ? 72 : 66
            )
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? PrintPalette.aiTint : hovering ? PrintPalette.hover : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? PrintPalette.ai : .clear, lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if hovering && !compact {
                    Text(verbatim: "⌘\(shortcut)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(PrintPalette.ink3)
                        .padding(.top, 4)
                        .padding(.trailing, 6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: help))
        .accessibilityLabel(
            Text(verbatim: layout.displayName(language: Bundle.main.preferredLocalizations.first ?? "en"))
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var compact: Bool { density == .compact }
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
        case .booklet where layout.sheet == .a3:
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
        case .twoUp:
            var text = Path()
            text.addRect(CGRect(x: 8, y: 7.5, width: 13, height: 16))
            text.addRect(CGRect(x: 25, y: 7.5, width: 13, height: 16))
            return Parts(papers: [CGRect(x: 5, y: 4.5, width: 36, height: 22)], text: text)
        }
    }
}

/// Page numbers, margins and the back side rotation for this window, applied to the sheets right away.
struct PrintOptionsPopover: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Print Options").font(.system(size: 12.5, weight: .semibold))
            Text(verbatim: subtitle)
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink3)
                .padding(.top, 3)
                .padding(.bottom, 8)
            row("Page Numbers", hint: "Adds the page number at the bottom of each page.") {
                Toggle("Page Numbers", isOn: $model.printOptions.showsPageNumbers)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            row("Margins (mm)", hint: "Applies to text documents and images. PDFs keep their own margins.") {
                HStack(spacing: 4) {
                    TextField("Margins (mm)", value: margin, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                    Stepper("Margins (mm)", value: margin, in: Self.marginRange, step: 1).labelsHidden()
                }
                .controlSize(.small)
            }
            row(
                "Rotate Back Sides 180°",
                hint: isDuplex
                    ? "For printers that print back sides upside down, or when feeding the back sides by hand."
                    : "Available for duplex layouts (A4 Duplex and booklets)."
            ) {
                Toggle("Rotate Back Sides 180°", isOn: $model.printOptions.rotatesBackSides)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!isDuplex)
            }
        }
        .foregroundStyle(PrintPalette.ink)
        .tint(PrintPalette.ai)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
        .frame(width: 360)
    }

    static let marginRange: ClosedRange<Double> = 0...40

    private var isDuplex: Bool { model.layout.duplex != .none }

    private var subtitle: String {
        PrintModeText.format(
            "%@ · Changes appear on the sheets right away", language: model.language,
            model.layout.displayName(language: model.language))
    }

    private var margin: Binding<Double> {
        Binding(
            get: { model.printOptions.marginsInMillimeters },
            set: {
                model.printOptions.marginsInMillimeters = min(
                    max($0, Self.marginRange.lowerBound), Self.marginRange.upperBound)
            }
        )
    }

    private func row<Control: View>(
        _ title: LocalizedStringKey, hint: LocalizedStringKey, @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(PrintPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                Text(title).font(.system(size: 12.5)).frame(width: 110, alignment: .leading).padding(.top, 3)
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
