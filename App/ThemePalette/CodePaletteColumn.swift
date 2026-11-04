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
                LazyVStack(alignment: .leading, spacing: 2) {
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
            Text("Code Colors").font(.system(size: 14, weight: .semibold)).fixedSize()
            Spacer(minLength: 4)
            Text("Stays when the style changes")
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
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// A palette, or "Match Style" for nil: its name, what it costs on paper, and a line of code in its colors.
private struct CodePaletteRow: View {
    let model: DocumentViewModel
    let palette: CodePalette?
    @State private var isHovering = false

    private var id: String { palette?.id ?? CodePalette.matchesStyleID }

    var body: some View {
        let isCurrent = id == model.codePaletteID
        Button {
            model.selectCodePalette(id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: model.codePaletteName(id))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let badge {
                        Text(verbatim: badge)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                sample
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(rowFill(isCurrent: isCurrent))
            )
            .overlay {
                if isCurrent { RoundedRectangle(cornerRadius: 8).strokeBorder(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
            if inside { model.tryCodePalette(id) }
        }
        .accessibilityLabel(Text(verbatim: model.codePaletteName(id)))
        .accessibilityValue(Text(verbatim: [note, badge ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func rowFill(isCurrent: Bool) -> AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(.tint.opacity(0.14)) }
        return AnyShapeStyle(isHovering ? Color.primary.opacity(0.06) : .clear)
    }

    /// The current style for "Match Style", whose colors it takes.
    private var note: String {
        guard let palette else {
            return model.theme(model.themeID)?.displayName(language: model.language) ?? model.themeID
        }
        return palette.displayNote(language: model.language)
    }

    private var badge: String? {
        guard let palette else { return nil }
        let ink =
            switch palette.inkLevel {
            case .low: String(localized: "Ink: Low")
            case .normal: String(localized: "Ink: Normal")
            case .raised: String(localized: "Ink: Slightly High")
            case .high: String(localized: "Ink: High")
            }
        return String(format: "%.1f:1", palette.minimumContrast) + " · " + ink
    }

    /// Always on paper, in both appearances: the sample shows how the code prints.
    private var sample: some View {
        Text(sampleText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(codeHex: palette?.ground ?? "#ffffff")))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
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
            row("Language Label", selection: $model.codeBlock.languageLabel) {
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
