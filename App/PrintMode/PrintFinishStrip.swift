import SurimonoCore
import SwiftUI

/// Places its views in rows, starting a new row where the next view no longer fits.
struct PrintFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width, subviews: subviews)
        return CGSize(
            width: proposal.width.map { min($0, rows.map(\.width).max() ?? 0) } ?? rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = alignment == .center ? bounds.midX - row.width / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat?, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.width + (row.indices.isEmpty ? 0 : spacing) + size.width
            if let width, !row.indices.isEmpty, next > width {
                rows.append(row)
                row = Row(indices: [index], width: size.width, height: size.height)
            } else {
                row.indices.append(index)
                row.width = next
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

struct PrintChoice<Value: Hashable> {
    let value: Value
    let title: LocalizedStringKey

    init(_ value: Value, _ title: LocalizedStringKey) {
        self.value = value
        self.title = title
    }
}

/// A row of choices in the tray's own colors; the chosen one is drawn in ai.
struct PrintSegments<Value: Hashable>: View {
    let label: LocalizedStringKey
    let options: [PrintChoice<Value>]
    let selection: Value?
    var help: LocalizedStringKey?
    var isVertical = false
    let choose: (Value) -> Void

    var body: some View {
        let stack = isVertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        stack {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button {
                    choose(option.value)
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? PrintPalette.raised : PrintPalette.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? PrintPalette.ai : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(PrintPalette.hover))
        .fixedSize()
        .help(help.map { Text($0) } ?? Text(label))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

/// The two families of paper in front of the layout cards.
struct PrintSeriesSwitch: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        PrintSegments(
            label: "Paper Size", options: [.init(PaperSeries.a, "A4 / A3"), .init(PaperSeries.b, "B5 / B4")],
            selection: model.trayPaperSeries, help: "A4 and A3, or B5 and B4 (JIS)", isVertical: true
        ) { model.choosePaperSeries($0) }
    }
}

/// The quick choices of the paper's finish, between the sheets and the press bar. Everything else is in the sheet. It
/// stays one line high: a narrow window shows the choices as menus, so the sheets keep their room.
struct PrintFinishStrip: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                group("Header & Footer", section: .furniture) { PrintFurnitureChoice(model: model) }
                if model.finishAppliesToText {
                    group("Page Breaks", section: .breaks) { PrintChapterBreakChoice(model: model) }
                    group("Printed Contents", section: .contents) { PrintContentsChoice(model: model) }
                }
                if showsNotes {
                    group("Notes", section: .notes) {
                        PrintNoteChoice(model: model)
                        if model.notes.isEnabled { noteSettingsButton }
                    }
                }
                detailsButton
            }
            // The notes are the first to shrink, so that a tray of the usual width keeps the choices it always had.
            HStack(spacing: 8) {
                group("Header & Footer", section: .furniture, spacing: 4) { PrintFurnitureChoice(model: model) }
                if model.finishAppliesToText {
                    group("Page Breaks", section: .breaks, spacing: 4) { PrintChapterBreakChoice(model: model) }
                    group("Printed Contents", section: .contents, spacing: 4) { PrintContentsChoice(model: model) }
                }
                if showsNotes { noteChip }
                detailsButton
            }
            HStack(spacing: 8) {
                menu("Header & Footer", value: furnitureTitle, section: .furniture) {
                    PrintFurnitureChoice(model: model).menuItems
                }
                if model.finishAppliesToText {
                    menu("Page Breaks", value: breakTitle, section: .breaks) {
                        PrintChapterBreakChoice(model: model).menuItems
                    }
                    menu("Printed Contents", value: contentsTitle, section: .contents) {
                        PrintContentsChoice(model: model).menuItems
                    }
                }
                if showsNotes {
                    menu("Notes", value: model.notes.isEnabled ? "Notes On" : "None", section: .notes) {
                        PrintNoteChoice(model: model).menuItems
                    }
                }
                detailsButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrintPalette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
    }

    /// The notes as one word: in color when they are on, with the choices in its menu.
    private var noteChip: some View {
        Menu {
            PrintNoteChoice(model: model).menuItems
            Divider()
            Button("Open in All Settings") { model.presentFinish(.notes) }
        } label: {
            Text("Notes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.notes.isEnabled ? PrintPalette.raised : PrintPalette.ink)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(model.notes.isEnabled ? PrintPalette.ai : PrintPalette.hover)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Notes")
    }

    private var showsNotes: Bool { model.offersNotes && model.notes.applies(to: model.layout) }

    private var noteSettingsButton: some View {
        Button {
            model.presentFinish(.notes)
        } label: {
            Text(verbatim: model.notePresetName ?? String(localized: "Own Lines"))
                .font(.system(size: 12))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PrintPalette.ai)
        .help("Note page lines and templates")
    }

    private var detailsButton: some View {
        Button("All Settings…") { model.isPrintFinishPresented.toggle() }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(PrintPalette.ai)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(model.isPrintFinishPresented ? PrintPalette.aiTint2 : .clear)
            )
            .fixedSize()
            .help("Paper, margins, header and footer, page breaks, contents and note pages")
    }

    /// The title opens the item's section of the print settings.
    private func group<Content: View>(
        _ title: LocalizedStringKey, section: PrintFinishSection, spacing: CGFloat = 7,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: spacing) {
            Button {
                model.presentFinish(section)
            } label: {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .buttonStyle(.plain)
            .help("Open in All Settings")
            content()
        }
    }

    private func menu<Content: View>(
        _ title: LocalizedStringKey, value: LocalizedStringKey, section: PrintFinishSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
            Divider()
            Button("Open in All Settings") { model.presentFinish(section) }
        } label: {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(PrintPalette.ink2)
                Text(value).fontWeight(.semibold)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink2)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(PrintPalette.ink)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(PrintPalette.hover))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(title))
    }

    private var furnitureTitle: LocalizedStringKey {
        PrintFurnitureChoice.choices.first { $0.value == model.furnitureChoice }?.title ?? "None"
    }

    private var breakTitle: LocalizedStringKey {
        PrintChapterBreakChoice.choices.first { $0.value == model.printFinish.breaks.h1 }?.title ?? "None"
    }

    private var contentsTitle: LocalizedStringKey {
        PrintContentsChoice.choices.first { $0.value == model.printFinish.toc.mode }?.title ?? "None"
    }
}

