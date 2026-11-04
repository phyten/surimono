import SurimonoCore
import SurimonoRendering
import SwiftUI

/// The note pages' part of the paper's finish: where they go, a shelf of presets, and the lines themselves.
struct PrintNoteSection: View {
    @Bindable var model: DocumentViewModel
    @State private var shelf = Shelf.practical
    @State private var saveName = ""

    init(model: DocumentViewModel) {
        self.model = model
    }

    private enum Shelf: Hashable { case practical, cute, own }

    private static let placements: [PrintChoice<NotePagePlan.Placement>] = [
        .init(.spreadLeft, "Notes on Left"), .init(.spreadRight, "Notes on Right"), .init(.duplexBack, "On the Back"),
        .init(.chapterEnd, "After Chapters"),
    ]

    private static let kinds: [(kind: NotePaperStyle.Kind, title: LocalizedStringKey)] = [
        (.ruled, "Ruled"), (.grid, "Grid"), (.dot, "Dots"), (.dotted, "Dotted Lines"), (.dashed, "Dashed Lines"),
        (.wavy, "Wavy Lines"), (.plain, "Plain"), (.cornell, "Cornell"), (.genko, "Manuscript Paper"),
        (.staff, "Music Staff"), (.table, "Table"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.notes.applies(to: model.layout) {
                hint("The 3-up handout has a notes column of its own, so it takes no note pages.")
            } else {
                PrintNoteChoice(model: model)
            }
            if model.notes.isEnabled, model.notes.applies(to: model.layout) {
                placement
                presets
                lineKinds
                lineSettings
                headerChoices
                savedPresets
            }
        }
        .onAppear {
            if model.selectedOwnNotePreset != nil {
                shelf = .own
            } else if let id = model.notes.presetID, NotePaperPreset.preset(id: id)?.group == .cute {
                shelf = .cute
            }
            saveName = model.preferences.nextNotePresetName
        }
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
            .padding(.top, 12)
            .padding(.bottom, 5)
    }

    // MARK: Placement

    @ViewBuilder private var placement: some View {
        subheading("Placement")
        PrintSegments(label: "Placement", options: Self.placements, selection: model.notes.placement) {
            model.notes.placement = $0
        }
        if let text = placementHint { hint(text) }
    }

    private var placementHint: LocalizedStringKey? {
        if model.notes.placement == .chapterEnd {
            return "One page after each chapter, or after the last page when the document has no chapters."
        }
        if model.layout.kind == .normal, model.layout.duplex == .none {
            return "One-sided sheets have no backs or spreads, so note pages print on sheets of their own."
        }
        if model.layout.kind == .twoUp, model.notes.placement == .duplexBack {
            return "2-up sheets have no backs, so each note page prints beside its page."
        }
        return nil
    }

