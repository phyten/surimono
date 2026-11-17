import SurimonoCore
import SwiftUI

/// The second column of the style palette: how the document's code is colored and set, whatever the style. Resting
/// the pointer on a row tries it on the paper, as a theme's sample does.
struct CodePaletteColumn: View {
    @Bindable var model: DocumentViewModel

    static let width: CGFloat = 310

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    groupTitle("Color Schemes")
                    CodePaletteRow(model: model, palette: nil)
                    groupTitle("Suggested")
                    ForEach(palettes(in: .candidate)) { CodePaletteRow(model: model, palette: $0) }
                    groupTitle("Uses More Ink")
                    ForEach(palettes(in: .inkHeavy)) { CodePaletteRow(model: model, palette: $0) }
                }
                .padding(8)
            }
            .onHover { inside in if !inside { model.endThemeTrial() } }
            Divider()
            CodeBlockControls(model: model)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Code Appearance").font(.system(size: 14, weight: .semibold)).fixedSize()
            Spacer(minLength: 4)
            Text("Chosen apart from the style")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func palettes(in group: CodePalette.Group) -> [CodePalette] {
        model.library.codePalettes.filter { $0.group == group }
    }

    private func groupTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            // In line with the names, past the rows' place for the check.
            .padding(.leading, 20)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// How a palette's ink is told on its row. The usual amount goes unsaid, so that the few palettes that use more stand
/// out, instead of every row repeating "Normal". Less ink goes unsaid too: the palette that uses less is named for it
/// (Ink Saver).
enum CodeInkNote {
    static func text(for level: CodePalette.InkLevel) -> String? {
        switch level {
        case .low, .normal: nil
        case .raised: String(localized: "Ink: Slightly High")
        case .high: String(localized: "Ink: High")
        }
    }
}

/// A palette, or "Match Style" for nil: its name, what it costs on paper, and a line of code in its colors. The rows are
/// a plain list: no box per row, and the chosen one is told by a check before its name.
private struct CodePaletteRow: View {
    let model: DocumentViewModel
    let palette: CodePalette?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var id: String { palette?.id ?? CodePalette.matchesStyleID }

