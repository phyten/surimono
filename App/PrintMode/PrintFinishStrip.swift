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
                        .frame(maxWidth: isVertical ? .infinity : nil, alignment: .leading)
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
            label: "Paper to Use", options: [.init(PaperSeries.a, "A4 / A3"), .init(PaperSeries.b, "B5 / B4")],
            selection: model.trayPaperSeries, help: "A4 and A3, or B5 and B4 (JIS)"
        ) { model.choosePaperSeries($0) }
    }
}

/// The quick choices of the print settings, between the sheets and the press bar. Everything else is in the sheet.
/// A menu is its name alone while its setting is the default and its name and value once the reader has set it, at any
/// width. The row never wraps: "All Print Settings…" stays at its right end and the menus that do not fit fold from the
/// right (`PrintStripFold`), which the sheet still offers.
struct PrintFinishStrip: View {
    @Bindable var model: DocumentViewModel
    /// What each menu takes in its current form, measured from a copy drawn out of sight: a folded menu has no view.
    @State private var widths: [Item: CGFloat] = [:]
    @State private var detailsWidth: CGFloat = 0
    @State private var rowWidth: CGFloat = 0

    enum Item: Hashable {
        case furniture, breaks, contents, notes

        var title: LocalizedStringKey {
            switch self {
            case .furniture: "Header & Footer"
            case .breaks: "Page Breaks"
            case .contents: "Contents Page"
            case .notes: "Notes"
            }
        }

        var section: PrintFinishSection {
            switch self {
            case .furniture: .furniture
            case .breaks: .breaks
            case .contents: .contents
            case .notes: .notes
            }
        }
    }

    private static let spacing: CGFloat = 8

    var body: some View {
        let items = applicableItems
        let fold = PrintStripFold(
            available: rowWidth, itemWidths: items.map { widths[$0] ?? 0 }, trailingWidth: detailsWidth,
            spacing: Self.spacing)
        HStack(spacing: Self.spacing) {
            ForEach(items.prefix(fold.visibleCount), id: \.self) { menu($0) }
            Spacer(minLength: 0)
            detailsButton
        }
        // Until everything is measured the row would show all the menus and then fold some.
        .opacity(rowWidth > 0 && detailsWidth > 0 && items.allSatisfy({ widths[$0] != nil }) ? 1 : 0)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            if rowWidth != width { rowWidth = width }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrintPalette.chrome)
        .background(alignment: .topLeading) { measurements(items) }
        .overlay(alignment: .top) { Rectangle().fill(PrintPalette.line).frame(height: 1) }
    }

    private var applicableItems: [Item] {
        var items: [Item] = [.furniture]
        if model.finishAppliesToText { items += [.breaks, .contents] }
        if model.offersNotes && model.notes.applies(to: model.layout) { items.append(.notes) }
        return items
    }

    /// The value a menu shows beside its name; nil while the setting is the default.
    private func value(of item: Item) -> LocalizedStringKey? {
        switch item {
        case .furniture: PrintFurnitureChoice.stripTitle(model.furnitureChoice)
        case .breaks: PrintChapterBreakChoice.stripTitle(model.printFinish.breaks.h1)
        case .contents: PrintContentsChoice.stripTitle(model.printFinish.toc.mode)
        case .notes: PrintNoteChoice.stripTitle(model.notes.isEnabled)
        }
    }

    private func measurements(_ items: [Item]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(items, id: \.self) { item in
                menu(item)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: { width in
                        if widths[item] != width { widths[item] = width }
                    }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var detailsButton: some View {
        Button {
            model.isPrintFinishPresented.toggle()
        } label: {
            Text("All Print Settings…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PrintPalette.ai)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(model.isPrintFinishPresented ? PrintPalette.aiTint2 : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Paper, margins, header and footer, page breaks, contents and note pages")
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { width in
            if detailsWidth != width { detailsWidth = width }
        }
    }

    private func menu(_ item: Item) -> some View {
        Menu {
            switch item {
            case .furniture: PrintFurnitureChoice(model: model).menuItems
            case .breaks: PrintChapterBreakChoice(model: model).menuItems
            case .contents: PrintContentsChoice(model: model).menuItems
            case .notes: PrintNoteChoice(model: model).menuItems
            }
            Divider()
            Button("Open in All Settings") { model.presentFinish(item.section) }
        } label: {
            let value = value(of: item)
            HStack(spacing: 5) {
                Text(item.title).foregroundStyle(value == nil ? PrintPalette.ink : PrintPalette.ink2)
                if let value { Text(value).fontWeight(.semibold).foregroundStyle(PrintPalette.ink) }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
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
        .help(Text(item.title))
    }
}

struct PrintFurnitureChoice: View {
    @Bindable var model: DocumentViewModel

    static let choices: [PrintChoice<PageFurniture.Preset>] = [
        .init(.none, "None"), .init(.number, "Page Number"), .init(.name, "File Name + Number"),
        .init(.nameAndDate, "File Name, Date + Number"), .init(.custom, "Specify Contents…"),
    ]

    var body: some View {
        // The names are long for one row of the sheet, and a gray box of five reads as a menu left open.
        PrintRadioList(
            label: "Header & Footer", options: Self.choices, selection: model.furnitureChoice,
            choose: model.chooseFurniture)
    }

    @ViewBuilder var menuItems: some View {
        ForEach(Self.choices, id: \.value) { choice in
            Button(choice.title) { model.chooseFurniture(choice.value) }
        }
    }

    /// What the strip shows beside the name; nothing while there is no header or footer.
    static func stripTitle(_ value: PageFurniture.Preset) -> LocalizedStringKey? {
        value == .none ? nil : choices.first { $0.value == value }?.title
    }
}

struct PrintChapterBreakChoice: View {
    @Bindable var model: DocumentViewModel

    static let choices: [PrintChoice<HeadingBreak>] = [
        .init(.none, "Do Not Break at Headings"), .init(.page, "New Page for Each Chapter"),
        .init(.rightPage, "Chapters from Right Page"),
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

    /// What the strip shows beside the name; nothing while headings do not break the page.
    static func stripTitle(_ value: HeadingBreak) -> LocalizedStringKey? {
        value == .none ? nil : choices.first { $0.value == value }?.title
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

    /// What the strip shows beside the name; nothing while there are no notes.
    static func stripTitle(_ isEnabled: Bool) -> LocalizedStringKey? {
        isEnabled ? "Notes On" : nil
    }
}

struct PrintContentsChoice: View {
    @Bindable var model: DocumentViewModel

    static let choices: [PrintChoice<PaperTOC.Mode>] = [
        .init(.source, "Follow the Text's Contents"), .init(.front, "Add Contents to Front"),
        .init(.hidden, "Do Not Print Contents"),
    ]

    var body: some View {
        PrintSegments(label: "Contents Page", options: Self.choices, selection: model.printFinish.toc.mode) {
            model.printFinish.toc.mode = $0
        }
    }

    @ViewBuilder var menuItems: some View {
        ForEach(Self.choices, id: \.value) { choice in
            Button(choice.title) { model.printFinish.toc.mode = choice.value }
        }
    }

    /// What the strip shows beside the name; nothing while the contents follow the text.
    static func stripTitle(_ value: PaperTOC.Mode) -> LocalizedStringKey? {
        value == .source ? nil : choices.first { $0.value == value }?.title
    }
}