struct PrintFurnitureChoice: View {
    @Bindable var model: DocumentViewModel

    static let choices: [PrintChoice<PageFurniture.Preset>] = [
        .init(.none, "None"), .init(.number, "Number"), .init(.name, "Name"), .init(.nameAndDate, "Name & Date"),
        .init(.custom, "Custom"),
    ]

    var body: some View {
        PrintSegments(
            label: "Header & Footer", options: Self.choices, selection: model.furnitureChoice,
            choose: model.chooseFurniture)
    }

    @ViewBuilder var menuItems: some View {
        ForEach(Self.choices, id: \.value) { choice in
            Button(choice.title) { model.chooseFurniture(choice.value) }
        }
    }
}

struct PrintChapterBreakChoice: View {
    @Bindable var model: DocumentViewModel

    static let choices: [PrintChoice<HeadingBreak>] = [
        .init(.none, "None"), .init(.page, "Before Chapters"), .init(.rightPage, "From Right Page"),
    ]

    var body: some View {
        PrintSegments(label: "Page Breaks", options: Self.choices, selection: model.printFinish.breaks.h1) {
            model.printFinish.breaks.h1 = $0
        }
    }

    @ViewBuilder var menuItems: some View {
        ForEach(Self.choices, id: \.value) { choice in
            Button(choice.title) { model.printFinish.breaks.h1 = choice.value }
        }
    }
}

struct PrintNoteChoice: View {
    @Bindable var model: DocumentViewModel

    static let choices: [PrintChoice<Bool>] = [.init(false, "None"), .init(true, "Notes On")]

    var body: some View {
        PrintSegments(label: "Notes", options: Self.choices, selection: model.notes.isEnabled) {
            model.notes.isEnabled = $0
        }
    }

    @ViewBuilder var menuItems: some View {
        ForEach(Self.choices, id: \.value) { choice in
            Button(choice.title) { model.notes.isEnabled = choice.value }
        }
    }
}

struct PrintContentsChoice: View {
    @Bindable var model: DocumentViewModel

    static let choices: [PrintChoice<PaperTOC.Mode>] = [
        .init(.source, "As in the Document"), .init(.front, "Add to Front"), .init(.hidden, "Do Not Print"),
    ]

    var body: some View {
        PrintSegments(label: "Printed Contents", options: Self.choices, selection: model.printFinish.toc.mode) {
            model.printFinish.toc.mode = $0
        }
    }

    @ViewBuilder var menuItems: some View {
        ForEach(Self.choices, id: \.value) { choice in
            Button(choice.title) { model.printFinish.toc.mode = choice.value }
        }
    }
}