    var body: some View {
        let isCurrent = id == model.codePaletteID
        Button {
            model.selectCodePalette(id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PrintPalette.ai)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: Self.checkWidth)
                    .accessibilityHidden(true)
                // The name sits close to its own sample and further from the next scheme, so each pair reads as one.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: model.codePaletteName(id))
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                        // The ink follows the description it qualifies; at the far edge it read as a separate column.
                        // A palette whose name says it all has no description, and its row shows the name alone.
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            if !note.isEmpty {
                                Text(verbatim: note)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if let badge {
                                Text(verbatim: note.isEmpty ? badge : " · " + badge)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    sample
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
            if inside { model.tryCodePalette(id) }
        }
        .accessibilityLabel(Text(verbatim: model.codePaletteName(id)))
        .help(contrast.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .accessibilityValue(
            Text(verbatim: [note, badge ?? "", contrast ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        )
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private static let checkWidth: CGFloat = 14

    /// The current style for "Match Style", whose colors it takes.
    private var note: String {
        guard let palette else {
            return model.theme(model.themeID)?.displayName(language: model.language) ?? model.themeID
        }
        return palette.displayNote(language: model.language)
    }

    /// The ink, unless the group's own name ("Uses More Ink") already says it.
    private var badge: String? {
        guard let palette, !(palette.group == .inkHeavy && [.raised, .high].contains(palette.inkLevel)) else {
            return nil
        }
        return CodeInkNote.text(for: palette.inkLevel)
    }

    private var contrast: String? {
        palette.map {
            String(format: String(localized: "Text contrast %@"), String(format: "%.1f:1", $0.minimumContrast))
        }
    }

    /// The code as it prints. On white paper it needs no frame; a palette with a ground of its own shows it behind the
    /// line, and in the dark appearance every sample keeps its paper, or dark ink would vanish into the popover.
    private var sample: some View {
        let ground = palette?.ground
        let showsGround = ground != nil || colorScheme == .dark
        return Text(sampleText)
            .lineLimit(1)
            .padding(.horizontal, showsGround ? 6 : 0)
            .padding(.vertical, showsGround ? 3 : 0)
            .background {
                if showsGround {
                    RoundedRectangle(cornerRadius: 4).fill(Color(codeHex: ground ?? "#ffffff"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sampleText: AttributedString {
        let colors =
            palette?.colors
            ?? model.theme(model.themeID).map { CodePalette.colors(inStyleSheet: $0.css) } ?? [:]
        let japanese = model.language.hasPrefix("ja")
        let parts: [(String, CodePalette.Token?)] = [
            ("func", .keyword), (" ", nil), (japanese ? "貸す" : "lend", .function), ("(", nil), ("Book", .type),
            (", ", nil), ("14", .number), (") ", nil), (japanese ? "\"星\"" : "\"star\"", .string), (" ", nil),
            (japanese ? "// 夜" : "// night", .comment),
        ]
        return parts.reduce(into: AttributedString()) { result, part in
            var piece = AttributedString(part.0)
            let face = part.1.map { palette?.face(for: $0) ?? .standard(for: $0) }
            var font = Font.system(
                size: 11, weight: Font.Weight(cssWeight: face?.weight ?? 400), design: .monospaced)
            if face?.isItalic == true { font = font.italic() }
            piece.font = font
            piece.foregroundColor = Color(codeHex: part.1.flatMap { colors[$0] } ?? palette?.ink ?? plainInk)
            result += piece
        }
    }

    private var plainInk: String { palette?.ground == nil ? "#1e1e20" : "#e6e8ec" }
}

/// How the block around the code is set, small under the colors: the choices are few and rarely changed.
private struct CodeBlockControls: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("Frame", selection: $model.codeBlock.frame) {
                Text("Match Style").tag(CodeBlockOptions.Frame.style)
                Text("No Frame").tag(CodeBlockOptions.Frame.none)
                Text("Pale Ground").tag(CodeBlockOptions.Frame.tint)
                Text("Thin Border").tag(CodeBlockOptions.Frame.rule)
                Text("Left Line").tag(CodeBlockOptions.Frame.left)
            }
            row("Line Numbers", selection: $model.codeBlock.lineNumbers) {
                Text("No Numbers").tag(CodeBlockOptions.LineNumbers.none)
                Text("Every Line").tag(CodeBlockOptions.LineNumbers.all)
                Text("Every 5 Lines").tag(CodeBlockOptions.LineNumbers.everyFive)
            }
            row("Long Lines", selection: $model.codeBlock.longLines) {
                Text("Wrap").tag(CodeBlockOptions.LongLines.wrap)
                Text("Shrink the Text").tag(CodeBlockOptions.LongLines.shrink)
                Text("Cut with a Mark").tag(CodeBlockOptions.LongLines.cut)
            }
            row("Language Name", selection: $model.codeBlock.languageLabel) {
                Text("No Label").tag(CodeBlockOptions.LanguageLabel.none)
                Text("Top Right").tag(CodeBlockOptions.LanguageLabel.corner)
                Text("Top Band").tag(CodeBlockOptions.LanguageLabel.band)
            }
        }
        .controlSize(.small)
    }

    private func row<Value: Hashable, Choices: View>(
        _ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder choices: () -> Choices
    ) -> some View {
        GridRow {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Picker(title, selection: selection, content: choices)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Color {
    /// A color of the code palettes, in sRGB as the page prints it.
    init(codeHex hex: String) {
        let color = CodeColor.components(hex) ?? (0, 0, 0)
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

extension Font.Weight {
    fileprivate init(cssWeight: Int) {
        switch cssWeight {
        case 700...: self = .bold
        case 600...: self = .semibold
        case 500...: self = .medium
        default: self = .regular
        }
    }
}
