import SwiftUI

struct BandHintPlacement: Layout {
    let rect: CGRect
    let above: Bool
    let canFlip: Bool
    let bandHeights: BandRoom

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let singleLine = ceil(card.sizeThatFits(.unspecified).width)
        let width = min(max(160, singleLine), 300, max(1, bounds.width - 16))
        let size = card.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let x = max(8, min(rect.midX - width / 2, bounds.width - width - 8))
        // A control can be shorter than its band. Measure the gap from the painted edge.
        let belowY = max(rect.maxY, bandHeights.top) + 6
        let aboveY = min(rect.minY, bounds.height - bandHeights.bottom) - 6 - size.height
        let y = above || (canFlip && belowY + size.height > bounds.height - 8) ? aboveY : belowY
        card.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + max(8, min(y, bounds.height - size.height - 8))),
            anchor: .topLeading, proposal: ProposedViewSize(width: width, height: size.height))
    }
}

struct BandHintCard: View {
    struct Colors {
        let name: Color
        var secondary: Color { name.opacity(0.80) }
        let active: Color
        let paper: Color

        init(dark: Bool, increasedContrast: Bool) {
            func swatch(_ swatch: PrintPalette.Swatch) -> Color {
                Color(
                    nsColor: swatch.resolved(
                        dark: dark, increasedContrast: increasedContrast, reduceTransparency: false))
            }
            name = swatch(.ink)
            active = dark ? Color(.sRGB, red: 147 / 255, green: 192 / 255, blue: 240 / 255) : swatch(.ai)
            paper = dark ? Color(.sRGB, red: 39 / 255, green: 49 / 255, blue: 61 / 255) : swatch(.raised)
        }
    }

    let content: BandHintContent
    var showName = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let colors = Colors(dark: dark, increasedContrast: DisplayAccessibility.shared.options.increasedContrast)
        let shape = RoundedRectangle(cornerRadius: BandDesign.hintRadius(AppPreferences.shared.corners))
        VStack(alignment: .leading, spacing: 3) {
            if showName || content.state != nil || !content.shortcut.isEmpty {
                HStack(spacing: 6) {
                    if showName {
                        Text(verbatim: content.name).font(.system(size: 12, weight: .medium)).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    if let state = content.state {
                        Text(verbatim: state).font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(content.active ? colors.active : colors.secondary)
                    }
                    if !content.shortcut.isEmpty {
                        Spacer(minLength: 0)
                        Text(verbatim: content.shortcut).font(.system(size: 11, weight: .medium)).fixedSize()
                            .foregroundStyle(colors.secondary)
                    }
                }
            }
            Text(verbatim: content.reason ?? content.detail)
                .font(.system(size: 12))
                .foregroundStyle(colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(colors.name)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(colors.paper))
        .shadow(color: .black.opacity(dark ? 0.24 : 0.12), radius: 6, y: 2)
    }
}