    // MARK: Presets

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            subheading("Presets").padding(.bottom, -3)
            PrintSegments(
                label: "Presets",
                options: [
                    .init(Shelf.practical, "Practical"), .init(Shelf.cute, "Cute"), .init(Shelf.own, "Yours"),
                ], selection: shelf
            ) { shelf = $0 }
            switch shelf {
            case .practical: shelfGrid(builtIn(.practical))
            case .cute: shelfGrid(builtIn(.cute))
            case .own:
                if model.preferences.notePresets.isEmpty {
                    Text("Presets you save appear here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PrintPalette.ink2)
                } else {
                    shelfGrid(model.preferences.notePresets.map(Card.init))
                }
            }
        }
    }

    private struct Card: Identifiable {
        let id: String
        let name: Text
        let style: NotePaperStyle
        var isOwn = false

        init(_ preset: NotePaperPreset) {
            id = preset.id
            name = Text(LocalizedStringKey(preset.englishName))
            style = preset.style
        }

        init(_ preset: NoteUserPreset) {
            id = preset.id
            name = Text(verbatim: preset.name)
            style = preset.style
            isOwn = true
        }
    }

    private func builtIn(_ group: NotePaperPreset.Group) -> [Card] {
        NotePaperPreset.all.filter { $0.group == group }.map(Card.init)
    }

    private func shelfGrid(_ cards: [Card]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: 5), spacing: 2) {
            ForEach(cards) { card in
                let isOn = card.id == model.notes.presetID
                Button {
                    model.chooseNotePreset(id: card.id, style: card.style)
                } label: {
                    VStack(spacing: 3) {
                        NoteSwatch(
                            style: Self.shelfStyle(card.style), pageSize: PaperSize.a4.size,
                            size: CGSize(width: 70, height: 70), lineScale: 3.6
                        )
                        .overlay(Rectangle().strokeBorder(PrintPalette.paperRing, lineWidth: 1))
                        card.name
                            .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(3)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? PrintPalette.aiTint2 : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7).strokeBorder(isOn ? PrintPalette.ai : .clear, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .contextMenu {
                    if card.isOwn {
                        Button("Delete", role: .destructive) { model.removeNotePreset(card.id) }
                    }
                }
            }
        }
    }

    /// On a card a page is a few centimetres wide, so its ruling is drawn wider apart to stay legible.
    private static func shelfStyle(_ style: NotePaperStyle) -> NotePaperStyle {
        var style = style
        style.spacingInMillimeters *= 1.7
        style.header = .init(date: false, title: false, pageNumber: false)
        return style
    }

    // MARK: Lines

    @ViewBuilder private var lineKinds: some View {
        subheading("Line Style")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3, alignment: .top), count: 4), spacing: 3) {
            ForEach(Self.kinds, id: \.kind) { item in
                let isOn = item.kind == model.notes.style.kind
                Button {
                    model.notes.style.kind = item.kind
                } label: {
                    VStack(spacing: 2) {
                        NoteSwatch(
                            style: NotePaperStyle(
                                kind: item.kind, weightInMillimeters: 0.5, spacingInMillimeters: 5,
                                marginInMillimeters: 3, colorHex: "#57585D",
                                header: .init(date: false, title: false, pageNumber: false)),
                            pageSize: CGSize(width: 34 * 72 / 25.4, height: 24 * 72 / 25.4),
                            size: CGSize(width: 34, height: 24)
                        )
                        .frame(width: 34, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(PrintPalette.line2, lineWidth: 1))
                        Text(item.title)
                            .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? PrintPalette.ink : PrintPalette.ink2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? PrintPalette.aiTint2 : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? PrintPalette.ai : .clear, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var lineSettings: some View {
        VStack(spacing: 0) {
            slider(
                "Thickness", value: $model.notes.style.weightInMillimeters, range: 0.1...1, step: 0.05,
                text: String(format: "%.2f mm", model.notes.style.weightInMillimeters))
            slider(
                "Spacing", value: $model.notes.style.spacingInMillimeters, range: 3...15, step: 0.5,
                text: String(format: "%.1f mm", model.notes.style.spacingInMillimeters))
            slider(
                "Margin", value: $model.notes.style.marginInMillimeters, range: 5...25, step: 1,
                text: String(format: "%.0f mm", model.notes.style.marginInMillimeters))
            colors
        }
        .padding(.top, 10)
        if model.notes.style.isFaint {
            Text("The lines are faint and may fade when printed")
                .font(.system(size: 11.5))
                .foregroundStyle(PrintPalette.warn)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(PrintPalette.warnTint))
                .padding(.top, 6)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private func slider(
        _ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(PrintPalette.ink2)
                .frame(width: 60, alignment: .leading)
            // Rounded here rather than with the slider's step, which would draw a tick for every value.
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = (($0 / step).rounded() * step * 100).rounded() / 100 }),
                in: range
            ) { Text(title) }
            .labelsHidden()
            .controlSize(.small)
            Text(verbatim: text)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 26)
    }

    private var colors: some View {
        HStack(spacing: 8) {
            Text("Color")
                .font(.system(size: 12))
                .foregroundStyle(PrintPalette.ink2)
                .frame(width: 60, alignment: .leading)
            HStack(spacing: 7) {
                ForEach(NotePaperStyle.palette, id: \.hex) { color in
                    let isOn = color.hex == model.notes.style.colorHex
                    Button {
                        model.notes.style.colorHex = color.hex
                    } label: {
                        Circle()
                            .fill(Self.color(color.hex))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(PrintPalette.line3, lineWidth: 1))
                            .padding(2)
                            .overlay(Circle().strokeBorder(isOn ? PrintPalette.ai : .clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(LocalizedStringKey(color.name)))
                    .accessibilityLabel(Text(LocalizedStringKey(color.name)))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }

    private static func color(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(
            .sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255, opacity: 1)
    }

    @ViewBuilder private var headerChoices: some View {
        subheading("Header")
        HStack(spacing: 5) {
            chip("Date Field", isOn: $model.notes.style.header.date)
            chip("Title Field", isOn: $model.notes.style.header.title)
            chip("Page Number", isOn: $model.notes.style.header.pageNumber)
        }
    }

    private func chip(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isOn.wrappedValue ? .semibold : .regular))
                .foregroundStyle(isOn.wrappedValue ? PrintPalette.ink : PrintPalette.ink2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(isOn.wrappedValue ? PrintPalette.aiTint2 : .clear))
                .overlay(Capsule().strokeBorder(isOn.wrappedValue ? PrintPalette.ai : PrintPalette.line2, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    // MARK: Saving

    @ViewBuilder private var savedPresets: some View {
        HStack(spacing: 6) {
            Text("Your Presets").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(PrintPalette.ink2)
            if let name = model.notePresetName {
                Group {
                    if model.isNoteStyleChanged {
                        Text("Changed from \(name)")
                    } else {
                        Text(verbatim: name)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(PrintPalette.ink3)
                .lineLimit(1)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 5)
        HStack(spacing: 6) {
            TextField("Preset Name", text: $saveName, prompt: Text(verbatim: ""))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Button {
                model.saveNotePreset(named: saveName)
                saveName = model.preferences.nextNotePresetName
                shelf = .own
            } label: {
                Text("Save").padding(.horizontal, 8)
            }
            .buttonStyle(PrintBorderedButtonStyle())
            .fixedSize()
            Button {
                model.overwriteNotePreset()
            } label: {
                Text("Overwrite").padding(.horizontal, 8)
            }
            .buttonStyle(PrintBorderedButtonStyle())
            .fixedSize()
            .disabled(model.selectedOwnNotePreset == nil || !model.isNoteStyleChanged)
        }
        saveState
    }

    @ViewBuilder private var saveState: some View {
        if let preset = model.selectedOwnNotePreset {
            if model.isNoteStyleChanged {
                hint("Overwrite replaces “\(preset.name)”.")
            } else {
                hint("Using “\(preset.name)”.")
            }
        } else {
            hint("Built-in presets are saved under a new name.")
        }
    }
}

/// A note page as a small picture. Each style is drawn once, since the sheet shows many and redraws often.
struct NoteSwatch: View {
    let style: NotePaperStyle
    let pageSize: CGSize
    let size: CGSize
    var lineScale = 1.0

    private struct Key: Hashable {
        let style: NotePaperStyle
        let width: CGFloat
        let height: CGFloat
        let pageWidth: CGFloat
        let lineScale: Double
    }

    private static var images: [Key: CGImage] = [:]
    private static let imageLimit = 128

    private var image: CGImage? {
        let key = Key(
            style: style, width: size.width, height: size.height, pageWidth: pageSize.width, lineScale: lineScale)
        if let image = Self.images[key] { return image }
        guard
            let image = NotePageDrawing.swatch(style: style, pageSize: pageSize, size: size, lineScale: lineScale)
        else { return nil }
        if Self.images.count >= Self.imageLimit { Self.images.removeAll() }
        Self.images[key] = image
        return image
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFit()
            } else {
                PrintPalette.paper
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
    }
}
